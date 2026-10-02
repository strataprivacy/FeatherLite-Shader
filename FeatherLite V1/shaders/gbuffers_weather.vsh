#version 120

uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

varying vec2 texcoord;
varying vec2 lmcoord;
varying vec3 worldPos;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.st;
    lmcoord = gl_MultiTexCoord1.st / 240.0;
    worldPos = (gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex).xyz + cameraPosition;
}
