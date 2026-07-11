{
  description = "C&C Generals: Zero Hour — Android port (DXVK + SDL3 + OpenAL on native Vulkan). One-command dev environment: the full Android NDK + SDK + vcpkg + meson + gradle.";

  inputs = {
    # nixos-unstable carries androidndkPkgs_27 (NDK r27 / llvm-18) and the
    # androidenv compose path the shell below relies on.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            # The Android SDK packages are licensed by Google's android-sdk-license;
            # nixpkgs gates them behind an explicit acceptance.
            android_sdk.accept_license = true;
          };
        };

        # ── Android SDK + NDK composition ──────────────────────────────────────
        # composeAndroidPackages gives us a fully-patched, autoPatchelf'd SDK+NDK
        # in the nix store, with the NDK toolchain at:
        #   ${ndk-bundle}/libexec/android-sdk/ndk-bundle   ← ANDROID_NDK_HOME
        #   ${androidsdk}/libexec/android-sdk              ← ANDROID_HOME
        #   ${platform-tools}/platform-tools               ← adb
        # NDK r27 (27.0.12077973, llvm-18) — matches the android-vulkan preset's
        # android-24 minimum. Bump here + CMakePresets.json together.
        ndkVersion = "27.0.12077973";
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          includeNDK = true;
          inherit ndkVersion;
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ "35.0.0" ];
          platformVersions = [ "34" "35" ];
          includeEmulator = false;
          includeSystemImages = false;
        };
        ndkHome = "${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle";
        androidHome = "${androidComposition.androidsdk}/libexec/android-sdk";
        platformTools = "${androidComposition.platform-tools}/bin";

        # ── vcpkg ───────────────────────────────────────────────────────────────
        # The engine's CMake uses vcpkg (freetype / curl / openal-soft / ffmpeg)
        # via the arm64-android overlay triplet (cmake/triplets/arm64-android.cmake).
        # vcpkg needs a WRITABLE root (downloads/, buildtrees/, installed/) which
        # the read-only nix store can't provide, so the shell clones a checkout
        # into a cache dir on first entry and points VCPKG_ROOT at it. The vcpkg
        # *tool* binary comes from nixpkgs (prebuilt, no bootstrap compile).
        # If the pinned tag is absent upstream, the shellHook falls back to the default branch.
        vcpkgRef = "2026.06.20";

        # Native build tools (host). These build the engine + DXVK (meson) + APK.
        nativeBuildTools = with pkgs; [
          cmake
          ninja
          meson
          pkg-config
          git
          # vcpkg runtime deps (it shells out to all of these building ports)
          curl
          unzip
          zip
          gnutar
          gzip
          autoconf
          automake
          libtool
          gnused
          gawk
          python3
          perl
          # APK packaging
          gradle
          jdk_headless
          # GeneralsX-Android @build generals-android 11/07/2026 DXVK's meson build needs
          # glslangValidator to compile its SPIR-V shaders (host build tool).
          glslang
          # The vcpkg tool (prebuilt). Ports tree comes from the cloned checkout.
          vcpkg
        ];

        # Android NDK r27 ships libc++ headers; the engine also needs a host C/C++
        # compiler for the meson DXVK build's codegen steps and for any native
        # helper tools. Use nixpkgs clang to match the NDK's llvm-18 lineage.
        hostToolchain = with pkgs; [ clang_18 llvm_18 lld ];

        mkDevShell = { extraAttrs ? { } }:
          pkgs.mkShell ({
            name = "generals-android";

            packages = nativeBuildTools ++ hostToolchain;

            # Hard-wired env the CMake preset and build scripts read.
            ANDROID_NDK_HOME = ndkHome;
            ANDROID_NDK_ROOT = ndkHome;
            ANDROID_HOME = androidHome;
            ANDROID_SDK_ROOT = androidHome;
            # VCPKG_ROOT is set in shellHook (needs $HOME expansion; a static
            # env attr would pass the literal string through unexpanded).
            DXVK_WSI_DRIVER = "SDL3";
            # Tell CMake/Gradle where adb + sdkmanager live.
            ANDROID_PLATFORM_TOOLS = platformTools;

            shellHook = ''
              export PATH="${platformTools}:$PATH"
              # vcpkg must have a writable root with a ports tree. VCPKG_ROOT needs
              # $HOME expansion, so export it here (not as a static env attr).
              export VCPKG_ROOT="''${VCPKG_CACHE_HOME:-$HOME/.cache/generalsx-android}/vcpkg"
              # The nixpkgs `vcpkg` binary on PATH reads VCPKG_ROOT for ports/scripts
              # and writes buildtrees/installed there. Clone the ports tree once.
              if [ ! -d "$VCPKG_ROOT" ]; then
                echo "==> Bootstrapping writable vcpkg checkout at $VCPKG_ROOT (one-time, FULL clone)"
                echo "    (a shallow clone breaks manifest version git-trees; the macOS README warns the same)"
                mkdir -p "$(dirname "$VCPKG_ROOT")"
                ${pkgs.git}/bin/git clone --branch "${vcpkgRef}" \
                  https://github.com/microsoft/vcpkg "$VCPKG_ROOT" 2>/dev/null \
                  || ${pkgs.git}/bin/git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
              fi
              # Manifest mode reads builtin-baseline from vcpkg.json; a shallow clone
              # doesn't contain that commit, so fetch it explicitly (vcpkg's auto-fetch
              # is unreliable on shallow checkouts). Cheap: one commit, no history.
              baseline=$(grep -oE '"builtin-baseline"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' "${self}/vcpkg.json" | grep -oE '[0-9a-f]{40}')
              if [ -n "$baseline" ] && ! ${pkgs.git}/bin/git -C "$VCPKG_ROOT" cat-file -e "$baseline" 2>/dev/null; then
                echo "==> Fetching vcpkg baseline commit $baseline"
                ${pkgs.git}/bin/git -C "$VCPKG_ROOT" fetch --depth 1 origin "$baseline" 2>/dev/null || true
              fi
              echo " generals-android dev shell"
              echo "   NDK : $ANDROID_NDK_HOME"
              echo "   SDK : $ANDROID_HOME"
              echo "   vcpkg: $VCPKG_ROOT"
              echo "   adb : $(command -v adb || echo '(platform-tools)')"
              echo " configure: cmake --preset android-vulkan"
              echo " build    : cmake --build build/android-vulkan --target z_generals"
              echo " package  : ./scripts/build/android/package-android-zh.sh --install"
            '';
          } // extraAttrs);
      in
      {
        devShells.default = mkDevShell { };

        # Re-expose the composition + paths for downstream flakes / CI that want
        # to consume the same pinned NDK without re-deriving it.
        packages.android-toolchain = androidComposition;
        lib = { inherit ndkHome androidHome platformTools ndkVersion; };
      });
}
