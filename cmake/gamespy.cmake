set(GS_OPENSSL FALSE)
set(GAMESPY_SERVER_NAME "server.cnc-online.net")

# GeneralsX-Android @bugfix generals-android 11/07/2026 Bionic has no pthread_cancel;
# Patches/gamespy-android.patch stubs gsiCancelThread on Android. Applied via
# PATCH_COMMAND so it survives a clean FetchContent re-fetch.
if(ANDROID)
    # Idempotent patch (same pattern as dx8.cmake's DXVK patch logic): skip when
    # already applied, apply otherwise. Survives FetchContent re-population.
    FetchContent_Declare(
        gamespy
        GIT_REPOSITORY https://github.com/TheAssemblyArmada/GamespySDK.git
        GIT_TAG        07e3d15c500415abc281efb74322ab6d9c857eb8
        PATCH_COMMAND  git apply --reverse --check ${CMAKE_SOURCE_DIR}/Patches/gamespy-android.patch
                       || git apply ${CMAKE_SOURCE_DIR}/Patches/gamespy-android.patch
    )
else()
    FetchContent_Declare(
        gamespy
        GIT_REPOSITORY https://github.com/TheAssemblyArmada/GamespySDK.git
        GIT_TAG        07e3d15c500415abc281efb74322ab6d9c857eb8
    )
endif()

FetchContent_MakeAvailable(gamespy)
