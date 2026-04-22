#!/usr/bin/env bash
# build-linux-release.sh
#
# Reproduce the upstream GitHub Actions "Build & Publish" workflow on a single
# Linux host using Docker. Produces the same release artifact that
# cs2-server-manager expects to download:
#
#     counterstrikesharp-with-runtime-linux-<VERSION>.zip
#
# All heavy lifting runs in containers so the host only needs:
#   - docker (engine, rootless or rooted)
#   - gh (only if you want this script to publish the release for you)
#   - git, bash (obviously)
#
# Usage:
#   ./scripts/build-linux-release.sh                         # build only, writes dist/
#   ./scripts/build-linux-release.sh v1.0.365-ag2            # build + tag the zip with this version
#   ./scripts/build-linux-release.sh v1.0.365-ag2 --publish  # build + gh release create on the origin remote
#
# Env overrides:
#   STEAMRT_IMAGE     Docker image for the native build (default: the upstream one).
#   DOTNET_IMAGE      Docker image for the managed build (default: mcr.microsoft.com/dotnet/sdk:8.0).
#   ASPNETCORE_URL    Tarball URL for the bundled ASP.NET Core runtime.
#   JOBS              Parallel build jobs (default: nproc).
#   SKIP_SUBMODULES   If set to "1", skip 'git submodule update --init --recursive'.
#   RELEASE_REPO      Passed to 'gh release create --repo' (default: current "origin" remote).
#
# Notes:
#   * The native .so MUST be built inside the Steam Runtime Sniper SDK or its
#     libstdc++/glibc will mismatch CS2's libtier0.so and you'll get
#     "undefined symbol" errors on load.
#   * Runs containers as $(id -u):$(id -g) so build outputs aren't root-owned.

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

STEAMRT_IMAGE="${STEAMRT_IMAGE:-registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest}"
DOTNET_IMAGE="${DOTNET_IMAGE:-mcr.microsoft.com/dotnet/sdk:8.0}"
# Same runtime version the upstream workflow bundles. Kept in sync manually.
ASPNETCORE_URL="${ASPNETCORE_URL:-https://download.visualstudio.microsoft.com/download/pr/c1371dc2-eed2-47be-9af3-ae060dbe3c7d/bd509e0a87629764ed47608466d183e6/aspnetcore-runtime-8.0.3-linux-x64.tar.gz}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------

VERSION="${1:-}"
PUBLISH=0
if [[ "${2:-}" == "--publish" ]]; then
    PUBLISH=1
fi

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$VERSION" ]]; then
    # Fall back to a sensible auto-version if the user didn't pass one.
    VERSION="$(git describe --tags --dirty --always 2>/dev/null || echo 'v0.0.0-dev')"
fi

# Strip a leading 'v' for the artifact filename to match upstream convention
# (counterstrikesharp-with-runtime-linux-1.0.365-ag2.zip, not ...-v1.0.365-ag2.zip).
VERSION_BARE="${VERSION#v}"
ZIP_NAME="counterstrikesharp-with-runtime-linux-${VERSION_BARE}.zip"

BUILD_DIR="$REPO_ROOT/build"
OUTPUT_DIR="$BUILD_DIR/output"
API_OUT="$BUILD_DIR/api-publish"
DIST_DIR="$REPO_ROOT/dist"

UID_GID="$(id -u):$(id -g)"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
docker info >/dev/null 2>&1      || die "docker daemon not reachable. Start Docker or fix permissions."

log "Version      : $VERSION"
log "Zip name     : $ZIP_NAME"
log "Jobs         : $JOBS"
log "Steam RT     : $STEAMRT_IMAGE"
log "dotnet SDK   : $DOTNET_IMAGE"

# --------------------------------------------------------------------------
# 1. Submodules
# --------------------------------------------------------------------------

if [[ "${SKIP_SUBMODULES:-}" != "1" ]]; then
    log "Initialising submodules (this may take a while on first run) ..."
    git submodule update --init --recursive --jobs "$JOBS"
else
    log "Skipping submodule init (SKIP_SUBMODULES=1)"
fi

# --------------------------------------------------------------------------
# 2. Clean previous outputs
# --------------------------------------------------------------------------

log "Cleaning previous outputs ..."
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$API_OUT" "$DIST_DIR"

# --------------------------------------------------------------------------
# 3. Native build (inside Steam Runtime Sniper SDK container)
# --------------------------------------------------------------------------

log "Pulling Steam Runtime image (cached on subsequent runs) ..."
docker pull "$STEAMRT_IMAGE"

log "Building counterstrikesharp.so inside Steam Runtime Sniper SDK ..."
docker run --rm \
    --user "$UID_GID" \
    -v "$REPO_ROOT":/work \
    -w /work \
    -e HOME=/tmp \
    "$STEAMRT_IMAGE" \
    bash -c "
        set -euo pipefail
        mkdir -p build
        cd build
        cmake -G Ninja -DCMAKE_BUILD_TYPE=Release ..
        cmake --build . --config Release -- -j${JOBS}
    "

