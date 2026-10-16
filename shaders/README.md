# Background shaders

Shadertoy-style samples for darger's background shader (see the README's
"Background shader"). Open one and press C-c C-c to run it behind the text, C-c C-o
to see the picture alone, C-c C-k to stop it; or start with it:

```lisp
(background-shader "~/path/to/darger/shaders/stars.glsl")
(setq background-shader-dim 0.6)   ; 0 = picture only
```

`mainImage(out vec4 fragColor, in vec2 fragCoord)` receives `iResolution`, `iTime`,
`iMouse` and `iFrame`; a whole `#version 410 core` fragment shader with its own
`main` works too. Compile errors go to the echo line and the `*shader*` buffer.
