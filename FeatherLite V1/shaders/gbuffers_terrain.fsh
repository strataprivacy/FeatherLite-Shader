#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/shadow.glsl"
#include "/lib/lighting.glsl"

// Loader-parsed: tilts the sun/moon orbit for slanted noon light.
// It shows up here only as documentation - sunDirWorld() is already rotated.

uniform sampler2D tex;
uniform vec3 fogColor;
uniform float fogStart;
uniform float fogEnd;

varying vec2 texcoord;
varying vec2 lmcoord;
varying vec4 glcolor;
varying vec3 worldPos;
varying vec3 worldNormal;
varying float matId;

void main() {
    vec4 albedo = texture2D(tex, texcoord) * glcolor;
    if (albedo.a < 0.1) discard;
    albedo.rgb = mix(vec3(luma(albedo.rgb)), albedo.rgb, 1.15);

    // ---- world-space lighting frame --------------------------------
    // Perturb the normal BEFORE anything reads it, so the bump and the
    // per-face variation feed the diffuse, specular and fresnel terms alike.
    //
    vec3 n = normalize(worldNormal);
    vec3 gn = n;   // geometric normal, used for shadow bias
    n = textureBump(n, texcoord, tex, distance(worldPos, cameraPosition));
    n = faceVariation(n, worldPos);

    vec3 v = normalize(cameraPosition - worldPos);   // fragment -> camera
    vec3 viewRay = -v;                               // camera -> fragment
    // v6.0: the sun and moon directions are computed once here and passed into
    // computeLighting. They used to be recomputed inside it, and a third time
    // for the fog tint - three normalize(mat3 * d) per fragment for one value.
    vec3 l = sunDirWorld();
    vec3 lMoon = moonDirWorld();
    float day = smoothstep(-0.07, 0.18, l.y);

    float skyVis = smoothstep(0.2, 0.8, lmcoord.y);

    // rain soaks up-facing outdoor surfaces (vanilla wetness lags rainStrength)
    float wet = 0.0;
    if (WET_GROUND) {
        // Rain reaches vertical faces too, but pools/glosses most strongly on
        // upward-facing surfaces.
        float wetExposure = clamp01(n.y * 0.7 + 0.3);
        wet = wetness * wetExposure * skyVis;
        albedo.rgb *= 1.0 - WET_DARKEN * wet;
    }

    // Per-block / per-texel value break-up. A couple of percent, but it stops
    // large flat faces from reading as smooth moulded plastic.
    if (MICRO_DETAIL > 0.0) {
        albedo.rgb *= 1.0 + microDetail(worldPos, texcoord);
    }

    // ---- shared surface shading -------------------------------------
    vec3 diffuseLight, specLight, sh;
    computeLighting(n, gn, v, worldPos, lmcoord, wet, l, lMoon, day, skyVis,
                    diffuseLight, specLight, sh);

    vec3 col = albedo.rgb * diffuseLight + specLight;

    if (LIGHTNING) {
        // bolts light the scene with inverse-square falloff + crackle
        if (lightningBoltPosition.w > 0.5) {
            float boltDist = distance(worldPos - cameraPosition, lightningBoltPosition.xyz);
            float bolt = inverseSquare(boltDist, BOLT_STRENGTH) * smoothstep(0.2, 0.9, lmcoord.y);
            col += BOLT_COLOR * bolt * boltFlicker();
        }
    }

    // emissive blocks (lava, glowstone, torches, ...) glow on their own
    float emissive = step(10000.5, matId) * step(matId, 10001.5);
    col += albedo.rgb * 1.6 * emissive;

    if (RAIN_RIPPLES) {
        // raindrop rings expanding on soaked up-facing surfaces
        if (wet > 0.3 && n.y > 0.9) {
            // v6.0: ONE ripple layer instead of two. The second used a
            // different scale and a different speed, so the two only read as
            // "more rings", and the outer layer's 0.08 amplitude was below the
            // point of being distinguishable from the 0.14 one on wet gravel.
            // Halves the hashes here and keeps the effect.
            vec2 rp = worldPos.xz * 1.6;
            vec2 cellA = floor(rp);
            vec2 cellB = floor(rp * 0.63 + vec2(17.3, -9.1));
            float hA = hash12(cellA);
            float hB = hash12(cellB);
            float phA = fract(frameTimeCounter * 0.9 + hA * 7.0);
            float phB = fract(frameTimeCounter * 0.63 + hB * 11.0);
            float dA = length(fract(rp) - 0.5);
            float dB = length(fract(rp * 0.63 + vec2(0.23, 0.71)) - 0.5);
            float ringA = (1.0 - smoothstep(0.0, 0.08, abs(dA - phA * 0.45)))
                        * (1.0 - phA) * step(0.62, hA);
            float ringB = (1.0 - smoothstep(0.0, 0.06, abs(dB - phB * 0.36)))
                        * (1.0 - phB) * step(0.70, hB);
            col *= 1.0 + (ringA * 0.14 + ringB * 0.08);
        }
    }

    // directional fog inscatter: fog picks up warm sunlight at golden hour
    float dusk = exp(-l.y * l.y * 9.0);
    vec3 fogTint = fogColor + SUN_COLOR * dusk * pow(clamp01(dot(viewRay, l)), 8.0) * 0.35;
    // storms pack the air with moisture: denser fog while raining
    float fogAmount = inEnd ? FOG_INTENSITY * 0.18 : FOG_INTENSITY * (1.0 + rainStrength * 0.75);
    col = applyFog(col, distance(worldPos, cameraPosition), fogStart, fogEnd, fogTint, fogAmount);

    gl_FragData[0] = vec4(col, albedo.a);
}
