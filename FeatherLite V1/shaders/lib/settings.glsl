#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL

// FeatherLite-Perf - single, shared option table.
// Keeping each option declared exactly once prevents Iris option-index crashes.
// Every entry in shaders.properties (screens + sliders) MUST match a name here.
//
// v6.0 DEFAULTS ARE PERFORMANCE-LEAN ON PURPOSE. The numbers below are the old
// "Balanced" values with the two multi-tap kernels (shadow PCF and SSAO) reduced
// and SHADOW_COLORED off. Together with the v6.0 early-outs in composite.fsh that
// is roughly a third fewer texture fetches per frame than the v5.5 default, with
// no visible loss. Raise SHADOW_TAPS / AO_SAMPLES in the settings screen if your
// GPU has headroom.

// --- Post: godrays -------------------------------------------------------
const bool  GODRAYS            = true;
const float GODRAYS_STRENGTH   = 0.040; // [0.00 0.015 0.025 0.040 0.055 0.075 0.10]
const int   GODRAYS_SAMPLES    = 6;     // [4 6 8 10 12 16]
const float GODRAYS_THRESHOLD  = 0.84;  // [0.65 0.72 0.78 0.84 0.90 0.95]

// --- Post: bloom / grade -------------------------------------------------
const bool  BLOOM              = true;
const float BLOOM_STRENGTH     = 0.040; // [0.00 0.02 0.035 0.040 0.06 0.09 0.12]
const float BLOOM_THRESHOLD    = 0.86;  // [0.65 0.75 0.82 0.86 0.90 0.96]
const float TONEMAP_EXPOSURE   = 1.10;  // [0.70 0.80 0.85 0.90 0.98 1.08]
const float SATURATION         = 1.28;  // [0.90 0.96 1.00 1.04 1.10 1.16]
const float CONTRAST           = 1.10;  // [0.95 1.00 1.05 1.12 1.18 1.25]
const float VIGNETTE           = 0.10;  // [0.00 0.03 0.06 0.10 0.16 0.22]
const float HIGHLIGHT_WARMTH   = 0.035; // [0.00 0.02 0.035 0.05 0.07 0.10]
// Cool shadows / warm highlights. This is what removes the "video game
// plastic" cast a pure saturation+contrast grade leaves behind.
// Pure arithmetic, no texture fetches, so it is free to keep on.
const bool  SHADOW_TINT        = true;
const float SHADOW_TINT_AMOUNT = 0.80;  // [0.00 0.15 0.35 0.55 0.75]

// --- End -----------------------------------------------------------------
const float END_GALAXY_STRENGTH = 0.82; // [0.30 0.50 0.65 0.82 1.00 1.20 1.40]
const float END_STAR_DENSITY    = 0.90; // [0.40 0.60 0.75 0.90 1.00 1.20]
const float END_NEBULA_STRENGTH = 0.70; // [0.15 0.30 0.50 0.70 0.90 1.10]
const float END_TEXTURE_MIX     = 1.00; // [0.40 0.60 0.80 0.90 1.00]
const float END_DARKNESS        = 0.88; // [0.55 0.68 0.78 0.88 0.94 0.98]
// v6.0: the End sky is ALREADY drawn by gbuffers_skybasic (skyGradient calls
// endGalaxy), so the composite pass re-projecting the same galaxy over every
// background pixel was doing that work twice and arriving at the same result.
// Default OFF removes an inverse projection, an atan, an asin and a texture
// fetch from every background pixel in the End. Turn this ON only if the sky
// pass does not cover the background on your loader.
// This is a GLSL const, so it must be tested with a runtime "if", never a
// preprocessor "#if" - see the CLOUD_QUALITY note further down.
const bool  END_COMPOSITE_OVERLAY = false;

// --- Ambient occlusion (screen-space, composite pass) --------------------
// Setting AO_SAMPLES to 0 removes the whole kernel loop, so AO costs nothing.
// The guard around it is a runtime `if`, not `#if`: these are GLSL consts, not
// preprocessor macros, and `#if CLOUD_QUALITY >= 2` style tests silently
// evaluate to 0 because the C preprocessor cannot see GLSL constants.
// A fully occluded pixel ends up at exactly (1 - AO_STRENGTH), so this value
// is directly readable as "how dark does a contact shadow get".
// AO_POWER is a response gamma applied AFTER the strength; keep it near 1.0,
// because pushing it up is what amplified kernel noise into visible flicker.
const bool  AO_ENABLED    = true;
const int   AO_SAMPLES    = 6;    // [0 4 6 8 12 16]
const float AO_RADIUS     = 0.90; // [0.40 0.65 0.90 1.20 1.60]
const float AO_BIAS       = 0.035;// [0.00 0.02 0.035 0.05 0.08]
const float AO_STRENGTH   = 0.55; // [0.00 0.25 0.40 0.55 0.70 0.85]
const float AO_POWER      = 1.00; // [0.60 0.80 1.00 1.20 1.50]

// --- Direct light --------------------------------------------------------
const float SUN_STRENGTH     = 1.05; // [0.90 1.05 1.20 1.35 1.50]
const float AMBIENT_STRENGTH  = 0.90; // [0.28 0.36 0.45 0.55 0.70]
const float SHADOW_LIFT       = 0.03; // [0.00 0.04 0.08 0.12 0.18 0.24]
// Wrap softens the light terminator. Deliberately SMALL: a large wrap value is
// exactly what makes shading look waxy and plastic.
const float WRAP_LIGHTING     = 0.00; // [0.00 0.02 0.04 0.08 0.14]
const float TORCH_STRENGTH    = 1.30; // [0.90 1.10 1.30 1.50 1.80 2.00]
const bool  TORCH_FLICKER     = true;

