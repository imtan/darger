// A drifting starfield on black: the text stays readable without dimming.
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec3 col = vec3(0.0);
    for (int layer = 0; layer < 3; layer++) {
        float depth = 1.0 + float(layer);
        vec2 uv = fragCoord / iResolution.y * depth * 40.0 + vec2(iTime * 2.0 * depth, 0.0);
        vec2 cell = floor(uv);
        vec2 f = fract(uv);
        float h = hash(cell + float(layer) * 17.0);
        vec2 star = vec2(hash(cell + 1.3), hash(cell + 7.1));
        float d = length(f - star);
        float twinkle = 0.6 + 0.4 * sin(iTime * (2.0 + h * 4.0) + h * 20.0);
        float bright = smoothstep(0.08, 0.0, d) * step(0.92, h) * twinkle / depth;
        col += bright * vec3(0.8 + 0.2 * h, 0.85, 1.0);
    }
    fragColor = vec4(col, 1.0);
}
