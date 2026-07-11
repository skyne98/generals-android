# Overlay triplet for Android arm64-v8a.
#
# Mirrors arm64-ios.cmake's role: pin the platform level so vcpkg-built static
# libs (freetype, curl, openal, ffmpeg) match the engine's ANDROID_PLATFORM and
# don't silently target a newer API than the engine links against.
#
# vcpkg ships a built-in arm64-android triplet; we override only to pin the
# platform level and keep linkage static (the engine links everything statically
# except the runtime .so layers: DXVK d3d8/d3d9, SDL3, OpenAL — see the iOS
# package script's Frameworks/ embedding for the analog).
#
# GeneralsX-Android @build generals-android 11/07/2026

set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_ENV_PASSTHROUGH "ANDROID_NDK_HOME;ANDROID_HOME")
# Match the engine preset's minimum (android-24 = Android 7.0, first stable
# Vulkan + NDK libc++ shared). Bump together with the preset.
set(VCPKG_CMAKE_CONFIGURE_OPTIONS
    "-DANDROID_ABI=arm64-v8a"
    "-DANDROID_PLATFORM=android-24"
    "-DANDROID_STL=c++_static"
)
