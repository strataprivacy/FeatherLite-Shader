#version 120

varying vec2 texcoord;
varying vec4 glcolor;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.st;
    glcolor = gl_Color;
}
