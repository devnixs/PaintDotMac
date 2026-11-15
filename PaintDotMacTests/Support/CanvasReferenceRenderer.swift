import CoreGraphics
import Foundation
@testable import PaintDotMac

/// The independent CPU oracle for canvas output (spec 0003). It re-implements the spec's
/// math directly in `Double`/integer arithmetic — its own premultiplication, its own
/// whole-image 2×2 box mip pyramid with transparent padding to a multiple of `2^L` and the
/// iterative `(sum + 2) / 4` rounding, its own nearest/area-average sampling, and its own
/// checkerboard formula. It uses nothing from production except `CanvasTransform`'s
/// `imageOriginInDevice`, `drawnImageRectInDevice`, `drawableSize` and `zoom` (each tested
/// separately) — never the renderer, the mipmapper, the sampler, or `CheckerboardStyle.color`.
enum CanvasReferenceRenderer {
    /// Background used by the canvas tests — distinct from both checkerboard colors so a
    /// background/checkerboard mix-up can never pass (spec 0003 *Test plan*).
    static let testBackground = ColorRGBA8(red: 50, green: 60, blue: 70, alpha: 255)

    /// The expected `transform.drawableSize` device-pixel buffer, row-major, y counting
    /// from the top (device space).
    static func render(image: LayeredImage, transform: CanvasTransform,
                       checkerboard: CheckerboardStyle = .standard,
                       backgroundColor: ColorRGBA8) -> [ColorRGBA8] {
        let width = transform.drawableSize.width
        let height = transform.drawableSize.height
        var output = [ColorRGBA8](repeating: backgroundColor, count: width * height)
        let drawn = transform.drawnImageRectInDevice
        guard drawn.width > 0, drawn.height > 0 else { return output }
        let origin = transform.imageOriginInDevice
        let zoom = transform.zoom

        guard let layer = image.layers.first, layer.isVisible else {
            fillCheckerboard(&output, drawn: drawn, width: width, origin: origin,
                             style: checkerboard, backingScale: transform.backingScale)
            return output
        }
        let opacity = Double(layer.opacity) / 255
        let size = image.size
        let level = level(for: zoom)

        // Whole-image premultiplied pyramid with transparent padding to a multiple of 2^L,
        // built iteratively with (sum + 2) / 4 rounding.
        let pad = 1 << level
        let paddedWidth = ((size.width + pad - 1) / pad) * pad
        let paddedHeight = ((size.height + pad - 1) / pad) * pad
        var pyramid = [[UInt8]]()
        var base = [UInt8](repeating: 0, count: paddedWidth * paddedHeight * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let straight = layer.surface.pixel(at: PixelPoint(x: x, y: y))
                let a = Int(straight.alpha)
                let offset = (y * paddedWidth + x) * 4
                base[offset] = UInt8((Int(straight.red) * a + 127) / 255)
                base[offset + 1] = UInt8((Int(straight.green) * a + 127) / 255)
                base[offset + 2] = UInt8((Int(straight.blue) * a + 127) / 255)
                base[offset + 3] = straight.alpha
            }
        }
        pyramid.append(base)
        var currentWidth = paddedWidth
        var currentHeight = paddedHeight
        // `paddedWidth`/`paddedHeight` are multiples of 2^level (and ≥ 2^level), so the
        // chain always reaches `level` — six halvings at most.
        while pyramid.count - 1 < CanvasSampling.maximumLevel, currentWidth > 1, currentHeight > 1 {
            let previousWidth = currentWidth
            let previous = pyramid[pyramid.count - 1]
            currentWidth /= 2
            currentHeight /= 2
            var next = [UInt8](repeating: 0, count: currentWidth * currentHeight * 4)
            for y in 0..<currentHeight {
                for x in 0..<currentWidth {
                    for channel in 0..<4 {
                        func at(_ column: Int, _ row: Int) -> Int {
                            Int(previous[(row * previousWidth + column) * 4 + channel])
                        }
                        next[(y * currentWidth + x) * 4 + channel] =
                            UInt8((at(2 * x, 2 * y) + at(2 * x + 1, 2 * y)
                                    + at(2 * x, 2 * y + 1) + at(2 * x + 1, 2 * y + 1) + 2) / 4)
                    }
                }
            }
            pyramid.append(next)
        }

        let level0 = pyramid[0]
        let texelScale = zoom * Double(1 << level)
        let step = 1 / texelScale
        let texels = pyramid[level]
        let texelColumns = paddedWidth >> level
        let texelRowStride = texelColumns * 4

