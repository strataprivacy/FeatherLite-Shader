#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/shadow.glsl"
#include "/lib/lighting.glsl"

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

    // ---- world-space lighting frame --------------------------------
    vec3 n = normalize(worldNormal);
    vec3 gn = n;   // geometric normal, used for shadow bias
    vec3 v = normalize(cameraPosition - worldPos);   // fragment -> camera

    // v6.0: sun/moon directions and day factor computed once here instead of
    // being rebuilt inside computeLighting (and again for the wave normal).
    vec3 l = sunDirWorld();
    vec3 lMoon = moonDirWorld();
    float day = smoothstep(-0.07, 0.18, l.y);

    float cold = coldFactor() * precipGate();
    float skyVis = smoothstep(0.2, 0.8, lmcoord.y);

    vec3 col;
    float alpha = albedo.a;
    vec3 surfN = n;          // shading normal, replaced by the wave normal
    float wet  = 0.0;

    if (matId > 10007.5 && matId < 10008.5) {
        // water: animated waves (freeze-slow in cold biomes)
        float t = frameTimeCounter * mix(1.0, 0.35, cold);
        float ph1x = worldPos.x * 0.9 + t * 1.7;
        float ph1z = worldPos.z * 0.9 - t * 1.5;

        // v6.0: DROPPED the third wave term (ph2, a diagonal at a different
        // scale and speed). It was 0.5 amplitude of a sin against two terms at
        // 1.0, and its only visible effect was a slight extra shimmer on the
        // wave normal. Removing it takes three sin/cos and two extra
        // multiplies out of the water shader, and water is a large part of the
        // screen when it is on screen at all.
        float ph2  = (worldPos.x + worldPos.z) * 0.45 + t * 2.3;
        float wave = (sin(ph1x) * sin(ph1z) + sin(ph2) * 0.5) * WAVE_INTENSITY;

        vec3 waterCol = mix(vec3(luma(albedo.rgb)), albedo.rgb, 1.25) * (1.0 + wave);
        waterCol = mix(waterCol, ICE_TINT, cold * 0.45);

        // analytic wave normal (derivative of the same sines) -> moving
        // sparkles and a correct fresnel silhouette
        float dhx = 0.9 * cos(ph1x) * sin(ph1z) + 0.45 * cos(ph2);
        float dhz = 0.9 * sin(ph1x) * cos(ph1z) + 0.45 * cos(ph2);
        surfN = normalize(vec3(-dhx, 3.0, -dhz));
        // Not 1.0: a fully smooth GGX lobe concentrates so much energy that the
        // glints read as hard white dots. 0.55 gives a moving sparkle.
        wet   = mix(0.55, 0.20, cold);   // ice is smoother, but frozen

        // Water is always a wet surface, so the shared GGX path handles both
        // the sun glint and the grazing-angle sky reflection for us.
        vec3 diffuseLight, specLight, sh;
        computeLighting(surfN, gn, v, worldPos, lmcoord, wet, l, lMoon, day, skyVis,
                        diffuseLight, specLight, sh);

        if (!WATER_GLINT) specLight *= 0.35;

        col = waterCol * diffuseLight + specLight;

        // fresnel: view straight down -> transparent, grazing -> reflective
        float fres = pow(1.0 - clamp01(dot(v, surfN)), 3.0);
        alpha = mix(mix(WATER_ALPHA, 0.95, fres), 0.92, cold * 0.35);
    } else {
        // other translucents: stained glass, ice, portals...
        // Same normal treatment as terrain, so glass and ice do not read as
        // perfectly smooth plastic panes. (The water branch above does NOT get
        // this: it already has an analytic wave normal.)
        n = textureBump(n, texcoord, tex, distance(worldPos, cameraPosition));
        n = faceVariation(n, worldPos);
        wet = clamp01(n.y * 0.7 + 0.3) * wetness * skyVis;
        if (MICRO_DETAIL > 0.0) albedo.rgb *= 1.0 + microDetail(worldPos, texcoord);

        vec3 diffuseLight, specLight, sh;
        computeLighting(n, gn, v, worldPos, lmcoord, wet, l, lMoon, day, skyVis,
                        diffuseLight, specLight, sh);

        float torch = pow(lmcoord.x, 3.0);
        col = albedo.rgb * (diffuseLight + TORCH_COLOR * torch * 0.6) + specLight;
    }

    if (LIGHTNING) {
        if (lightningBoltPosition.w > 0.5) {
            float boltDist = distance(worldPos - cameraPosition, lightningBoltPosition.xyz);
            col += BOLT_COLOR * inverseSquare(boltDist, BOLT_STRENGTH * 0.7) * albedo.a;
        }
    }

    col = applyFog(col, distance(worldPos, cameraPosition), fogStart, fogEnd, fogColor,
                   FOG_INTENSITY * (1.0 + rainStrength * 0.75));

    gl_FragData[0] = vec4(col, alpha);
}
