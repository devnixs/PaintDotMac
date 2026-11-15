import Testing

@testable import PaintDotMac

struct ImageOrientationTests {
    /// Six distinct colors for A…F (red channel 1…6).
    private static let letters: [Character: ColorRGBA8] = [
        "A": ColorRGBA8(red: 1, green: 0, blue: 10),
        "B": ColorRGBA8(red: 2, green: 0, blue: 10),
        "C": ColorRGBA8(red: 3, green: 0, blue: 10),
        "D": ColorRGBA8(red: 4, green: 0, blue: 10),
        "E": ColorRGBA8(red: 5, green: 0, blue: 10),
        "F": ColorRGBA8(red: 6, green: 0, blue: 10),
    ]

    private static let sourceSize = PixelSize(width: 3, height: 2)

    /// `sourcePoint` (and `apply`) produce exactly these layouts (spec 0002 *mappingTable*).
    private static let layouts: [(ImageOrientation, [String])] = [
        (.up, ["ABC", "DEF"]),
        (.upMirrored, ["CBA", "FED"]),
        (.down, ["FED", "CBA"]),
        (.downMirrored, ["DEF", "ABC"]),
        (.leftMirrored, ["AD", "BE", "CF"]),
        (.right, ["DA", "EB", "FC"]),
        (.rightMirrored, ["FC", "EB", "DA"]),
        (.left, ["CF", "BE", "AD"]),
    ]

    /// The 3×2 source `ABC/DEF` as a tightly packed buffer.
    private static func sourceBytes() -> [UInt8] {
        TestImages.rgbaBytes(width: 3, height: 2) { x, y in
            Self.letters[[["A", "B", "C"], ["D", "E", "F"]][y][x]] ?? .clear
        }
    }

    @Test(arguments: layouts)
    func mappingTable(_ orientation: ImageOrientation, layout: [String]) throws {
        let expectedSize = PixelSize(width: layout[0].count, height: layout.count)
        // 1. The reference mapping itself.
        for (y, row) in layout.enumerated() {
            for (x, letter) in row.enumerated() {
                let source = orientation.sourcePoint(
                    forDestination: PixelPoint(x: x, y: y), sourceSize: Self.sourceSize)
                let sourceLetter = [["A", "B", "C"], ["D", "E", "F"]][source.y][source.x]
                #expect(sourceLetter == String(letter),
                        "\(orientation): dest (\(x), \(y)) should be \(letter), maps to \(sourceLetter)")
            }
        }
        // 2. `apply` produces exactly the mapping table.
        let expected = TestImages.rgbaBytes(width: expectedSize.width, height: expectedSize.height) { x, y in
            Self.letters[Array(layout[y])[x]] ?? .clear
        }
        let applied = try #require(orientation.apply(to: Self.sourceBytes(), size: Self.sourceSize))
        #expect(applied.size == expectedSize)
        #expect(applied.pixels == expected)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func applyMatchesSourcePointOnRandomImages(rawValue: Int) throws {
        let orientation = try #require(ImageOrientation(rawValue: rawValue))
        let seed = SeededRandom.resolvedSeed(default: 0xA11CE + UInt64(rawValue))
        var rng = SeededRandom(seed: seed)
        let sourceSize = PixelSize(width: 37, height: 23)
        let bytes = TestImages.rgbaBytes(width: sourceSize.width, height: sourceSize.height) { _, _ in
            rng.color()
        }
        let destinationSize = orientation.orientedSize(sourceSize)
        var expected = [UInt8]()
        expected.reserveCapacity(bytes.count)
        for y in 0..<destinationSize.height {
            for x in 0..<destinationSize.width {
                let source = orientation.sourcePoint(forDestination: PixelPoint(x: x, y: y),
                                                     sourceSize: sourceSize)
                let base = (source.y * sourceSize.width + source.x) * 4
                expected.append(contentsOf: bytes[base ..< base + 4])
            }
        }
        let applied = try #require(orientation.apply(to: bytes, size: sourceSize),
                                   "apply failed for \(rawValue) — \(rng.comment)")
        #expect(applied.size == destinationSize, rng.comment)
        #expect(applied.pixels == expected, rng.comment)
    }

    @Test func exifValueParsing() {
        #expect(ImageOrientation(exifValue: nil) == .up)
        #expect(ImageOrientation(exifValue: 0) == .up)
        #expect(ImageOrientation(exifValue: 9) == .up)
        #expect(ImageOrientation(exifValue: -3) == .up)
        #expect(ImageOrientation(exifValue: 6) == .right)
        for value in 1...8 {
            let orientation = ImageOrientation(exifValue: value)
            #expect(orientation.swapsDimensions == (5...8).contains(value), "value \(value)")
            let oriented = orientation.orientedSize(PixelSize(width: 3, height: 2))
            #expect(oriented == ((5...8).contains(value)
                    ? PixelSize(width: 2, height: 3) : PixelSize(width: 3, height: 2)),
                    "orientedSize for \(value)")
        }
    }
}
