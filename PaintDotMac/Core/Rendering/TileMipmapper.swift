import Foundation

/// CPU-side preparation of one 256×256 tile for upload (spec 0003): premultiplication and a
/// deterministic box-filter mip pyramid. Pure and deterministic — no Accelerate — so the
/// tests check exact values and the GPU reads exactly these bytes. The byte-level kernels
/// are the single implementation; the `ColorRGBA8` API wraps them, so the exact-value unit
/// tests validate the very code the renderer uploads.
enum TileMipmapper {
    /// Levels 0…6: 256, 128, 64, 32, 16, 8, 4 texels per side.
    static let levelCount = CanvasSampling.maximumLevel + 1

    /// Straight → premultiplied: `rgb' = (rgb · a + 127) / 255` (integer division),
    /// `a' = a`. Fully transparent pixels become `(0, 0, 0, 0)` whatever their stored RGB,
    /// so straight-alpha color under alpha 0 never leaks into averages.
    static func premultiplied(_ c: ColorRGBA8) -> ColorRGBA8 {
        let alpha = Int(c.alpha)
        return ColorRGBA8(
            red: UInt8((Int(c.red) * alpha + 127) / 255),
            green: UInt8((Int(c.green) * alpha + 127) / 255),
            blue: UInt8((Int(c.blue) * alpha + 127) / 255),
            alpha: c.alpha
        )
    }

    // MARK: - Byte kernels (used by the renderer's upload path)

    /// The full 256×256 tile as row-major RGBA8 bytes, premultiplied, everything outside
    /// the image's valid region overwritten to `(0, 0, 0, 0)`. Bytes beyond a short
    /// `tileBytes` degrade to transparent padding instead of trapping.
    static func paddedPremultipliedBytes(tileBytes: [UInt8], validWidth: Int,
                                         validHeight: Int) -> [UInt8] {
        let side = TiledSurface.tileSize
        let width = min(max(validWidth, 0), side)
        let height = min(max(validHeight, 0), side)
        var out = [UInt8](repeating: 0, count: Tile.byteCount)
        srcPrepass(tileBytes, into: &out, width: width, height: height)
        return out
    }

