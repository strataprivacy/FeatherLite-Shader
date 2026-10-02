#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/shadow.glsl"
#include "/lib/lighting.glsl"

uniform sampler2D tex;
uniform vec4 entityColor;
uniform vec3 fogColor;
uniform float fogStart;
uniform float fogEnd;

varying vec2 texcoord;
varying vec2 lmcoord;
varying vec4 glcolor;
varying vec3 worldPos;
varying vec3 worldNormal;

void main() {
    vec4 albedo = texture2D(tex, texcoord) * glcolor;
    if (albedo.a < 0.1) discard;
    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);
    albedo.rgb = mix(vec3(luma(albedo.rgb)), albedo.rgb, 1.15);

    // ---- world-space lighting frame (identical to terrain) -----------
    vec3 n = normalize(worldNormal);
    vec3 gn = n;   // geometric normal, used for shadow bias
    n = textureBump(n, texcoord, tex, distance(worldPos, cameraPosition));
    n = faceVariation(n, worldPos);

    vec3 v = normalize(cameraPosition - worldPos);   // fragment -> camera

    // v6.0: computed once and passed down, as in terrain.
    vec3 l = sunDirWorld();
    vec3 lMoon = moonDirWorld();
    float day = smoothstep(-0.07, 0.18, l.y);
    float skyVis = smoothstep(0.2, 0.8, lmcoord.y);

    // Mobs in the rain get the same wet darkening as terrain, otherwise they
    // stand out as clean, unshaded props sitting in a soaked world.
    float wet = 0.0;
    if (WET_GROUND) {
        float wetExposure = clamp01(n.y * 0.7 + 0.3);
        wet = wetness * wetExposure * skyVis;
        albedo.rgb *= 1.0 - WET_DARKEN * wet;
    }

    if (MICRO_DETAIL > 0.0) {
        albedo.rgb *= 1.0 + microDetail(worldPos, texcoord);
    }

    vec3 diffuseLight, specLight, sh;
    computeLighting(n, gn, v, worldPos, lmcoord, wet, l, lMoon, day, skyVis,
                    diffuseLight, specLight, sh);

    vec3 col = albedo.rgb * diffuseLight + specLight;

    if (LIGHTNING) {
        // entities get lit up by nearby strikes too
        if (lightningBoltPosition.w > 0.5) {
            float boltDist = distance(worldPos - cameraPosition, lightningBoltPosition.xyz);
            col += BOLT_COLOR * inverseSquare(boltDist, BOLT_STRENGTH) * boltFlicker();
        }
    }

    col = applyFog(col, distance(worldPos, cameraPosition), fogStart, fogEnd, fogColor,
                   FOG_INTENSITY * (1.0 + rainStrength * 0.75));

    gl_FragData[0] = vec4(col, albedo.a);
}
