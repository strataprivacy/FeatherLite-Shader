#version 120

uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

varying vec2 texcoord;
varying vec2 lmcoord;
varying vec4 glcolor;
varying vec3 worldPos;
varying vec3 worldNormal;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.st;
    lmcoord = gl_MultiTexCoord1.st / 240.0;
    glcolor = gl_Color;

    mat4 worldMatrix = gbufferModelViewInverse * gl_ModelViewMatrix;
    // modelview*vertex is CAMERA-RELATIVE; add cameraPosition for true world space.
    worldPos = (worldMatrix * gl_Vertex).xyz + cameraPosition;
    worldNormal = normalize(mat3(worldMatrix) * gl_Normal);
}
