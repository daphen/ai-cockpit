#version 440
// Context meter fill: the ThinkingOrb aurora field (QsLib aurora.frag) masked to a
// pill that fills from the left. Compile: qsb --glsl "100 es,120,150" --hlsl 50 --msl 12
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float ph1;
    float ph2;
    float ph3;
    float ph4;
    vec4 colA;
    vec4 colB;
    vec4 colC;
    float angle;
    float bandX;
    float bandY;
    float warp;
    float gain;
    float feather;
    float bright;
    float swirl;
    float plasma;
    float fill;     // 0..1
    float aspect;   // width / height
    float pixel;    // one device-independent pixel in uv units
} ubuf;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + vec2(17.31, 9.17);
        a *= ubuf.gain;
    }
    return v;
}

void main() {
    vec2 uv = (qt_TexCoord0 * 2.0 - 1.0) * vec2(ubuf.aspect, 1.0);
    vec2 pq = abs(uv) - vec2(ubuf.aspect - 1.0, 0.0);
    float pd = length(max(pq, 0.0)) + min(max(pq.x, pq.y), 0.0) - 1.0;
    float front = (ubuf.fill * 2.0 - 1.0) * ubuf.aspect;
    float mask = (1.0 - smoothstep(-ubuf.pixel, ubuf.pixel, pd))
               * (1.0 - smoothstep(front - ubuf.pixel, front + ubuf.pixel, uv.x)) * step(0.001, ubuf.fill);
    float r = abs(uv.y);
    float c = cos(ubuf.angle), sn = sin(ubuf.angle);
    vec2 u = mat2(c, -sn, sn, c) * uv;
    // liquid: the whole constellation swirls back and forth
    float ga = ubuf.swirl * 0.7 * sin(ubuf.ph1);
    float gc = cos(ga), gs = sin(ga);
    u = mat2(gc, -gs, gs, gc) * u;
    vec2 d1 = vec2(cos(ubuf.ph1), sin(ubuf.ph2));
    vec2 d2 = vec2(cos(ubuf.ph2 + 2.1), sin(ubuf.ph3 + 1.0));
    vec2 d3 = vec2(cos(ubuf.ph3 + 4.2), sin(ubuf.ph4 + 3.1));
    vec2 d4 = vec2(cos(ubuf.ph4 + 0.7), sin(ubuf.ph1 + 2.6));
    // Fluid gradient: features LARGER than the disc. Iso-lines of a compact
    // source are closed loops (an outlined blob); only sub-viewport-frequency
    // warped noise gives the open folds that sweep across and out of frame.
    vec2 b = u * (0.8 / max(0.3, ubuf.bandX));
    vec2 q = vec2(fbm(b + d1), fbm(b + vec2(3.7, 1.9) + d2));
    float vraw = fbm(b + ubuf.warp * (q - 0.45) + d4);
    float v = smoothstep(0.22, 0.62, vraw);
    // second field for the bright islands: same space, rotated warp, own drift
    float praw = fbm(b * (1.1 + 0.2 * ubuf.bandY) + ubuf.warp * 0.8 * vec2(q.y, -q.x) + vec2(9.1, 4.7) + d3);
    float pl = smoothstep(0.30, 0.60, praw);
    // Same gradient floor as vb below, own phase: a saturated crest field made
    // the whole disc bright regardless of the base ramp.
    float ga3 = ubuf.ph3 + 1.7;
    pl -= 0.18 * (dot(u, vec2(cos(ga3), sin(ga3))) * 0.5 + 0.5);

    // fluid-gradient color zones: deep ground -> swept mid body -> bright
    // islands, boundaries wide but DEFINED (satin, not fog)
    float vb = v + (ubuf.bright - 0.5) * 0.6;
    // Gradient floor: the drifting fbm occasionally passes a low-variance
    // stretch and the whole disc lands in ONE zone (all-dark / all-light).
    // A slowly rotating linear ramp guarantees ~0.32 of spread across the
    // disc at all times; with healthy noise it is an invisible bias.
    // FULL-rate phase: ph2*0.5 was 4pi-periodic, so the ramp direction snapped
    // 180 degrees at every 2pi phase wrap — the visible "jank back".
    float ga2 = ubuf.ph2;
    vb += 0.22 * dot(u, vec2(cos(ga2), sin(ga2)));
    // ...plus a radial term: tilt alone is planar and the wide feather washes
    // it out; center-vs-rim contrast survives the softest blend.
    vb += 0.10 * (0.6 - r);
    float fw = mix(0.10, 0.45, ubuf.feather);
    float s1 = smoothstep(0.55 - fw, 0.55 + fw, vb);
    vec3 col = mix(ubuf.colA.rgb, ubuf.colB.rgb, s1);
    float s2 = smoothstep(0.80 - fw * 0.6, 0.92, pl + (ubuf.bright - 0.5) * 0.3);
    col = mix(col, ubuf.colC.rgb, s2 * 0.92);
    // the fold: a thin luminous crease along the deep|mid interface — the
    // satin seam that sells the reference
    float cr = exp(-pow(vb - 0.55, 2.0) / 0.0032);
    col += ubuf.colC.rgb * cr * (0.55 * clamp(ubuf.plasma, 0.0, 1.0));
    col *= 1.0 - 0.12 * smoothstep(0.55, 1.0, r);
    fragColor = vec4(col, 1.0) * mask * ubuf.qt_Opacity;
}
