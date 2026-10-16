// A slow colour gradient (the NeoEmacs bg-shader): the smallest useful background.
// Open this file in darger and press C-c C-c to run it behind the text,
// C-c C-o to see the picture alone, C-c C-k to stop it.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float t = iTime * 0.9;
    vec3 col = 0.5 + 0.5 * cos(t + uv.xyx * 3.0 + vec3(0.0, 2.0, 4.0));
    fragColor = vec4(col, 1.0);
}
