#!/bin/bash
# Build a self-contained APK with all game data bundled inside.
#
# The game data (~2.7GB) is tarred into android/app/src/main/assets/gamedata.tar.
# On first launch, the engine extracts it to the app's internal files directory.
# On subsequent launches, extraction is skipped (marker file exists).
#
# Usage: ./scripts/build/android/build-apk-bundled.sh [--install]
#   --install  Install the APK to a connected device after building.
set -euo pipefail

DO_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        *) echo "ERROR: unknown argument '$arg'"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ANDROID_DIR="${PROJECT_ROOT}/android"
ASSETS_DIR="${ANDROID_DIR}/app/src/main/assets"
GAME_DATA="${GX_GAME_DATA:-${PROJECT_ROOT}/build/gamedata}"

echo "==> Building self-contained APK with bundled game data"

if [[ ! -d "${GAME_DATA}" ]]; then
    echo "ERROR: Game data not found at ${GAME_DATA}"
    echo "  Set GX_GAME_DATA or stage your game files in build/gamedata/"
    exit 1
fi

echo "==> Staging game data tar into assets (this takes a minute)..."
mkdir -p "${ASSETS_DIR}"
tar cf "${ASSETS_DIR}/gamedata.tar" -C "${GAME_DATA}" .
TAR_SIZE=$(du -h "${ASSETS_DIR}/gamedata.tar" | cut -f1)
echo "    gamedata.tar: ${TAR_SIZE}"

echo "==> Building APK (Gradle assembleDebug)..."
cd "${ANDROID_DIR}"
gradle assembleDebug --no-daemon --console=plain 2>&1 | tail -10

APK="${ANDROID_DIR}/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -f "${APK}" ]]; then
    echo "ERROR: no APK produced"
    exit 1
fi
APK_SIZE=$(du -h "${APK}" | cut -f1)
echo "==> APK ready: ${APK} (${APK_SIZE})"

if [[ "${DO_INSTALL}" == "1" ]]; then
    echo "==> Installing to connected device..."
    adb install -r "${APK}"
    echo "==> Installed. First launch will extract game data (~2.7GB) — be patient."
fi

# Clean up the large tar from the source tree (it's now in the APK).
rm -f "${ASSETS_DIR}/gamedata.tar"
echo "==> Done"
