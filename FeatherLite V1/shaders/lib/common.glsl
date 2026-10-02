#ifndef COMMON_GLSL
#define COMMON_GLSL

#include "/lib/settings.glsl"

// ---------------------------------------------------------------------------
// Coordinate spaces
// ---------------------------------------------------------------------------
// VIEW space   : camera-relative (gl_ModelViewMatrix, gl_NormalMatrix, ...)
// WORLD space  : absolute world coordinates (relPosToWorld / viewDirToWorld)
// CLIP/SCREEN  : only where a projection is unavoidable (godrays in composite)
//
// ALL lighting math in this pack is done in WORLD SPACE.
// Shading convention: v = normalize(cameraPosition - worldPos) points from
// the fragment TO the camera (the usual Blinn-Phong view direction).
//
// NOTE on sunPathRotation: the shader loader parses that const and tilts the
// sun/moon orbit before sunPosition / moonPosition ever reach the shader.
// We never rotate anything ourselves - sunDirWorld() is already on the
// tilted path.

uniform mat4  gbufferModelView;        // world(dir) -> view
uniform mat4  gbufferModelViewInverse; // view -> world (camera-relative)
uniform vec3  sunPosition;             // view space, dist ~100, loader-rotated
uniform vec3  moonPosition;            // view space, loader-rotated
uniform vec3  cameraPosition;          // absolute world position of the camera
uniform float frameTimeCounter;        // seconds
uniform float rainStrength;            // 0..1, fast rain intensity
uniform float wetness;                 // 0..1, lagged rainStrength (soaked ground)
uniform float temperature;             // biome temperature (Iris): frozen ~0 .. hot ~2
uniform int   isEyeInWater;            // 0 = air, 1 = water
uniform vec4  lightningBoltPosition;   // Iris: camera-relative bolt pos, w = active
uniform int   moonPhase;               // 0 = full moon ... 4 = new moon ... 7
uniform bool  inEnd;                    // Iris: The End dimension

// moonlight scales with the actual moon phase (full -> new)
float moonLightFactor() {
    float d = float(moonPhase);
    if (d > 4.0) d = 8.0 - d;
    return mix(0.30, 1.0, 1.0 - d * 0.25);
}

// ---------------------------------------------------------------------------
// Math helpers (defined FIRST - GLSL has no forward declarations)
// ---------------------------------------------------------------------------

const vec3 LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);

float luma(vec3 c) { return dot(c, LUMA_WEIGHTS); }
float clamp01(float x) { return clamp(x, 0.0, 1.0); }

