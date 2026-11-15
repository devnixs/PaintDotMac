#include <metal_stdlib>
using namespace metal;

/// Shared between `Canvas.metal` and `MetalCanvasRenderer.CanvasUniforms` (Swift) —
/// keep both in sync. All members are float/int sized so the C layout has no implicit
/// padding beyond the natural alignment.
struct CanvasUniforms {
    float4 quadRect;                    // drawnImageRectInDevice: (x, y, w, h), device pixels
    float2 intermediateOriginDevice;    // device position of intermediate texel (0, 0)
    float2 targetSize;                  // drawable size in device pixels
    int2   checkerOrigin;               // imageOriginInDevice
    uint2  intermediateSize;            // intermediate texture size in texels
    uint2  validTexelSize;              // image size at level L inside the intermediate
    float  devicePerTexel;              // zoom * 2^L
    float  opacity;                     // layer.opacity / 255, 0 when hidden
    float  checkerSide;                 // checker square side in device pixels
    float  isNearest;                   // 1 = nearest (zoom >= 1, level 0), 0 = area average
    float  checkerLightR;
    float  checkerLightG;
    float  checkerLightB;
    float  checkerLightA;
    float  checkerDarkR;
    float  checkerDarkG;
    float  checkerDarkB;
    float  checkerDarkA;
};

/// A triangle-strip quad covering `quadRect` in device space (origin top-left, y down),
/// mapped to clip space for a target of `targetSize`.
vertex float4 canvas_vertex(uint vertexId [[vertex_id]],
                            constant CanvasUniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vertexId & 1u), float((vertexId >> 1) & 1u));
    float2 devicePos = u.quadRect.xy + corner * u.quadRect.zw;
    float2 size = max(u.targetSize, float2(1.0));
    float2 ndc = devicePos / size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    return float4(ndc, 0.0, 1.0);
}

/// Samples the premultiplied intermediate and composites over the checkerboard, all on
/// sRGB-encoded values (no linear light). Device pixels outside the drawn quad keep the
/// render pass's clear color (the background).
fragment float4 canvas_fragment(float4 position [[position]],
                                texture2d<float, access::read> intermediate [[texture(0)]],
                                constant CanvasUniforms &u [[buffer(0)]]) {
    // Checkerboard: same formula as CheckerboardStyle.color.
    float2 rel = position.xy - float2(u.checkerOrigin);
    float2 square = floor(rel / u.checkerSide);
    bool dark = fmod(square.x + square.y, 2.0) != 0.0;
    float3 checker = dark ? float3(u.checkerDarkR, u.checkerDarkG, u.checkerDarkB)
                          : float3(u.checkerLightR, u.checkerLightG, u.checkerLightB);

    float4 src = float4(0.0);
    float2 texelPos = (position.xy - u.intermediateOriginDevice) / u.devicePerTexel;
    if (u.isNearest != 0.0) {
        // Nearest neighbor: pick the right/lower texel; clamped so the partial device pixel
        // past the image edge repeats the last image pixel.
        float2 t = clamp(floor(texelPos), float2(0.0), max(float2(u.validTexelSize) - 1.0, float2(0.0)));
        src = intermediate.read(uint2(t));
    } else {
        // Area average: the device pixel footprint is [x0, x1) x [y0, y1) in texel units
        // (between 1 and 2 texels per axis); texels outside the intermediate count as
        // transparent 0, so image edges get partial coverage.
        float stepWidth = 1.0 / u.devicePerTexel;
        float x0 = texelPos.x - 0.5 * stepWidth;
        float x1 = x0 + stepWidth;
        float y0 = texelPos.y - 0.5 * stepWidth;
        float y1 = y0 + stepWidth;
        int ix0 = int(floor(x0));
        int iy0 = int(floor(y0));
        float4 sum = float4(0.0);
        for (int j = iy0; j <= iy0 + 2; ++j) {
            float wy = max(0.0, min(y1, float(j + 1)) - max(y0, float(j)));
            if (wy <= 0.0) { continue; }
            for (int i = ix0; i <= ix0 + 2; ++i) {
                float wx = max(0.0, min(x1, float(i + 1)) - max(x0, float(i)));
                if (wx <= 0.0) { continue; }
                if (i >= 0 && j >= 0
                        && uint(i) < u.intermediateSize.x && uint(j) < u.intermediateSize.y) {
                    sum += (wx * wy) * intermediate.read(uint2(uint(i), uint(j)));
                }
            }
        }
        src = sum / max((x1 - x0) * (y1 - y0), 1e-20);
    }

    // Composite the premultiplied source over the checkerboard, opaque result.
    src *= u.opacity;
    float3 outRGB = src.rgb + (1.0 - src.a) * checker;
    return float4(outRGB, 1.0);
}
