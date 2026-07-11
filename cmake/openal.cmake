# GeneralsX @build fbraz 24/02/2026
# GeneralsX @bugfix fbraz 10/03/2026 Use FetchContent for ALL platforms (macOS, Linux, Windows)
# OpenAL audio library via FetchContent (openal-soft v1.24.2)
#
# On Linux, openal-soft is managed via vcpkg (see vcpkg.json). The vcpkg build compiles
# openal-soft with ALSA-only backend (no PipeWire, no PulseAudio), which avoids a SIGSEGV
# crash in the system libopenal1 1.25.1 Debian package. find_package(OpenAL) picks up the
# vcpkg-installed version automatically when the vcpkg toolchain is active.
#
# On macOS, CMake's FindOpenAL prefers Apple's deprecated OpenAL.framework which uses
# <OpenAL/al.h> instead of the standard <AL/al.h> expected by the Linux-compatible code.
# Prefer openal-soft (brew install openal-soft) which matches the Linux layout.
# Strategy: FetchContent for ALL platforms -- no Homebrew/system detection.
# - macOS:   CoreAudio backend. Compiled natively (arm64 on Apple Silicon).
#            Apple's deprecated OpenAL.framework is avoided -- it uses <OpenAL/al.h>
#            which is incompatible with the standard <AL/al.h> used throughout the codebase.
#            Homebrew openal-soft was unreliable: Intel Homebrew (/usr/local) installs
#            x86_64-only binaries that fail to link against native arm64 builds.
# - Linux:   ALSA/PipeWire backend.
# - Windows: WASAPI backend (modern, low-latency).
#
# FetchContent_MakeAvailable is idempotent: safe to include from multiple CMakeLists.
# Callers guard with: if(NOT TARGET OpenAL::OpenAL) find_package... endif()
#
# Reference: jmarshall OpenAL implementation uses <AL/al.h> throughout.

if(SAGE_USE_OPENAL)
    message(STATUS "Configuring OpenAL Soft (v1.24.2) with FetchContent...")

    include(FetchContent)

    FetchContent_Declare(
        openal_soft
        URL "https://github.com/kcat/openal-soft/archive/refs/tags/1.24.2.tar.gz"
        URL_HASH "SHA256=7efd383d70508587fbc146e4c508771a2235a5fc8ae05bf6fe721c20a348bd7c"
    )

    # Minimal build: no utilities, examples, or tests
    set(ALSOFT_INSTALL_RUNTIME_LIBS  ON  CACHE BOOL "Install runtime libs" FORCE)
    set(ALSOFT_EXAMPLES              OFF CACHE BOOL "Build examples"       FORCE)
    set(ALSOFT_TESTS                 OFF CACHE BOOL "Build tests"          FORCE)
    set(ALSOFT_UTILS                 OFF CACHE BOOL "Build utils"          FORCE)
    set(ALSOFT_NO_CONFIG_UTIL        ON  CACHE BOOL "Disable config util"  FORCE)

    if(WIN32)
        # Windows: WASAPI is the modern low-latency audio API
        set(ALSOFT_REQUIRE_WASAPI ON CACHE BOOL "Require WASAPI backend on Windows" FORCE)
    elseif(ANDROID)
        # Use the NDK's native OpenSL ES backend. OpenAL Soft's FindOpenSL does
        # not search the NDK sysroot correctly when vcpkg's toolchain is layered
        # over Android's toolchain, so provide the paths explicitly.
        set(ALSOFT_BACKEND_SDL3 OFF CACHE BOOL "Disable SDL3 OpenAL backend" FORCE)
        set(ALSOFT_REQUIRE_SDL3 OFF CACHE BOOL "Do not require SDL3 backend" FORCE)
        unset(SDL3_DIR CACHE)
        set(CMAKE_DISABLE_FIND_PACKAGE_SDL3 TRUE CACHE BOOL
            "OpenAL does not need to rediscover in-tree SDL3" FORCE)
        set(ALSOFT_BACKEND_OPENSL ON CACHE BOOL "Enable OpenSL ES on Android" FORCE)
        set(ALSOFT_REQUIRE_OPENSL ON CACHE BOOL "Require OpenSL ES on Android" FORCE)
        set(_opensl_sysroot "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot")
        set(OPENSL_INCLUDE_DIR "${_opensl_sysroot}/usr/include" CACHE PATH "OpenSL headers" FORCE)
        set(OPENSL_ANDROID_INCLUDE_DIR "${_opensl_sysroot}/usr/include" CACHE PATH "Android OpenSL headers" FORCE)
        set(OPENSL_LIBRARY "${_opensl_sysroot}/usr/lib/aarch64-linux-android/24/libOpenSLES.so"
            CACHE FILEPATH "Android OpenSL ES library" FORCE)
    endif()

    FetchContent_MakeAvailable(openal_soft)

    # Force the vendored fmt 11.1.1 headers ahead of any system include dirs.
    # A Homebrew fmt (e.g. 12.x at /opt/homebrew/include) earlier on the include
    # path makes openal sources compile against fmt::v12 inline-namespace headers
    # while linking the vendored v11 static lib -> unresolved fmt::v12 symbols.
    foreach(_alsoft_tgt OpenAL alsoft.common alsoft.excommon)
        if(TARGET ${_alsoft_tgt})
            target_include_directories(${_alsoft_tgt} BEFORE PRIVATE
                "${openal_soft_SOURCE_DIR}/fmt-11.1.1/include")
        endif()
    endforeach()

    # openal-soft FetchContent creates the OpenAL::OpenAL imported target
    message(STATUS "OpenAL Soft configured: target OpenAL::OpenAL available")
endif()
