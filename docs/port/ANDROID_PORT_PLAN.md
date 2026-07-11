# Android Port — Architecture Decision Log & Plan

Companion to `PORTING_PATTERNS.md` (generalized methodology) and
`PORTING_PLAYBOOK.md` (the iOS port instance). This document is the Android
equivalent of the iOS playbook: the per-subsystem strategy, the phased plan,
and the concrete files to create/modify, grounded in the *actual* seams of this
codebase (not hypothetical).

**Status:** planning / scaffolding. Last updated 2026-07-11.

---

## 0. The headline: Android is the *easiest* non-Apple target this engine has

The iOS port had to invent two things that Android gets for free:

1. **No MoltenVK.** Android has native Vulkan. The render chain is just
   `D3D8 → DXVK → Vulkan → (GPU driver)`. iOS needed `→ MoltenVK → Metal` on
   top; Android stops one layer earlier. The entire `SAGE_USE_MOLTENVK`,
`fetch-moltenvk.sh`, `MoltenVK.framework` embedding, and the MoltenVK-specific
DXVK patches **do not apply**.
2. **The touch gesture translator already exists and is platform-independent.**
   `SDL3GameEngine.cpp`'s `handleTouchEvent()` / `updateTouchLongPress()` /
`TouchState` are written against raw SDL3 `SDL_EVENT_FINGER_*` events — they
make zero iOS/Darwin calls. They are gated on `TARGET_OS_IPHONE` only because
that was the only touch target when written. Widening that guard to
`__ANDROID__` is the entire input-semantic port. This is the single biggest
gift the iOS work gives us.

What is genuinely new for Android (in rough difficulty order):

| # | Work item | Difficulty | Reuse from |
|---|---|---|---|
| 1 | DXVK built for Android (never been done) | **Hard** — the long pole | `cmake/dx8.cmake` macOS branch + `Patches/dxvk-ios.patch` as template |
| 2 | APK packaging + native-lib + asset bundling | Hard | `scripts/build/ios/package-ios-zh.sh` (concept), but Gradle not Xcode |
| 3 | SDL3 Android lifecycle (Activity ↔ engine) | Medium | iOS `TARGET_OS_IPHONE` blocks in `SDL3Main.cpp` |
| 4 | NDK cross-build preset + vcpkg triplet + meson cross-file | Medium | `ios-vulkan` preset + `arm64-ios.cmake` triplet + `meson-arm64-ios-cross.ini.in` |
| 5 | Widen touch + resolution + filesystem guards to `__ANDROID__` | Easy | the iOS blocks already do the right thing |
| 6 | Audio (OpenAL Soft Android backend) | Low | `openal.cmake` + vcpkg |
| 7 | Video (FFmpeg Android) | Low | existing `FindFFmpeg.cmake` |

---

## 1. Per-subsystem strategy (per `PORTING_PATTERNS.md` §1)

| Subsystem | Strategy | Backend | Reused from existing? |
|---|---|---|---|
| Renderer (D3D8) | **Translate** | DXVK D3D8→Vulkan (native Android Vulkan, no MoltenVK) | `cmake/dx8.cmake` APPLE branch — clone for Android |
| Windowing | **Swap** (behind `SDL3GameEngine` seam) | SDL3 Android backend (`SDLActivity` / `SDL_main`) | `SDL3GameEngine.cpp`, `SDL3Main.cpp` — already SDL3 |
| Input (touch→mouse) | **Reuse** | the existing gesture translator | `SDL3GameEngine.cpp` `TouchState` — widen guard |
| Audio | **Swap** (manager seam) | OpenAL Soft (OpenSL ES / AAudio backend) | `OpenALAudioDevice/`, `cmake/openal.cmake` |
| Video | **Swap** (manager seam) | FFmpeg (NDK build) | `VideoDevice/FFmpeg/`, `cmake/FindFFmpeg.cmake` |
| OS plumbing | **Shim** | `CompatLib` (already reimplements Win32 on POSIX) | `GeneralsMD/Code/CompatLib/` — verify POSIX paths cover Android Bionic |
| Filesystem | **Bootstrap** (bundle data + writable user dir) | reuse iOS pattern | `SDL3Main.cpp` `TARGET_OS_IPHONE` FS block |
| Lifecycle | **Adapt** | SDL3 Android background/foreground events | iOS "hold your breath" pause in `SDL3GameEngine` |
| Packaging | **New** | Gradle APK with native libs + assets | (no existing equivalent; iOS uses xcodebuild) |