// --- Shadows -------------------------------------------------------------
// Softness = PCF radius in shadow-map texels. The disc is a golden-angle
// spiral rotated per pixel, so more taps = smoother edge, not more noise.
const int   SHADOW_TAPS    = 8;   // [4 6 8 12 16]
const float SHADOW_SOFTNESS = 1.60;// [0.60 1.00 1.60 2.40 3.50]
const float SHADOW_STRENGTH = 1.00;// [0.50 0.70 0.85 1.00 1.15]
// Translucent shadow casters (stained glass, water) tint light. Costs one
// extra texture fetch per tap, so it can be switched off cheaply.
//
// v6.0 DEFAULT IS NOW FALSE. This was the single most expensive setting in the
// pack: with it on, every shadow tap that lands on an occluder issued three
// texture fetches (shadowtex1, shadowtex0, shadowcolor0) instead of one, so
// shadowed areas cost up to 3x the unshadowed ones. Losing coloured shadows
// costs a coloured shadow under stained glass, which is barely noticeable;
// the perf win applies to exactly the pixels that were slowest.
const bool  SHADOW_COLORED = false;
const int   shadowMapResolution = 1024; // [512 1024 2048 3072 4096]
const float shadowDistance      = 72.0; // [48.0 64.0 72.0 80.0 96.0 128.0]
const float SHADOW_BIAS         = 0.85; // [0.70 0.78 0.85 0.92 1.00]

// --- Material / surface --------------------------------------------------
// GGX specular with a physically sane roughness. Blocks are matte by default
// and only get glossy where they are wet, so highlights stop looking sprayed on.
const float SPECULAR_STRENGTH = 0.18;  // [0.00 0.10 0.18 0.30 0.45]
const float SURFACE_ROUGHNESS = 0.60;  // [0.20 0.40 0.60 0.80 0.95]
// Grazing-angle sky reflection. Adds a believable edge without a highlight.
const float SKY_FRESNEL       = 0.04;  // [0.00 0.06 0.12 0.22 0.35]
// Per-block + per-texel value break-up (a couple of percent). Tiny, but it is
// what stops large flat faces from reading as injection-moulded.
const float MICRO_DETAIL      = 0.50;  // [0.00 0.30 0.80 1.20 1.60]
// Bump derived from the block texture's own luminance. This, not specular
// strength, is what stops a flat quad reading as plastic: it gives every face
// real shading variation. 0 disables it.
//
// v6.0: the cost dropped from 4 texture fetches to 2. The centre luma is
// supplied by the caller (it already sampled the atlas to get the albedo), so
// the kernel only needs the +u and +v neighbours and can double the
// difference to recover the centred gradient. Half the fetches, same normal.
const float BUMP_STRENGTH    = 0.0; // [0.00 0.50 1.00 1.60 2.50 4.00]
// Per-face normal tilt so neighbouring blocks shade slightly differently.
const float FACE_VARIATION   = 0.0; // [0.00 0.03 0.07 0.12 0.20]

// --- Sky -----------------------------------------------------------------
const float CLOUD_COVERAGE = 0.55; // [0.20 0.35 0.48 0.60 0.72 0.85]
const float CLOUD_SPEED    = 0.35; // [0.00 0.40 0.75 1.00 1.50 2.00]
const int   CLOUD_QUALITY  = 2;    // [1 2 3]
const float CLOUD_DARKNESS = 0.82; // [0.50 0.65 0.82 0.92 1.00]
const float CLOUD_SILVER   = 0.24; // [0.08 0.16 0.24 0.32 0.42]

// --- Weather -------------------------------------------------------------
const bool  LIGHTNING      = true;
const float BOLT_STRENGTH  = 2.0; // [0.80 1.40 2.00 2.60 3.50]
const float RAIN_AMOUNT    = 1.0; // [0.50 0.75 1.00 1.25 1.50 2.00]
const float RAIN_SPEED     = 1.0; // [0.50 0.75 1.00 1.50 2.00]
const float RAIN_SLANT     = 0.12;// [0.00 0.10 0.20 0.35 0.50]
const bool  RAIN_RIPPLES   = true;
const bool  WET_GROUND     = true;
const float WET_DARKEN     = 0.20; // [0.05 0.12 0.20 0.28 0.36]
const float WET_GLOSS      = 0.28; // [0.00 0.12 0.28 0.42 0.58]
const bool  FROST_OVERLAY  = true;
const float FROST_STRENGTH = 0.65; // [0.20 0.40 0.65 0.80 1.00]

// --- Water ---------------------------------------------------------------
const bool  WATER_GLINT    = true;
const float WAVE_INTENSITY = 0.10; // [0.00 0.04 0.08 0.10 0.15 0.22]
const float WATER_ALPHA    = 0.78; // [0.55 0.65 0.78 0.85 0.92]
const float FOG_INTENSITY  = 0.72; // [0.00 0.20 0.40 0.60 0.72 0.90 1.10]

// --- Style ---------------------------------------------------------------
// Ink-style outline from a depth Laplacian (4 depth taps, near range only).
const float OUTLINE_STRENGTH = 0.35; // [0.00 0.20 0.35 0.50 0.70]

#endif
