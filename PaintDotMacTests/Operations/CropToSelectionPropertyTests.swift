import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Round-trip property test for Crop to Selection (spec 0022): seeded random images and
/// selections, apply/revert/apply through `DocumentSnapshotHistoryItem`, and every result
/// pixel against an independent per-pixel oracle (`mul255(a, c) = (a·c + 127) / 255`
/// written out here, coverages read off the mask, sources read off the original image).
struct CropToSelectionPropertyTests {
    /// The independent `mul255` crop rule.
    private func maskedRef(_ pixel: ColorRGBA8, _ c: UInt8) -> ColorRGBA8 {
        guard c != 255 else { return pixel }
        let alpha = UInt8((UInt32(pixel.alpha) * UInt32(c) + 127) / 255)
        guard alpha != 0 else { return ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0) }
        return ColorRGBA8(red: pixel.red, green: pixel.green, blue: pixel.blue, alpha: alpha)
    }

    /// A deterministic sparse pixel from a SplitMix64 mix of (seed, iteration, layer, x, y).
    private func hashColor(seed: UInt64, iteration: Int, layer: Int, x: Int, y: Int) -> ColorRGBA8 {
        var z = seed &+ UInt64(bitPattern: Int64(iteration)) &* 0x9E37_79B9_7F4A_7C15
            &+ UInt64(layer) &* 0xD6E8_FEB8_6659_FD93
            &+ UInt64(bitPattern: Int64(y &* 4093 &+ x)) &* 0xA076_1D64_78BD_642F
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        let mixed = z ^ (z >> 31)
        guard mixed % 3 != 0 else { return ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0) }
        return ColorRGBA8(red: UInt8(truncatingIfNeeded: mixed),
                          green: UInt8(truncatingIfNeeded: mixed >> 8),
                          blue: UInt8(truncatingIfNeeded: mixed >> 16),
                          alpha: UInt8(truncatingIfNeeded: mixed >> 24))
    }

    /// The tight bounding box of coverage > 0, scanned directly off the mask.
    private func oracleBounds(of mask: SelectionMask) -> PixelRect {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<mask.size.height {
            for x in 0..<mask.size.width where mask.coverage(x: x, y: y) > 0 {
                if x < minX { minX = x }
                if x >= maxX { maxX = x + 1 }
                if y < minY { minY = y }
                if y >= maxY { maxY = y + 1 }
            }
        }
        guard maxX > minX else { return .zero }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// One seeded iteration.
    private func iterate(iteration: Int, seed: UInt64) throws {
        let comment: Comment = "iteration \(iteration), seed=0x\(String(seed, radix: 16, uppercase: true))"
        var rng = SeededRandom(seed: seed &+ UInt64(iteration) &* 0x1000_0000)
        let size = PixelSize(width: rng.int(in: 1...700), height: rng.int(in: 1...700))
        let layerCount = rng.int(in: 1...3)

        var layers: [Layer] = []
        for layerIndex in 0..<layerCount {
            let surface = TestImages.surface(width: size.width, height: size.height) { x, y in
                hashColor(seed: seed, iteration: iteration, layer: layerIndex, x: x, y: y)
            }
            layers.append(Layer(name: "L\(layerIndex)", surface: surface))
        }
        let image = LayeredImage(size: size, dpi: Double(72 + layerCount),
                                 layers: layers,
                                 activeLayerIndex: rng.int(in: 0...(layerCount - 1)))

        // A random selection: rect, ellipse, or the union of two rects.
        func randomRect() -> CGRect {
            let x = rng.int(in: 0...size.width - 1)
            let y = rng.int(in: 0...size.height - 1)
            return CGRect(x: x, y: y,
                          width: rng.int(in: 1...(size.width - x)),
                          height: rng.int(in: 1...(size.height - y)))
        }
        let selection: Selection
        switch rng.int(in: 0...2) {
        case 0:
            selection = Selection(rect: randomRect(), canvasSize: size)!
        case 1:
            let rect = randomRect()
            selection = Selection(path: CGPath(ellipseIn: rect, transform: nil), canvasSize: size)
                ?? Selection(rect: rect, canvasSize: size)!
        default:
            let first = Selection(rect: randomRect(), canvasSize: size)!
            let second = Selection(rect: randomRect(), canvasSize: size)!
            selection = first.combined(with: second, mode: .union) ?? first
        }

        let state = DocumentState(image: image, selection: selection)
        guard let item = CropToSelection.makeHistoryItem(for: state) else {
            return  // Select All (or a full-canvas full selection): a defined no-op
        }

        // The oracle rectangle: tight bbox of coverage > 0.
        let oracle = oracleBounds(of: selection.mask)
        #expect(item.after.image.size == oracle.size, comment)

        // apply → equal to `after`; every pixel equals the oracle; revert → the original.
        var live = state
        item.apply(to: &live)
        let firstApply = live
        #expect(live.image == item.after.image, comment)
        #expect(live.selection == item.after.selection, comment)
        for layerIndex in image.layers.indices {
            let source = state.image.layers[layerIndex].surface
            let result = live.image.layers[layerIndex].surface
            var mismatches = 0
            var firstSample = ""
            for y in 0..<oracle.height {
                for x in 0..<oracle.width {
                    let sx = oracle.x + x, sy = oracle.y + y
                    let expected = maskedRef(source.pixel(at: PixelPoint(x: sx, y: sy)),
                                             selection.mask.coverage(x: sx, y: sy))
                    if result.pixel(at: PixelPoint(x: x, y: y)) != expected {
                        mismatches += 1
                        if firstSample.isEmpty {
                            firstSample = "(\(x), \(y)): got \(result.pixel(at: PixelPoint(x: x, y: y))) expected \(expected)"
                        }
                    }
                }
            }
            #expect(mismatches == 0, "layer \(layerIndex) \(mismatches) mismatches \(firstSample) \(comment)")
            // Layer properties survive.
            #expect(live.image.layers[layerIndex].id == image.layers[layerIndex].id, comment)
            #expect(live.image.layers[layerIndex].name == image.layers[layerIndex].name, comment)
            #expect(live.image.layers[layerIndex].isVisible == image.layers[layerIndex].isVisible, comment)
            #expect(live.image.layers[layerIndex].opacity == image.layers[layerIndex].opacity, comment)
            #expect(live.image.layers[layerIndex].blendMode == image.layers[layerIndex].blendMode, comment)
        }

        item.revert(&live)
        #expect(live == state, comment)

        // apply again equals the first result.
        var again = state
        item.apply(to: &again)
        #expect(again == firstApply, comment)
    }

    @Test(arguments: 0..<50)
    func randomCropsRoundTrip(iteration: Int) throws {
        let seed = SeededRandom.resolvedSeed(default: 0xC40C_7A55_0002_22)
        try iterate(iteration: iteration, seed: seed)
    }
}
