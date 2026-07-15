# TurnTV Specification

English | [日本語](SPEC_Turn_ja.md)

Created: July 13, 2026 / Target engine: Godot 4.6.3 (GL Compatibility) / Repository: https://github.com/TSUISHI/TurnTV

## 1. Overview

TurnTV lets the user select any rectangular area of the desktop and display it in a separate window as if it were shown on a CRT television connected through NTSC composite video.

The TV shaders were ported from a retro game currently in development (`CRT_SIGNAL_SHADER_CODE` and `CRT_DISPLAY_SHADER_CODE` in `BaseState.gd`).

## 2. Operating modes

The application uses one window and switches between two modes.

### 2.1 Selection mode (SELECT)

- Selection mode is entered on first launch when no saved rectangle exists, or when the TV image is left-clicked.
- TurnTV minimizes its own window, waits approximately 0.3 seconds, and captures a still image of the entire desktop with `DisplayServer.screen_get_image()`.
- The window then expands to cover the screen and displays a dark overlay over the still image, similar to a standard screenshot tool.
- Drag with the left mouse button to define a rectangle. The selected area remains bright while the outside area is dimmed, and the rectangle size is shown in pixels.
- Releasing the mouse button confirms the rectangle and enters TV mode. The minimum selection size is 8x8 pixels.
- Esc cancels selection. TurnTV returns to TV mode if a rectangle was already confirmed; otherwise, the application exits.
- Rectangle coordinates are stored as absolute desktop coordinates and support multiple monitors.
- Coordinate conversion compensates for the ratio between the still image's physical pixel size and the window size. The visible selection therefore maps to the capture position even when the window does not exactly match the screen because of the taskbar or DPI scaling.

### 2.2 TV mode (TV)

- A live capture of the selected rectangle is shown in a resizable borderless window through the NTSC/CRT shader pipeline.
- `DisplayServer.screen_get_image_rect()` updates the live capture every N frames. The default is every 3 frames, approximately 20 Hz, and can be changed from the parameter panel.
- If the TV window overlaps the selected desktop region, it captures itself. This is expected behavior.

## 3. TV rendering pipeline

TurnTV uses the same two-stage design as the retro game currently in development.

```text
[Desktop capture Image]
   -> ImageTexture
[NTSC canvas SubViewport]  default 320x240; capture centered over black
   -> ViewportTexture
[Stage 1 SubViewport + crt_signal.gdshader]  NTSC/RF signal degradation
   -> ViewportTexture
[Stage 2 ColorRect + crt_display.gdshader]   CRT display simulation
   ->
[Main window]
```

- **NTSC canvas:** The default resolution is 320x240, representing a 4:3 240p-class signal. Width and height can be adjusted from the parameter panel within 160-720 and 120-540 respectively.
- If the selected rectangle is larger than the canvas, it is scaled down to fit while preserving its aspect ratio and is centered. Smaller selections remain at 1:1 scale. Unused canvas space is black, representing the no-signal area around the picture.
- **Display scale:** TurnTV calculates a scale factor `k` so that the selected picture occupies approximately 90% of the window along the limiting axis. The complete Stage 2 canvas is scaled by `k` and centered. Black canvas margins may extend beyond the window and be clipped.
- Mouse-wheel zoom multiplies `k` by an adjustable value from 0.1x to 8.0x.

## 4. Mouse and keyboard controls in TV mode

| Input | Action |
|---|---|
| Left click without moving | Enter selection mode |
| Left drag in the center | Move the selected capture region in the opposite direction of the mouse, producing the feel of dragging the displayed picture; clamp it to the source screen |
| Middle-button drag | Move the window using `DisplayServer.window_start_drag` |
| Left drag within 10 px of an edge | Resize the window using `DisplayServer.window_start_resize`; update the cursor shape to match |
| Mouse wheel | Zoom in or out in 1.1x steps |
| Right click | Show or hide the parameter panel |
| Top-right X button | Save settings and exit |
| Esc | Save settings and exit |

## 5. Parameter panel

Right-clicking opens a slider panel on the right side of the window. Defaults are based on the Composite TV preset used by the retro game currently in development (`Crt_composite_*` and `Crt_shared_*` in `BaseState.gd`).

### 5.1 Stage 1: NTSC/RF signal

| Uniform | Default | Range |
|---|---:|---:|
| `signal_amount` | 1.0 | 0-1 |
| `composite_artifact` | 0.85 | 0-2 |
| `composite_fringing` | 0.65 | 0-2 |
| `subcarrier_phase_px` | 1.047 | 0.1-3.14 |
| `line_phase_amount` | 2.094 | 0-6.283 |
| `phase_jitter` | 0.025 | 0-0.25 |
| `chroma_delay_px` | 1.25 | -8 to 8 |
| `y_band_px` | 1.25 | 0.5-5 |
| `i_band_px` | 2.75 | 1-9 |
| `q_band_px` | 4.25 | 1-12 |
| `ghost_strength` | 0.08 | 0-0.5 |
| `ghost_offset_px` | 6.0 | 0-32 |
| `noise_luma` | 0.012 | 0-0.1 |
| `noise_chroma` | 0.018 | 0-0.1 |
| `rgb_bypass_mix` | 0.0 | 0-1 |
| `rf_amount` | 0.20 | 0-1 |
| `sync_jitter_px` | 0.18 | 0-4 |
| `rf_tuning_error` | 0.08 | -1 to 1 |
| `burst_phase_noise` | 0.03 | 0-0.5 |
| `rf_snow` | 0.015 | 0-0.25 |
| `rf_gain_wobble` | 0.015 | 0-0.25 |
| `hue_deg` | 0.0 | -45 to 45 |
| `saturation` | 1.0 | 0-2 |

