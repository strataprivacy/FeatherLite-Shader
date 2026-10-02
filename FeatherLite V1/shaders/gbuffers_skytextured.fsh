#version 120
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform sampler2D tex;
varying vec2 texcoord;
varying vec4 glcolor;

void main() {
    // The End has its own full-sky galaxy texture. Suppress the vanilla
    // sun/moon sprite pass so it cannot wash the galaxy out.
    if (inEnd) {
        gl_FragData[0] = vec4(0.0);
        return;
    }
    vec4 col = texture2D(tex, texcoord) * glcolor;
    col.rgb *= 1.08;
    gl_FragData[0] = col;
}
