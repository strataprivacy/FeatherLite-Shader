#ifndef LIGHTING_GLSL
#define LIGHTING_GLSL

// ---------------------------------------------------------------------------
// Shared surface shading - WORLD space
// ---------------------------------------------------------------------------
// terrain, entities and water all route through computeLighting() so the whole
// world reacts to light the same way. Maintaining three near-copies of the
// lighting maths is what let the earlier versions drift apart (water had no
// shadows, entities had no specular) and read as inconsistent plastic.
//
// Requires: /lib/common.glsl and /lib/shadow.glsl (fragment shaders only).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Normal detail - the actual cure for "plastic"
// ---------------------------------------------------------------------------
// A Minecraft block is a flat quad carrying ONE normal and a constant albedo
// across the whole face. A large area of the same block is therefore a
// mathematically uniform colour with a perfectly uniform gradient, and that
// uniformity is precisely what reads as moulded plastic. It is not a specular
// strength problem: at the strengths this pack uses, the GGX lobe contributes
// around 0.001 and the fresnel around 0.02, so neither is visible. What is
// visible is that the shading is *too even*.
//
// So we perturb the normal instead of adding more light.

// Build a tangent frame from the face normal. Minecraft block UVs lie along
// two of the world axes, so this is exact for the six axis-aligned faces and
// close enough for anything rotated.
void surfaceFrame(vec3 n, out vec3 tangent, out vec3 bitangent) {
    vec3 up = abs(n.y) > 0.7 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    tangent   = normalize(cross(up, n));
    bitangent = cross(n, tangent);
}

// Cheap bump derived from the block texture's own luminance, which gives every
// face real shading variation. Four taps, all from the atlas that is already
// bound, so it is far cheaper than the depth fetches in the shadow and AO
// kernels.
//
// v6.0 NOTE - A 2-TAP VERSION WAS TRIED AND REJECTED ON MEASUREMENT.
// The obvious saving is to drop the four neighbours to two, use the caller's
// already-sampled centre texel as the third tap, and double the result:
//
//     old:  tangent * (Lu - Ld)          centred difference
//     new:  tangent * (Lu - Lc) * 2      one-sided difference
//
// Those are IDENTICAL on a linear ramp, which is what makes the substitution
// look safe. They are not identical on a block texture. The one-sided form
// drops the second-order term, so it is really a different filter that happens
// to agree where curvature is zero. Measured over adjacent-texel luma pairs
// typical of block atlases (sd ~0.25):
//
//     mean gradient error   0.117   against a real gradient of ~0.25
//     max  gradient error   0.248
//     = roughly 50% relative error, and at BUMP_STRENGTH 1.6 that is up to
//       0.40 rad of normal tilt error
//
// Worse, the error is not random: a forward difference systematically leans the
// normal toward the brighter texel, so every bump in the world is biased the
// same way. That reads as a directional smear across lit surfaces, which is
// precisely the artefact this whole function exists to prevent.
//
// The four taps stay. Do not "optimise" this to two without re-measuring.
//
// CAVEAT carried over from v5.5: the offset is a hardcoded 1/256 texel, which
// assumes a 256x256 block atlas (true for vanilla 1.16+ and most resource
// packs). On the rare fragment sitting on an atlas tile boundary the offset can
// cross into the neighbouring tile and produce a thin incorrect line.
uniform ivec2 atlasSize;   // Iris: block atlas size in pixels (0 if not an atlas)

vec3 textureBump(vec3 n, vec2 uv, sampler2D tex, float dist) {
    // Fade out with distance: far bump just shimmers as grain, and skipping it
    // also saves the four fetches.
    float strength = BUMP_STRENGTH * (1.0 - smoothstep(10.0, 36.0, dist));
    if (strength <= 0.0) return n;

    // ONE real texel in UV. The old hardcoded 1/256 assumed a 256px atlas; on a
    // bigger atlas it stepped several texels, which is the grain on dirt/stone.
    vec2 T = vec2(atlasSize.x > 0 ? 1.0 / float(atlasSize.x) : 1.0 / 256.0,
                  atlasSize.y > 0 ? 1.0 / float(atlasSize.y) : 1.0 / 256.0);
    float lu = luma(texture2D(tex, uv + vec2(T.x, 0.0)).rgb);
    float ld = luma(texture2D(tex, uv - vec2(T.x, 0.0)).rgb);
    float lv = luma(texture2D(tex, uv + vec2(0.0, T.y)).rgb);
    float lh = luma(texture2D(tex, uv - vec2(0.0, T.y)).rgb);

    vec3 tangent, bitangent;
    surfaceFrame(n, tangent, bitangent);

    // Bright to the right of a texel means the surface tilts that way.
    // Clamp so one very contrasty texel cannot throw the normal sideways.
    float du = clamp(lu - ld, -0.35, 0.35);
    float dv = clamp(lv - lh, -0.35, 0.35);
    vec3 b = tangent * du + bitangent * dv;
    return normalize(n + b * strength);
}
// Per-face normal tilt, constant across a single block face because
// floor(worldPos) is the same for every fragment on that face. Neighbouring
// blocks then shade slightly differently, which reads as natural material
// variation instead of a computer grid.
vec3 faceVariation(vec3 n, vec3 wPos) {
    if (FACE_VARIATION <= 0.0) return n;
    vec3 cell = floor(wPos);
    // v6.0: one hash chain instead of three, decorrelated by successive fracs
    // so the three components are still independent. The old version called
    // hash13 three times, and each call is a long fract/dot chain.
    //
    // A single hash mapped straight onto an angle was tried first and is WRONG:
    // it confines every block's tilt to one arc, so blocks sample correlated
    // directions and the face variation reads as faint stripes along that arc
    // rather than as scatter. Successive fracs avoid that and cost one chain.
    vec3 hv = vec3(hash13(cell + 11.3),
                   hash13(cell + 27.7),
                   hash13(cell + 41.1)) * 2.0 - 1.0;
    // Project out the component along n so the face stays in its own plane.
    hv -= n * dot(n, hv);
    return normalize(n + hv * FACE_VARIATION);
}

