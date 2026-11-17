/// Metal source for the launch sticker peel, compiled at runtime with `makeLibrary(source:)` so the
/// build needs no Metal toolchain.
///
/// The sticker is a `StickerPeelKit.grid` x `grid` vertex mesh over the art rect, in UIKit points
/// (y down, z toward the viewer). A cylinder of radius R rolls along `d` from the art's corner: points
/// behind the fold line wrap around it, and past `phiMax` they leave it as a straight tail. Both
/// passes bend the same vertices: the sticker (two-sided, lit) and its shadow on the screen.
///
/// `Uniforms` must match `StickerPeelUniforms` in StickerPeelRenderer.swift, field for field.
let stickerPeelShaderSource = """
#include <metal_stdlib>
using namespace metal;

constant uint N = \(StickerPeelKit.grid);

struct Uniforms {
    float4 art;     // art rect origin.xy, size.wh (points)
    float4 peel;    // peel origin c0.xy, unit direction d.xy
    float4 curl;    // fold line p, radius R, max wrap angle, eye distance D
    float4 view;    // screen centre.xy, size.wh (points)
    float4 shade;   // shadow opacity, shadow reach per point of height, unused, unused
    float4x4 rigid; // carries the detached sticker away
};

struct Sheet { float3 pos; float3 n; float s; };

static Sheet bend(uint vid, constant Uniforms &u, thread float2 &uv) {
    uv = float2(vid % N, vid / N) / float(N - 1);
    float2 x = u.art.xy + uv * u.art.zw;
    float2 d = u.peel.zw;
    float p = u.curl.x, R = u.curl.y, phiMax = u.curl.z;
    float s = p - dot(x - u.peel.xy, d);          // > 0: peeled, this far behind the fold line
    float3 pos = float3(x, 0.0);
    float3 n = float3(0.0, 0.0, 1.0);
    if (s > 0.0) {
        float phi = min(s / R, phiMax);
        float e = s - R * phi;                        // straight tail past the cylinder
        float along = R * sin(phi) + e * cos(phi);
        pos = float3(x + d * (s - along), R * (1.0 - cos(phi)) + e * sin(phi));
        n = float3(d * sin(phi), cos(phi));
    }
    pos = (u.rigid * float4(pos, 1.0)).xyz;
    n = (u.rigid * float4(n, 0.0)).xyz;
    return { pos, n, max(s, 0.0) };
}

// Perspective about the screen centre with the eye D points away; z = 0 maps 1:1 onto points, and
// w carries the depth so texture coordinates stay perspective-correct.
static float4 project(float3 pos, constant Uniforms &u) {
    float w = (u.curl.w - pos.z) / u.curl.w;
    float2 ndc = (pos.xy - u.view.xy) * 2.0 / u.view.zw;
    return float4(ndc.x, -ndc.y, (0.5 - pos.z / 4000.0) * w, w);
}

struct StickerOut {
    float4 position [[position]];
    float2 uv;
    float3 n;
    float s;
};

vertex StickerOut sticker_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv;
    Sheet sh = bend(vid, u, uv);
    return { project(sh.pos, u), uv, sh.n, sh.s };
}

fragment float4 sticker_fragment(StickerOut in [[stage_in]], bool front [[front_facing]],
                                 texture2d<float> art [[texture(0)]], texture2d<float> backing [[texture(1)]],
                                 sampler smooth [[sampler(0)]], sampler exact [[sampler(1)]],
                                 constant Uniforms &u [[buffer(0)]]) {
    // Still stuck: the launch screen's own texels, untouched, so the first frame matches it exactly.
    if (in.s <= 0.0) { return art.sample(exact, in.uv); }
    // Full detail only: smaller mips would bleed color past the outline where the fold squeezes the mesh.
    float4 c = art.sample(smooth, in.uv, level(0.0));
    // The paper side is cut to the art's outline with the seams inside it closed: where the art's
    // shapes meet, its alpha dips, and paper cut with that would show a hairline of what is behind.
    float cover = front ? c.a : backing.sample(smooth, in.uv, level(0.0)).r;
    if (cover <= 0.002) { discard_fragment(); }       // no depth from the clear parts of the sheet
    float3 n = normalize(in.n);
    if (!front) { n = -n; }
    float3 L = normalize(float3(-0.35, -0.55, 0.75)); // top left, in front
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    const float ka = 0.55, kd = 0.45;
    // Normalized so a flat sheet gets exactly 1 and no gloss.
    float lit = (ka + kd * max(dot(n, L), 0.0)) / (ka + kd * L.z);
    if (front) {
        float gloss = 0.35 * max(pow(max(dot(n, H), 0.0), 48.0) - pow(H.z, 48.0), 0.0);
        return float4(c.rgb * lit + gloss * c.a, c.a);
    }
    // The backing: pale paper in the art's silhouette, darker in the fold where the light can't reach.
    float R = u.curl.y;
    float fold = mix(0.72, 1.0, smoothstep(0.0, 1.5 * R, in.s - 0.5 * M_PI_F * R));
    float gloss = 0.2 * max(pow(max(dot(n, H), 0.0), 24.0) - pow(H.z, 24.0), 0.0);
    float3 paper = float3(0.925, 0.910, 0.885);
    return float4((paper * lit * fold + gloss) * cover, cover);
}

struct ShadowOut {
    float4 position [[position]];
    float2 uv;
    float z;
};

// The sheet dropped onto the screen, pushed down and right (away from the light) by its height.
vertex ShadowOut shadow_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv;
    Sheet sh = bend(vid, u, uv);
    float z = max(sh.pos.z, 0.0);
    float2 xy = sh.pos.xy + z * u.shade.y * float2(0.35, 0.6);
    return { project(float3(xy, 0.01), u), uv, z };
}

fragment float4 shadow_fragment(ShadowOut in [[stage_in]], texture2d<float> art [[texture(0)]],
                                sampler smooth [[sampler(0)]], constant Uniforms &u [[buffer(0)]]) {
    float contact = smoothstep(0.0, 2.0, in.z);       // nothing under the stuck part
    if (contact <= 0.0) { discard_fragment(); }
    // Sharp at the fold, softer under the high tail: blur by reading smaller mips.
    float a = art.sample(smooth, in.uv, level(log2(1.0 + in.z / 4.0))).a;
    float o = u.shade.x * contact * (1.0 - 0.6 * smoothstep(0.0, 140.0, in.z)) * a;
    if (o <= 0.002) { discard_fragment(); }
    return float4(0.0, 0.0, 0.0, o);
}
"""
