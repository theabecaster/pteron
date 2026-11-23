/// The Metal shaders, compiled at run time on the render thread.
///
/// They are a Swift string, not a .metal file, because building .metal needs Xcode's optional
/// Metal Toolchain component, which the build machines don't have installed.
enum GhosttyShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Layouts match GhosttyRectInstance / GhosttyGlyphInstance / GhosttyUniforms in Swift.

struct GhosttyUniforms {
    float2 viewport;    // drawable size in pixels
    float2 cell;        // cell size in pixels
    float2 origin;      // top-left of the grid in pixels (fractional while scrolling smoothly)
    uint2 cursorCell;   // cell under a block cursor, 0xffff when there is none
    float4 cursorText;  // color of the glyph under a block cursor
    float4 matchText;   // text color of the current find match
    uint4 matchSpans[4]; // its rows: row, first column, last column
    uint matchCount;    // 0 while nothing is found
};

struct RectInstance {
    packed_short2 pos;    // x from the grid's left edge, y from the top of the row
    packed_ushort2 size;
    packed_uchar4 color;
    ushort row;
    ushort pad;
};

struct GlyphInstance {
    packed_short2 pos;
    packed_ushort2 size;
    packed_ushort2 uv;    // top-left texel in the atlas
    packed_uchar4 color;
    packed_ushort2 cell;  // column, row
    ushort kind;          // 1 mask atlas, 2 color atlas
    ushort pad;
};

struct RectOut {
    float4 position [[position]];
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float4 color;
    float2 texel;
    uint kind [[flat]];
};

static inline float4 toClip(float2 px, float2 viewport) {
    float2 ndc = px / viewport * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

vertex RectOut ghosttyRectVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device RectInstance *instances [[buffer(0)]],
                                 constant GhosttyUniforms &u [[buffer(1)]]) {
    RectInstance in = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 pos = float2(short2(in.pos)) + float2(0.0, float(in.row) * u.cell.y);
    float2 px = u.origin + pos + corner * float2(ushort2(in.size));
    float4 c = float4(uchar4(in.color)) / 255.0;
    RectOut out;
    out.position = toClip(px, u.viewport);
    out.color = float4(c.rgb * c.a, c.a);
    return out;
}

fragment float4 ghosttyRectFragment(RectOut in [[stage_in]]) {
    return in.color;
}

vertex GlyphOut ghosttyGlyphVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device GlyphInstance *instances [[buffer(0)]],
                                   constant GhosttyUniforms &u [[buffer(1)]]) {
    GlyphInstance in = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 size = float2(ushort2(in.size));
    ushort2 cell = ushort2(in.cell);
    float2 pos = float2(short2(in.pos)) + float2(0.0, float(cell.y) * u.cell.y);
    float2 px = u.origin + pos + corner * size;
    float4 c = float4(uchar4(in.color)) / 255.0;
    // Text in the current find match is black or white, whichever reads on its fill.
    if (in.kind == 1) {
        for (uint i = 0; i < u.matchCount; i++) {
            uint4 s = u.matchSpans[i];
            if (uint(cell.y) == s.x && uint(cell.x) >= s.y && uint(cell.x) <= s.z) {
                c = float4(u.matchText.rgb, c.a);
            }
        }
    }
    // Text under a block cursor takes the cursor's text color, as in Ghostty's shader.
    if (in.kind == 1 && uint(cell.x) == u.cursorCell.x && uint(cell.y) == u.cursorCell.y) {
        c = float4(u.cursorText.rgb, c.a);
    }
    GlyphOut out;
    out.position = toClip(px, u.viewport);
    out.color = c;
    out.texel = float2(ushort2(in.uv)) + corner * size;
    out.kind = in.kind;
    return out;
}

fragment float4 ghosttyGlyphFragment(GlyphOut in [[stage_in]],
                                     texture2d<float> mask [[texture(0)]],
                                     texture2d<float> color [[texture(1)]]) {
    // Quads are pixel-snapped, so each fragment maps to exactly one texel.
    uint2 texel = uint2(in.texel);
    if (in.kind == 2) {
        // Already premultiplied. Only alpha (faint) applies.
        return color.read(texel) * in.color.a;
    }
    float a = mask.read(texel).r * in.color.a;
    return float4(in.color.rgb * a, a);
}
"""#
}
