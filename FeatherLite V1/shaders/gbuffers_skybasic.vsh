#version 120

uniform mat4 gbufferModelViewInverse;
varying vec3 vWorldDir;

void main() {
    gl_Position = ftransform();
    // Dome vertex -> VIEW space (includes camera rotation) -> WORLD direction.
    // Skipping the first step made the sky rotate against the camera.
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vWorldDir = normalize(mat3(gbufferModelViewInverse) * viewPos);
}