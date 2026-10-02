#version 120

uniform sampler2D tex;
varying vec2 texcoord;

// Cutout alpha: without this leaves and grass cast solid square shadows.
void main() {
    if (texture2D(tex, texcoord).a < 0.5) discard;
}