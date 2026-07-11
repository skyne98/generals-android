#!/bin/bash
# Build the Android arm64-v8a build of Zero Hour.
#
# Flow:
#   1. Check prerequisites: ANDROID_NDK_HOME, meson, ninja, vcpkg.
#   2. Configure the android-vulkan CMake preset (cross-build via NDK toolchain).
#   3. Build the engine as a shared library (libmain.so) + DXVK .so layers.
#
# Mirrors scripts/build/ios/ (no single iOS build script; the iOS flow is
# cmake --preset ios-vulkan && cmake --build, then package-ios-zh.sh). This
# script wraps the configure+build for convenience.
#
# Usage: ./scripts/build/android/build-android-zh.sh
#   GX_TEAM_ID / GX_BUNDLE_ID are not needed (Android uses debug signing in the
#   Gradle packager; release signing is a separate step).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/android-vulkan"

echo "==> Checking prerequisites"
for var in ANDROID_NDK_HOME VCPKG_ROOT; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: \${${var}} is not set"
        exit 1
    fi
done
for cmd in cmake ninja meson; do
    if ! command -v "${cmd}" >/dev/null; then
        echo "ERROR: ${cmd} not found on PATH"
        exit 1
    fi
done
if [[ ! -d "${ANDROID_NDK_HOME}" ]]; then
    echo "ERROR: ANDROID_NDK_HOME=${ANDROID_NDK_HOME} does not exist"
    exit 1
fi
echo "    NDK:   ${ANDROID_NDK_HOME}"
echo "    vcpkg: ${VCPKG_ROOT}"

# The iOS DXVK build needs the local fork submodule (references/fbraz3-dxvk) so
# Patches/dxvk-android.patch can be applied. Same requirement on Android.
DXVK_FORK="${PROJECT_ROOT}/references/fbraz3-dxvk"
if [[ ! -d "${DXVK_FORK}/.git" ]]; then
    echo "==> Initializing DXVK local fork submodule (for the Android patch)"
    git -C "${PROJECT_ROOT}" submodule update --init references/fbraz3-dxvk
fi

echo "==> Configuring (android-vulkan preset)"
cmake --preset android-vulkan

echo "==> Building (libmain.so + DXVK layers)"
# On Android the engine target is built as a shared library named 'main'
# (SDLActivity loads libmain.so). The CMake target name is z_generals; the
# packager renames/copies. Build the DXVK install target too.
cmake --build "${BUILD_DIR}" --target z_generals dxvk_d3d8_install

echo "==> Build complete: ${BUILD_DIR}"
echo "    Next: ./scripts/build/android/package-android-zh.sh [--install]"
