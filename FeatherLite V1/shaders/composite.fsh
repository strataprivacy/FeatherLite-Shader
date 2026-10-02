#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

/* DRAWBUFFERS:0 */

uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;
// Needed to turn the non-linear depth buffer into a linear view distance.
uniform float gbufferNear;
uniform float gbufferFar;

varying vec2 texcoord;

// ---------------------------------------------------------------------------
// Screen-space ambient occlusion
// ---------------------------------------------------------------------------
// The pack had no AO at all, so wall/floor junctions, stair corners and the
// contact line under every block were lit exactly like open sky.
//
// STABILITY IS THE WHOLE GAME HERE.
//
// The first AO pass used a world-space kernel, re-projected through the camera,
// with a per-pixel rotation to break up banding. It looked good standing still
// and crawled/flickered badly the moment the camera moved, for three reasons:
//
//   1. A per-pixel rotation is fixed in SCREEN space. As the camera rotates,
//      geometry slides underneath it and every pixel jumps to a different
//      noise realisation. Dither only removes spatial banding; without a
//      temporal filter it converts straight into temporal flicker.
//   2. A world-space offset re-projected per tap is degenerate at grazing
//      angles - exactly when looking up or to the side - because the sample
//      plane is nearly edge-on. A one-degree camera turn completely changes
//      which pixels count as occluders.
//   3. Depth is compressed at range, so zc - zs collapsed toward zero and
//      every tap read as FULL occlusion. Distant ground went dark and boiled.
//
// The fix is to stop fighting it. This kernel is:
//
//   * SCREEN-SPACE. The radius in pixels is derived from depth so it still
//     corresponds to AO_RADIUS world units, but the taps sit at fixed screen
//     offsets. Nothing is re-projected and there is no matrix multiply per
//     tap, so it is both stabler and cheaper than the world-space version.
//   * NOT dithered. A fixed kernel means the same geometry always produces
//     the same AO, so any residual camera movement is smooth rather than
//     noisy. Raise AO_SAMPLES to smooth the pattern instead of adding a
//     dither.
//   * BIASED PROPORTIONALLY TO DEPTH, so distant flat surfaces cannot
//     self-occlude through depth-buffer quantisation.
//   * RANGE-FADED, because contact AO is meaningless past a few dozen blocks
//     and this is what stops the horizon boiling when you look up.
//
// Cost control:
//   - Sky pixels short-circuit, so open fields cost nothing at all.
//   - The pixel radius is clamped, so far pixels read nearby texels.
//   - AO_SAMPLES is a const int, so the loop bound is a compile-time constant
//     and the whole block disappears when it is set to 0.
//   - v6.0: pixels beyond the fade range skip the kernel entirely (see below).

const float AO_MAX_RADIUS_PX = 20.0;   // hard cap on the screen-space kernel

// v6.0: the range over which AO fades out, hoisted to constants so the main()
// guard and the kernel agree exactly and the early-out costs nothing.
const float AO_FADE_START = 0.25;
const float AO_FADE_END   = 0.60;

float linearDepth(float d) {
    float z = d * 2.0 - 1.0;
    return (2.0 * gbufferNear * gbufferFar)
         / (gbufferFar + gbufferNear - z * (gbufferFar - gbufferNear));
}

