#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Only the photographic layer enters this lens. Text and controls remain perfectly crisp.
//
// A bounded glass. The first version sheared the sample point by up to 22 px at the screen
// edges and every circle that reached the side tore into a rainbow-fringed teardrop; a version
// with no geometry at all read as flat. This one pulls the image outward by at most 22 px across
// the outer quarter of the width with a quadratic falloff, adds a chromatic split, a glare that
// follows the finger and a thin edge light. White remains white; the photographs supply the
// refracted color.
[[ stitchable ]] half4 welcomeRefraction(float2 p, SwiftUI::Layer layer, float2 size,
                                         float2 touch, float contact, float time) {
    float2 uv = p / max(size, float2(1));
    float2 d = uv - 0.5;
    float side = smoothstep(0.44, 1.0, abs(d.x) * 2.0);
    float ends = smoothstep(0.84, 1.0, abs(d.y) * 2.0) * 0.5;
    float lens = max(side, ends);
    float pull = pow(lens, 1.5);
    // The glass: across the outer quarter of the screen the image is pulled outward, so a circle
    // passing the edge stretches toward it the way it would behind a thick pane. Bounded at
    // 22 px with a 1.5-power falloff — roughly half the first version, which tore circles into
    // teardrops — and the slow vertical ripple keeps a resting screen breathing.
    float2 warp = float2(sign(d.x) * 22.0, sin(uv.y * 6.0 + time * 0.07) * 5.0) * pull;
    float2 samplePoint = p - warp;
    float2 split = float2(2.4, 0.8) * pull;
    half4 r = layer.sample(samplePoint + split);
    half4 g = layer.sample(samplePoint);
    half4 b = layer.sample(samplePoint - split);
    // Composite over white BEFORE separating channels: transparent pixels must never seam.
    half3 color = clamp(half3(r.r + 1.0h - r.a, g.g + 1.0h - g.a, b.b + 1.0h - b.a), 0.0h, 1.0h);
    float distance = length((p - touch) / float2(135.0, 175.0));
    float touchLight = exp(-distance * distance * 2.5) * contact * 0.16;
    float edgeLight = pow(max(0.0, 1.0 - abs(side - 0.70) / 0.22), 3.0) * 0.10;
    color = mix(color, half3(1.0), half(max(touchLight, edgeLight)));
    return half4(color, 1.0h);
}
