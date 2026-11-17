import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Core Crop to Selection (spec 0022; PRD IMG-1, E-3/D-40, H-6/D-34, D-7, NF-4). Every
/// expected value is hand-computed or comes from the independent `maskedRef` oracle below
/// (`mul255(a, c) = (a·c + 127) / 255`, the 0009 rule written out); nothing is derived
/// from the code under test.
private func px(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
    ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
}

/// The independent `mul255` — `(a·c + 127) / 255` with plain integer arithmetic.
private func mul255Ref(_ a: UInt8, _ c: UInt8) -> UInt8 {
    UInt8((UInt32(a) * UInt32(c) + 127) / 255)
}

/// The independent per-pixel crop rule: c == 255 keeps the pixel bit-for-bit; otherwise
/// alpha scales by `mul255` and a zero result clears the color too.
private func maskedRef(_ pixel: ColorRGBA8, coverage c: UInt8) -> ColorRGBA8 {
    guard c != 255 else { return pixel }
    let alpha = mul255Ref(pixel.alpha, c)
    guard alpha != 0 else { return px(0, 0, 0, 0) }
    return px(Int(pixel.red), Int(pixel.green), Int(pixel.blue), Int(alpha))
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

/// A `SelectionMask` from a coverage table; pixels not in `values` are 0.
private func coverageMask(_ size: PixelSize, _ values: [PixelPoint: UInt8]) -> SelectionMask {
    SelectionMask(size: size) { x, y in values[PixelPoint(x: x, y: y)] ?? 0 }
}

private func rectSelection(_ rect: PixelRect, canvasSize: PixelSize) -> Selection {
    Selection(rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
              canvasSize: canvasSize)!
}

struct CropToSelectionTests {
    /// A single layer filled with the given per-pixel function.
    private func layer(_ size: PixelSize,
                       _ f: (Int, Int) -> ColorRGBA8) -> Layer {
        Layer(name: "Layer", surface: TestImages.surface(width: size.width, height: size.height, f))
    }

    // MARK: - Enablement and the crop rectangle

    @Test func enablement() {
        let image = LayeredImage.blank(size: PixelSize(width: 8, height: 6), fill: .white)
        let noSelection = DocumentState(image: image)
        #expect(!CropToSelection.isEnabled(in: noSelection))
        #expect(CropToSelection.cropRect(for: noSelection) == nil)
        #expect(CropToSelection.makeHistoryItem(for: noSelection) == nil)
        #expect(CropToSelection.croppedState(noSelection) == nil)

        let selected = DocumentState(image: image,
                                     selection: rectSelection(PixelRect(x: 2, y: 1, width: 3, height: 4),
                                                              canvasSize: image.size))
        #expect(CropToSelection.isEnabled(in: selected))
        #expect(CropToSelection.cropRect(for: selected) == PixelRect(x: 2, y: 1, width: 3, height: 4))
    }

    // MARK: - Rectangle crop

    @Test func rectangleCropsAllLayers() throws {
        let size = PixelSize(width: 8, height: 6)
        let l0 = layer(size) { x, y in px(x * 10, y * 10, 7, 255) }
        let l1 = layer(size) { x, y in px(255 - x, y, 0, 100) }
        let image = LayeredImage(size: size, layers: [l0, l1], activeLayerIndex: 1)
        let state = DocumentState(image: image,
                                  selection: rectSelection(PixelRect(x: 2, y: 1, width: 3, height: 4),
                                                           canvasSize: size))
        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.size == PixelSize(width: 3, height: 4))
        TestImages.expectPixels(cropped.image.layers[0].surface) { i, j in
            px((i + 2) * 10, (j + 1) * 10, 7, 255)
        }
        TestImages.expectPixels(cropped.image.layers[1].surface) { i, j in
            px(255 - (i + 2), j + 1, 0, 100)
        }
    }

    // MARK: - The per-pixel rule

    @Test func nonRectangularMaskHandValues() throws {
        let size = PixelSize(width: 6, height: 6)
        let image = LayeredImage(surface: layer(size) { _, _ in px(200, 100, 50, 255) }.surface)
        let mask = coverageMask(size, [
            PixelPoint(x: 1, y: 1): 255,
            PixelPoint(x: 3, y: 2): 128,
            PixelPoint(x: 2, y: 4): 1,
        ])
        let selection = try #require(Selection(mask: mask,
                                               outline: CGPath(rect: CGRect(x: 1, y: 1, width: 3, height: 4),
                                                               transform: nil)))
        let state = DocumentState(image: image, selection: selection)
        #expect(CropToSelection.cropRect(for: state) == PixelRect(x: 1, y: 1, width: 3, height: 4))
        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.size == PixelSize(width: 3, height: 4))
        let surface = cropped.image.layers[0].surface
        #expect(surface.pixel(at: PixelPoint(x: 0, y: 0)) == px(200, 100, 50, 255))
        #expect(surface.pixel(at: PixelPoint(x: 2, y: 1)) == px(200, 100, 50, 128))
        #expect(surface.pixel(at: PixelPoint(x: 1, y: 3)) == px(200, 100, 50, 1))
        let expectedClear: [PixelPoint] = [PixelPoint(x: 0, y: 1), PixelPoint(x: 1, y: 0),
                                           PixelPoint(x: 2, y: 0), PixelPoint(x: 0, y: 2),
                                           PixelPoint(x: 1, y: 2), PixelPoint(x: 2, y: 2),
                                           PixelPoint(x: 0, y: 3), PixelPoint(x: 2, y: 3)]
        for point in expectedClear {
            #expect(surface.pixel(at: point) == px(0, 0, 0, 0), "(\(point.x), \(point.y))")
        }
    }

    @Test func maskedPixelRule() {
        #expect(CropToSelection.masked(px(10, 20, 30, 0), coverage: 255) == px(10, 20, 30, 0))
        #expect(CropToSelection.masked(px(10, 20, 30, 0), coverage: 254) == px(0, 0, 0, 0))
        #expect(CropToSelection.masked(px(10, 20, 30, 1), coverage: 128) == px(10, 20, 30, 1))
        #expect(CropToSelection.masked(px(10, 20, 30, 1), coverage: 127) == px(0, 0, 0, 0))
        #expect(CropToSelection.masked(px(200, 100, 50, 255), coverage: 0) == px(0, 0, 0, 0))
        #expect(CropToSelection.masked(px(200, 100, 50, 200), coverage: 64) == px(200, 100, 50, 50))

        // Exhaustive over all 65,536 (alpha, coverage) pairs, color (1, 2, 3).
        for alphaValue in 0...255 {
            let alpha = UInt8(alphaValue)
            for coverageValue in 0...255 {
                let coverage = UInt8(coverageValue)
                let pixel = px(1, 2, 3, alphaValue)
                #expect(CropToSelection.masked(pixel, coverage: coverage)
                            == maskedRef(pixel, coverage: coverage),
                        "alpha \(alpha) coverage \(coverage)")
            }
        }
    }

    @Test func boundingBoxIncludesCoverageOne() throws {
        let size = PixelSize(width: 10, height: 10)
        let image = LayeredImage(surface: layer(size) { x, y in px(x, y, 40, 200) }.surface)
        var values: [PixelPoint: UInt8] = [:]
        for x in 4...5 { for y in 4...5 { values[PixelPoint(x: x, y: y)] = 255 } }
        values[PixelPoint(x: 9, y: 0)] = 1
        let mask = coverageMask(size, values)
        let selection = try #require(Selection(mask: mask, outline: CGPath(rect: .zero, transform: nil)))
        let state = DocumentState(image: image, selection: selection)
        #expect(CropToSelection.cropRect(for: state) == PixelRect(x: 4, y: 0, width: 6, height: 6))
        let cropped = try #require(CropToSelection.croppedState(state))
        // Result (5, 0) is source (9, 0) with coverage 1: alpha mul255(200, 1) = (200+127)/255 = 1.
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 5, y: 0)) == px(9, 0, 40, 1))
    }

    @Test func ellipseCropMatchesOracle() throws {
        let seed = SeededRandom.resolvedSeed(default: 0x0022_C115_5E11_FC00)
        var random = SeededRandom(seed: seed)
        let width = 300, height = 280
        var colors = [ColorRGBA8](repeating: .clear, count: width * height)
        for index in colors.indices { colors[index] = random.color() }
        let source = TestImages.surface(width: width, height: height) { x, y in colors[y * width + x] }
        let image = LayeredImage(surface: source)
        let selection = try #require(Selection(
            path: CGPath(ellipseIn: CGRect(x: 20.5, y: 30.25, width: 250, height: 200), transform: nil),
            canvasSize: PixelSize(width: width, height: height)))
        let state = DocumentState(image: image, selection: selection)
        let oracle = oracleBounds(of: selection.mask)
        #expect(CropToSelection.cropRect(for: state) == oracle)
        #expect(oracle.width > 230 && oracle.height > 160, "seed=\(seed): ellipse bbox sanity")

        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.size == oracle.size)
        TestImages.expectPixels(cropped.image.layers[0].surface) { i, j in
            let x = oracle.x + i, y = oracle.y + j
            return maskedRef(colors[y * width + x],
                             coverage: selection.mask.coverage(x: x, y: y))
        }
    }

    // MARK: - Layers, properties, DPI

    @Test func layerPropertiesAndDPIKept() throws {
        let size = PixelSize(width: 8, height: 6)
        let ids = [UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                   UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
                   UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!]
        let l0 = Layer(id: ids[0], name: "A", surface: TestImages.surface(width: 8, height: 6) { x, y in px(x, y, 1, 255) })
        var l1 = Layer(id: ids[1], name: "B", surface: TestImages.surface(width: 8, height: 6) { x, y in px(x + 1, y, 2, 255) })
        let l2 = Layer(id: ids[2], name: "C", surface: TestImages.surface(width: 8, height: 6) { x, y in px(x, y + 1, 3, 255) })
        l1.isVisible = false
        l1.opacity = 77
        // `.normal` is the only `BlendMode` case until 0026/0027; identity still proves
        // the property is carried through the crop.
        l1.blendMode = .normal
        let image = LayeredImage(size: size, dpi: 150, layers: [l0, l1, l2], activeLayerIndex: 1)
        let state = DocumentState(image: image,
                                  selection: rectSelection(PixelRect(x: 1, y: 1, width: 4, height: 3),
                                                           canvasSize: size))
        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.size == PixelSize(width: 4, height: 3))
        #expect(cropped.image.dpi == 150)
        #expect(cropped.image.activeLayerIndex == 1)
        #expect(cropped.image.isConsistent)
        #expect(cropped.image.layers.map(\.id) == ids)
        #expect(cropped.image.layers.map(\.name) == ["A", "B", "C"])
        #expect(cropped.image.layers.map(\.isVisible) == [true, false, true])
        #expect(cropped.image.layers.map(\.opacity) == [255, 77, 255])
        #expect(cropped.image.layers.map(\.blendMode) == [.normal, .normal, .normal])
        // The hidden layer was cropped too (two points): result (i, j) is source
        // (i + 1, j + 1) of the pattern (x + 1, y, 2, 255).
        #expect(cropped.image.layers[1].surface.pixel(at: PixelPoint(x: 0, y: 0)) == px(2, 1, 2, 255))
        #expect(cropped.image.layers[1].surface.pixel(at: PixelPoint(x: 3, y: 2)) == px(5, 3, 2, 255))
    }

    // MARK: - The selection after the crop

    @Test func selectionIsTranslated() throws {
        let size = PixelSize(width: 8, height: 6)
        let image = LayeredImage.blank(size: size, fill: .white)
        let state = DocumentState(image: image,
                                  selection: rectSelection(PixelRect(x: 2, y: 1, width: 3, height: 4),
                                                           canvasSize: size))
        let cropped = try #require(CropToSelection.croppedState(state))
        let selection = try #require(cropped.selection)
        #expect(selection.canvasSize == PixelSize(width: 3, height: 4))
        #expect(selection.mask.isFull)
        #expect(selection.bounds == PixelRect(x: 0, y: 0, width: 3, height: 4))

        // The hand-coverage case: coverages move with the pixels; the outline translates.
        let small = PixelSize(width: 6, height: 6)
        let mask = coverageMask(small, [
            PixelPoint(x: 1, y: 1): 255,
            PixelPoint(x: 3, y: 2): 128,
            PixelPoint(x: 2, y: 4): 1,
        ])
        let handSelection = try #require(Selection(
            mask: mask, outline: CGPath(rect: CGRect(x: 1, y: 1, width: 3, height: 4), transform: nil)))
        let handState = DocumentState(image: LayeredImage.blank(size: small, fill: .white),
                                      selection: handSelection)
        let handCropped = try #require(CropToSelection.croppedState(handState))
        let croppedMask = try #require(handCropped.selection).mask
        #expect(croppedMask.coverage(x: 0, y: 0) == 255)
        #expect(croppedMask.coverage(x: 2, y: 1) == 128)
        #expect(croppedMask.coverage(x: 1, y: 3) == 1)
        var allZero = true
        for y in 0..<croppedMask.size.height {
            for x in 0..<croppedMask.size.width {
                if (x == 0 && y == 0) || (x == 2 && y == 1) || (x == 1 && y == 3) { continue }
                if croppedMask.coverage(x: x, y: y) != 0 { allZero = false }
            }
        }
        #expect(allZero, "all other coverages are 0")
        let bbox = handCropped.selection!.path.boundingBoxOfPath
        #expect(bbox == CGRect(x: 0, y: 0, width: 3, height: 4),
                "outline translated by (−1, −1)")
    }

    // MARK: - History item and the no-op rule

    @Test func historyItemNameAndIcon() throws {
        let size = PixelSize(width: 8, height: 6)
        let state = DocumentState(
            image: LayeredImage.blank(size: size, fill: .white),
            selection: rectSelection(PixelRect(x: 2, y: 1, width: 3, height: 4), canvasSize: size))
        let item = try #require(CropToSelection.makeHistoryItem(for: state))
        #expect(item.name == "Crop to Selection")
        #expect(item.icon == .cropToSelection)
        #expect(item.change == .structure)
        #expect(!item.isNoOp)
    }

    @Test func noOpWhenSelectAll() {
        for size in [PixelSize(width: 8, height: 6), PixelSize(width: 1, height: 1)] {
            let state = DocumentState(image: LayeredImage.blank(size: size, fill: .white),
                                      selection: .all(canvasSize: size))
            #expect(CropToSelection.croppedState(state) == nil, "\(size)")
            #expect(CropToSelection.makeHistoryItem(for: state) == nil, "\(size)")
        }
        let size = PixelSize(width: 8, height: 6)
        let fullRect = DocumentState(image: LayeredImage.blank(size: size, fill: .white),
                                     selection: rectSelection(size.bounds, canvasSize: size))
        #expect(CropToSelection.croppedState(fullRect) == nil)
        #expect(CropToSelection.makeHistoryItem(for: fullRect) == nil)
    }

    @Test func fullBoundsPartialMaskIsNotNoOp() throws {
        let size = PixelSize(width: 8, height: 8)
        let mask = SelectionMask(size: size) { x, y in
            (x == 0 && y == 0) || (x == 7 && y == 7) ? 0 : 255
        }
        let selection = try #require(Selection(mask: mask,
                                               outline: CGPath(rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                                                               transform: nil)))
        #expect(selection.bounds == size.bounds)
        let state = DocumentState(image: LayeredImage.blank(size: size, fill: .white),
                                  selection: selection)
        let item = try #require(CropToSelection.makeHistoryItem(for: state))
        #expect(!item.isNoOp)
        let cropped = item.after
        #expect(cropped.image.size == size)
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 0, y: 0)) == .clear)
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 7, y: 7)) == .clear)
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 3, y: 3)) == .white)
    }

    // MARK: - Edges and seams

    @Test func onePixelCrop() throws {
        let size = PixelSize(width: 5, height: 5)
        let mask = coverageMask(size, [PixelPoint(x: 3, y: 2): 1])
        let selection = try #require(Selection(mask: mask, outline: CGPath(rect: .zero, transform: nil)))
        let state = DocumentState(image: LayeredImage.blank(size: size, fill: px(9, 8, 7, 255)),
                                  selection: selection)
        #expect(CropToSelection.cropRect(for: state) == PixelRect(x: 3, y: 2, width: 1, height: 1))
        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.size == PixelSize(width: 1, height: 1))
        #expect(cropped.image.layers[0].surface.pixel(at: .zero) == px(9, 8, 7, 1))
        let newSelection = try #require(cropped.selection)
        #expect(newSelection.canvasSize == PixelSize(width: 1, height: 1))
        #expect(newSelection.mask.coverage(x: 0, y: 0) == 1)
    }

    @Test func disjointSelectionGapIsTransparent() throws {
        let size = PixelSize(width: 20, height: 10)
        let a = rectSelection(PixelRect(x: 1, y: 1, width: 2, height: 2), canvasSize: size)
        let b = rectSelection(PixelRect(x: 15, y: 6, width: 3, height: 3), canvasSize: size)
        let union = try #require(a.combined(with: b, mode: .union))
        let image = LayeredImage(surface: layer(size) { x, y in px(x, y, 3, 255) }.surface)
        let state = DocumentState(image: image, selection: union)
        #expect(CropToSelection.cropRect(for: state) == PixelRect(x: 1, y: 1, width: 17, height: 8))
        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 0, y: 0)) == px(1, 1, 3, 255))
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 16, y: 7)) == px(17, 8, 3, 255))
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 7, y: 3)) == .clear)
    }

    @Test func unalignedTileSeams() throws {
        let size = PixelSize(width: 600, height: 600)
        func sourceColor(_ x: Int, _ y: Int) -> ColorRGBA8 {
            px(x % 256, y % 256, (x / 256) * 100 + (y / 256) * 10, 255)
        }
        let image = LayeredImage(surface: layer(size, sourceColor).surface)
        for rect in [PixelRect(x: 255, y: 255, width: 3, height: 3),
                     PixelRect(x: 100, y: 300, width: 500, height: 300)] {
            let state = DocumentState(image: image, selection: rectSelection(rect, canvasSize: size))
            let cropped = try #require(CropToSelection.croppedState(state), "\(rect)")
            #expect(cropped.image.size == rect.size, "\(rect)")
            TestImages.expectPixels(cropped.image.layers[0].surface) { i, j in
                sourceColor(rect.x + i, rect.y + j)
            }
        }
    }

    // MARK: - Memory (NF-4)

    /// An opaque image whose tiles each own a distinct buffer (`blank(fill:)` shares one
    /// buffer across all interior tiles, which would make storage claims vacuous).
    private func opaqueImage(_ size: PixelSize) -> LayeredImage {
        let surface = TestImages.surface(width: size.width, height: size.height) { _, _ in
            px(4, 5, 6, 255)
        }
        return LayeredImage(surface: surface)
    }

    @Test func alignedFullTilesShareStorage() throws {
        let size = PixelSize(width: 1024, height: 768)
        let image = opaqueImage(size)

        let alignedRect = PixelRect(x: 256, y: 256, width: 512, height: 512)
        let aligned = DocumentState(image: image,
                                    selection: rectSelection(alignedRect, canvasSize: size))
        let cropped = try #require(CropToSelection.croppedState(aligned))
        let pairs: [(dst: TileCoordinate, src: TileCoordinate)] = [
            (TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 1)),
            (TileCoordinate(column: 1, row: 0), TileCoordinate(column: 2, row: 1)),
            (TileCoordinate(column: 0, row: 1), TileCoordinate(column: 1, row: 2)),
            (TileCoordinate(column: 1, row: 1), TileCoordinate(column: 2, row: 2)),
        ]
        for pair in pairs {
            let destination = try #require(cropped.image.layers[0].surface.tile(at: pair.dst))
            let sourceTile = try #require(image.layers[0].surface.tile(at: pair.src))
            #expect(destination.sharesStorage(with: sourceTile), "\(pair)")
        }

        let unalignedRect = PixelRect(x: 1, y: 0, width: 512, height: 256)
        let unaligned = DocumentState(image: image,
                                      selection: rectSelection(unalignedRect, canvasSize: size))
        let croppedU = try #require(CropToSelection.croppedState(unaligned))
        let sourceTiles = image.layers[0].surface.allocatedTileCoordinates.compactMap {
            image.layers[0].surface.tile(at: $0)
        }
        for coordinate in croppedU.image.layers[0].surface.allocatedTileCoordinates {
            let tile = try #require(croppedU.image.layers[0].surface.tile(at: coordinate))
            #expect(!sourceTiles.contains { tile.sharesStorage(with: $0) }, "\(coordinate)")
        }
    }

    @Test func historyCostCountsOnlyUnsharedTiles() throws {
        let size = PixelSize(width: 1024, height: 768)
        let image = opaqueImage(size)
        let state = DocumentState(
            image: image,
            selection: rectSelection(PixelRect(x: 256, y: 256, width: 512, height: 512),
                                     canvasSize: size))
        let item = try #require(CropToSelection.makeHistoryItem(for: state))
        // 4×3 = 12 source tiles, 4 shared with the 2×2 destination → 8 side-only tiles;
        // both masks are rect masks (full/empty tiles only, no storages) and the paths
        // differ, so the selection part is both path estimates.
        let beforePath = try #require(item.before.selection).pathByteEstimate
        let afterPath = try #require(item.after.selection).pathByteEstimate
        #expect(item.byteCost == 8 * Tile.byteCount + beforePath + afterPath)
    }

    @Test func sparseTilesStaySparse() throws {
        let size = PixelSize(width: 1024, height: 1024)
        var surface = TiledSurface(size: size)
        surface.fill(px(7, 8, 9, 255), in: PixelRect(x: 768, y: 768, width: 256, height: 256))
        let image = LayeredImage(surface: surface)
        #expect(image.layers[0].surface.allocatedTileCoordinates
            == [TileCoordinate(column: 3, row: 3)])

        let sparseState = DocumentState(image: image,
                                        selection: rectSelection(PixelRect(x: 0, y: 0, width: 600, height: 600),
                                                                 canvasSize: size))
        let sparse = try #require(CropToSelection.croppedState(sparseState))
        #expect(sparse.image.layers[0].surface.allocatedTileCoordinates.isEmpty)

        let filledState = DocumentState(image: image,
                                        selection: rectSelection(PixelRect(x: 700, y: 700, width: 300, height: 300),
                                                                 canvasSize: size))
        let filled = try #require(CropToSelection.croppedState(filledState))
        let filledSurface = filled.image.layers[0].surface
        #expect(filledSurface.allocatedTileCount == 4)
        #expect(filledSurface.pixel(at: PixelPoint(x: 68, y: 68)) == px(7, 8, 9, 255))
        #expect(filledSurface.pixel(at: PixelPoint(x: 299, y: 299)) == px(7, 8, 9, 255))
        #expect(filledSurface.pixel(at: PixelPoint(x: 67, y: 68)) == .clear)
    }

    @Test func wideImageCrop() throws {
        let size = PixelSize(width: 65_535, height: 300)
        var surface = TiledSurface(size: size)
        surface.fill(px(5, 5, 5, 255))
        let markerA = px(250, 251, 252, 253)
        let markerB = px(100, 101, 102, 103)
        surface.setPixel(markerA, at: PixelPoint(x: 40_000, y: 10))
        surface.setPixel(markerB, at: PixelPoint(x: 59_999, y: 209))
        let state = DocumentState(
            image: LayeredImage(surface: surface),
            selection: rectSelection(PixelRect(x: 40_000, y: 10, width: 20_000, height: 200),
                                     canvasSize: size))
        let cropped = try #require(CropToSelection.croppedState(state))
        #expect(cropped.image.size == PixelSize(width: 20_000, height: 200))
        #expect(cropped.image.layers[0].surface.pixel(at: .zero) == markerA)
        #expect(cropped.image.layers[0].surface.pixel(at: PixelPoint(x: 19_999, y: 199)) == markerB)
    }
}