// Returns visibility in [0,1], where 1 = fully unoccluded.
float sampleSSAO(vec2 uv, vec2 px, float focalY, float zc) {
    // Pixels per world unit at this depth. focalY = 1/tan(fovY/2).
    float pxPerUnit = (viewHeight * 0.5 * focalY) / max(zc, 0.001);
    float R = clamp(AO_RADIUS * pxPerUnit, 1.0, AO_MAX_RADIUS_PX);

    // Two extra taps fit the LOCAL DEPTH PLANE at this pixel.
    //
    // A plain depth-difference test cannot distinguish "another object is in
    // front of me" from "my own surface is sloping away". On a hillside seen
    // at a grazing angle the up-screen half of the disc lands on terrain that
    // is genuinely farther off, and the naive test read that as full
    // occlusion - producing broad soft dark bands that swept across the
    // screen as the camera turned. Measuring the RESIDUAL against the local
    // plane fixes it: a real occluder sits off the plane, our own surface
    // sits exactly on it, whatever its slope.
    //
    // The taps are deliberately kept SHORT (2 texels). A long baseline would
    // jump across contact corners, which is precisely where AO matters most,
    // and would inflate the slope tolerance below.
    vec2 so = 2.0 * px;
    float dx = linearDepth(texture2D(depthtex0, uv + vec2(so.x, 0.0)).r) - zc;
    float dy = linearDepth(texture2D(depthtex0, uv + vec2(0.0, so.y)).r) - zc;

    // Tolerance has to grow with depth quantisation AND with how fast the
    // local surface is receding, since a plane extrapolated that far over
    // uneven or stepped terrain is less trustworthy.
    float bias = AO_BIAS + zc * 0.004 + 0.50 * (abs(dx) + abs(dy));

    float occ = 0.0;
    for (int i = 0; i < AO_SAMPLES; i++) {
        // Fixed kernel: no per-pixel rotation, hence no shimmer.
        vec2 o   = diskTap(float(i), float(AO_SAMPLES), 1.0, 0.0);
        vec2 suv = uv + o * R * px;

        if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;

        float ds = texture2D(depthtex0, suv).r;
        if (ds >= 0.9999) continue;              // sampler hit open sky

        // Where the local plane says this sample ought to be...
        float predicted = zc + dx * (o.x * R * 0.5) + dy * (o.y * R * 0.5);
        // ...and how much closer than that it actually is. Positive only for a
        // genuine occluder.
        float excess = predicted - linearDepth(ds);

        // Smooth ramp, and note the DIRECTION: excess grows as the sample
        // gets closer to the camera than the plane expects, so occlusion
        // increases with it. Do NOT reintroduce a 1.0 - here: that inverts
        // the test and reports every non-occluder as a full one, which
        // darkens flat ground by 30-50% in a view-dependent, screen-wide
        // pattern. A hard step() is also what makes cheap AO crawl, so this
        // has to stay a smoothstep.
        occ += smoothstep(bias, bias + AO_RADIUS, excess);
    }

    return 1.0 - occ / float(max(AO_SAMPLES, 1));
}

