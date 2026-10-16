// Plasma: layered sines in a dark palette, calm enough to read over.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord * 2.0 - iResolution.xy) / iResolution.y;
    float t = iTime * 0.4;
    float v = sin(uv.x * 3.0 + t) + sin((uv.y + t) * 2.5)
            + sin((uv.x + uv.y) * 2.0 + t * 1.3)
            + sin(length(uv * 4.0) - t * 2.0);
    v *= 0.25;
    vec3 col = vec3(0.05, 0.08, 0.16) + 0.35 * vec3(sin(v * 3.14159) * 0.5 + 0.5,
                                                   sin(v * 3.14159 + 2.0) * 0.5 + 0.5,
                                                   sin(v * 3.14159 + 4.0) * 0.5 + 0.5);
    fragColor = vec4(col, 1.0);
}
