import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PaintDotMac

private let unlimited = ImageLimits(memoryCapBytes: .max)

struct ImageDecoderTests {
    private func decode(_ data: Data) throws -> DecodedImage {
        try ImageDecoder.decode(data, limits: unlimited)
    }

    // MARK: - Straight alpha and sparseness

    @Test func straightAlphaPNGDecodesExactly() throws {
        let pixels: [[ColorRGBA8]] = [
            [ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 10), ColorRGBA8(red: 255, green: 0, blue: 0)],
            [ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0), ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 128)],
        ]
        let data = TestImages.encode(
            TestImages.cgImage(width: 2, height: 2,
                               bytes: TestImages.rgbaBytes(width: 2, height: 2) { x, y in pixels[y][x] }),
            as: .png)
        let image = try ImageDecoder.decodeImage(from: data, limits: unlimited)
        TestImages.expectPixels(image.layers[0].surface) { x, y in pixels[y][x] }
        #expect(image.size == PixelSize(width: 2, height: 2))
        #expect(image.layers.count == 1)
        #expect(image.layers[0].name == "Background")
        #expect(image.dpi == 96)
    }

    @Test func alphaZeroColorAllocatesItsTile() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 600, height: 300,
                               bytes: TestImages.rgbaBytes(width: 600, height: 300) { x, y in
                                   x == 300 && y == 10
                                       ? ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0) : .clear
                               }),
            as: .png)
        let decoded = try decode(data)
        #expect(decoded.surface.allocatedTileCoordinates
                == [TileCoordinate(column: 1, row: 0)])
        #expect(decoded.surface.pixel(at: PixelPoint(x: 300, y: 10))
                == ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0))
    }

    @Test func transparentTilesStayUnallocated() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 600, height: 300,
                               bytes: TestImages.rgbaBytes(width: 600, height: 300) { x, y in
                                   (300..<310).contains(x) && (10..<20).contains(y) ? .white : .clear
                               }),
            as: .png)
        let decoded = try decode(data)
        #expect(decoded.surface.allocatedTileCoordinates
                == [TileCoordinate(column: 1, row: 0)])
        TestImages.expectPixels(decoded.surface) { x, y in
            (300..<310).contains(x) && (10..<20).contains(y) ? .white : .clear
        }
    }

    @Test func opaqueJPEGHasFullAlpha() throws {
        func quadrant(_ x: Int, _ y: Int) -> ColorRGBA8 {
            switch (x < 32, y < 32) {
            case (true, true): ColorRGBA8(red: 255, green: 0, blue: 0)
            case (false, true): ColorRGBA8(red: 0, green: 255, blue: 0)
            case (true, false): ColorRGBA8(red: 0, green: 0, blue: 255)
            case (false, false): ColorRGBA8(red: 255, green: 255, blue: 255)
            }
        }
        let data = TestImages.encode(
            TestImages.cgImage(width: 64, height: 64,
                               bytes: TestImages.rgbaBytes(width: 64, height: 64, quadrant)),
            as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let decoded = try decode(data)
        for y in 0..<64 {
            for x in 0..<64 {
                #expect(decoded.surface.pixel(at: PixelPoint(x: x, y: y)).alpha == 255,
                        "(\(x), \(y)) JPEG pixels are opaque")
            }
        }
        for center in [(16, 16), (48, 16), (16, 48), (48, 48)] {
            TestImages.expectColor(decoded.surface.pixel(at: PixelPoint(x: center.0, y: center.1)),
                                   quadrant(center.0, center.1), tolerance: 8)
        }
    }

    // MARK: - Conversion paths

    @Test func premultipliedTIFFUsesDocumentedRounding() throws {
        // Premultiplied pixel (min(x,y), min(x,y)/2, 0, y) — components ≤ alpha.
        let bytes = TestImages.rgbaBytes(width: 256, height: 256) { x, y in
            let alpha = UInt8(y)
            let red = UInt8(min(x, y))
            return ColorRGBA8(red: red, green: red / 2, blue: 0, alpha: alpha)
        }
        let image = TestImages.cgImage(width: 256, height: 256, bytes: bytes,
                                       alphaInfo: .premultipliedLast)
        let data = TestImages.encode(image, as: .tiff)
        let decoded = try decode(data)
        #expect(decoded.surface.size == PixelSize(width: 256, height: 256))
        let decodedBytes = decoded.surface.readPixels(in: decoded.surface.bounds)
        for y in 0..<256 {
            for x in 0..<256 {
                let alpha = UInt8(y)
                let red = UInt8(min(x, y))
                let base = (y * 256 + x) * 4
                let expectedRed = ColorRGBA8.unpremultiply(red, alpha: alpha)
                let expectedGreen = ColorRGBA8.unpremultiply(red / 2, alpha: alpha)
                #expect(decodedBytes[base] == expectedRed, "(x=\(x), y=\(y)) red")
                #expect(decodedBytes[base + 1] == expectedGreen, "(x=\(x), y=\(y)) green")
                #expect(decodedBytes[base + 2] == ColorRGBA8.unpremultiply(0, alpha: alpha))
                #expect(decodedBytes[base + 3] == alpha)
            }
        }
        // The alpha-0 row decodes to (0, 0, 0, 0) for every x.
        for x in 0..<256 {
            #expect(decoded.surface.pixel(at: PixelPoint(x: x, y: 0)) == .clear, "x=\(x)")
        }
    }

    @Test func sixteenBitIsReducedToEightBit() throws {
        // Big-endian 16-bit components (CGImage default byte order for 16 bpc).
        let samples: [[UInt16]] = [
            [0xFFFF, 0x8080, 0x0000, 0xFFFF],
            [0x1234, 0x5678, 0x9ABC, 0xFFFF],
        ]
        var bytes = [UInt8]()
        for sample in samples {
            for value in sample {
                bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF))
            }
        }
        let image = TestImages.cgImage(width: 2, height: 1, bitsPerComponent: 16, bytes: bytes)
        let data = TestImages.encode(image, as: .png)
        let decoded = try decode(data)
        // Oracle: round(v / 257).
        TestImages.expectColor(decoded.surface.pixel(at: PixelPoint(x: 0, y: 0)),
                               ColorRGBA8(red: 255, green: 128, blue: 0))
        TestImages.expectColor(decoded.surface.pixel(at: PixelPoint(x: 1, y: 0)),
                               ColorRGBA8(red: 18, green: 86, blue: 154), tolerance: 1)
    }

    @Test func floatIsReducedToEightBit() throws {
        let floats: [Float] = [1.0, 0.5, 0.0, 1.0]
        let bytes = floats.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        // ImageIO's TIFF writer only round-trips float RGBA through a premultiplied
        // layout, which is also how float TIFF files carry alpha in practice.
        let image = TestImages.cgImage(width: 1, height: 1, bitsPerComponent: 32, bytes: bytes,
                                       alphaInfo: .premultipliedLast, byteOrder: .floatComponents)
        let data = TestImages.encode(image, as: .tiff)
        let decoded = try decode(data)
        TestImages.expectColor(decoded.surface.pixel(at: .zero),
                               ColorRGBA8(red: 255, green: 128, blue: 0), tolerance: 1)
    }

    @Test func grayscaleIsExpandedToRGBA() throws {
        let gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let image = TestImages.cgImage(width: 2, height: 1, bytes: [0, 128],
                                       colorSpace: gray, alphaInfo: .none)
        let data = TestImages.encode(image, as: .png)
        let decoded = try decode(data)
        TestImages.expectColor(decoded.surface.pixel(at: .zero), .black, tolerance: 1)
        TestImages.expectColor(decoded.surface.pixel(at: PixelPoint(x: 1, y: 0)),
                               ColorRGBA8(red: 128, green: 128, blue: 128), tolerance: 1)
    }

    @Test func linearGrayIsConvertedToSRGBTransfer() throws {
        let linearGray = try #require(CGColorSpace(name: CGColorSpace.linearGray))
        let image = TestImages.cgImage(width: 1, height: 1, bytes: [128],
                                       colorSpace: linearGray, alphaInfo: .none)
        let data = TestImages.encode(image, as: .png)
        let decoded = try decode(data)
        // Oracle: l = 128/255; s = l ≤ 0.0031308 ? 12.92·l : 1.055·l^(1/2.4) − 0.055; round(s·255) = 188.
        let l = 128.0 / 255.0
        let s = l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1.0 / 2.4) - 0.055
        let expected = UInt8((s * 255).rounded())
        #expect(expected == 188)
        TestImages.expectColor(decoded.surface.pixel(at: .zero),
                               ColorRGBA8(red: expected, green: expected, blue: expected),
                               tolerance: 2)
    }

    @Test func displayP3IsConvertedToSRGB() throws {
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))

        // Neutral gray: same white point and transfer → unchanged.
        let grayImage = TestImages.cgImage(width: 1, height: 1, bytes: [128, 128, 128, 255],
                                           colorSpace: displayP3)
        let grayDecoded = try decode(TestImages.encode(grayImage, as: .png))
        TestImages.expectColor(grayDecoded.surface.pixel(at: .zero),
                               ColorRGBA8(red: 128, green: 128, blue: 128), tolerance: 1)

        // Pure P3 red is out of sRGB gamut: clipped toward (255, 0, 0).
        let redImage = TestImages.cgImage(width: 1, height: 1, bytes: [255, 0, 0, 255],
                                          colorSpace: displayP3)
        let red = try decode(TestImages.encode(redImage, as: .png)).surface.pixel(at: .zero)
        #expect(Int(red.red) >= 250, "red \(red.red)")
        #expect(Int(red.green) <= 10, "green \(red.green)")
        #expect(Int(red.blue) <= 10, "blue \(red.blue)")

        // An in-gamut color: conversion must have happened (≠ unchanged) and must match a
        // CoreGraphics oracle (draw the source into an 8-bit sRGB context) within ±2.
        let colorImage = TestImages.cgImage(width: 1, height: 1, bytes: [200, 120, 90, 255],
                                            colorSpace: displayP3)
        let converted = try decode(TestImages.encode(colorImage, as: .png)).surface.pixel(at: .zero)
        #expect(abs(Int(converted.red) - 200) >= 3
            || abs(Int(converted.green) - 120) >= 3
            || abs(Int(converted.blue) - 90) >= 3,
            "a color-changing conversion should not leave \(converted) unchanged")
        let sRGBContext = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: TestImages.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        sRGBContext.draw(colorImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let oracleBase = try #require(sRGBContext.data)
        let oracle = ColorRGBA8(red: oracleBase.load(fromByteOffset: 0, as: UInt8.self),
                                green: oracleBase.load(fromByteOffset: 1, as: UInt8.self),
                                blue: oracleBase.load(fromByteOffset: 2, as: UInt8.self))
        TestImages.expectColor(converted, oracle, tolerance: 2)
    }

    @Test(arguments: [UTType.tiff, UTType.jpeg])
    func cmykIsConvertedToRGB(_ type: UTType) throws {
        let cmyk = try #require(CGColorSpace(name: CGColorSpace.genericCMYK))
        // 2×1: pure (C0 M0 Y0 K0) and pure black ((C0 M0 Y0 K255)), no alpha.
        let image = TestImages.cgImage(width: 2, height: 1,
                                       bytes: [0, 0, 0, 0, 0, 0, 0, 255],
                                       colorSpace: cmyk, alphaInfo: .none)
        let decoded = try decode(TestImages.encode(image, as: type))
        let white = decoded.surface.pixel(at: .zero)
        #expect(Int(white.red) >= 250 && Int(white.green) >= 250 && Int(white.blue) >= 250,
                "\(type): (0,0,0,0) → \(white)")
        #expect(white.alpha == 255)
        let black = decoded.surface.pixel(at: PixelPoint(x: 1, y: 0))
        #expect(Int(black.red) <= 60 && Int(black.green) <= 60 && Int(black.blue) <= 60,
                "\(type): (0,0,0,255) → \(black)")
        #expect(abs(Int(black.red) - Int(black.green)) <= 4)
        #expect(abs(Int(black.green) - Int(black.blue)) <= 4)
        #expect(black.alpha == 255)
    }

    @Test func untaggedImageIsTreatedAsSRGB() throws {
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        let image = TestImages.cgImage(width: 1, height: 1, bytes: [10, 20, 30, 40],
                                       colorSpace: deviceRGB)
        let decoded = try decode(TestImages.encode(image, as: .png))
        TestImages.expectColor(decoded.surface.pixel(at: .zero),
                               ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 40))
    }

    @Test func animatedGIFUsesFirstFrame() throws {
        let red = TestImages.cgImage(width: 1, height: 1, bytes: [255, 0, 0, 255])
        let blue = TestImages.cgImage(width: 1, height: 1, bytes: [0, 0, 255, 255])
        let data = TestImages.encodeFrames([red, blue], as: .gif)
        let decoded = try decode(data)
        TestImages.expectColor(decoded.surface.pixel(at: .zero), .redPixel, tolerance: 1)
    }

    // MARK: - DPI and orientation

    @Test func dpiIsReadFromPNG() throws {
        let image = TestImages.cgImage(width: 4, height: 4,
                                       bytes: [UInt8](repeating: 9, count: 4 * 4 * 4))
        let decoded = try decode(TestImages.encode(image, as: .png, properties: [
            kCGImagePropertyDPIWidth: 300.0, kCGImagePropertyDPIHeight: 300.0,
        ]))
        // pHYs stores pixels per metre: 11,811 px/m = 299.9994 DPI.
        #expect(abs(decoded.dpi - 300) < 0.01, "dpi is \(decoded.dpi)")
    }

    @Test func dpiIsReadFromJPEG() throws {
        let image = TestImages.cgImage(width: 4, height: 4,
                                       bytes: [UInt8](repeating: 9, count: 4 * 4 * 4))
        let decoded = try decode(TestImages.encode(image, as: .jpeg, properties: [
            kCGImagePropertyDPIWidth: 72.5, kCGImagePropertyDPIHeight: 72.5,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]))
        #expect(decoded.dpi == 72.5, "dpi is \(decoded.dpi)")
    }

    @Test func missingDPIDefaultsTo96() throws {
        let image = TestImages.cgImage(width: 4, height: 4,
                                       bytes: [UInt8](repeating: 9, count: 4 * 4 * 4))
        let decoded = try decode(TestImages.encode(image, as: .png))
        #expect(decoded.dpi == 96)
    }

    @Test func resolvedDPIRules() {
        let up = ImageOrientation.up
        #expect(ImageDecoder.resolvedDPI(properties: [kCGImagePropertyDPIWidth: 300.0,
                                                      kCGImagePropertyDPIHeight: 150.0],
                                         orientation: up) == 300)
        #expect(ImageDecoder.resolvedDPI(properties: [kCGImagePropertyDPIWidth: 300.0,
                                                      kCGImagePropertyDPIHeight: 150.0],
                                         orientation: .right) == 150)
        #expect(ImageDecoder.resolvedDPI(properties: [kCGImagePropertyDPIWidth: 0.0,
                                                      kCGImagePropertyDPIHeight: 200.0],
                                         orientation: up) == 200)
        #expect(ImageDecoder.resolvedDPI(properties: [kCGImagePropertyDPIWidth: Double.nan,
                                                      kCGImagePropertyDPIHeight: -1.0],
                                         orientation: up) == 96)
        #expect(ImageDecoder.resolvedDPI(properties: [:], orientation: up) == 96)
        #expect(ImageDecoder.resolvedDPI(properties: [kCGImagePropertyDPIWidth: Double.infinity,
                                                      kCGImagePropertyDPIHeight: 72.0],
                                         orientation: up) == 72)
    }

    @Test func orientationIsAppliedToPixelsAndSize() throws {
        let letters: [Character: ColorRGBA8] = [
            "A": ColorRGBA8(red: 1, green: 0, blue: 10), "B": ColorRGBA8(red: 2, green: 0, blue: 10),
            "C": ColorRGBA8(red: 3, green: 0, blue: 10), "D": ColorRGBA8(red: 4, green: 0, blue: 10),
            "E": ColorRGBA8(red: 5, green: 0, blue: 10), "F": ColorRGBA8(red: 6, green: 0, blue: 10),
        ]
        let grid = [["A", "B", "C"], ["D", "E", "F"]]
        let source = TestImages.cgImage(width: 3, height: 2,
                                        bytes: TestImages.rgbaBytes(width: 3, height: 2) { x, y in
                                            letters[Character(grid[y][x])] ?? .clear
                                        })
        let rotated = try decode(TestImages.encode(source, as: .png,
                                                   properties: [kCGImagePropertyOrientation: 6]))
        #expect(rotated.surface.size == PixelSize(width: 2, height: 3))
        let layout = ["DA", "EB", "FC"]
        TestImages.expectPixels(rotated.surface) { x, y in
            letters[Array(layout[y])[x]] ?? .clear
        }

        let halves = TestImages.cgImage(width: 64, height: 32,
                                        bytes: TestImages.rgbaBytes(width: 64, height: 32) { x, _ in
                                            x < 32 ? .redPixel : .bluePixel
                                        })
        let jpeg = TestImages.encode(halves, as: .jpeg, properties: [
            kCGImagePropertyOrientation: 8, kCGImageDestinationLossyCompressionQuality: 0.95,
        ])
        let rotatedJPEG = try decode(jpeg)
        #expect(rotatedJPEG.surface.size == PixelSize(width: 32, height: 64))
        TestImages.expectColor(rotatedJPEG.surface.pixel(at: PixelPoint(x: 16, y: 8)),
                               .bluePixel, tolerance: 8, "top half blue")
        TestImages.expectColor(rotatedJPEG.surface.pixel(at: PixelPoint(x: 16, y: 56)),
                               .redPixel, tolerance: 8, "bottom half red")
    }

    // MARK: - Limits and integrity

    @Test func maximumWidthOpens() throws {
        let width = 65_535
        var bytes = [UInt8](repeating: 0, count: width * 4)
        bytes[(width - 1) * 4 ..< (width - 1) * 4 + 4] = [0, 255, 0, 255]
        let image = TestImages.cgImage(width: width, height: 1, bytes: bytes)
        let decoded = try decode(TestImages.encode(image, as: .png))
        #expect(decoded.surface.size == PixelSize(width: 65_535, height: 1))
        #expect(decoded.surface.allocatedTileCoordinates
                == [TileCoordinate(column: 255, row: 0)])
        #expect(decoded.surface.pixel(at: PixelPoint(x: 65_534, y: 0))
                == ColorRGBA8(red: 0, green: 255, blue: 0))
    }

    @Test func decodedSurfaceMatchesSurfaceFromCGImage() throws {
        let pixels = TestImages.rgbaBytes(width: 2, height: 2) { x, y in
            ColorRGBA8(red: UInt8(10 + x * 40), green: UInt8(20 + y * 40),
                       blue: 50, alpha: UInt8(x == 0 && y == 1 ? 0 : 200))
        }
        let image = TestImages.cgImage(width: 2, height: 2, bytes: pixels)
        let fromCG = try ImageDecoder.surface(from: image, limits: unlimited)
        let fromFile = try decode(TestImages.encode(image, as: .png))
        #expect(fromCG == fromFile.surface)
    }

    /// `surface(from:)` runs the same APP-10 limit check as `decode` (spec 0002 *Public API*).
    @Test func surfaceFromCGImageEnforcesLimits() throws {
        let image = TestImages.cgImage(width: 16, height: 16,
                                       bytes: [UInt8](repeating: 0x40, count: 16 * 16 * 4))
        #expect(throws: ImageCodecError.limitExceeded(
            .exceedsMemoryCap(requiredBytes: 1_024, capBytes: 1_023))) {
            try ImageDecoder.surface(from: image, limits: ImageLimits(memoryCapBytes: 1_023))
        }
        let surface = try ImageDecoder.surface(from: image, limits: ImageLimits(memoryCapBytes: 1_024))
        #expect(surface.size == PixelSize(width: 16, height: 16))
    }

    /// Path S with a premultiplied source (step 8): an 8-bit Display P3 TIFF written from a
    /// premultiplied buffer keeps its associated-alpha semantics; alpha-0 pixels must decode
    /// to exactly `(0, 0, 0, 0)` no matter what color the premultiplied source stored under
    /// them (invalid input here: red 120, green 60, blue 30 with alpha 0).
    @Test func premultipliedWideGamutAlphaZeroPixelsDecodeToClear() throws {
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let bytes: [UInt8] = [255, 0, 0, 255, 120, 60, 30, 0]
        let image = TestImages.cgImage(width: 2, height: 1, bytes: bytes,
                                       colorSpace: displayP3, alphaInfo: .premultipliedLast)
        let decoded = try decode(TestImages.encode(image, as: .tiff))
        let red = decoded.surface.pixel(at: .zero)
        #expect(Int(red.red) >= 250 && Int(red.green) <= 10 && Int(red.blue) <= 10,
                "opaque P3 red converts to clipped sRGB red, got \(red)")
        #expect(red.alpha == 255)
        #expect(decoded.surface.pixel(at: PixelPoint(x: 1, y: 0)) == .clear,
                "alpha-0 pixels of a premultiplied source decode to (0, 0, 0, 0)")
    }

    @Test func pngChunkWalk() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 8, height: 8,
                               bytes: TestImages.rgbaBytes(width: 8, height: 8) { x, y in
                                   ColorRGBA8(red: UInt8(x * 30), green: UInt8(y * 20), blue: 9)
                               }),
            as: .png)
        #expect(ImageDecoder.pngChunksAreComplete(data))
        #expect(ImageDecoder.pngChunksAreComplete(data + Data(repeating: 0x55, count: 100)))
        #expect(!ImageDecoder.pngChunksAreComplete(Data()))
        #expect(!ImageDecoder.pngChunksAreComplete(Data(data.prefix(8))))
        #expect(!ImageDecoder.pngChunksAreComplete(data.dropLast(1)))
        #expect(!ImageDecoder.pngChunksAreComplete(data.dropLast(12)))
        #expect(!ImageDecoder.pngChunksAreComplete(data.prefix(data.count / 2)))
        var hugeFirstChunk = [UInt8](data)
        hugeFirstChunk[4] = 0xFF; hugeFirstChunk[5] = 0xFF
        hugeFirstChunk[6] = 0xFF; hugeFirstChunk[7] = 0xFF
        #expect(!ImageDecoder.pngChunksAreComplete(Data(hugeFirstChunk)))
    }
}

private extension ColorRGBA8 {
    static let redPixel = ColorRGBA8(red: 255, green: 0, blue: 0)
    static let bluePixel = ColorRGBA8(red: 0, green: 0, blue: 255)
}