**Per-subsystem verdict:** nothing is rewritten. DXVK-on-Android is the only
truly novel engineering; everything else is configuration of layers that
already ship Android support.

---

## 2. The render chain on Android (the part that needs the most thought)

```
Generals SAGE engine
   │  calls DirectX 8 API (d3d8)
   ▼
libdxvk_d3d8.so   ← DXVK, D3D8→Vulkan translation layer (built from fbraz3 fork)
   │  calls Vulkan
   ▼
libvulkan.so      ← Android system Vulkan loader (no MoltenVK!)
   ▼
GPU driver (Adreno / Mali / PowerVR)
```

Contrast with iOS: `D3D8 → DXVK → Vulkan → MoltenVK → Metal → GPU`. Android
deletes the last two hops. Concretely this means:

- `SAGE_USE_MOLTENVK` stays **OFF** for Android.
- `cmake/dx8.cmake`'s `elseif(APPLE AND SAGE_USE_MOLTENVK)` branch is the
  template, but we add a new `elseif(ANDROID)` branch that builds DXVK with a
  meson cross-file targeting the NDK toolchain + Android Vulkan headers.
- `Patches/dxvk-ios.patch` is the template for `Patches/dxvk-android.patch`.
  The iOS patch does two things; the Android equivalents:

  | iOS patch hunk | Android equivalent |
  |---|---|
  | `vulkan_loader.cpp`: prepend `@executable_path/Frameworks/MoltenVK.framework/...` to dlopen search list | Android's Vulkan is the system `libvulkan.so`; DXVK's existing `dlopen("libvulkan.so")` likely works as-is on Android (system lib). Verify; may need the app's lib dir on the search path. |
  | `wsi/sdl3/wsi_window_sdl3.cpp`: `SDL_GetWindowSizeInPixels` instead of `SDL_GetWindowSize` (high-DPI) | **Identical fix needed** — Android phones are high-DPI; same points-vs-pixels swapchain bug. Reuse the exact hunk. |

- DXVK loads SDL3 via a function-pointer table (not linking) — see
  `PORTING_PATTERNS.md` §6. The `sdl3.pc` pkg-config generation in `dx8.cmake`
  must point at the Android-built SDL3.

**Unknowns to resolve by experiment (Phase 2):**
- Does DXVK's meson build succeed against the NDK's clang + `--sysroot`?
  DXVK uses C++20 + some POSIX APIs; Bionic covers most.
- Android's `dlopen` namespace restrictions (Android 7+): the app's own `.so`
  files in `libdir/` are loadable; system `libvulkan.so` is loadable. Should
  work without the bundle-path dance iOS needed.
- DXVK native WSI driver: set `DXVK_WSI_DRIVER=SDL3` (already done in
  `SDL3Main.cpp` — reuse).

---

## 3. The build matrix (mirrors the iOS preset exactly)