float hash13(vec3 p) {
    p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// smooth value noise (frost overlay, underwater shimmer, clouds, micro detail)
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// wrap diffuse: softens the light terminator (smooth-lighting feel)
float wrapDiffuse(vec3 n, vec3 l, float wrap) {
    return clamp((dot(n, l) + wrap) / (1.0 + wrap), 0.0, 1.0);
}

// inverse-square falloff with a soft knee (lightning illumination)
float inverseSquare(float dist, float strength) {
    return strength / (1.0 + dist * dist * 0.02);
}

// ---------------------------------------------------------------------------
// Filter kernel helpers
// ---------------------------------------------------------------------------
// GLSL ES 1.0 forbids dynamically indexed arrays, so both the shadow PCF and
// the SSAO kernel are evaluated procedurally from the loop index instead of
// from a constant table. Same result, but the kernel can be a compile-time
// constant and therefore costs nothing when an option is turned off.

const float GOLDEN_ANGLE = 2.39996323; // 137.507 degrees

// i: sample index, count: kernel size, radius: world/texel scale, rot: radians
vec2 diskTap(float i, float count, float radius, float rot) {
    float f = i + 0.5;
    float r = sqrt(f / max(count, 1.0));      // equal-area disc distribution
    float a = f * GOLDEN_ANGLE + rot;
    return vec2(cos(a), sin(a)) * r * radius;
}

// Interleaved gradient noise: a per-pixel rotation angle that is far better
// distributed than a hash. This is what turns banded PCF into smooth dither
// that the eye averages out.
float ignRotation(vec2 fragCoord) {
    return fract(52.9829189 * fract(dot(fragCoord, vec2(0.06711056, 0.00583715)))) * 6.2831853;
}

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

const vec3 SUN_COLOR     = vec3(1.12, 0.96, 0.76);
const vec3 MOON_COLOR    = vec3(0.16, 0.20, 0.30);
const vec3 DAY_AMBIENT   = vec3(0.42, 0.52, 0.80);
const vec3 NIGHT_AMBIENT = vec3(0.075, 0.095, 0.16);
// Light bouncing back up off terrain/foliage. Without a distinct lower
// hemisphere, ambient collapses into a uniform wash and everything looks
// like moulded plastic - this term is the main cure.
const vec3 GROUND_BOUNCE = vec3(0.30, 0.22, 0.14);
const vec3 TORCH_COLOR   = vec3(1.00, 0.60, 0.30);
const vec3 BOLT_COLOR    = vec3(0.75, 0.85, 1.00);
const vec3 ICE_TINT      = vec3(0.72, 0.85, 0.94);

// ---------------------------------------------------------------------------
// Surface micro-detail
// ---------------------------------------------------------------------------
// Constant across a single block face (floor(worldPos) is the same for every
// fragment on that face) so it produces a per-block value shift rather than
// noise. Amplitude is deliberately tiny - a few percent.
//
// v6.0: the fine term was vnoise(uv * 23.0), which is 4 hash12 calls plus the
// interpolation, and it ran on EVERY terrain and entity fragment. The total
// amplitude of this term is 0.030 * MICRO_DETAIL, i.e. about 2% of albedo -
// far below the point where a smooth gradient can be told apart from a noisy
// one. A single hash12 is one quarter of the cost and is indistinguishable at
// that amplitude.
float microDetail(vec3 wPos, vec2 uv) {
    float blockV = hash13(floor(wPos + 0.0001)) * 2.0 - 1.0;
    return blockV * 0.045 * MICRO_DETAIL;
}

// ---------------------------------------------------------------------------
// Space helpers
// ---------------------------------------------------------------------------

vec3 viewDirToWorld(vec3 d) { return mat3(gbufferModelViewInverse) * d; }
vec3 worldDirToView(vec3 d) { return mat3(gbufferModelView) * d; }

// camera-relative view-space position -> absolute world position
vec3 relPosToWorld(vec3 p) {
    return (gbufferModelViewInverse * vec4(p, 1.0)).xyz + cameraPosition;
}

// celestial directions, world space, on the loader's tilted sun path.
// v6.0: these are normalize(mat3 * d). The composite pass was calling
// sunDirWorld() three separate times per pixel for what is the same constant
// value within a frame, so the godray block now takes them as arguments and
// computes each exactly once.
vec3 sunDirWorld()  { return normalize(viewDirToWorld(sunPosition)); }
vec3 moonDirWorld() { return normalize(viewDirToWorld(moonPosition)); }

float dayFactor()  { return smoothstep(-0.07, 0.18, sunDirWorld().y); }
float coldFactor() { return smoothstep(0.20, 0.05, temperature); }

// 1 while precipitation is falling or the ground is soaked
float precipGate() { return clamp01((rainStrength + wetness) * 3.0); }

// crackle while a bolt is live
float boltFlicker() {
    return 0.65 + 0.35 * sin(frameTimeCounter * 47.0) * sin(frameTimeCounter * 13.7);
}

// ---------------------------------------------------------------------------
// Shadows
// ---------------------------------------------------------------------------
// Shadow CONSTS live in /lib/settings.glsl (shadow.vsh needs SHADOW_BIAS in a
// vertex shader). The shadow uniforms + sampleShadow() live in
// /lib/shadow.glsl, which must only be included by FRAGMENT shaders (it uses
// gl_FragCoord) and only AFTER this file.

// ---------------------------------------------------------------------------
// Sky & fog
// ---------------------------------------------------------------------------

// Textured, dark deep-space End sky. The texture provides the large-scale
// galaxy/nebula structure; a very cheap procedural layer adds depth and a few
// extra stars. No ray marching.
uniform sampler2D endGalaxyTex;

vec3 endGalaxy(vec3 dir, float time) {
    const float TWO_PI = 6.2831853;
    vec2 uv = vec2(atan(dir.z, dir.x) / TWO_PI + 0.5, asin(clamp(dir.y, -1.0, 1.0)) / 3.1415926 + 0.5);
    vec3 texGalaxy = texture2D(endGalaxyTex, uv).rgb;

    // Keep the End genuinely deep-black; the galaxy should be the feature, not
    // a bright purple daytime sky.
    texGalaxy *= 0.92;

    float bandAxis = abs(dot(dir, normalize(vec3(0.18, 0.78, 0.60))));
    float band = pow(clamp01(1.0 - bandAxis), 5.5);
    // v6.0: one vnoise instead of two. The second octave (dir.xz * 42.0) was
    // modulating a term already multiplied by two smoothstep windows, so it
    // mostly added cost rather than structure. The band and the two windows
    // are untouched, so the nebula keeps its shape and its soft edges.
    float fine = vnoise(dir.xz * 18.0 + dir.yx * 7.0);
    float cloud = vnoise(dir.xz * 42.0 - dir.yz * 11.0);
    float nebula = smoothstep(0.34, 0.78, fine) * smoothstep(0.20, 0.82, cloud);
    vec3 purple = vec3(0.42, 0.12, 0.72);
    vec3 cyan   = vec3(0.08, 0.34, 0.62);
    vec3 pink   = vec3(0.72, 0.16, 0.40);
    float colorMix = smoothstep(-0.35, 0.55, dir.x + dir.y * 0.35);
    vec3 nebulaCol = mix(purple, cyan, colorMix);
    nebulaCol = mix(nebulaCol, pink, smoothstep(0.55, 0.95, dir.z) * 0.45);

    vec3 procedural = nebulaCol * nebula * band * END_NEBULA_STRENGTH * 0.34;
    vec3 q = normalize(dir);
    float s1 = hash13(floor(q * 320.0));
    float bright = step(0.9976, s1) * (0.55 + 0.45 * sin(time * 1.7 + s1 * 90.0));
    float s2 = hash13(floor(q * 1050.0 + vec3(17.0, 31.0, 7.0)));
    float tiny = step(0.9986, s2) * (0.35 + 0.65 * sin(time * 2.8 + s2 * 130.0));
    float starFade = 0.35 + 0.65 * END_STAR_DENSITY;
    procedural += vec3(0.78, 0.86, 1.00) * bright * starFade * (0.45 + band * 1.2);
    procedural += mix(vec3(0.55, 0.68, 1.00), vec3(1.00, 0.68, 0.38), s2) * tiny * starFade * 0.22;

    vec3 col = mix(vec3(0.00035, 0.00025, 0.0012), texGalaxy, END_TEXTURE_MIX);
    col += procedural;
    col *= END_GALAXY_STRENGTH;
    col *= mix(1.0, 0.22, END_DARKNESS);
    return col;
}

// Stylized sky gradient. dir: normalized world direction.
vec3 skyGradient(vec3 dir, vec3 sunDir, vec3 moonDir, float rain, float time) {
    if (inEnd) return endGalaxy(dir, time);
    float sunH = sunDir.y;
    float day  = smoothstep(-0.07, 0.18, sunH);
    float dusk = exp(-sunH * sunH * 9.0);

    float sunDot  = clamp01(dot(dir, sunDir));
    float moonDot = clamp01(dot(dir, moonDir));

    vec3 zenith  = mix(vec3(0.008, 0.014, 0.040), vec3(0.07, 0.28, 0.80), day);
    vec3 horizon = mix(vec3(0.035, 0.050, 0.095), vec3(0.62, 0.78, 0.98), day);

    float h = clamp01(dir.y);
    vec3 col = mix(horizon, zenith, pow(h, 0.5));
    col += vec3(0.10, 0.08, 0.04) * day * pow(1.0 - h, 6.0) * (0.4 + 0.6 * sunDot);

    // sunrise / sunset glow hugging the horizon
    float band = pow(clamp01(1.0 - abs(dir.y) * 2.2), 2.0);
    col += vec3(1.05, 0.38, 0.12) * dusk * band * (0.25 + 0.75 * sunDot * sunDot);
    col += vec3(0.30, 0.18, 0.38) * dusk * 0.35;

    // tight sun halo + wide warm scatter
    float sunVis = smoothstep(-0.12, 0.02, sunH);
    col += vec3(1.00, 0.85, 0.60) * pow(sunDot, 48.0) * 0.55 * sunVis * (1.0 - rain);
    col += vec3(1.00, 0.55, 0.25) * pow(sunDot, 8.0) * 0.18 * sunVis * (0.35 + 0.65 * dusk) * (1.0 - rain);

    // procedural twinkling stars
    float night = 1.0 - day;
    if (night > 0.01 && dir.y > 0.0 && rain < 0.9) {
        // v6.0: a single hash now drives both the star presence and its phase.
        // The two-tier (bright + tiny) star field used a second hash chain; at
        // these densities the second tier is a handful of pixels per screen.
        float st = hash13(floor(dir * 140.0));
        float star = step(0.9975, st);
        float tw = 0.55 + 0.45 * sin(time * 2.5 + st * 90.0);
        col += vec3(0.90, 0.93, 1.00) * star * tw * night * clamp01(dir.y * 3.0) * (1.0 - rain);

        // faint milky-way band across the night sky
        float mw = pow(clamp01(1.0 - abs(dot(dir, normalize(vec3(0.35, 0.60, 0.71))))), 4.0);
        col += vec3(0.16, 0.18, 0.26) * mw * night * (1.0 - rain) * 0.30;
    }

    // moon halo
    col += vec3(0.35, 0.42, 0.58) * pow(moonDot, 48.0) * 0.25 * night * (1.0 - rain);

    // dynamic procedural cloud layer (plane projection above the camera).
    // coverage grows with rain so storms roll in as actual overcast skies.
    if (dir.y > 0.015) {
        vec2 wind = vec2(time * 0.010, time * 0.006) * CLOUD_SPEED;
        float safeY = max(dir.y, 0.04);
        vec2 cp = dir.xz / safeY * 1.4 + wind;

        float cov = clamp(CLOUD_COVERAGE + rain * 0.35, 0.0, 0.95);
        float cl = vnoise(cp) * 0.55;
        float wsum = 0.55;
        // NOTE: these must be runtime `if`, not `#if`. CLOUD_QUALITY is a GLSL
        // const, not a preprocessor macro, so `#if CLOUD_QUALITY >= 2` was
        // evaluating to `0 >= 2` and silently disabling every extra octave.
        if (CLOUD_QUALITY >= 2) {
            cl += vnoise(cp * 2.3 - wind * 1.7) * 0.28;
            wsum += 0.28;
        }
        if (CLOUD_QUALITY >= 3) {
            cl += vnoise(cp * 5.1 + wind * 2.6) * 0.17;
            wsum += 0.17;
        }
        cl /= wsum;
        // Averaging octaves reduces their variance, so each extra octave
        // flattens the clouds. Without this the sky becomes one uniform milky
        // sheet and takes the contrast of the whole frame with it. Expand
        // back around the mean, more for each octave.
        cl = clamp((cl - 0.5) * (1.0 + 0.42 * float(CLOUD_QUALITY - 1)) + 0.5, 0.0, 1.0);

        // v6.0: the density threshold depends only on constants and the cloud
        // value, so the final mix cannot change the result when density is 0.
        // Testing it first skips the mix and, more importantly, means an
        // overcast sky does not pay the gradient/blend work it cannot use.
        float density = smoothstep(1.0 - cov - 0.08, 1.0 - cov + 0.22, cl);
        density *= smoothstep(0.08, 0.38, dir.y);   // fade at the horizon

        if (density > 0.001) {
            vec3 cloudCol = mix(vec3(0.024, 0.030, 0.052), vec3(0.86, 0.89, 0.96), day);
            cloudCol += vec3(1.00, 0.48, 0.25) * dusk * 0.26;
            cloudCol += vec3(1.00, 0.84, 0.62) * pow(sunDot, 7.0) * CLOUD_SILVER * sunVis * (1.0 - rain);
            cloudCol = mix(cloudCol, cloudCol * 0.40 + vec3(0.012), rain * CLOUD_DARKNESS);
            col = mix(col, cloudCol, density * 0.80);
        }
    }

    // rain washes color out
    col = mix(col, vec3(luma(col)) * 0.7 + vec3(0.06), rain * 0.7);

    // void fade below horizon
    // v1: below the horizon keep the hazy horizon colour (slightly deeper) so
    // low render distance shows soft atmosphere instead of a flat navy slab.
    vec3 belowCol = horizon * mix(0.55, 0.85, day) + vec3(0.02, 0.025, 0.04) * day;
    belowCol = mix(belowCol, vec3(luma(belowCol)) * 0.8 + vec3(0.05), rain * 0.7);
    col = mix(col, belowCol, smoothstep(0.0, -0.18, dir.y));

    return col;
}

// cheap distance fog matched to vanilla fog colors.
// dens: extra density multiplier (storms pack the air with moisture).
vec3 applyFog(vec3 color, float dist, float start, float end, vec3 fogCol, float dens) {
    float f = clamp01((dist - start) / max(end - start, 0.001));
    f = f * f * dens;
    return mix(color, fogCol, f);
}

#endif
