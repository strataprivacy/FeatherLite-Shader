#ifndef SHADOW_GLSL
#define SHADOW_GLSL

// FRAGMENT SHADERS ONLY - include after /lib/common.glsl.
// sampleShadow() uses gl_FragCoord, which does not exist in vertex shaders;
// putting this in common.glsl breaks every vertex program that includes it.
//
// Include this BEFORE /lib/lighting.glsl (computeLighting calls sampleShadow).

uniform sampler2D shadowtex0;   // depth incl. translucents (glass, water)
uniform sampler2D shadowtex1;   // depth of opaque geometry only
uniform sampler2D shadowcolor0; // color of translucent shadow casters
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;

// Soft shadow for a world-space position.
// Opaque casters (terrain, entities, leaves) block fully via shadowtex1.
// With SHADOW_COLORED on, translucent casters (stained glass, water) tint the
// light via shadowcolor0, detected as: blocked in shadowtex0 but not in
// shadowtex1. Returns 1 = fully lit, 0 = fully blocked (per channel colored).
//
// v6.0: SHADOW_COLORED now defaults to false because it was the most expensive
// setting in the pack. It looks cheap on paper - one extra line - but that line
// is inside the tap loop, and it only runs for taps that are ALREADY occluded.
// The result was that shadowed pixels issued 3 fetches per tap while lit pixels
// issued 1, so the slowest part of the frame (large cast-shadow areas, seen
// from inside a forest or a cave mouth) was up to 3x the cost. Off by default,
// every tap is one fetch everywhere.
vec3 sampleShadow(vec3 wPos, vec3 gn) {
    vec3 playerPos = wPos - cameraPosition;
    float dist = length(playerPos.xz);

    // Outside the shadow frustum everything is lit.
    if (dist > shadowDistance) return vec3(1.0);

    // Local size of one shadow texel in blocks. The radial warp makes texels
    // large far from the player, which is where acne (the diagonal stripes)
    // comes from. Push the sample point out along the GEOMETRIC normal by about
    // one texel so a surface never shadows itself.
    vec4 sp0 = shadowProjection * (shadowModelView * vec4(playerPos, 1.0));
    float f0 = 1.0 - SHADOW_BIAS + length(sp0.xy) * SHADOW_BIAS;
    float worldTexel = shadowDistance * (2.0 / float(shadowMapResolution)) * f0 * f0 / (1.0 - SHADOW_BIAS);
    playerPos += gn * min(worldTexel * 1.1, 0.35);

    vec4 sp = shadowProjection * (shadowModelView * vec4(playerPos, 1.0));
    // radial distortion (ortho: clip == ndc) - must match shadow.vsh
    float f = 1.0 - SHADOW_BIAS + length(sp.xy) * SHADOW_BIAS;
    sp.xyz = vec3(sp.xy / f, sp.z * 0.2);
    sp.xyz = sp.xyz * 0.5 + 0.5;

    if (sp.x < 0.0 || sp.x > 1.0 || sp.y < 0.0 || sp.y > 1.0 || sp.z < 0.0 || sp.z > 1.0) {
        return vec3(1.0);
    }
    // ---- filter kernel -------------------------------------------------
    // Equal-area golden-angle disc, rotated per pixel by interleaved gradient
    // noise. The old version used 4 taps at a fixed +/-1 / +/-1.5 texel cross,
    // which is a box filter: hard edge plus visible concentric banding. A
    // rotated disc gives a genuinely soft penumbra and dithers out cleanly.
    float texel = 1.0 / float(shadowMapResolution);

    // The penumbra widens gently with distance so the shadow map does not look
    // uniformly crisp near and far. Kept subtle to avoid detaching contact.
    float radius = texel * SHADOW_SOFTNESS * (1.0 + 0.75 * dist / shadowDistance);
    // Dither angle is tied to the WORLD texel (16 per block), not the screen pixel,
    // so it stays put when the camera moves instead of crawling.
    float rot    = 0.0;   // fixed kernel: deterministic, no grain

    float sum  = 0.0;
    vec3  csum = vec3(0.0);
    float cnt = 0.0;

    for (int i = 0; i < SHADOW_TAPS; i++) {
        vec2 o   = diskTap(float(i), float(SHADOW_TAPS), radius, rot);
        vec2 suv = sp.xy + o;

        // Cheap early-out for taps that leave the map entirely.
        if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
            sum  += 1.0;
            csum += vec3(1.0);
            cnt  += 1.0;
            continue;
        }

        float opaqueLit = step(sp.z - 0.0025, texture2D(shadowtex1, suv).r);

        if (SHADOW_COLORED) {
            if (opaqueLit < 0.5) {
                csum += vec3(0.0);                       // hard occluder
            } else {
                // Only pay for shadowtex0/shadowcolor0 when the opaque map
                // says this tap is lit, so the extra fetches are rare.
                float allLit = step(sp.z - 0.0025, texture2D(shadowtex0, suv).r);
                csum += allLit < 0.5
                     ? clamp(texture2D(shadowcolor0, suv).rgb * 1.8, 0.15, 1.0)
                     : vec3(1.0);
            }
        } else {
            sum += opaqueLit;
        }

        cnt += 1.0;
    }

    // v6.0: the uncoloured path accumulates a SCALAR and the coloured path a
    // VEC3, but the previous code ran both and discarded one - so with
    // SHADOW_COLORED off (the new default) it was still doing the vector adds
    // for nothing. Both branches are now genuinely exclusive.
    vec3 filtered = SHADOW_COLORED
                  ? csum / max(cnt, 1.0)
                  : vec3(sum / max(cnt, 1.0));

    // fade to unshadowed at the edge of the shadow distance
    float fade = smoothstep(shadowDistance * 0.85, shadowDistance, dist);
    return mix(filtered, vec3(1.0), fade);
}

#endif
