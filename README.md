# TurnTV

English | [日本語](README_ja.md)

TurnTV lets you select any rectangular area of the Windows desktop and display it in real time as if it were shown on a CRT television connected through NTSC composite video.

It is built with Godot 4.6 using the GL Compatibility renderer. Its two-stage CRT shader pipeline—NTSC signal processing followed by CRT display simulation—was ported from a retro game currently in development and expanded with techniques inspired by ShaderGlass and a real-time NTSC-J RF decoder.

## Usage

1. Start TurnTV. The desktop is dimmed while selection mode is active.
2. Drag over the area you want to display. The selected region opens in a live NTSC/CRT-style window.

### TV window controls

| Input | Action |
|---|---|
| Left click | Select a new capture region |
| Left drag | Move the captured region |
| Middle-button drag | Move the window |
| Drag the window edge | Resize the window |
| Mouse wheel | Adjust display zoom |
| Right click | Show or hide the parameter panel |
| Top-right X / Esc | Save settings and exit |

The parameter panel exposes more than 50 controls, including color bleeding, false color, RF sync instability, tuning error, snow, scanlines, phosphor masks, RGB convergence, and halation. Three presets—`CRT Studio`, `Famicom RF`, and `Lightweight`—can also be applied instantly.

## CRT/RF upgrade

- [ShaderGlass](https://github.com/mausimus/ShaderGlass) inspired the preset workflow, horizontal sharpness, RGB convergence error, and highlight halation.
- [famicom-rf-hackrf-decoder](https://github.com/GOROman/famicom-rf-hackrf-decoder) inspired the horizontal-sync PLL residual, RF tuning error, color-burst phase instability, AGC variation, RF snow, and post-demodulation hue and saturation controls.
- The implementation was written specifically for TurnTV's Godot shaders; source code from the reference projects was not copied verbatim.

## GPU performance and lightweight settings

At a typical 640x480 window size, TurnTV is likely to run even on older integrated graphics. Stage 2 scales with the number of displayed pixels, however, so low-end GPUs may show reduced frame rate or sluggish resizing when a 4K or maximized window is combined with all additional effects.

- Stage 1 runs its 17-tap filter at the default low resolution of 320x240, so its cost is relatively small.
- Stage 2 adds four texture samples for halation, two for RGB convergence, and two for horizontal sharpness for every displayed pixel.
- Desktop capture is primarily a CPU-side cost. Increasing the capture interval can reduce CPU usage, but has little effect on the GPU cost of the CRT shaders, which render every frame.

On low-end systems, start with the `Lightweight` preset. It bypasses the Stage 1 17-tap filter and the additional optical samples. For manual tuning, reduce settings in this order:

1. Set `halation_strength` to 0.
2. Set `convergence_x_px` and `convergence_y_px` to 0.
3. Set `horizontal_sharpness` to 0.
4. Reduce the TV window size.
5. Increase the capture interval only if CPU usage is also high.

Automatic quality adjustment based on GPU performance or frame rate is not currently implemented.

## Download

The current release is **v1.0.1**. Download `TurnTV_v1.0.1.exe` from the [Releases](https://github.com/TSUISHI/TurnTV/releases) page. It is a standalone Windows x86_64 executable with the PCK embedded.

Verify the downloaded file with this SHA-256 hash:

```
SHA256: 0BA89F0CDB4E17855182D456A1113EDCF2DBE987A16214A767CB7CCA220B66DE
```

PowerShell verification command: `Get-FileHash TurnTV_v1.0.1.exe -Algorithm SHA256`

## Requirements

- Windows; desktop capture uses `DisplayServer.screen_get_image`
- Godot 4.6 or later when running the project from source

See [SPEC_TurnTV.md](SPEC_TurnTV.md) for the full specification, [SPEC_Turn_ja.md](SPEC_Turn_ja.md) for the Japanese version, and [CODEX_SPEC_TURNTV_CRT_UPGRADE_20260715.md](CODEX_SPEC_TURNTV_CRT_UPGRADE_20260715.md) for the upgrade design contract.
