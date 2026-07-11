package com.generalsx.android;

import android.os.Bundle;
import android.view.Display;
import android.view.Window;
import android.view.WindowManager;

import org.libsdl.app.SDLActivity;

/**
 * Thin entry Activity. SDL3's SDLActivity owns the window/surface, the Android
 * lifecycle (onPause/onResume -> SDL_EVENT_DID_ENTER_BACKGROUND/WILL_ENTER_FOREGROUND),
 * touch event delivery, and calls the native SDL_main() (the engine's main() in
 * SDL3Main.cpp) on a managed native thread.
 *
 * The native lib name is "main" -> libmain.so, set via SDL's
 * SDL_LIBRARY_NAME build or getLibraries() override. The packager stages the
 * engine .so as lib/arm64-v8a/libmain.so.
 *
 * GeneralsX-Android @feature generals-android 11/07/2026
 */
public class MainActivity extends SDLActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestHighestRefreshRate();
    }

    /**
     * Android otherwise selects the power-saving 60 Hz mode on high-refresh
     * phones even when the renderer is uncapped. Prefer the highest mode with
     * the current native resolution and tell SurfaceFlinger our frame cadence.
     */
    private void requestHighestRefreshRate() {
        Display display = getWindowManager().getDefaultDisplay();
        Display.Mode current = display.getMode();
        Display.Mode best = current;

        for (Display.Mode mode : display.getSupportedModes()) {
            if (mode.getPhysicalWidth() == current.getPhysicalWidth()
                    && mode.getPhysicalHeight() == current.getPhysicalHeight()
                    && mode.getRefreshRate() > best.getRefreshRate()) {
                best = mode;
            }
        }

        Window window = getWindow();
        WindowManager.LayoutParams attributes = window.getAttributes();
        attributes.preferredDisplayModeId = best.getModeId();
        window.setAttributes(attributes);

    }

    @Override
    protected String[] getLibraries() {
        return new String[]{
            // Order matters: dependencies first. libc++_shared.so is NEEDED by the
            // DXVK .so (built with -stdlib=libc++); load it explicitly first.
            "c++_shared",  // libc++_shared.so (NDK) — required by dxvk/openal
            "dxvk_d3d9",   // libdxvk_d3d9.so (D3D9 translation, d3d8 depends on it)
            "dxvk_d3d8",   // libdxvk_d3d8.so (D3D8 -> Vulkan, the one the engine loads)
            "SDL3",        // libSDL3.so (windowing/input)
            "SDL3_image",  // libSDL3_image.so (cursor ANI/PNG loading)
            "openal",      // libopenal.so (audio)
            "main"         // libmain.so (the engine itself; SDL3 calls SDL_main)
        };
    }
}