# CMake already places addons/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so
# under build/ and the PRE_BUILD step copies configs/ into build/. Hoist that
# tree into build/output/ to match the upstream "counterstrikesharp-linux-*"
# artifact layout.
log "Staging native artifact tree ..."
mv "$BUILD_DIR/addons" "$OUTPUT_DIR/addons"

# --------------------------------------------------------------------------
# 4. Managed build (inside .NET 8 SDK container)
# --------------------------------------------------------------------------

log "Publishing CounterStrikeSharp.API with dotnet 8 ..."
docker run --rm \
    --user "$UID_GID" \
    -v "$REPO_ROOT":/work \
    -w /work \
    -e HOME=/tmp \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    -e DOTNET_NOLOGO=1 \
    "$DOTNET_IMAGE" \
    bash -c "
        set -euo pipefail
        dotnet restore managed/CounterStrikeSharp.sln
        dotnet publish -c Release \
            /p:Version=${VERSION_BARE} \
            /p:AssemblyVersion=${VERSION_BARE%%-*}.0 \
            /p:InformationalVersion=${VERSION_BARE} \
            -o /work/build/api-publish \
            managed/CounterStrikeSharp.API
    "

log "Injecting API publish output into addons/counterstrikesharp/api/ ..."
mkdir -p "$OUTPUT_DIR/addons/counterstrikesharp/api"
cp -r "$API_OUT"/. "$OUTPUT_DIR/addons/counterstrikesharp/api/"

# --------------------------------------------------------------------------
# 5. Bundle ASP.NET Core runtime
# --------------------------------------------------------------------------

log "Downloading ASP.NET Core runtime ..."
RUNTIME_TGZ="$BUILD_DIR/aspnetcore-runtime.tar.gz"
curl -fSL "$ASPNETCORE_URL" -o "$RUNTIME_TGZ"

log "Extracting runtime into addons/counterstrikesharp/dotnet/ ..."
mkdir -p "$OUTPUT_DIR/addons/counterstrikesharp/dotnet"
tar -xzf "$RUNTIME_TGZ" -C "$OUTPUT_DIR/addons/counterstrikesharp/dotnet"

# --------------------------------------------------------------------------
# 6. Package
# --------------------------------------------------------------------------

log "Creating $ZIP_NAME ..."
(
    cd "$OUTPUT_DIR"
    zip -qq -r "$DIST_DIR/$ZIP_NAME" .
)

log "Artifact ready: $DIST_DIR/$ZIP_NAME"
ls -lh "$DIST_DIR/$ZIP_NAME"
( cd "$DIST_DIR" && sha256sum "$ZIP_NAME" | tee "$ZIP_NAME.sha256" )

# --------------------------------------------------------------------------
# 7. Optional: publish GitHub release
# --------------------------------------------------------------------------

if [[ "$PUBLISH" == "1" ]]; then
    command -v gh >/dev/null 2>&1 || die "gh CLI not found; install it or drop --publish and upload manually."
    gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated; run 'gh auth login' first."

    REPO_FLAG=()
    if [[ -n "${RELEASE_REPO:-}" ]]; then
        REPO_FLAG=(--repo "$RELEASE_REPO")
    fi

    BUILD_HOST="$(hostname)"
    BUILD_TS="$(date -u +%FT%TZ)"
    SHA256_LINE="$(cat "$DIST_DIR/$ZIP_NAME.sha256")"
    RELEASE_NOTES=$(cat <<EOF_NOTES
Automated build of CounterStrikeSharp ${VERSION}.

Produced by scripts/build-linux-release.sh on ${BUILD_HOST} at ${BUILD_TS}.

SHA-256 of the Linux runtime zip:
${SHA256_LINE}
EOF_NOTES
)

    log "Creating GitHub release $VERSION ..."
    gh release create "$VERSION" \
        "${REPO_FLAG[@]}" \
        --title "CounterStrikeSharp $VERSION" \
        --notes "$RELEASE_NOTES" \
        "$DIST_DIR/$ZIP_NAME" \
        "$DIST_DIR/$ZIP_NAME.sha256"

    log "Release published."
else
    cat <<EOF

Next step: attach the artifact to a GitHub release on your fork.
If you have gh CLI:

    gh release create $VERSION \\
        --repo jibsonline/CounterStrikeSharp \\
        --title "CounterStrikeSharp $VERSION" \\
        --notes "Rebuild against CS2 AnimGraph2 engine (fix/ag2-update)." \\
        $DIST_DIR/$ZIP_NAME \\
        $DIST_DIR/$ZIP_NAME.sha256

Or upload manually via the GitHub UI.
EOF
fi