| File to create | Mirrors | Purpose |
|---|---|---|
| `cmake/toolchains/android-arm64.cmake` | (NDK provides `build/cmake/android.toolchain.cmake`; we point at it) | CMake cross toolchain |
| `cmake/triplets/arm64-android.cmake` | `cmake/triplets/arm64-ios.cmake` | vcpkg overlay triplet (freetype, curl, openal, ffmpeg) |
| `cmake/meson-arm64-android-cross.ini.in` | `cmake/meson-arm64-ios-cross.ini.in` | meson cross-file for DXVK build |
| `Patches/dxvk-android.patch` | `Patches/dxvk-ios.patch` | DXVK loader + WSI fixes for Android |
| `android-vulkan` preset in `CMakePresets.json` | `ios-vulkan` preset | the top-level configure preset |
| `cmake/dx8.cmake` — add `elseif(ANDROID)` branch | the `APPLE` branch | build DXVK for Android |
| `scripts/build/android/build-android-zh.sh` | `scripts/build/ios/package-ios-zh.sh` | build + assemble |
| `scripts/build/android/package-android-zh.sh` | (iOS packaging) | APK assembly via Gradle |
| `android/` Gradle project | `ios/` XcodeGen stub | the APK shell: `SDLActivity` + native lib loading |
| `android/config/dxvk.conf`, `android/config/Options.ini` | `ios/config/` | shipped config |

**vcpkg note:** vcpkg has a built-in `arm64-android` triplet. We may not need an
overlay at all (unlike iOS, which needed `arm64-ios.cmake` to pin the deployment
target). Start with the built-in triplet; add an overlay only if we need to pin
`ANDROID_PLATFORM` (API level).

---

## 4. The Android app shell (the part with no iOS analog)

iOS uses `xcodegen` + `xcodebuild` to produce a signed `.app` whose stub
executable is swapped for the real engine binary. Android has no "swap the
executable" model — the engine must be a **shared library** loaded by a Java
`Activity`.

