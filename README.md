# Command & Conquer: Generals — Zero Hour on Android

**Zero Hour running natively on Android phones** — campaign, skirmish, and
Generals Challenge, with touch controls built for RTS (tap-select, drag-box,
long-press deselect, two-finger scroll, pinch zoom). No emulation: this is the
real 2003 engine compiled for ARM64, rendering DirectX 8 →
[DXVK](https://github.com/doitsujin/dxvk) → Vulkan.

Built on EA's GPL v3 source release, standing on a chain of community work —
[TheSuperHackers](https://github.com/TheSuperHackers/GeneralsGameCode),
[Fighter19's original Unix port](https://github.com/Fighter19/CnC_Generals_Zero_Hour), and
[fbraz3/GeneralsX](https://github.com/fbraz3/GeneralsX) — this fork adds the
Android port and a set of engine fixes. The macOS/iOS port this fork was based
on lives at [ammaarreshi/Generals-Mac-iOS-iPad](https://github.com/ammaarreshi/Generals-Mac-iOS-iPad).

**No game assets are included or distributed.** You need your own copy
([Steam](https://store.steampowered.com/app/2732960/), ~$5 on sale).

## What this port involved

The lineage below built the foundation: EA's source release, the community's
modernization, Fighter19's original Unix port, GeneralsX's macOS/Linux work,
and ammaarreshi's iOS port. What this fork adds is the Android target:

- **DXVK built for Android (never done before).** DXVK's D3D8/D3D9 layers were
  cross-compiled for ARM64 via the Android NDK, with a Meson cross-build and a
  patch to the Vulkan loader for Android's shared-library model
  ([`Patches/dxvk-android.patch`](Patches/dxvk-android.patch)).
- **The render chain is D3D8 → DXVK → Vulkan → Mali/Adreno driver.** No
  MoltenVK translation layer — Android has native Vulkan, so the chain is one
  hop shorter than iOS.
- **Touch controls inherited from the iOS port.** The gesture translator in
  `SDL3GameEngine.cpp` (tap-deferred-for-hover, drag-box vs. camera-pan
  disambiguation, long-press right-click, pinch zoom) was already
  platform-independent — widening the `TARGET_OS_IPHONE` guard to `__ANDROID__`
  was the entire input-semantic port.
- **Team-color texture recoloring through CPU memory.** DXVK's D3D8 surface
  copy (`D3DXLoadSurfaceFromSurface`) leaves destination textures zeroed on
  Android's Mali driver. Infantry textures were solid black because only
  team-color pixels got data. The fix: reload source TGAs into lockable CPU
  surfaces, copy rows with `memcpy`, and generate mip levels explicitly.
- **120 Hz display support.** Android's `SurfaceView` defaults to 60 Hz; the
  activity now requests the highest available refresh rate and sets the
  surface frame rate for SurfaceFlinger.
- **Offline ASTC texture transcoding** (experimental). The Mali-G615 does not
  support `textureCompressionBC`, so DXT textures are software-decompressed to
  RGBA (696 MB GPU memory). A Python pipeline transcodes the 3,496-texture
  archive to ASTC 6×6, wrapping in a private `AS66` FourCC that passes through
  D3D8→DXVK→Vulkan natively. See [`scripts/build/android/transcode-textures-astc.py`](scripts/build/android/transcode-textures-astc.py).
- **Touch-to-skip intro movies.** Movie playback bypasses normal input
  translators; a latched touch flag lets taps stop skippable cinematics.
- **Persistent DXVK shader cache.** The NDK's `HOME` is unset for native
  processes; the cache path is now explicitly set to the app's cache directory
  to survive across sessions and eliminate shader-compilation stutter.

## Quick start

### Prerequisites (one time)

```sh
# Nix (provides the full Android NDK + SDK + vcpkg + meson + gradle)
# https://nixos.org/download.html
nix develop    # enters the dev shell with everything configured

# Or set up manually:
#   - Android NDK r27 (ANDROID_NDK_HOME)
#   - Android SDK (ANDROID_HOME)
#   - vcpkg (VCPKG_ROOT)
#   - cmake, ninja, meson, gradle, JDK
```

### Build, package, play

```sh
git clone https://github.com/<your-fork>/generals-android.git GeneralsX
cd GeneralsX
git submodule update --init references/fbraz3-dxvk   # DXVK local fork (patched for Android)

# Inside the nix dev shell:
./scripts/build/android/build-android-zh.sh          # configure + build libmain.so + DXVK .so
./scripts/build/android/package-android-zh.sh --install  # stage .so, build APK, install to device

# Sideload game data (your own copy):
adb shell run-as com.generalsx.android mkdir -p files
adb push <your-gamedata> /sdcard/Android/data/com.generalsx.android/files/
# Or via tar: adb shell run-as com.generalsx.android tar -xf /data/local/tmp/gamedata.tar -C files/
```

The APK is ~220 MB (native .so libs). GameData (~2.7 GB) is sideloaded
separately — it is not bundled in the APK.

## Where things are

| Path | What it is |
|---|---|
| [`docs/port/ANDROID_PORT_PLAN.md`](docs/port/ANDROID_PORT_PLAN.md) | Architecture decision log: per-subsystem strategy, phased plan, concrete files |
| [`docs/port/PORTING_PLAYBOOK.md`](docs/port/PORTING_PLAYBOOK.md) | The complete iOS port engineering log (the bug archaeology this port inherits) |
| `scripts/build/android/build-android-zh.sh` | Configure + build (CMake + Meson + NDK) |
| `scripts/build/android/package-android-zh.sh` | Stage .so libs, vendor SDL3 Java, Gradle APK, install |
| `scripts/build/android/transcode-textures-astc.py` | Offline DXT→ASTC 6×6 transcoder for GPU memory reduction |
| `android/` | Gradle project: `app/` (APK module), `config/` (dxvk.conf, Options.ini) |
| `Patches/dxvk-android.patch` | DXVK changes the Android d3d8/d3d9 .so are built from |
| `cmake/triplets/arm64-android.cmake` | vcpkg triplet for ARM64 Android |
| `cmake/meson-arm64-android-cross.ini.in` | Meson cross-file for DXVK's NDK build |
| `flake.nix` | One-command dev environment: NDK + SDK + vcpkg + meson + gradle |

## Known issues

- **ASTC texture transcoding is experimental.** The pipeline works (textures
  load, GPU memory drops from ~696 MB to ~563 MB), but team-color textures need
  a CPU decode fallback during recoloring. Bulk deployment requires visual
  validation. See the [knowledge base](https://github.com/skyne98/kb-mobile-texture-transcoding).
- **Intermittent stutters** during first playthrough are shader compilation
  (DXVK has no graphics pipeline library support on Mali); the persistent state
  cache eliminates this after the first session.
- **FPS is capped at 30** to match the engine's fixed 30 Hz simulation tick.
  Uncapping the render rate causes 4× game speed. A decoupled render/sim loop
  is future work.

## Lineage & credits

This port is the newest link in a long chain, and the earlier links did
foundational work that this repo inherits everywhere:

- **Westwood / EA Pacific** — the game; **EA** — the GPL v3 source release
- **[TheSuperHackers/GeneralsGameCode](https://github.com/TheSuperHackers/GeneralsGameCode)** —
  the community mainline: build modernization, VC6→modern toolchain, and much
  of the cross-platform groundwork
- **[Fighter19/CnC_Generals_Zero_Hour](https://github.com/Fighter19/CnC_Generals_Zero_Hour)** —
  the original Unix/64-bit port: SDL3 platform management, C++17
  filesystem/threading, Freetype/Fontconfig text rendering, and the DXVK
  approach this renderer path descends from
- **[fbraz3/GeneralsX](https://github.com/fbraz3/GeneralsX)** — the macOS/Linux
  port this fork builds on directly
- **[ammaarreshi/Generals-Mac-iOS-iPad](https://github.com/ammaarreshi/Generals-Mac-iOS-iPad)** —
  the iOS/iPadOS port whose touch gesture translator, app lifecycle handling,
  and engine fixes this Android port inherits
- **This fork** — the Android port (NDK cross-build, DXVK-on-Android,
  team-color texture recoloring fix, 120 Hz display support, ASTC transcoding
  pipeline) and engine fixes
- **DXVK, SDL, OpenAL Soft, FFmpeg, Liberation Fonts** — the load-bearing walls

Engine code **GPL v3** (EA's source release → the chain above → this fork).
Game assets: not included, not licensed.