### 5.2 Stage 2: CRT display

| Uniform | Default | Range |
|---|---:|---:|
| `display_amount` | 1.0 | 0-1 |
| `scanline_strength` | 0.42 | 0-1 |
| `scanline_width_dark` | 0.18 | 0.05-1 |
| `scanline_width_bright` | 0.42 | 0.05-1 |
| `mask_type` | 1 (slot) | 0=Off / 1=Slot / 2=Aperture grille / 3=Shadow mask |
| `mask_strength` | 0.45 | 0-1 |
| `mask_pitch_px` | 3.6 | 2-8 |
| `mask_dark` | 0.45 | 0-1 |
| `mask_softness` | 0.35 | 0-2 |
| `brightness_compensation` | 1.22 | 0.5-2 |
| `gamma_in` | 2.4 | 1-3 |
| `gamma_out` | 2.2 | 1-3 |
| `curve_amount` | 0.040 | 0-0.2 |
| `corner_radius` | 0.045 | 0-0.15 |
| `vignette_strength` | 0.18 | 0-1 |
| `bezel_strength` | 0.35 | 0-1 |
| `interlace_enabled` | false | On/Off |
| `interlace_dim` | 0.72 | 0-1 |
| `interlace_bob_px` | 0.5 | 0-1 |
| `horizontal_sharpness` | 0.15 | 0-1.5 |
| `convergence_x_px` | 0.25 | -4 to 4 |
| `convergence_y_px` | 0.0 | -4 to 4 |
| `halation_strength` | 0.12 | 0-1 |
| `halation_radius_px` | 1.5 | 0.5-8 |
| `halation_threshold` | 0.65 | 0-1 |

### 5.3 Video presets

| Preset | Description |
|---|---|
| CRT Studio | A high-quality CRT image that minimizes RF instability and emphasizes sharpness, halation, and RGB convergence error |
| Famicom RF | An RF-connected look with stronger false color, bleeding, sync instability, tuning error, snow, and AGC variation |
| Lightweight | Bypasses the Stage 1 17-tap FIR and additional optical samples while retaining scanlines and the phosphor mask |

Presets change only video parameters. They do not change the capture interval, canvas size, or always-on-top setting. Every value can still be adjusted after applying a preset, and the resulting values are saved to the settings JSON.

### 5.4 Application settings

| Setting | Default | Range |
|---|---:|---:|
| Always on top | On | On/Off |
| Capture interval in frames | 3 | 1-30 |
| NTSC canvas width | 320 | 160-720 |
| NTSC canvas height | 240 | 120-540 |

When Always on top is enabled, the TV window remains above other tools. It is enabled by default.

- **Reset to defaults** restores all parameters to the Composite TV preset.
- **Select region again** enters selection mode, equivalent to left-clicking the TV image.

## 6. Settings persistence

On exit, TurnTV writes the following values to `user://turntv_settings.json` using settings format version 2 and restores them at the next launch. Version 1 files remain compatible: existing keys are loaded, while new parameters retain their defaults.

- All shader parameters and application settings
- The selected rectangle in absolute desktop coordinates and the source screen number
- TV window position and size, plus the zoom value

If a valid rectangle has been saved, TurnTV starts directly in TV mode.

## 7. Files

| File | Purpose |
|---|---|
| `project.godot` | Main scene and borderless-window project settings |
| `main.tscn` | Root `Control` node with `main.gd` attached |
| `main.gd` | Mode management, capture, layout, input, settings, and generated UI |
| `crt_signal.gdshader` | Stage 1 NTSC composite/RF signal path, ported from a retro game currently in development |
| `crt_display.gdshader` | Stage 2 CRT display and phosphor simulation, ported from a retro game currently in development |
| `SPEC_TurnTV.md` | English specification (this document) |
| `SPEC_Turn_ja.md` | Japanese specification |

## 8. Debug environment variables

These variables are intended for coordinate diagnostics and automated testing; normal use does not require them.

| Variable | Behavior |
|---|---|
| `TURNTV_SHOT=<PNG path>` | Save the window contents to a PNG approximately three seconds after launch |
| `TURNTV_DUMP=<PNG path>` | Save the first raw live-capture image; also save a full-screen-capture-and-crop comparison as `<path>.crop.png` |
| `TURNTV_GRADIENT=<screen number>` | Start in a full-screen diagnostic mode where every pixel encodes its position as color: R=`x % 256`, G=`y % 256`, B=`(x / 256) * 16 + (y / 256)`. Decoding a captured color reveals the actual sampled coordinate |

## 9. Known limitations

- **`display/window/stretch/mode` must remain `disabled`.** Other modes convert mouse coordinates into the 640x480 content space, which causes large errors between the selected rectangle and the captured region. This failure was reproduced and isolated with the gradient diagnostic on July 13, 2026. `_ready()` also forces content scaling off at runtime. Low-resolution NTSC rendering is handled by the internal SubViewport pipeline, so project-level stretching is unnecessary.
- At Windows display scaling values other than 100%, selection and capture coordinates may not match. Godot window coordinates are physical pixels, and scaled environments have not yet been verified.
- Exclusive full-screen games and DRM-protected windows, including some streaming video applications, may not be capturable.
- The TV window captures itself when it overlaps the selected desktop region.
- Capture uses polling through `screen_get_image_rect`; shorter intervals increase CPU usage.