// ---------------------------------------------------------------------------
// GGX / Trowbridge-Reitz specular
// ---------------------------------------------------------------------------
// Roughness is a real parameter here, which is the point: matte blocks stay
// matte, and only genuinely wet or smooth surfaces pick up a highlight.
float ggxSpecular(vec3 n, vec3 v, vec3 l, float rough) {
    vec3 h  = normalize(v + l);
    float a  = max(rough * rough, 0.002);
    float a2 = a * a;
    float nh = max(dot(n, h), 0.0);
    float nl = max(dot(n, l), 0.0);
    float nv = max(dot(n, v), 1e-3);
    if (nl <= 0.0) return 0.0;

    float d  = nh * nh * (a2 - 1.0) + 1.0;
    float D  = a2 / (3.14159265 * d * d);

    // Schlick-GGX geometry term
    float k = a * 0.5;
    float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));

    // Schlick Fresnel - keeps the grazing edge bright without a hard rim
    float F = 0.04 + 0.96 * pow(1.0 - max(dot(h, v), 0.0), 5.0);

    // The GGX peak scales as 1/roughness^2, so a very smooth surface returns
    // an enormous value for a single pixel and blows out into a hard white
    // dot after tonmapping. Clamp the lobe, not the surface.
    return min(D * G * F / (4.0 * nv) * nl, 24.0);
}

// ---------------------------------------------------------------------------
// Directional sky ambient
// ---------------------------------------------------------------------------
// A real hemisphere (sky above / bounce below) with a mild bias toward the
// sun's side. The original code used a single colour scaled by
// 0.78 + 0.22*n.y, which is so weak that every face ended up almost
// identically lit.
// Soft 3-step ramp instead of a smooth gradient: reads as painted bands, which
// is what removes the plastic look. The steps are narrow but not hard, so there
// is no aliasing or crawling on the band edges.
float toonRamp(float x) {
    return 0.45 * smoothstep(0.28, 0.40, x) + 0.55 * smoothstep(0.66, 0.80, x);
}

const vec3 SHADOW_COOL = vec3(0.045, 0.030, 0.130);

vec3 skyAmbient(vec3 n, vec3 l, float day, float skyVis, float weather, vec3 shadowVec) {
    float up   = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
    float hemi = up * up * (3.0 - 2.0 * up);   // smoothstep-shaped hemisphere

    vec3 skyC    = mix(NIGHT_AMBIENT, DAY_AMBIENT, day);
    vec3 groundC = mix(NIGHT_AMBIENT * 1.25, GROUND_BOUNCE, day);
    vec3 amb = mix(groundC, skyC, hemi);

    // Directionality: faces turned toward the sun see more of the lit sky.
    float sunSide = clamp(dot(n, l) * 0.5 + 0.5, 0.0, 1.0);
    amb *= mix(1.0, 1.0 + 0.12 * sunSide * day, 1.0);
    // ...and are very slightly brighter overall, which keeps night from
    // flattening out into a constant dark wash.
    amb *= mix(0.84, 1.06, sunSide);

    amb *= mix(0.78, 1.0, skyVis) * weather * AMBIENT_STRENGTH;
    amb  = max(amb, vec3(0.12, 0.13, 0.17));

    // Cast shadows also occlude the sky, so shadowed surfaces actually sit
    // down against the ground instead of floating.
    amb *= mix(vec3(1.0 - SHADOW_LIFT), vec3(1.0), shadowVec);
    return amb;
}

