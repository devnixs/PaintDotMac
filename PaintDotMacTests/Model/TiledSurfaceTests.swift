import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

struct TiledSurfaceTests {
    private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }
    private func coord(_ column: Int, _ row: Int) -> TileCoordinate {
        TileCoordinate(column: column, row: row)
    }
    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> PixelRect {
        PixelRect(x: x, y: y, width: w, height: h)
    }

    @Test func tileGridDimensions() {
        for (width, height, columns, rows) in [
            (1, 1, 1, 1), (256, 256, 1, 1), (257, 256, 2, 1), (512, 513, 2, 3), (65_535, 1, 256, 1),
        ] {
            let surface = TiledSurface(size: PixelSize(width: width, height: height))
            #expect(surface.tileColumns == columns, "\(width)×\(height) columns")
            #expect(surface.tileRows == rows, "\(width)×\(height) rows")
            #expect(surface.tileCount == columns * rows)
        }
    }

    @Test func newSurfaceIsEmptyAndSparse() {
        let surface = TiledSurface(size: PixelSize(width: 1_000, height: 700))
        #expect(surface.allocatedTileCount == 0)
        #expect(surface.generation == 0)
        #expect(surface.pixel(at: point(0, 0)) == .clear)
        #expect(surface.pixel(at: point(999, 699)) == .clear)
        #expect(surface.pixel(at: point(500, 350)) == .clear)
        #expect(surface.readPixels(in: surface.bounds).allSatisfy { $0 == 0 })
    }

    @Test func setAndGetPixel() {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 300))
        let color = ColorRGBA8(red: 10, green: 20, blue: 0, alpha: 128)
        for p in [point(0, 0), point(255, 0), point(256, 0), point(599, 299)] {
            surface.setPixel(color, at: p)
        }
        for p in [point(0, 0), point(255, 0), point(256, 0), point(599, 299)] {
            #expect(surface.pixel(at: p) == color, "\(p)")
        }
        #expect(surface.allocatedTileCoordinates == [coord(0, 0), coord(1, 0), coord(2, 1)])
        #expect(surface.pixel(at: point(1, 1)) == .clear)
    }

    @Test func outOfBoundsAccessIsSafe() {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 300))
        for p in [point(-1, 0), point(600, 0), point(0, 300)] {
            #expect(surface.pixel(at: p) == .clear)
            surface.setPixel(.white, at: p)
        }
        #expect(surface.allocatedTileCount == 0)
        #expect(surface.generation == 0)
    }

    @Test func writeAndReadRegionAcrossTiles() {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 600))
        let region = rect(100, 100, 300, 300)
        let bytes = TestImages.rgbaBytes(width: 300, height: 300) { x, y in
            ColorRGBA8(red: UInt8(x % 251), green: UInt8(y % 241), blue: UInt8((x + y) % 256))
        }
        surface.writePixels(bytes, to: region)
        #expect(surface.readPixels(in: region) == bytes)
        #expect(surface.allocatedTileCoordinates == [coord(0, 0), coord(1, 0), coord(0, 1), coord(1, 1)])
        #expect(surface.pixel(at: point(99, 100)) == .clear)
    }

    @Test func regionWritesAreClipped() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0)
        var surface = TiledSurface(size: PixelSize(width: 300, height: 200))
        let bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
        surface.writePixels(TestImages.rgbaBytes(width: 100, height: 100) { _, _ in red },
                            to: rect(250, 150, 100, 100))
        for y in 150..<200 {
            for x in 250..<300 {
                #expect(surface.pixel(at: point(x, y)) == red, "(\(x), \(y))")
            }
        }
        #expect(surface.pixel(at: point(249, 150)) == .clear)
        #expect(bytes.count > 0)

        var clippedTopLeft = TiledSurface(size: PixelSize(width: 300, height: 200))
        clippedTopLeft.writePixels(TestImages.rgbaBytes(width: 100, height: 100) { _, _ in red },
                                   to: rect(-50, -50, 100, 100))
        for y in 0..<50 {
            for x in 0..<50 {
                #expect(clippedTopLeft.pixel(at: point(x, y)) == red, "(\(x), \(y))")
            }
        }
        #expect(clippedTopLeft.pixel(at: point(50, 0)) == .clear)
        #expect(clippedTopLeft.pixel(at: point(0, 50)) == .clear)

        let generationBefore = clippedTopLeft.generation
        clippedTopLeft.writePixels(TestImages.rgbaBytes(width: 10, height: 10) { _, _ in red },
                                   to: rect(400, 400, 10, 10))
        #expect(clippedTopLeft.generation == generationBefore, "a fully outside write is a no-op")
    }

    @Test func regionReadPadsOutOfBoundsWithZero() {
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255)
        var surface = TiledSurface(size: PixelSize(width: 10, height: 10))
        surface.setPixel(blue, at: point(0, 0))
        surface.setPixel(blue, at: point(1, 0))
        surface.setPixel(blue, at: point(0, 1))
        let bytes = surface.readPixels(in: rect(-2, -2, 4, 4))
        // Row-major 4×4; local (2,2), (3,2), (2,3) map to (0,0), (1,0), (0,1).
        func localPixel(_ lx: Int, _ ly: Int) -> [UInt8] {
            Array(bytes[(ly * 4 + lx) * 4 ..< (ly * 4 + lx) * 4 + 4])
        }
        #expect(localPixel(2, 2) == [0, 0, 255, 255])
        #expect(localPixel(3, 2) == [0, 0, 255, 255])
        #expect(localPixel(2, 3) == [0, 0, 255, 255])
        #expect(localPixel(3, 3) == [0, 0, 0, 0])
        #expect(localPixel(0, 0) == [0, 0, 0, 0])
    }

    @Test func readIntoBufferWithStride() {
        var surface = TiledSurface(size: PixelSize(width: 300, height: 10))
        let bytes = TestImages.rgbaBytes(width: 300, height: 10) { x, y in
            ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 7)
        }
        surface.writePixels(bytes, to: rect(0, 0, 300, 10))
        let width = 300, height = 10, stride = width * 4 + 12
        var buffer = [UInt8](repeating: 0xEE, count: stride * height)
        buffer.withUnsafeMutableBytes { destination in
            surface.readPixels(in: surface.bounds, into: destination, bytesPerRow: stride)
        }
        for y in 0..<height {
            let rowOk = Array(buffer[y * stride ..< y * stride + width * 4])
                == Array(bytes[y * width * 4 ..< (y + 1) * width * 4])
            #expect(rowOk, "row \(y) written at its stride")
            let padOk = buffer[(y * stride + width * 4) ..< (y + 1) * stride].allSatisfy { $0 == 0xEE }
            #expect(padOk, "row \(y) padding untouched")
        }
    }

    @Test func transparentWritesDoNotAllocate() {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 300))
        surface.setPixel(.clear, at: point(10, 10))
        #expect(surface.allocatedTileCount == 0)
        #expect(surface.generation == 0)

        surface.writePixels([UInt8](repeating: 0, count: 300 * 300 * 4), to: rect(0, 0, 300, 300))
        #expect(surface.allocatedTileCount == 0)
        #expect(surface.generation == 0)

        surface.fill(.clear)
        #expect(surface.allocatedTileCount == 0)
        #expect(surface.generation == 0)

        surface.setPixel(ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0), at: point(40, 40))
        #expect(surface.allocatedTileCount == 1)
        #expect(surface.pixel(at: point(40, 40)) == ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0))
    }

    @Test func fillWholeSurface() throws {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 300))
        surface.fill(.white)
        TestImages.expectPixels(surface) { _, _ in .white }
        #expect(surface.allocatedTileCount == 6)
        let interiorA = try #require(surface.tile(at: coord(0, 0)))
        let interiorB = try #require(surface.tile(at: coord(1, 0)))
        #expect(interiorA.sharesStorage(with: interiorB),
                "fully covered interior tiles share one buffer")
        // Edge tile (2,1): only x < 88 and y < 44 are in bounds; everything else stays zero.
        if let edge = surface.tile(at: coord(2, 1)) {
            var paddingOk = true
            for y in 0..<256 {
                for x in 0..<256 where x >= 88 || y >= 44 {
                    if edge.pixel(x: x, y: y) != .clear { paddingOk = false }
                }
            }
            #expect(paddingOk)
        }
        surface.fill(.clear)
        #expect(surface.allocatedTileCount == 0)
    }

    @Test func fillSharesInteriorTileStorage() throws {
        var surface = TiledSurface(size: PixelSize(width: 1_024, height: 1_024))
        surface.fill(.white)
        #expect(surface.allocatedTileCount == 16)
        let tileA = try #require(surface.tile(at: coord(0, 0)))
        let tileB = try #require(surface.tile(at: coord(3, 3)))
        #expect(tileA.sharesStorage(with: tileB))
        surface.setPixel(.black, at: point(0, 0))
        #expect(surface.tile(at: coord(0, 0))?.sharesStorage(with: surface.tile(at: coord(3, 3)) ?? Tile()) == false)
        #expect(surface.tile(at: coord(3, 3))?.pixel(x: 255, y: 255) == .white)
        #expect(surface.tile(at: coord(3, 3))?.pixel(x: 0, y: 0) == .white)
        #expect(surface.tile(at: coord(1, 0))?.sharesStorage(with: surface.tile(at: coord(3, 3)) ?? Tile()) == true)
    }

    @Test func fillRectPartialTiles() {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 600))
        surface.fill(.black, in: rect(250, 250, 20, 20))
        #expect(surface.allocatedTileCoordinates == [coord(0, 0), coord(1, 0), coord(0, 1), coord(1, 1)])
        for y in 250..<270 {
            for x in 250..<270 {
                #expect(surface.pixel(at: point(x, y)) == .black, "(\(x), \(y))")
            }
        }
        #expect(surface.pixel(at: point(249, 250)) == .clear)
        #expect(surface.pixel(at: point(270, 250)) == .clear)
        #expect(surface.pixel(at: point(250, 270)) == .clear)
    }

    @Test func releaseTransparentTilesFreesZeroTiles() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0)
        var surface = TiledSurface(size: PixelSize(width: 800, height: 300))
        for p in [point(10, 10), point(300, 10), point(550, 10)] {
            surface.setPixel(red, at: p)
        }
        #expect(surface.allocatedTileCount == 3)
        surface.setPixel(.clear, at: point(10, 10))
        surface.setPixel(.clear, at: point(300, 10))
        #expect(surface.allocatedTileCount == 3)
        let generationBefore = surface.generation
        surface.releaseTransparentTiles()
        #expect(surface.allocatedTileCount == 1)
        #expect(surface.changedTiles(since: generationBefore) == [coord(0, 0), coord(1, 0)])
        #expect(surface.pixel(at: point(550, 10)) == red)
        #expect(surface.pixel(at: point(10, 10)) == .clear)
    }

    @Test func copyOnWriteIsPerTile() throws {
        var original = TiledSurface(size: PixelSize(width: 512, height: 512))
        for y in 0..<512 {
            for x in 0..<512 {
                original.setPixel(ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 3),
                                  at: point(x, y))
            }
        }
        var copy = original
        let old = copy.pixel(at: point(300, 10))
        copy.setPixel(.black, at: point(300, 10))
        #expect(original.pixel(at: point(300, 10)) == old, "the original is unchanged")
        #expect(copy.pixel(at: point(300, 10)) == .black)
        #expect(try #require(copy.tile(at: coord(0, 0)))
            .sharesStorage(with: try #require(original.tile(at: coord(0, 0)))),
            "untouched tiles still share")
        #expect(try #require(copy.tile(at: coord(1, 0)))
            .sharesStorage(with: try #require(original.tile(at: coord(1, 0)))) == false,
            "the touched tile was copied")
    }

    @Test func generationTracksTouchedTiles() {
        var surface = TiledSurface(size: PixelSize(width: 1_024, height: 1_024))
        let g0 = surface.generation
        surface.setPixel(.white, at: point(600, 300))  // tile (2,1)
        #expect(surface.generation == g0 + 1)
        #expect(surface.changedTiles(since: g0) == [coord(2, 1)])
        surface.writePixels(TestImages.rgbaBytes(width: 200, height: 100) { _, _ in .black },
                            to: rect(100, 100, 200, 100))  // tiles (0,0) and (1,0)
        #expect(surface.generation == g0 + 2)
        #expect(surface.changedTiles(since: g0 + 1) == [coord(0, 0), coord(1, 0)])
        #expect(surface.changedTiles(since: g0) == [coord(0, 0), coord(1, 0), coord(2, 1)])
        surface.setTile(nil, at: coord(3, 3))
        #expect(surface.generation == g0 + 3)
        #expect(surface.changedTiles(since: g0 + 2) == [coord(3, 3)])
    }

    @Test func noOpWritesDoNotBumpGeneration() {
        var surface = TiledSurface(size: PixelSize(width: 600, height: 600))
        surface.writePixels(TestImages.rgbaBytes(width: 10, height: 10) { _, _ in .white },
                            to: rect(900, 900, 10, 10))
        surface.fill(.white, in: PixelRect.zero)
        surface.setPixel(.clear, at: point(5, 5))
        surface.writePixels([UInt8](repeating: 0, count: 50 * 50 * 4), to: rect(0, 0, 50, 50))
        #expect(surface.generation == 0)
        #expect(surface.allocatedTileCount == 0)
    }

    @Test func equalityIgnoresAllocationAndGenerations() {
        var withZeroTile = TiledSurface(size: PixelSize(width: 300, height: 300))
        withZeroTile.setPixel(.white, at: point(0, 0))
        withZeroTile.setPixel(.clear, at: point(0, 0))
        let empty = TiledSurface(size: PixelSize(width: 300, height: 300))
        #expect(withZeroTile == empty, "an allocated all-zero tile equals an unallocated one")

        var a = TiledSurface(size: PixelSize(width: 300, height: 300))
        var b = TiledSurface(size: PixelSize(width: 300, height: 300))
        a.setPixel(.black, at: point(10, 10))
        b.setPixel(.white, at: point(10, 10))
        b.setPixel(.black, at: point(10, 10))
        #expect(a.generation != b.generation)
        #expect(a == b)
        b.setPixel(.black, at: point(11, 10))
        #expect(a != b)
        #expect(a != TiledSurface(size: PixelSize(width: 300, height: 301)))
    }

    @Test func bulkImportSkipsZeroTiles() {
        let width = 600, height = 300, stride = width * 4 + 16
        var buffer = [UInt8](repeating: 0, count: stride * height)
        buffer[280 * stride + 400 * 4 ... 280 * stride + 400 * 4 + 3] = [9, 8, 7, 255]
        let surface = buffer.withUnsafeBytes { bytes in
            TiledSurface(size: PixelSize(width: width, height: height), rgba8: bytes, bytesPerRow: stride)
        }
        #expect(surface.allocatedTileCoordinates == [coord(1, 1)])
        #expect(surface.pixel(at: point(400, 280)) == ColorRGBA8(red: 9, green: 8, blue: 7))
    }

    @Test func makeCGImageRoundTrip() throws {
        let surface = TestImages.surface(width: 300, height: 200) { x, y in
            ColorRGBA8(red: UInt8((x * 3) % 256), green: UInt8((y * 5) % 256),
                       blue: UInt8((x ^ y) % 256),
                       alpha: (x + y) % 7 == 0 ? 10 : 255)
        }
        let image = try #require(surface.makeCGImage())
        #expect(image.width == 300)
        #expect(image.height == 200)
        #expect(image.bitsPerComponent == 8)
        #expect(image.alphaInfo == .last)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        let providerBytes = [UInt8](image.dataProvider!.data! as Data)
        #expect(providerBytes == surface.readPixels(in: surface.bounds))
    }

    @Test func setTileRoundTrip() throws {
        var surface = TiledSurface(size: PixelSize(width: 256, height: 256))
        let tile = Tile(filledWith: .white)
        surface.setTile(tile, at: coord(0, 0))
        #expect(surface.tile(at: coord(0, 0)) == tile)
        surface.setTile(nil, at: coord(0, 0))
        #expect(surface.tile(at: coord(0, 0)) == nil)
        #expect(surface.allocatedTileCount == 0)
    }

    @Test func tileCoordinateOrderingIsRowMajor() {
        #expect(TileCoordinate(column: 1, row: 0) < TileCoordinate(column: 0, row: 1),
                "a lower row sorts before a higher one regardless of column")
        #expect(TileCoordinate(column: 0, row: 0) < TileCoordinate(column: 1, row: 0))
        #expect(!(TileCoordinate(column: 0, row: 1) < TileCoordinate(column: 0, row: 1)))
        #expect([TileCoordinate(column: 0, row: 1), TileCoordinate(column: 5, row: 0),
                 TileCoordinate(column: 1, row: 0)].sorted()
                == [TileCoordinate(column: 1, row: 0), TileCoordinate(column: 5, row: 0),
                    TileCoordinate(column: 0, row: 1)])
    }

    @Test func tileBasicOperations() {
        let color = ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 4)
        var tile = Tile(filledWith: color)
        #expect(tile.pixel(x: 0, y: 0) == color)
        #expect(tile.pixel(x: 255, y: 255) == color)
        #expect(Tile().isFullyTransparent)
        #expect(!tile.isFullyTransparent)
        tile.setPixel(.clear, x: 5, y: 5)
        #expect(tile.pixel(x: 5, y: 5) == .clear)
        let copy = tile
        #expect(copy.sharesStorage(with: tile))
        // Array initialization copies lazily: the buffers share until one is mutated.
        var independent = Tile(bytes: tile.bytes)
        #expect(independent.sharesStorage(with: tile))
        independent.setPixel(.white, x: 0, y: 0)
        #expect(!independent.sharesStorage(with: tile))
        #expect(tile.pixel(x: 0, y: 0) == color)
        #expect(Tile.size == 256)
        #expect(Tile.bytesPerRow == 1_024)
        #expect(Tile.byteCount == 262_144)
    }
}