    /// Applies `premultiplied` to the valid region of a freshly zeroed 256×256 buffer.
    /// Rows whose valid pixels are all opaque copy straight through (the premultiply of an
    /// opaque pixel is the identity); other rows premultiply per pixel.
    private static func srcPrepass(_ src: [UInt8], into out: inout [UInt8], width: Int, height: Int) {
        src.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { destination in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destination.bindMemory(to: UInt8.self).baseAddress
                else { return }   // empty buffer → out stays transparent padding
                let bytesPerRow = Tile.bytesPerRow
                for y in 0..<height {
                    let rowStart = y * bytesPerRow
                    guard rowStart + width * 4 <= source.count else { break }   // short input → padding
                    var opaque = true
                    var x = 0
                    while x < width {
                        if src[rowStart + x * 4 + 3] != 255 { opaque = false; break }
                        x += 1
                    }
                    if opaque {
                        memcpy(dst + rowStart, src + rowStart, width * 4)
                    } else {
                        for pixel in 0..<width {
                            let offset = rowStart + pixel * 4
                            let alpha = Int(src[offset + 3])
                            if alpha == 255 {
                                dst[offset] = src[offset]
                                dst[offset + 1] = src[offset + 1]
                                dst[offset + 2] = src[offset + 2]
                                dst[offset + 3] = 255
                            } else if alpha != 0 {
                                dst[offset] = UInt8((Int(src[offset]) * alpha + 127) / 255)
                                dst[offset + 1] = UInt8((Int(src[offset + 1]) * alpha + 127) / 255)
                                dst[offset + 2] = UInt8((Int(src[offset + 2]) * alpha + 127) / 255)
                                dst[offset + 3] = UInt8(alpha)
                            }   // alpha 0 → stays (0, 0, 0, 0)
                        }
                    }
                }
            }
        }
    }

    /// One 2×2 box downsample: `dst = (s00 + s10 + s01 + s11 + 2) / 4` per channel, of the
    /// previous level's `side × side` RGBA8 byte buffer. Pixels are averaged as four 8-bit
    /// lanes inside a `UInt32` (split into the 0x00FF00FF lane pairs, summed in 16-bit-wide
    /// lanes that cannot carry, shifted, and recombined) — arithmetically identical to the
    /// per-channel integer formula, which the exact-value unit tests pin down.
    private static func boxDownsampled(_ src: [UInt8], side: Int) -> [UInt8] {
        let half = side / 2
        var out = [UInt8](repeating: 0, count: half * half * 4)
        src.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { destination in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
                for y in 0..<half {
                    let topRow = (2 * y) * side * 4
                    let bottomRow = topRow + side * 4
                    let dstRow = y * half * 4
                    for x in 0..<half {
                        let i00 = topRow + x * 8
                        let i10 = i00 + 4
                        let i01 = bottomRow + x * 8
                        let i11 = i01 + 4
                        let a = src.loadUnaligned(fromByteOffset: i00, as: UInt32.self)
                        let b = src.loadUnaligned(fromByteOffset: i10, as: UInt32.self)
                        let c = src.loadUnaligned(fromByteOffset: i01, as: UInt32.self)
                        let d = src.loadUnaligned(fromByteOffset: i11, as: UInt32.self)
                        dst.storeBytes(of: Self.boxAverage(a, b, c, d),
                                       toByteOffset: dstRow + x * 4, as: UInt32.self)
                    }
                }
            }
        }
        return out
    }

    /// The packed four-lane 2×2 box average described above. Each 16-bit lane holds
    /// at most `255 × 4 + 2 = 1022`, so sums never carry between lanes; the `& lanes`
    /// masks drop the two bits the shift drags down from each upper lane into the lower.
    @inline(__always)
    private static func boxAverage(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        let lanes: UInt32 = 0x00FF_00FF
        let low = (a & lanes) &+ (b & lanes) &+ (c & lanes) &+ (d & lanes) &+ 0x0002_0002
        let high = ((a >> 8) & lanes) &+ ((b >> 8) & lanes) &+ ((c >> 8) & lanes) &+ ((d >> 8) & lanes) &+ 0x0002_0002
        return ((low >> 2) & lanes) | (((high >> 2) & lanes) << 8)
    }

    /// The byte form of `mipChain`: the chain `baseLevel...6` as row-major RGBA8 byte
    /// buffers (the first element is level `baseLevel`).
    static func mipChainBytes(level0: [UInt8], baseLevel: Int) -> [[UInt8]] {
        let base = min(max(baseLevel, 0), CanvasSampling.maximumLevel)
        guard level0.count == Tile.byteCount else {
            return (base...CanvasSampling.maximumLevel).map { level in
                [UInt8](repeating: 0, count: (TiledSurface.tileSize >> level)
                    * (TiledSurface.tileSize >> level) * 4)
            }
        }
        var chain: [[UInt8]] = base == 0 ? [level0] : []
        var current = level0
        var side = TiledSurface.tileSize
        for level in 1...CanvasSampling.maximumLevel {
            current = boxDownsampled(current, side: side)
            side /= 2
            if level >= base { chain.append(current) }
        }
        return chain
    }

    // MARK: - ColorRGBA8 API (wrappers over the byte kernels; used by the tests)

    /// The full 256×256 tile (row-major, as 0002's `Tile.bytes` stores it) premultiplied,
    /// with everything outside the image's valid region overwritten to `(0, 0, 0, 0)`.
    /// `validWidth`/`validHeight` come from the image size; values outside 0…256 and a short
    /// `pixels` buffer degrade to transparent padding instead of trapping.
    static func paddedPremultipliedTile(from pixels: [ColorRGBA8],
                                        validWidth: Int, validHeight: Int) -> [ColorRGBA8] {
        let tileBytes = pixels.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        let bytes = paddedPremultipliedBytes(tileBytes: tileBytes,
                                             validWidth: validWidth, validHeight: validHeight)
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: ColorRGBA8.self)) }
    }

    /// The mip chain `baseLevel...6` (so `count == levelCount − baseLevel`; the first element
    /// is level `baseLevel`). Each texel of level `k + 1` is the 2×2 box average of the
    /// **previous level**, rounding half up per channel:
    /// `dst = (s00 + s10 + s01 + s11 + 2) / 4` — iterative, not a direct average of level 0.
    /// `level0` must be the 256×256 premultiplied tile from `paddedPremultipliedTile`.
    static func mipChain(level0: [ColorRGBA8], baseLevel: Int) -> [[ColorRGBA8]] {
        let level0Bytes = level0.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        return mipChainBytes(level0: level0Bytes, baseLevel: baseLevel).map { bytes in
            bytes.withUnsafeBytes { Array($0.bindMemory(to: ColorRGBA8.self)) }
        }
    }
}