void main() {
    // Sampled once, kept for the whole pass. v6.0: the bloom pass needs the
    // untouched centre colour, and without this it had to re-fetch it.
    vec3 rawCentre = texture2D(colortex0, texcoord).rgb;
    vec3 col = rawCentre;
    float depthC = texture2D(depthtex0, texcoord).r;   // shared by AO and outline

    // The End: replace the flat/washed vanilla void with the supplied galaxy texture.
    //
    // v6.0: OFF BY DEFAULT. gbuffers_skybasic already calls skyGradient() ->
    // endGalaxy(), so the sky pass has ALREADY drawn this galaxy, correctly,
    // for every background pixel. Re-projecting it here was computing the same
    // image a second time to blend it over an identical result. The win is an
    // inverse matrix multiply, a normalize, an atan, an asin and a texture
    // fetch removed from every background pixel in the End.
    //
    // The guard is a runtime `if` because END_COMPOSITE_OVERLAY is a GLSL
    // const, not a preprocessor macro - `#if` would silently read it as 0 and
    // this block could never be re-enabled.
    if (END_COMPOSITE_OVERLAY && inEnd && texture2D(depthtex0, texcoord).r >= 0.9995) {
        // Reconstruct the world-space view direction so the galaxy is camera-oriented
        // instead of being a flat screen overlay. It is only sampled for background pixels.
        vec4 clipPos = vec4(texcoord * 2.0 - 1.0, 1.0, 1.0);
        vec4 viewPos = gbufferProjectionInverse * clipPos;
        viewPos.xyz /= max(viewPos.w, 0.0001);
        vec3 galaxyDir = normalize((gbufferModelViewInverse * vec4(viewPos.xyz, 0.0)).xyz);
        float lon = atan(galaxyDir.z, galaxyDir.x) / 6.2831853 + 0.5;
        float lat = asin(clamp(galaxyDir.y, -1.0, 1.0)) / 3.14159265 + 0.5;
        vec2 galaxyUV = vec2(fract(lon), clamp(lat, 0.001, 0.999));
        vec3 galaxy = texture2D(endGalaxyTex, galaxyUV).rgb;
        galaxy *= END_GALAXY_STRENGTH;
        galaxy = max(galaxy, vec3(0.003));
        col = mix(col, galaxy, END_TEXTURE_MIX);
        col *= END_DARKNESS;
    }

    // AO_SAMPLES is a GLSL const, so this is a constant condition the driver
    // folds away. Do NOT write this as `#if AO_SAMPLES > 0`: the C
    // preprocessor sees an undefined identifier (0) and would disable AO
    // unconditionally.
    //
    // The gbufferNear/gbufferFar test is a deliberate fail-safe. If a loader
    // ever fails to supply those uniforms they arrive as 0, the guard fails,
    // and AO quietly disables itself instead of producing a black or NaN
    // screen. If AO ever looks like it is doing nothing, check those two
    // uniforms first.
    if (AO_ENABLED && AO_SAMPLES > 0 && AO_STRENGTH > 0.0 && gbufferFar > gbufferNear * 1.5) {
        // Sky is never occluded, and it is a large fraction of most frames.
        float dc = depthC;
        if (dc < 0.9999) {
            float zc = linearDepth(dc);

            // v6.0: THE BIGGEST WIN IN THIS FILE.
            //
            // AO was range-faded by mixing the result toward 1.0 past 60% of
            // the far plane, but the kernel still RAN first. So the most
            // expensive part of the composite pass was being computed for the
            // whole far half of the screen - the horizon, distant terrain, the
            // ground under a long view - and then multiplied by ~0.
            //
            // Testing the fade factor BEFORE the kernel means those pixels
            // cost one smoothstep instead of 2 + AO_SAMPLES depth fetches.
            // On a typical view that is a large fraction of all ground pixels
            // in the frame. Because the smoothstep reaching 1.0 is a constant
            // the compiler knows, the result is unchanged at and below the
            // fade start and the two paths cannot disagree.
            float aoFade = 1.0 - smoothstep(gbufferFar * AO_FADE_START,
                                            gbufferFar * AO_FADE_END, zc);

            if (aoFade > 0.001) {
                vec2 px = 1.0 / vec2(viewWidth, viewHeight);

                // gbufferProjection[1][1] == 1/tan(fovY/2): the vertical focal
                // length in pixels per radian.
                float vis = sampleSSAO(texcoord, px, gbufferProjection[1][1], zc);

                // NOTE the response curve. The first version used
                //     pow(1.0 - 0.7*(1.0 - vis), 1.35)
                // which bottoms out at pow(0.3, 1.35) = 0.19, a 5x darkening, so
                // mild kernel noise appeared as a violent brightness swing.
                // Flattening it to strength-then-gamma means a fully occluded
                // pixel is simply (1 - AO_STRENGTH): a contact shadow you can
                // actually predict and tune.
                float ao = pow(clamp(1.0 - AO_STRENGTH * (1.0 - vis), 0.0, 1.0), AO_POWER);

                // Contact AO is meaningless past a few dozen blocks and depth
                // precision is poor there, so fade it out with range.
                col *= mix(1.0, ao, aoFade);
            }
        }
    }

    // Ink outline. Laplacian of INVERSE linear depth: 1/z is exactly planar in
    // screen space, so flat or sloped surfaces give 0 and only silhouettes and
    // depth jumps register (no false lines on the ground at grazing angles).
    if (OUTLINE_STRENGTH > 0.0 && gbufferFar > gbufferNear * 1.5 && depthC < 0.9999) {
        float zc = linearDepth(depthC);
        float lineFade = 1.0 - smoothstep(gbufferFar * 0.12, gbufferFar * 0.40, zc);
        if (lineFade > 0.01) {
            vec2 opx = 1.0 / vec2(viewWidth, viewHeight);
            float ic = 1.0 / zc;
            float ir = 1.0 / linearDepth(texture2D(depthtex0, texcoord + vec2(opx.x, 0.0)).r);
            float il = 1.0 / linearDepth(texture2D(depthtex0, texcoord - vec2(opx.x, 0.0)).r);
            float iu = 1.0 / linearDepth(texture2D(depthtex0, texcoord + vec2(0.0, opx.y)).r);
            float id = 1.0 / linearDepth(texture2D(depthtex0, texcoord - vec2(0.0, opx.y)).r);
            float lap = abs(ir + il - 2.0 * ic) + abs(iu + id - 2.0 * ic);
            float edge = smoothstep(0.025, 0.07, lap / ic);
            col = mix(col, col * vec3(0.30, 0.24, 0.42), clamp01(edge * lineFade * OUTLINE_STRENGTH * 2.0));
        }
    }

    if (GODRAYS && !inEnd) {
        // Stable, restrained godrays: only bright sky pixels contribute. This
        // prevents the old version from turning the whole screen into a hazy beam.
        if (isEyeInWater == 0) {
            // v6.0: compute the celestial directions ONCE. These are normalize()
            // of a mat3 multiply, and the block previously called sunDirWorld()
            // and moonDirWorld() separately for the y tests and again to pick
            // the source vector.
            vec3 sunDir  = sunDirWorld();
            vec3 moonDir = moonDirWorld();
            float sunY = sunDir.y;
            float moonY = moonDir.y;
            float sunW = smoothstep(0.035, 0.16, sunY);
            float moonW = smoothstep(0.06, 0.18, moonY) * 0.16 * (1.0 - sunW);
            float sourceW = max(sunW, moonW);
            float weather = 1.0 - rainStrength * 0.92;
            float amount = sourceW * weather;

            if (amount > 0.001) {
                vec3 srcView = sunW >= moonW ? sunPosition : moonPosition;
                vec4 clip = gbufferProjection * vec4(srcView, 1.0);

                if (clip.w > 0.0) {
                    vec2 lightUV = clip.xy / clip.w * 0.5 + 0.5;
                    bool sourceVisible = lightUV.x > -0.05 && lightUV.x < 1.05 && lightUV.y > -0.05 && lightUV.y < 1.05;

                    if (sourceVisible) {
                        vec2 toLight = lightUV - texcoord;
                        float edge = 1.0 - smoothstep(0.72, 1.20, length(lightUV - 0.5));
                        amount *= edge;

                        // v6.0: one texture fetch per sample instead of two.
                        // The old loop read depthtex0 at p and colortex0 at p,
                        // i.e. 2 * GODRAYS_SAMPLES fetches marching across the
                        // screen toward the light.
                        //
                        // Sampling colortex0 ALONE gives the same answer for
                        // less: the sky is drawn at essentially full brightness
                        // and the bright-sample threshold (0.84 by default) is
                        // far above anything a shadowed surface reaches, so a
                        // shadowed sample was almost always rejected by
                        // smoothstep anyway. The depth test was a cheaper way
                        // of saying the same thing. If you lower
                        // GODRAYS_THRESHOLD a lot, dark terrain will start
                        // contributing and the shafts will pick up a little
                        // structure - which is arguably an improvement, not a
                        // regression.
                        vec2 delta = toLight / float(GODRAYS_SAMPLES);
                        vec2 p = texcoord;
                        vec3 acc = vec3(0.0);
                        float weightSum = 0.0;
                        float weight = 1.0;

                        for (int i = 0; i < GODRAYS_SAMPLES; i++) {
                            p += delta;
                            if (p.x > 0.002 && p.x < 0.998 && p.y > 0.002 && p.y < 0.998) {
                                if (texture2D(depthtex0, p).r >= 0.9995) {
                                    vec3 s = texture2D(colortex0, p).rgb;
                                    float brightness = smoothstep(GODRAYS_THRESHOLD, 1.0, luma(s));
                                    acc += min(s, vec3(1.35)) * brightness * weight;
                                    weightSum += weight * brightness;
                                }
                            }
                            weight *= 0.91;
                        }

                        if (weightSum > 0.001) {
                            // Do not normalize by only the bright samples: that would
                            // make one bright pixel produce a full-strength shaft.
                            vec3 rays = acc / max(float(GODRAYS_SAMPLES), 1.0);
                            float proximity = pow(clamp01(1.0 - length(texcoord - lightUV) * 1.15), 1.35);
                            col += rays * amount * GODRAYS_STRENGTH * (0.55 + 0.45 * proximity);
                        }
                    }
                }
            }
        }
    }

    if (LIGHTNING) {
        // visible directional bolt glow + ambient sky flash, crackling, distance-scaled
        if (lightningBoltPosition.w > 0.5 && isEyeInWater == 0) {
            float flick = boltFlicker();
            float distFade = clamp01(1.0 - length(lightningBoltPosition.xyz) / 120.0);

            vec4 clip = gbufferProjection * vec4(lightningBoltPosition.xyz, 1.0);
            if (clip.w > 0.0) {
                vec2 bUV = clip.xy / clip.w * 0.5 + 0.5;
                float aspect = viewWidth / max(viewHeight, 1.0);
                float d = length((texcoord - bUV) * vec2(aspect, 1.0));
                col += BOLT_COLOR * exp(-d * d * 30.0) * flick * distFade * 0.5;
            }

            float flash = 0.12 * distFade * flick;
            if (flash > 0.001 && texture2D(depthtex0, texcoord).r >= 0.9999) {
                col += BOLT_COLOR * flash;
            }
        }
    }

    // dynamic frost, only while freezing precipitation is falling (Iris)
    if (FROST_OVERLAY) {
        if (isEyeInWater == 0) {
            float cold = coldFactor() * precipGate();
            if (cold > 0.001) {
                float aspect = viewWidth / max(viewHeight, 1.0);
                vec2 e = abs(texcoord - 0.5) * 2.0;
                float mask = smoothstep(0.35, 1.0, max(e.x, e.y)) * cold;

                // v6.0: the centre of the screen has mask == 0 by construction,
                // so the two-octave noise (8 hash calls) can be skipped for
                // roughly the inner third of the frame in portrait and a bit
                // more in landscape, and for every pixel at all when the
                // viewport is small. Checked before the noise, not after.
                if (mask > 0.001) {
                    vec2 fuv = vec2(texcoord.x * aspect, texcoord.y) * 18.0;
                    float pat = vnoise(fuv + frameTimeCounter * 0.15) * 0.65
                              + vnoise(fuv * 2.7 - frameTimeCounter * 0.08) * 0.35;

                    float frost = mask * smoothstep(0.42, 0.78, pat) * FROST_STRENGTH;
                    col = mix(col, vec3(0.78, 0.86, 0.94), clamp01(frost));
                    col += vec3(0.10, 0.12, 0.14) * mask * smoothstep(0.85, 1.0, pat);
                }
            }
        }
    }

    if (isEyeInWater == 1) {
        // underwater tint + soft light shimmer
        //
        // v6.0: one vnoise instead of a full 8x8 lookup. The old term ran
        // value noise across eight cells per axis, which is 4 hash calls to
        // produce a low-frequency shimmer that the tint hides anyway.
        float shimmer = 0.85 + 0.15 * vnoise(vec2(texcoord.x * 8.0, texcoord.y * 8.0 - frameTimeCounter * 0.5));
        col *= vec3(0.55, 0.80, 0.95) * shimmer;
    }

    if (BLOOM) {
        // Five-tap cross bloom: very cheap, but gives sun, lamps and emissives a
        // soft photographic glow without blurring the whole frame.
        vec2 px = 1.0 / vec2(viewWidth, viewHeight);
        vec3 glow = vec3(0.0);
        float glowW = 0.0;
        vec2 offsets[5];
        offsets[0] = vec2(0.0);
        offsets[1] = vec2(1.0, 0.0);
        offsets[2] = vec2(-1.0, 0.0);
        offsets[3] = vec2(0.0, 1.0);
        offsets[4] = vec2(0.0, -1.0);

        // v6.0: the centre tap is colortex0 at texcoord, which was sampled
        // into rawCentre on the first line of main() and is still in
        // registers. Reusing it drops one of the five fetches - a fifth of
        // the bloom cost - for an identical result.
        //
        // It must be rawCentre, not col: by this point col has had godrays,
        // lightning, frost and underwater tint added to it, and using that
        // would let every one of those effects feed back into the bloom.
        glow += rawCentre;
        glowW += smoothstep(BLOOM_THRESHOLD, 1.15, luma(rawCentre));

        for (int i = 1; i < 5; i++) {
            vec3 s = texture2D(colortex0, texcoord + offsets[i] * px * 3.0).rgb;
            float b = smoothstep(BLOOM_THRESHOLD, 1.15, luma(s));
            glow += s * b;
            glowW += b;
        }

        if (glowW > 0.001) {
            col += glow / 5.0 * BLOOM_STRENGTH;
        }
    }

    // filmic tonemap (ACES, Narkowicz fit) for cohesive, filmic highlights
    col *= TONEMAP_EXPOSURE;
    col = clamp((col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14), 0.0, 1.0);

    float lum = luma(col);

    // Split toning: cool shadows, warm highlights. This is the grade step that
    // does the most to stop the frame reading as a single uniform plastic
    // material - a pure saturation + linear-contrast grade leaves every hue
    // pointing at the same point on the wheel.
    if (SHADOW_TINT && SHADOW_TINT_AMOUNT > 0.0) {
        float shMask = 1.0 - smoothstep(0.0, 0.55, lum);
        float hiMask = smoothstep(0.45, 1.0, lum);
        col += vec3( 0.020, -0.006,  0.070) * shMask * SHADOW_TINT_AMOUNT;
        col += vec3( 0.050,  0.020, -0.015) * hiMask * SHADOW_TINT_AMOUNT;
    }

    // final grade: saturation + gentle S-curve
    col = mix(vec3(luma(col)), col, SATURATION);
    if (CONTRAST != 1.0) {
        vec3 scurve = col * col * (3.0 - 2.0 * col);
        col = clamp(mix(col, scurve, clamp((CONTRAST - 1.0) * 3.0, 0.0, 1.0)), 0.0, 1.0);
    }
    float highlightMask = smoothstep(0.45, 1.0, lum);
    col += vec3(HIGHLIGHT_WARMTH, HIGHLIGHT_WARMTH * 0.55, 0.0) * highlightMask;

    // subtle vignette
    col *= 1.0 - VIGNETTE * smoothstep(0.35, 1.2, length(texcoord - 0.5) * 1.8);

    gl_FragData[0] = vec4(col, 1.0);
}
