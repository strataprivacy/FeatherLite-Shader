#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 fogColor;
uniform float fogStart;
uniform float fogEnd;

varying vec2 texcoord;
varying vec2 lmcoord;
varying vec3 worldPos;

void main() {
    // Fully procedural precipitation - the vanilla texture is never sampled.
    // Pattern coordinates are absolute WORLD coordinates, so moving the camera
    // does not make the rain/snow pattern slide across the terrain.

    float t = frameTimeCounter;
    vec3 wp = worldPos;

    bool snow = temperature < 0.15;

    // fade out at the edges of the rain quad so cell borders never pop in/out
    vec2 ef = min(texcoord, 1.0 - texcoord);
    float edgeFade = smoothstep(0.0, 0.06, ef.x) * smoothstep(0.0, 0.12, ef.y);

    // wind slant + slow gust drift
    vec3 sp = wp;
    sp.x += wp.y * RAIN_SLANT;
    sp.xz += vec2(sin(t * 0.6), cos(t * 0.43)) * 0.6;

    float a = 0.0;
    vec3 tint = vec3(1.0);

    if (snow) {
        // slow drifting flakes
        vec3 fp = sp;
        fp.y = wp.y * 0.35 - t * 2.2 * RAIN_SPEED;
        fp.x += sin(t * 0.9 + wp.y * 0.8) * 0.25;
        vec2 cell = floor(fp.xz * 1.6);
        float h = hash12(cell);
        vec2 f = fract(fp.xz * 1.6);
        vec2 c = vec2(hash12(cell + 7.0), hash12(cell + 13.0));
        float flake = 1.0 - smoothstep(0.05, 0.16, length(f - c));
        a = flake * step(1.0 - clamp(0.5 * RAIN_AMOUNT, 0.05, 0.9), h) * edgeFade;
        tint = vec3(0.93, 0.95, 1.00);
    } else {
        // thin, fast, mostly transparent streaks - each with its own phase
        vec3 rp = sp;
        rp.y = wp.y * 0.55 - t * 14.0 * RAIN_SPEED;
        vec2 cell = floor(rp.xz * 1.6);
        float h = hash12(cell);
        vec2 f = fract(rp.xz * 1.6);
        float dx = abs(f.x - h);
        float line = 1.0 - smoothstep(0.002, 0.014, dx);
        float yF = fract(rp.y + h * 7.0);
        float seg = 1.0 - smoothstep(0.0, 0.18, abs(yF - 0.5));
        a = line * seg * step(1.0 - clamp(0.5 * RAIN_AMOUNT, 0.05, 0.95), h) * edgeFade;
        tint = vec3(0.72, 0.82, 1.00);
    }

    a = clamp(a, 0.0, 1.0) * rainStrength * 0.45;
    if (a < 0.004) discard;

    // lit by cool sky light so it reads as water, plus a hint of torch at night
    float day = dayFactor();
    vec3 amb = mix(NIGHT_AMBIENT * 2.0, DAY_AMBIENT * 1.3, day) * vec3(0.90, 0.95, 1.05);
    vec3 lit = tint * amb * (0.3 + 0.7 * lmcoord.y)
             + TORCH_COLOR * pow(lmcoord.x, 3.0) * 0.35;

if (LIGHTNING) {
    if (lightningBoltPosition.w > 0.5) {
        lit += BOLT_COLOR * 0.35 * boltFlicker();
    }
}

    lit = applyFog(lit, distance(worldPos, cameraPosition), fogStart, fogEnd, fogColor,
                   FOG_INTENSITY * (1.0 + rainStrength * 0.75));

    gl_FragData[0] = vec4(lit, a);
}