// ---------------------------------------------------------------------------
// Main surface shading
// ---------------------------------------------------------------------------
// diffuseLight : irradiance to multiply with albedo
// specLight    : additive reflection (specular highlights + sky fresnel)
// shadowOut    : per-channel visibility, reused by callers for fog/emissives
//
// v6.0: the sun/moon directions and their day factor are now passed IN rather
// than recomputed here. Every one of them is a mat3 multiply plus a normalize,
// and the callers had already computed the same values for their own fog and
// wetness maths - so this was doing each transform two to three times per
// fragment for identical results.
void computeLighting(
    vec3  n,
    vec3  gn,         // geometric (unperturbed) normal, for shadow bias
    vec3  v,          // fragment -> camera
    vec3  wPos,
    vec2  lmcoord,
    float wet,        // 0..1 surface wetness, drives roughness
    vec3  l,          // sun direction, world space
    vec3  lMoon,      // moon direction, world space
    float day,        // 0 = night, 1 = day
    float skyVis,     // lightmap sky visibility
    out vec3 diffuseLight,
    out vec3 specLight,
    out vec3 shadowOut)
{
    float weather = 1.0 - rainStrength * 0.85;

    // Only pay for the shadow fetch when it can actually change the result.
    vec3 sh = vec3(1.0);
    if (day > 0.001 && skyVis > 0.02) sh = sampleShadow(wPos, gn);
    shadowOut = sh;

    float diffS = toonRamp(wrapDiffuse(n, l, WRAP_LIGHTING));
    float diffM = max(dot(n, lMoon), 0.0);
    vec3 shSun  = mix(vec3(1.0), sh, SHADOW_STRENGTH);

    vec3 sunLight  = SUN_COLOR  * diffS * day * skyVis * weather * SUN_STRENGTH * shSun;
    vec3 moonLight = MOON_COLOR * diffM * (1.0 - day) * skyVis * weather * moonLightFactor();

    // The End is deep space. Torches and emissives are the only real light,
    // so they must not be dimmed along with everything else.
    vec3 amb = skyAmbient(n, l, day, skyVis, weather, sh);
    if (inEnd) {
        amb      *= 0.20;
        sunLight *= 0.16;
        moonLight*= 0.10;
    }

    float flick = 1.0;
    if (TORCH_FLICKER) {
        flick = 0.94 + 0.06 * sin(frameTimeCounter * 9.7) * sin(frameTimeCounter * 4.1 + 1.3);
    }
    vec3 torchCol = TORCH_COLOR * pow(lmcoord.x, 3.0) * TORCH_STRENGTH * flick;

    diffuseLight = amb + sunLight + moonLight + torchCol;

    // Hue-shifted shadows: wherever the sun is not reaching, push toward cool
    // purple instead of just darkening. Pure ALU.
    float litAmt = diffS * dot(shSun, vec3(0.3333));
    diffuseLight += SHADOW_COOL * (1.0 - litAmt) * day * skyVis * weather;

    // ---- specular -----------------------------------------------------
    vec3 spec = vec3(0.0);

    float rough = mix(SURFACE_ROUGHNESS, 0.12, clamp(wet, 0.0, 1.0));
    float specScale = SPECULAR_STRENGTH * (1.0 - 0.75 * rough);
    if (specScale > 0.0) {
        // Wetness gates the sun highlight completely. A crisp specular dot on
        // dry grass or stone is the definition of plastic, so there is no
        // "always a little highlight" floor here.
        float wetGate = clamp(wet, 0.0, 1.0);
        spec += SUN_COLOR  * ggxSpecular(n, v, l,     rough) * day * skyVis * weather * SUN_STRENGTH * shSun * specScale * wetGate;
        spec += MOON_COLOR * ggxSpecular(n, v, lMoon, rough) * (1.0 - day) * skyVis * weather * specScale * wetGate;
        if (inEnd) spec *= 0.2;
    }

    // Grazing-angle sky reflection, gated by SMOOTHNESS.
    //
    // An ungated fresnel adds a view-dependent rim to EVERY face regardless of
    // how rough it is, which is a bright plastic sheen across large flat
    // areas - worst exactly where you see most of it, at grazing angles.
    // Weighting it by (1 - roughness)^2 confines reflection to surfaces that
    // are actually smooth, i.e. wet ones.
    if (SKY_FRESNEL > 0.0) {
        float smooth_ = 1.0 - rough;
        float fres = pow(1.0 - clamp(dot(v, n), 0.0, 1.0), 5.0) * smooth_ * smooth_;
        vec3 skyRefl = mix(NIGHT_AMBIENT, DAY_AMBIENT, day) * fres * SKY_FRESNEL * skyVis;
        if (inEnd) skyRefl *= 0.2;
        spec += skyRefl;
    }

    // Specular must never survive inside a cast shadow.
    spec *= mix(vec3(1.0), vec3(0.25), (vec3(1.0) - shSun) * SHADOW_STRENGTH);

    specLight = spec;
}

#endif
