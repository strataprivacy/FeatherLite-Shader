#version 120
#include "/lib/settings.glsl"

varying vec2 texcoord;

// Must apply the SAME warp the lookup in lib/shadow.glsl uses.
void main() {
    texcoord = gl_MultiTexCoord0.st;
    gl_Position = ftransform();
    float f = 1.0 - SHADOW_BIAS + length(gl_Position.xy) * SHADOW_BIAS;
    gl_Position.xy /= f;
    gl_Position.z  *= 0.2;
}