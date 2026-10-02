# FeatherLite

**A Lightweight Stylized Shaderpack With Soft Lighting, Rich Shadows And Atmospheric Skies, Built For Performance.**

![FeatherLite Banner](images/banner.png)

![Minecraft](https://img.shields.io/badge/Minecraft-1.21%2B-green)
![Loader](https://img.shields.io/badge/Requires-Iris%20%2B%20Sodium-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Work%20in%20Progress-orange)

---

## About

FeatherLite is a clean, lightweight shaderpack that gives Minecraft a soft, stylized look. Lighting has gentle bands, shadows are cool-toned, sunlight is warm, outlines are subtle and the sky is atmospheric. It keeps the game's original pixel textures and is designed to run well on modest hardware.

FeatherLite is developed solo by **resurrect5** and is still in active development.

---

## Screenshots

| | |
|---|---|
| ![Day](images/screenshot-day.png) | ![Forest](images/screenshot-forest.png) |
| ![Water](images/screenshot-water.png) | ![Sunset](images/screenshot-sunset.png) |

---

## Features

- **Stylized Lighting** - soft light bands instead of flat, plastic shading
- **Cool-Toned Shadows** - shadows shift toward purple-blue instead of turning grey
- **Soft Outlines** - subtle edges on silhouettes that fade with distance
- **Atmospheric Sky** - rich gradients, soft clouds and a warm horizon glow
- **Water And Weather** - animated waves, rain ripples, wet ground, frost and lightning
- **The End** - a textured deep-space galaxy sky
- **Performance Profiles** - from Ultra-Lite to Cinematic

---

## Requirements

- Minecraft Java Edition
- [Iris Shaders](https://modrinth.com/mod/iris)
- [Sodium](https://modrinth.com/mod/sodium)

---

## Installation

1. Install **Iris** and **Sodium** for your Minecraft version
2. Download the latest `FeatherLite.zip` from [Releases](../../releases)
3. Put the zip into `.minecraft/shaderpacks/` (do not unzip it)
4. In game, go to **Options > Video Settings > Shader Packs** and select FeatherLite
5. Open **Shader Pack Settings** to choose a profile or tune options

> **Note:** Delete older FeatherLite versions before installing a new one. Iris caches settings, and old packs can cause errors on the settings screen.

---

## Profiles

| Profile | Best For |
|---|---|
| **Ultra-Lite** | Low-end PCs and laptops |
| **Performance** | Integrated graphics, higher FPS |
| **Balanced** | Recommended default |
| **Quality** | Mid to high-end GPUs |
| **Cinematic** | Screenshots and showcases |

---

## Key Settings

| Setting | What It Does |
|---|---|
| `OUTLINE_STRENGTH` | Outline strength, 0 turns it off |
| `SATURATION` | Color intensity |
| `AMBIENT_STRENGTH` | Brightness of shaded areas |
| `TONEMAP_EXPOSURE` | Overall brightness |
| `SHADOW_TAPS` | Shadow edge smoothness |
| `shadowDistance` | How far shadows are drawn |
| `AO_SAMPLES` | Ambient occlusion quality, 0 turns it off |

---

## Performance Tips

If you need more FPS, change these in order:

1. Set `AO_SAMPLES` to 0
2. Lower `SHADOW_TAPS` and `shadowDistance`
3. Set `OUTLINE_STRENGTH` to 0
4. Turn off `GODRAYS`

Or simply switch to the **Performance** or **Ultra-Lite** profile.

---

## Known Issues

- At low render distance the edge of loaded terrain is visible (game chunk limit). Raising `FOG_INTENSITY` helps blend it in
- `WET_GLOSS` currently has no effect
- Night, rain, Nether, End and underwater have had less testing than daytime overworld
- Results may vary between GPUs and Iris versions

---

## Reporting Bugs

Found a problem? Please [open an issue](../../issues) and include:

- A **screenshot** of the problem
- Your **Minecraft version**, **Iris version** and **GPU**
- The **profile** or settings you were using
- Where it happens (biome, time of day, weather)

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full history.

---

## Credits

Created by **resurrect5**.

---

## License

Released under the [MIT License](LICENSE).
