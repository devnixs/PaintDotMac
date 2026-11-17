#include <metal_stdlib>
using namespace metal;

// The Metal display compositor's blend kernels (spec 0024 item 3). All arithmetic is
// integer and bit-exact with BlendOps.swift / TileMipmapper.swift — the golden tests'
// ±1 tolerance is a safety margin, not an expected difference. One kernel per BlendMode
// case, named exactly `BlendMode.rawValue`; 0026/0027/0059 add one `…Op` struct and one
// kernel per new case (AGENTS.md *Code style*).

/// Mirrors the Swift `LayerBlendUniforms` in `MetalCompositor.swift` — keep both in sync.
/// The explicit `_padding` makes the layout unambiguous (both fields after it sit at
/// their C offsets); Swift asserts the matching `validSize` offset in its tests.
struct LayerBlendUniforms {
    uint opacity;
    uint _padding;
    uint2 validSize;
};

/// `round(a·b / 255)` exactly — 0009's rounding: `t = a·b + 128; ((t >> 8) + t) >> 8`.
static inline uint mul255(uint a, uint b) {
    uint t = a * b + 128;
    return ((t >> 8) + t) >> 8;
}

/// 0009's Normal formula verbatim (Porter-Duff source-over, straight alpha, uint
/// arithmetic, truncating division): `Sa == 0` → `dst` unchanged bit for bit; else
/// `fa = Sa·255 + Da·(255 − Sa)`, `outA = (fa + 127) / 255`,
/// `outC = (Sc·Sa·255 + Dc·Da·(255 − Sa) + fa/2) / fa` per channel.
static inline uint4 blend_normal_op(uint4 dst, uint4 src) {
    uint sa = src.a;
    uint da = dst.a;
    if (sa == 0) { return dst; }
    uint fa = sa * 255 + da * (255 - sa);
    uint outA = (fa + 127) / 255;
    uint halfFa = fa / 2;
    uint inverse = 255 - sa;
    uint r = (src.r * sa * 255 + dst.r * da * inverse + halfFa) / fa;
    uint g = (src.g * sa * 255 + dst.g * da * inverse + halfFa) / fa;
    uint b = (src.b * sa * 255 + dst.b * da * inverse + halfFa) / fa;
    return uint4(r, g, b, outA);
}

/// The `Op` the `normal` kernel dispatches through (spec 0024 item 3).
struct NormalOp {
    static inline uint4 apply(uint4 dst, uint4 src) {
        return blend_normal_op(dst, src);
    }
};

/// One layer's contribution to the accumulator: outside the tile's in-canvas region the
/// accumulator stays untouched (padding remains zero); `src.a` is first scaled by the
/// layer opacity exactly as `BlendOps.blend` does.
template <typename Op>
static inline void apply_layer(device uchar4* accum, device const uchar4* src,
                               constant LayerBlendUniforms& u, uint2 gid) {
    if (gid.x >= u.validSize.x || gid.y >= u.validSize.y) { return; }
    uint index = gid.y * 256u + gid.x;
    uchar4 s = src[index];
    uchar4 d = accum[index];
    uint4 src4 = uint4(uint(s.x), uint(s.y), uint(s.z), mul255(uint(s.w), u.opacity));
    uint4 dst4 = uint4(uint(d.x), uint(d.y), uint(d.z), uint(d.w));
    uint4 out = Op::apply(dst4, src4);
    accum[index] = uchar4(uchar(out.r), uchar(out.g), uchar(out.b), uchar(out.a));
}

kernel void normal(device uchar4* accum [[buffer(0)]],
                   device const uchar4* src [[buffer(1)]],
                   constant LayerBlendUniforms& u [[buffer(2)]],
                   uint2 gid [[thread_position_in_grid]]) {
    apply_layer<NormalOp>(accum, src, u, gid);
}

/// Straight → premultiplied: `rgb' = (rgb·a + 127) / 255`, `a' = a`, `a == 0` →
/// `(0,0,0,0)` — identical to `TileMipmapper.premultiplied`. Texels outside `validSize`
/// (edge-tile padding) are written as 0. The texture is bound through a `.rgba8Uint`
/// view so integers land exactly, with no float conversion.
kernel void compositor_premultiply(device const uchar4* accum [[buffer(0)]],
                                   texture2d<uint, access::write> level0 [[texture(0)]],
                                   constant LayerBlendUniforms& u [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.validSize.x || gid.y >= u.validSize.y) {
        level0.write(uint4(0, 0, 0, 0), gid);
        return;
    }
    uchar4 c = accum[gid.y * 256u + gid.x];
    uint a = uint(c.w);
    uint r = (uint(c.x) * a + 127) / 255;
    uint g = (uint(c.y) * a + 127) / 255;
    uint b = (uint(c.z) * a + 127) / 255;
    level0.write(uint4(r, g, b, a), gid);
}

/// One 2×2 box downsample — `dst = (s00 + s10 + s01 + s11 + 2) / 4` per channel,
/// identical to `TileMipmapper.mipChain`. The Swift side binds single-level `.rgba8Uint`
/// views of the tile texture: `src` is level `k`, `dst` level `k + 1`.
kernel void compositor_downsample(texture2d<uint, access::read> src [[texture(0)]],
                                  texture2d<uint, access::write> dst [[texture(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    uint2 s00 = gid * 2u;
    uint4 sum = src.read(s00)
              + src.read(s00 + uint2(1u, 0u))
              + src.read(s00 + uint2(0u, 1u))
              + src.read(s00 + uint2(1u, 1u));
    dst.write((sum + uint4(2u, 2u, 2u, 2u)) / 4u, gid);
}
