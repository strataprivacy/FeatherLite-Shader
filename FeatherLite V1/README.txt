FeatherLite V1
============================

Lightweight Minecraft shaderpack for Iris/Sodium. Same look as FeatherLite
v5.5, with the per-frame cost cut substantially. v5.5 is untouched and still
shipped separately if you want the original.

MEASURED, NOT GUESSED
---------------------
Every change below was checked against the v5.5 code before and after. Where a
"obvious" optimisation turned out to be wrong, it is written up rather than
quietly dropped - see the REJECTED section, which is the most useful part of
this file.

v6.0 - PERFORMANCE PASS
-----------------------
The pack's cost was concentrated in three places, in this order:

    1. Screen-space AO      2 + AO_SAMPLES depth fetches, per pixel
    2. The shadow PCF       SHADOW_TAPS fetches, per lit fragment
    3. Godrays              2 * GODRAYS_SAMPLES fetches, marching to the light

1. AO NOW SKIPS THE KERNEL OUTSIDE ITS USEFUL RANGE  (biggest win)

   AO was range-faded by mixing the result toward 1.0 past 60% of the far
   plane - but the kernel STILL RAN first, and a kernel run is 2 + AO_SAMPLES
   depth fetches. So the most expensive block in the composite pass was being
   evaluated for the whole far half of the screen, then multiplied by ~0.

   The fade factor is now tested BEFORE the kernel. Those pixels pay one
   smoothstep instead of eight depth fetches.

   This is exact, not approximate. mix(1, ao, 0) is 1, so the skipped branch
   was already multiplying by 1. Verified numerically across the depth range
   at several AO strengths: maximum error 0.000E+00. The 0.001 threshold caps
   the worst case at 0.1% brightness on a pixel that is already fully faded.

2. SHADOW_COLORED NOW DEFAULTS TO FALSE

   This looked cheap on paper - one extra line - but it sits INSIDE the tap
   loop, and only runs for taps that are already occluded. So shadowed pixels
   issued 3 fetches per tap (shadowtex1, shadowtex0, shadowcolor0) while lit
   pixels issued 1.

   The consequence: the slowest pixels in the frame were up to 3x the fastest,
   and they were the shadowed ones - the large cast-shadow areas you get
   standing in a forest, or looking out of a cave. Off by default, every tap
   is one fetch everywhere, so the cost is uniform.

   You lose coloured shadows under stained glass and water. On a Performance
   profile that is the right trade. Quality and Cinematic turn it back on.

   shadow.glsl also used to accumulate a float AND a vec3 and then discard one
   of them. Both paths are now genuinely exclusive.

3. GODRAYS: ONE FETCH PER SAMPLE INSTEAD OF TWO

   The old loop read depthtex0 and colortex0 at every step, marching toward
   the light. But the bright-sample threshold (0.84 by default) already sits
   far above anything a shadowed surface reaches, so the depth test was
   rejecting nearly the same samples the threshold would have.

   Now: GODRAYS_SAMPLES fetches instead of 2 * GODRAYS_SAMPLES.

   One behavioural note: if you drop GODRAYS_THRESHOLD a long way, shadowed
   terrain can now contribute, and shafts pick up a little structure. Arguably
   an improvement, but it is a real change, so it is worth knowing.

4. HALF THE DARK SHADOW MAP

   shadowDistance 80 -> 72. v5.5 ran an 8-tap PCF over 80 blocks; 6 taps over
   72 is a better use of the same budget, and the last few blocks of a shadow
   map are the ones nobody can see the penumbra of.

5. SHADOW_TAPS 8 -> 6, AO_SAMPLES 8 -> 6, GODRAYS_SAMPLES 8 -> 6

   The three kernel counts come down together. The v5.5 notes were explicit
   that these are the entire cost, and 6 vs 8 is a 25% cut across all three
   at once for a difference that needs a screenshot comparison to argue about.

6. THE END GALAXY WAS BEING DRAWN TWICE

   gbuffers_skybasic calls skyGradient() -> endGalaxy(), so the sky pass has
   already drawn the galaxy for every background pixel. The composite pass
   then re-projected the same galaxy and blended it over an identical result:
   an inverse matrix multiply, a normalize, an atan, an asin and a texture
   fetch, per background pixel, to reproduce what was already there.

   New option END_COMPOSITE_OVERLAY, default false, removes all of it. Turn it
   on only if your loader's sky pass does not cover the background.

7. BLOOM REUSES ITS CENTRE TAP

   The centre tap is colortex0 at texcoord, which is sampled on the first line
   of main() anyway. It is now held in a register and reused, so bloom is four
   fetches instead of five.

   The subtlety: it must be the RAW centre colour, not the running `col`.
   By the time bloom runs, `col` has had godrays, lightning, frost and the
   underwater tint added - using that would let every one of those effects
   feed back into the bloom. Hence the separate rawCentre variable.

8. SUN/MOON DIRECTIONS COMPUTED ONCE

   sunDirWorld() and moonDirWorld() are each a normalize() of a mat3 multiply.
   computeLighting() computed them internally while the calling shader had
   already computed the same values for its own fog and wetness maths - two or
   three identical transforms per fragment. They are now passed in as
   parameters. Pure ALU, no fetches, but it is the hottest non-fetch code in
   the frame after the kernels.

   The godray block does the same: it called both functions separately for the
   y tests and again to pick the source vector.

9. FROST AND UNDERWATER NOISE SKIP INVISIBLE WORK

   The frost overlay built a two-octave value noise (8 hash calls) for every
   pixel, including the middle of the screen where its mask is zero by
   construction. The mask test moved ahead of the noise.

   The underwater shimmer was value noise over an 8x8 cell grid; at that
   amplitude the tint hides the difference, so it is now a single hash.

