#version 460 core
uniform vec3 u_colour;
out vec4 f_colour;
void main() {
    f_colour = vec4(u_colour, 1.0);
}