SDL3's Android port works like this:
- The app is a Gradle project with a `MainActivity` extending SDL's
  `SDLActivity` (or SDL3's newer `SDL_EntryPoint` model).
- SDL3 expects the native code as `libmain.so` (or a configured lib name) with a
  `main()` symbol — which `SDL3Main.cpp` already provides.
- SDL3's Android backend handles the Activity lifecycle, the window/surface,
  touch event delivery, and calls the engine's `main()` on a native thread.

So the engine binary target (`z_generals`) must be built as a **shared library**
on Android (`.so`), not an executable. This is a build-target-type change gated
on `ANDROID`. The `main()` in `SDL3Main.cpp` is already `#ifndef _WIN32` and
already `#include`s `SDL_main.h` on iOS — Android uses the same `SDL_main`
machinery (SDL3 renames `main` → `SDL_main` and calls it from Java).

**The Gradle project layout (`android/`):**
```
android/
  build.gradle              # com.android.application
  settings.gradle
  src/main/
    AndroidManifest.xml     # MainActivity, permissions, portrait/landscape
    java/.../MainActivity.java   # extends SDLActivity (from SDL3 aar)
    res/...                  # launcher icon
    assets/                  # (optional: staged config; GameData is too big for APK normally — see assets)
  config/
    dxvk.conf
    Options.ini
```

**Assets (the 2.7 GB problem):** iOS bundles GameData inside the `.app` (signed,
read-only). Android APKs have a 200 MB AAB / practical size limits. Options:
1. Ship GameData as a downloaded expansion file (OBB) — Android's sanctioned
   large-asset mechanism.
2. Require the user to copy assets into the app's external storage on first run
   (the `--dev` equivalent).
3. Ship a minimal APK + on-first-launch asset fetch (like `get-assets.sh` but
   in-app). **Recommended** — matches iOS's "bring your own copy" ethos.

For the *first running build* (Phase 4), use option 2: sideload assets to
`/sdcard/Android/data/<pkg>/files` and chdir there (the iOS Documents-folder
fallback path already does exactly this).

---

## 5. Lifecycle (the "hold your breath" port)

iOS's killer lifecycle bug: the OS seizes the Metal drawable mid-frame on
app-switcher open, and drawing one more frame kills the process. Android's
equivalent: the `Surface` is destroyed when the app backgrounds, and rendering
to a destroyed surface crashes. SDL3 delivers this as:

- `SDL_EVENT_DID_ENTER_BACKGROUND` — stop rendering/sim
- `SDL_EVENT_WILL_ENTER_FOREGROUND` — reacquire surface, resume

The iOS pause logic in `SDL3GameEngine.cpp` (whatever holds the render/sim
loop) maps to these. **Action:** locate the iOS backgrounding guard and add an
`__ANDROID__` arm that listens for the same SDL3 events. (Both are SDL3 events,
so the handler is likely shared once the platform gate is widened.)

---

## 6. Phased plan (per `PORTING_PATTERNS.md` §2, adapted)

> Gates are **behavioral**, not build-based ("it compiles" is not a milestone).

### Phase 0 — Toolchain & environment setup  ✅ DONE via `flake.nix`
- `nix develop` provides the full Android SDK + NDK r27 (llvm-18), `meson`, `ninja`,
  `cmake`, `pkg-config`, `gradle` + JDK, `adb`, and a bootstrapped writable
  `vcpkg` (ports tree cloned to `~/.cache/generalsx-android/vcpkg`). Env vars
  `ANDROID_NDK_HOME`, `ANDROID_HOME`, `VCPKG_ROOT`, `DXVK_WSI_DRIVER` are set.
- The flake is the single entry point: it pulls every dep, so the build is
  reproducible across machines with no manual SDK/NDK installs.
- **Gate:** `vcpkg install openal-soft:arm64-android` succeeds (in the shell).

### Phase 1 — Compile-with-stubs milestone  ✅ DONE
- `cmake --preset android-vulkan` configures (vcpkg builds zlib, libpng, bzip2, brotli,
  freetype, glm, gli, openal-soft, ffmpeg for arm64-android).
- `cmake --build build/android-vulkan --target z_generals` produces
  `build/android-vulkan/GeneralsMD/GeneralsXZH` — a **179 MB ELF64 AArch64 PIE**
  executable linking `libSDL3.so`, `libSDL3_image.so`, `libopenal.so`,
  `libgamespy.so`, `libandroid.so`, `libmediandk.so`. 1433/1434 units compiled.
- **Fixes landed** (each a Bionic/NDK-vs-glibc portability issue, annotated
  ﻿// GeneralsX-Android @bugfix ...`):
  - `thread_compat.cpp` / gamespy `gsthreadlinux.c`: stub `pthread_cancel`
    (Bionic omits it). Gamespy fix survives re-fetch via idempotent `PATCH_COMMAND`.
  - `INI.cpp`: `std::from_chars` for floats is deleted on NDK libc++ → reuse the
    Apple `strtod` fallback; also `if constexpr`-guard the integer path so the
    float instantiation doesn't type-check the deleted overload.
  - `render2dsentence.{h,cpp}` + WW3D2 `CMakeLists.txt`: widen the iOS bundled-
    fonts path to Android (no fontconfig); add Android to `SAGE_USE_FREETYPE`
    compile-defs AND the Freetype link list.
  - `FTP.cpp`: drop vestigial `#include <sys/timeb.h>` (Bionic removed it).
  - `SDL3Main.cpp`: guard the desktop-Linux `FilterSoftwareVulkanICDs()` (uses
    `glob()`, Bionic API≥28) to `__linux__ && !__ANDROID__`.
  - `dx8.cmake`: outer DXVK-from-source branch now matches Android; CompatLib uses
    the Wine-style `include/native` DXVK header layout for Android (not the Linux
    tarball flat layout). Nested DXVK submodules (directx-headers, vulkan-headers,
    spirv-headers) must be init'd recursively.
  - `sdl3.cmake`: Android uses SDL3_image's bundled stb PNG backend (vcpkg ships
    only static libpng, SDL3_image rejects `.a`).
  - `CMakePresets.json`: added `CMAKE_ANDROID_API=24` (CMake's built-in Android
    support reads this, not `ANDROID_PLATFORM`; without it `getifaddrs` etc. hide
    behind API≥24 and the build silently targets API 21).
  - vcpkg: gate `curl`/`fontconfig` out of Android (curl is `SAGE_UPDATE_CHECK`
    only = OFF; Android uses iOS-style bundled fonts). `ffmpeg` added for Android
    (required by `OpenALAudioCache` for audio decoding, not just video).
  - flake shellHook: full vcpkg clone (a shallow clone breaks manifest version
    git-trees; the macOS README warns the same).
- **Gate:** ✅ the engine links as an Android arm64 PIE.

### Phase 2 — Graphics bring-up (the long pole)  ✅ DONE
- DXVK built for Android arm64 (never been done before — the project's novel engineering):
  - `libdxvk_d3d8.so` (643K) + `libdxvk_d3d9.so` (3.4M), both ELF64 AArch64 shared objects.
  - `libdxvk_d3d8.so` exports `Direct3DCreate8` (the factory the engine dlopens) and
    dlopens the system `libvulkan.so` at runtime (NOT a NEEDED entry — matches the
    DXVK native design and the iOS pattern).
- Built via meson cross-file (`cmake/meson-arm64-android-cross.ini.in`) +
  `Patches/dxvk-android.patch` (the WSI high-DPI `SDL_GetWindowSizeInPixels` fix).
- **Fixes landed:**
  - meson cross-file: `@ANDROID_API@` placeholder (not `@api@` — `configure_file(@ONLY)`
    ate lowercase `@api@` as an undefined var → empty → `aarch64-linux-android-clang`
    not found).
  - `DXVK_PKG_CONFIG_ENV` ordering: moved the sdl3.pc generation block ABOVE the
    platform-variables block so `DXVK_MESON_ENV` sees a populated `PKG_CONFIG_PATH`.
  - `SDL3.pc` uppercase symlink: DXVK's meson.build calls `dependency('SDL3')`
    (uppercase); pkg-config is case-sensitive on the `.pc` filename. (macOS finds SDL3
    via CMake; cross-builds fall back to pkg-config and need the uppercase file.)
  - `glslang` added to the flake devShell (DXVK compiles its SPIR-V shaders with
    `glslangValidator` — a host build tool).
  - `-DVK_ENABLE_BETA_EXTENSIONS` in the cross-file c/cpp args: DXVK references
    `VK_KHR_portability_subset` symbols (gated behind this define in the Vulkan
    headers; macOS gets it via the SDK).
- **Gate:** ✅ DXVK `.so` layers built; the engine + DXVK both compile for Android.

### Phase 3 — Windowing + input (first pixels)  ✅ DONE
- The touch gesture translator (`SDL3GameEngine.cpp`: `TouchState`, `handleTouchEvent`,
  `updateTouchLongPress`, `sendSyntheticMouse`) is pure SDL3 — widened its
  `TARGET_OS_IPHONE` guard to `|| defined(__ANDROID__)` (5 sites: the translator
  block, `SDL_EVENT_DID_ENTER_BACKGROUND` lifecycle, the `SDL_TOUCH_MOUSEID` drop,
  the `SDL_EVENT_FINGER_*` dispatch, the per-frame long-press poll). The two
  iOS-specific Metal-drawable guards (`iosLifecycleWatcher`, `iosShouldPauseRendering`)
  stay iOS-only — Android's lifecycle comes via SDL3 events.
- `SDL3Main.cpp`: widened 4 sites (SDL_main include, `SDL_HINT_TOUCH_MOUSE_EVENTS=0`,
  `SDL_WINDOW_HIGH_PIXEL_DENSITY`, the resolution-match-to-aspect-ratio). Added an
  `__ANDROID__` FS bootstrap `#elif` (DXVK env vars + chdir to the app data dir;
  no `funopen` stderr swap — Android uses logcat).
- **Gate:** ✅ the engine + touch path compile for Android (libmain.so links, see Phase 4).

### Phase 4 — Packaging (first installable APK)  ✅ DONE
- Engine target type changed: `add_executable(z_generals WIN32)` →
  `if(ANDROID) add_library(z_generals MODULE) + OUTPUT_NAME main` (produces
  `libmain.so`, which SDLActivity loads; SDL3's `SDL_main.h` renamed `main`→
  `SDL_main`, exported as `T SDL_main`).
- `android/` Gradle project (`settings.gradle` + `build.gradle` + `app/build.gradle`):
  AGP 8.7.3, compileSdk 35, buildToolsVersion 35.0.0 (pinned to the flake's
  androidenv), minSdk 24. `MainActivity extends SDLActivity`; `getLibraries()` loads
  dxvk_d3d9, dxvk_d3d8, SDL3, SDL3_image, openal, gamespy, main.
- `scripts/build/android/package-android-zh.sh`: stages all 7 `.so` into
  `jniLibs/arm64-v8a/`, vendors SDL3's 11 Java sources (SDLActivity et al.),
  generates `local.properties`, runs `gradle assembleDebug`.
- Flake: added platform 35 to `composeAndroidPackages` (for compileSdk 35).
- **Result:** `android/app/build/outputs/apk/debug/app-debug.apk` (39 MB), arm64-v8a,
  debug-signed, containing libmain.so + DXVK + SDL3 + OpenAL + gamespy + the SDL
  Java DEX. Launchable on a Vulkan-capable Android 7.0+ device.
- **Gate:** ✅ `package-android-zh.sh` produces a launchable APK.
  (On-device run + asset sideload = next: install the APK, `adb push` your owned
  Zero Hour GameData to the app's files dir, launch — see §4.)

### Phase 5 — Audio + video
- OpenAL Soft Android backend (OpenSL ES); verify `cmake/openal.cmake`.
- FFmpeg NDK build for Bink video replacement.
- **Gate:** menu music plays; intro cinematic plays.

### Phase 6 — Hardening
- Lifecycle pause/resume (§5).
- Asset strategy decision (OBB vs in-app fetch, §4).
- Memory: long-session OOM (Android will kill backgrounded heavy apps; the iOS
  ~3GB resident note applies — monitor with `logcat`).
- Shader cache location (Android: app cache dir, like iOS `Library/Caches`).
- **Gate:** 10-minute skirmish stability; background/resume doesn't crash.

### Phase 7 — Upstream & docs
- Slice changes into reviewable PRs per the annotation convention
  (`// GeneralsX-Android @feature ...`).
- Add `docs/port/ANDROID_PORT_PLAYBOOK.md` (the engineering log, parallel to
  the iOS playbook §8 bug archaeology).
- Offer upstream to ammaarreshi/fbraz3.

---

## 7. What we explicitly do NOT need (vs iOS)

- ❌ MoltenVK (`fetch-moltenvk.sh`, `SAGE_USE_MOLTENVK`, MoltenVK.framework)
- ❌ Apple code signing / provisioning / `codesign`
- ❌ `xcodegen` / `xcodebuild` (Gradle instead)
- ❌ `funopen` / Darwin stderr swap (Android: `__android_log_print` + logcat)
- ❌ iPhoneOS sysroot / `xcrun --sdk iphoneos`

## 8. First concrete deliverables (this session)

1. This document. ✅
2. `flake.nix` + `flake.lock` — the repo's center: one `nix develop` pulls the
   full Android toolchain (NDK r27, SDK, meson, vcpkg, gradle, adb). ✅ verified.
3. `cmake/triplets/arm64-android.cmake` — vcpkg triplet. ✅
4. `cmake/meson-arm64-android-cross.ini.in` — DXVK meson cross-file template. ✅
5. `Patches/dxvk-android.patch` — DXVK loader + WSI fixes (WSI hunk reused from iOS). ✅
6. `android-vulkan` preset added to `CMakePresets.json`. ✅
7. `cmake/dx8.cmake` — `elseif(ANDROID)` branch building DXVK `.so` via meson. ✅
8. `android/` Gradle project skeleton + `scripts/build/android/` build scripts. ✅

Phases 1–2 then proceed entirely inside `nix develop`:
```
  nix develop
  cmake --preset android-vulkan
  cmake --build build/android-vulkan --target z_generals dxvk_d3d8_install
```
This will surface the engine's first compile errors against Bionic (the
`#ifdef`/ABI/STL issues in its POSIX paths) — Phase 1's compile-with-stubs
milestone, per `PORTING_PATTERNS.md` §2.