        for deviceY in drawn.minY..<drawn.maxY {
            for deviceX in drawn.minX..<drawn.maxX {
                let checker = checkerColor(
                    deviceX: deviceX, deviceY: deviceY, origin: origin,
                    style: checkerboard, backingScale: transform.backingScale
                )
                var source = (r: 0.0, g: 0.0, b: 0.0, a: 0.0)   // premultiplied, 0…255
                if opacity > 0 {
                    let px = Double(deviceX) + 0.5
                    let py = Double(deviceY) + 0.5
                    if zoom >= 1 {
                        // Nearest neighbor: floor to the right/lower texel, clamped to the
                        // last image pixel.
                        let tx = min(max(Int(floor((px - Double(origin.x)) / zoom)), 0), size.width - 1)
                        let ty = min(max(Int(floor((py - Double(origin.y)) / zoom)), 0), size.height - 1)
                        let offset = (ty * paddedWidth + tx) * 4
                        source = (Double(level0[offset]), Double(level0[offset + 1]),
                                  Double(level0[offset + 2]), Double(level0[offset + 3]))
                    } else {
                        // Area-weighted box filter from mip `level`.
                        let x0 = (px - 0.5 - Double(origin.x)) / texelScale
                        let x1 = x0 + step
                        let y0 = (py - 0.5 - Double(origin.y)) / texelScale
                        let y1 = y0 + step
                        let firstTexelX = Int(floor(x0))
                        let firstTexelY = Int(floor(y0))
                        var sum = (r: 0.0, g: 0.0, b: 0.0, a: 0.0)
                        for texelY in firstTexelY...(firstTexelY + 2) {
                            let wy = max(0, min(y1, Double(texelY + 1)) - max(y0, Double(texelY)))
                            guard wy > 0 else { continue }
                            for texelX in firstTexelX...(firstTexelX + 2) {
                                let wx = max(0, min(x1, Double(texelX + 1)) - max(x0, Double(texelX)))
                                guard wx > 0, texelX >= 0, texelX < texelColumns,
                                      texelY >= 0, texelY < texels.count / texelRowStride
                                else { continue }
                                let offset = texelY * texelRowStride + texelX * 4
                                let weight = wx * wy
                                sum.r += weight * Double(texels[offset])
                                sum.g += weight * Double(texels[offset + 1])
                                sum.b += weight * Double(texels[offset + 2])
                                sum.a += weight * Double(texels[offset + 3])
                            }
                        }
                        let area = (x1 - x0) * (y1 - y0)
                        source = (sum.r / area, sum.g / area, sum.b / area, sum.a / area)
                    }
                    source = (source.r * opacity, source.g * opacity,
                              source.b * opacity, source.a * opacity)
                }
                let backgroundAlpha = 1 - source.a / 255
                output[deviceY * width + deviceX] = ColorRGBA8(
                    red: UInt8(clamping: Int((source.r + backgroundAlpha * Double(checker.red)).rounded())),
                    green: UInt8(clamping: Int((source.g + backgroundAlpha * Double(checker.green)).rounded())),
                    blue: UInt8(clamping: Int((source.b + backgroundAlpha * Double(checker.blue)).rounded())),
                    alpha: 255
                )
            }
        }
        return output
    }

    private static func fillCheckerboard(_ output: inout [ColorRGBA8], drawn: PixelRect, width: Int,
                                         origin: (x: Int, y: Int), style: CheckerboardStyle,
                                         backingScale: Double) {
        for deviceY in drawn.minY..<drawn.maxY {
            for deviceX in drawn.minX..<drawn.maxX {
                output[deviceY * width + deviceX] = checkerColor(
                    deviceX: deviceX, deviceY: deviceY, origin: origin,
                    style: style, backingScale: backingScale
                )
            }
        }
    }

    /// The largest `k ≤ maximumLevel` with `zoom · 2^k ≤ 1 + 1e-12` (`.nearest` above 1).
    private static func level(for zoom: Double) -> Int {
        guard zoom < 1 else { return 0 }
        var k = 0
        while k < CanvasSampling.maximumLevel, zoom * pow(2.0, Double(k + 1)) <= 1 + 1e-12 {
            k += 1
        }
        return k
    }

    /// The checkerboard formula of the spec: `floor` division of the offset by
    /// `squareSize · backingScale`, light when `i + j` is even.
    private static func checkerColor(deviceX dx: Int, deviceY dy: Int, origin: (x: Int, y: Int),
                                     style: CheckerboardStyle, backingScale: Double) -> ColorRGBA8 {
        let side = style.squareSize * backingScale
        let i = floor(Double(dx - origin.x) / side)
        let j = floor(Double(dy - origin.y) / side)
        let sum = i + j
        let isEven = abs(sum.truncatingRemainder(dividingBy: 2)) == 0
        return isEven ? style.lightColor : style.darkColor
    }
}
