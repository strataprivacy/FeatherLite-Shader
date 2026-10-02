#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

varying vec3 vWorldDir;

void main() {
    vec3 dir = normalize(vWorldDir);
    vec3 col = skyGradient(dir, sunDirWorld(), moonDirWorld(), rainStrength, frameTimeCounter);

if (LIGHTNING && !inEnd) {
    // sky lifts briefly when a bolt strikes nearby, scaled by distance
    float boltFlash = step(0.5, lightningBoltPosition.w)
                    * clamp01(1.0 - length(lightningBoltPosition.xyz) / 120.0);
    col += BOLT_COLOR * 0.12 * boltFlash;
}
/* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(col, 1.0);
}
