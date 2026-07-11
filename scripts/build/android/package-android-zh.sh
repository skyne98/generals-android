#!/bin/bash
# Package the Android build of Zero Hour into a signed APK and optionally install.
#
# Flow (parallels scripts/build/ios/package-ios-zh.sh):
#   1. Stage native .so libs into android/app/src/main/jniLibs/arm64-v8a/.
#   2. Vendor SDL3's Java sources (SDLActivity et al.) into the app java tree.
#   3. Gradle assembleDebug + sign (debug key).
#   4. Optional: adb install to a connected device.
#
# GameData (~2.7 GB) is NOT bundled in the APK. The engine chdir's to the app's
# data dir (HOME, set by SDL3's Android backend) on launch; sideload your owned
# copy there: adb push <GameData> /data/data/com.generalsx.android/files/
# (debug build, via run-as) — see ANDROID_PORT_PLAN.md §4.
#
# Usage: ./scripts/build/android/package-android-zh.sh [--install]
set -euo pipefail

DO_INSTALL=0
PUSH_DATA=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        --push-data) PUSH_DATA=1 ;;
        *) echo "ERROR: unknown argument '$arg' (usage: $0 [--install] [--push-data])"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/android-vulkan"
ANDROID_DIR="${PROJECT_ROOT}/android"
APP_DIR="${ANDROID_DIR}/app"
JNILIBS="${APP_DIR}/src/main/jniLibs/arm64-v8a"
SDL3_SRC="${BUILD_DIR}/_deps/sdl3-src"

echo "==> Staging native libraries into ${JNILIBS}"
rm -rf "${APP_DIR}/src/main/jniLibs"
mkdir -p "${JNILIBS}"

# Order in MainActivity.getLibraries(): dxvk_d3d9, dxvk_d3d8, SDL3, SDL3_image,
# openal, main. Stage all of them.
stage() {  # <path> <destname>
    if [[ -f "$1" ]]; then cp "$1" "${JNILIBS}/$2"; echo "    staged $2"; else echo "ERROR: missing $1"; exit 1; fi
}
stage "${BUILD_DIR}/libdxvk_d3d9.so"              libdxvk_d3d9.so
stage "${BUILD_DIR}/libdxvk_d3d8.so"              libdxvk_d3d8.so
stage "${BUILD_DIR}/_deps/sdl3-build/libSDL3.so"  libSDL3.so
stage "${BUILD_DIR}/_deps/sdl3_image-build/libSDL3_image.so" libSDL3_image.so
stage "${BUILD_DIR}/_deps/openal_soft-build/libopenal.so"    libopenal.so
stage "${BUILD_DIR}/libgamespy.so"                libgamespy.so
stage "${BUILD_DIR}/GeneralsMD/Code/Main/libmain.so" libmain.so

# GeneralsX-Android @bugfix generals-android 11/07/2026 DXVK/OpenAL .so were built
# with -stdlib=libc++ and NEEDED libc++_shared.so. The engine used c++_static, so
# ship the NDK's libc++_shared.so explicitly (loaded first by SDLActivity).
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    LIBCPP=$(find -L "${ANDROID_NDK_HOME}" -path '*aarch64-linux-android*' -name 'libc++_shared.so' 2>/dev/null | head -1)
    if [[ -n "${LIBCPP}" ]]; then
        cp "${LIBCPP}" "${JNILIBS}/libc++_shared.so"
        echo "    staged libc++_shared.so (from NDK)"
    else
        echo "ERROR: libc++_shared.so not found under ANDROID_NDK_HOME"
        exit 1
    fi
else
    echo "ERROR: ANDROID_NDK_HOME not set (needed for libc++_shared.so)"
    exit 1
fi

echo "==> Vendoring SDL3 Java sources (SDLActivity et al.)"
SDL_JAVA_SRC="${SDL3_SRC}/android-project/app/src/main/java/org/libsdl/app"
SDL_JAVA_DST="${APP_DIR}/src/main/java/org/libsdl/app"
if [[ -d "${SDL_JAVA_SRC}" ]]; then
    rm -rf "${SDL_JAVA_DST}"
    mkdir -p "${SDL_JAVA_DST}"
    cp "${SDL_JAVA_SRC}"/*.java "${SDL_JAVA_DST}/"
    echo "    vendored $(ls "${SDL_JAVA_DST}"/*.java | wc -l) SDL Java files"
else
    echo "ERROR: SDL3 Java sources not found at ${SDL_JAVA_SRC}"
    exit 1
fi

echo "==> Generating local.properties (sdk.dir)"
cat > "${ANDROID_DIR}/local.properties" <<EOF
sdk.dir=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}
EOF

echo "==> Assembling APK (Gradle assembleDebug)"
cd "${ANDROID_DIR}"
gradle assembleDebug --no-daemon --console=plain 2>&1 | tail -20

APK=$(find "${APP_DIR}/build/outputs/apk/debug" -name '*.apk' 2>/dev/null | head -1)
if [[ -z "${APK}" ]]; then
    echo "ERROR: no APK produced"
    exit 1
fi
echo "==> APK ready: ${APK} ($(du -h "${APK}" | cut -f1))"

if [[ "${DO_INSTALL}" == "1" ]]; then
    echo "==> Installing to connected device"
    adb install -r "${APK}"
    echo "==> Installed. Sideload game data to the app's files dir, then launch."
fi

# GeneralsX-Android @build generals-android 11/07/2026 push the staged GameData.
# Source defaults to the repo's build/gamedata (gitignored); override with GX_GAME_DATA.
# Destination is the app's EXTERNAL files dir (directly writable via adb without
# root). The engine's FS bootstrap chdir's to the app data dir on launch.
if [[ "${PUSH_DATA}" == "1" ]]; then
    GAME_DATA="${GX_GAME_DATA:-${PROJECT_ROOT}/build/gamedata}"
    if [[ ! -d "${GAME_DATA}" ]]; then
        echo "ERROR: GameData not found at ${GAME_DATA}"
        echo "  Stage it first from your Steam install (see scripts/get-assets.sh pattern):"
        echo "    rsync -a <excludes> ~/.steam/.../Command \& Conquer Generals - Zero Hour/ build/gamedata/"
        exit 1
    fi
    echo "==> Pushing GameData (${GAME_DATA}) to device — this is ~2.7 GB"
    adb shell run-as com.generalsx.android mkdir -p files 2>/dev/null || true
    # Push to the external files dir (writable), then the app reads from its data dir.
    adb push "${GAME_DATA}" /sdcard/Android/data/com.generalsx.android/files/
    echo "==> GameData pushed. Launch the app."
fi