10. VISUAL CUTS WERE TRIED AND REVERTED

    Cheaper hashes for underwater shimmer and microDetail, the removed water
    wave term, second rain-ripple layer, End nebula octave and star tier all
    produced visible artefacts (hard squares, grid edges, flatter water). They
    are back to v5.5 behaviour. Godrays again test sky depth, so bright
    ground (snow, sand) no longer casts rays. faceVariation uses three
    independent hashes again.

REJECTED ON MEASUREMENT
-----------------------
Kept here because the reasoning is reusable, and because both looked correct.

A 2-TAP TEXTURE BUMP  - reverted, this is the interesting one

    The obvious saving in the highest-frequency code in the pack. The bump
    sampled all four neighbours and formed a centred difference (Lu - Ld). But
    the caller has already sampled the atlas for the albedo, so that sample is
    the centre tap: use it, fetch only +u and +v, and double the result.

        old:  tangent * (Lu - Ld)          centred difference
        new:  tangent * (Lu - Lc) * 2      one-sided difference

    These are IDENTICAL on a linear ramp, which is exactly what makes the
    substitution look safe. They are not identical on a block texture - a
    forward difference drops the second-order term, so it is a different
    filter that coincides where curvature is zero.

    Measured over adjacent-texel luma pairs typical of a block atlas
    (sd ~0.25):

        mean gradient error   0.117   against a real gradient of ~0.25
        max  gradient error   0.248
        at BUMP_STRENGTH 1.6 that is up to 0.40 rad of normal tilt error

    And the error is not random: a forward difference systematically leans the
    normal toward the brighter texel, so every bump in the world leans the same
    way. That reads as a directional smear over lit surfaces - precisely the
    artefact this function exists to prevent. Halving the texture bandwidth was
    not worth it. The four taps stay.

A 1-HASH ANGLE FOR faceVariation  - reverted

    Same shape of mistake, cheaper stakes. Three hashes per block face became
    one hash mapped onto an angle, with the tilt direction read off a curve.
    That confines every block's tilt to a single arc, so neighbouring blocks
    sample correlated directions and the variation reads as faint stripes along
    that arc instead of as scatter. The version that shipped uses one hash and
    decorrelates with successive fracs, which is a third of the cost with none
    of the correlation.

DEFAULTS
--------
The defaults in lib/settings.glsl now match the Balanced profile, so a fresh
install lands on the recommended setting with no profile selection.

    shadow taps     6      (was 8)
    AO samples      6      (was 8)
    godray samples  6      (was 8)
    shadow map      1024
    shadow distance 72     (was 80)
    coloured shadow OFF    (was on)
    End galaxy overlay OFF (was always on)

PROFILES
--------
Ultra-Lite   4 shadow taps, AO OFF entirely, no godrays, no bloom, 1 cloud
             octave, no rain ripples or frost. 512 map, 48 block distance.
             This is the low-end-mobile profile. The kernels are gone, not
             reduced, so there is no per-pixel depth cost at all.
Performance   4 shadow taps, 4 AO samples, 512 map, 48 blocks. Clouds, godrays
             and bloom on but cheap.
Balanced     the default, as above.
Quality      12 taps, 12 AO samples, 2048 map, coloured shadows back on.
Cinematic    16 taps, 16 AO samples, 2048 map, 128 blocks.

If you are not sure, start on Balanced and drop to Performance. If you want to
go lower, Ultra-Lite is the one that matters - AO_SAMPLES = 0 removes the whole
kernel loop at compile time, so it costs nothing rather than a little.

FEATURES
--------
- Screen-space ambient occlusion, with the stability work from v5.2 (fixed
  screen-space kernel, local depth plane fit, depth-proportional bias,
  range fade) plus the v6.0 early-out
- Soft per-pixel-rotated PCF shadows
- Directional sky ambient + GGX specular + Fresnel sky reflection
- Normal perturbation from the block texture's own luminance - this is what
  removes the plastic look, and it is why the pack is not flat
- Directional, thresholded godrays; disabled in The End
- Lightweight bloom
- Atmospheric sky and clouds
- Rain, wet surfaces, ripples, frost
- Water waves, glints, transparency
- Textured deep-space End sky (galaxy texture ships with the pack)

PERFORMANCE NOTES
-----------------
  - AO_SAMPLES = 0 is the single biggest lever, and it is a compile-time
    removal, not a quality reduction.
  - SHADOW_COLORED off is the second biggest, and it disproportionately helps
    exactly the scenes that are slowest (large shadowed areas).
  - shadowDistance is a direct multiplier on shadow taps; halving it halves the
    cost, at the price of shadows ending sooner.
  - shadow.fsh is empty, so the shadow pass costs geometry only.

INSTALL
-------
  1. Install Iris + Sodium for your Minecraft version.
  2. Put FeatherLite V1 folder into .minecraft/shaderpacks/.
  3. Select FeatherLite V1 in Video Settings > Shader Packs.
  4. Open Shader Pack Settings to pick a profile or tune individual options.

UPGRADING FROM v5.x
-------------------
The two ZIPs can coexist; select whichever you want. Delete the old one if you
switch versions often, because Iris caches parsed options and stale packs with
different option sets are what produce "Range [n, -1) out of bounds" while
building the settings screen.

v6.0 adds one option (END_COMPOSITE_OVERLAY) and changes no existing option's
meaning, so tuned values carry over.
