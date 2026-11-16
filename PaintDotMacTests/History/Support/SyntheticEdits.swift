import Foundation
import Testing

@testable import PaintDotMac

/// Writes a solid color through 0002's region write (`writePixels`) and returns the touched
/// `TileCoordinate`s, computed independently of `TiledSurface` as
/// `floor(minX/256)…floor((maxX−1)/256)` × rows (spec 0008 *Test support*). Rects are clipped
/// to the image bounds first, so a partly off-canvas rect touches only the tiles whose
/// in-bounds part changes.
@discardableResult
func fillRect(_ image: inout LayeredImage, layer: Int, rect: PixelRect,
              color: ColorRGBA8) -> Set<TileCoordinate> {
    let clipped = rect.intersection(image.size.bounds)
    let pixel = [color.red, color.green, color.blue, color.alpha]
    var buffer = [UInt8]()
    buffer.reserveCapacity(clipped.width * clipped.height * 4)
    for _ in 0..<(clipped.width * clipped.height) {
        buffer.append(contentsOf: pixel)
    }
    image.layers[layer].surface.writePixels(buffer, to: clipped)
    return touchedTiles(of: clipped)
}

/// As `fillRect`, also advancing the `ReferenceCanvas` oracle with direct byte writes.
@discardableResult
func fillRect(_ image: inout LayeredImage, layer: Int, rect: PixelRect, color: ColorRGBA8,
              oracle: inout ReferenceCanvas) -> Set<TileCoordinate> {
    let touched = fillRect(&image, layer: layer, rect: rect, color: color)
    oracle.fillRect(rect: rect, color: color, layer: layer)
    return touched
}

/// The tiles a (clipped) rect touches, computed independently of `TiledSurface`.
func touchedTiles(of rect: PixelRect) -> Set<TileCoordinate> {
    guard !rect.isEmpty else { return [] }
    var result: Set<TileCoordinate> = []
    for row in (rect.minY / 256)...((rect.maxY - 1) / 256) {
        for column in (rect.minX / 256)...((rect.maxX - 1) / 256) {
            result.insert(TileCoordinate(column: column, row: row))
        }
    }
    return result
}

/// The independent pixel oracle (spec 0008 *Test support*): one flat `[UInt8]` of
/// `width × height × 4` per layer, updated by direct byte writes.
struct ReferenceCanvas {
    let size: PixelSize
    /// One `w × h × 4` byte plane per layer, in image order.
    var layers: [[UInt8]]

    /// Reads every layer's full bounds.
    init(image: LayeredImage) {
        size = image.size
        layers = image.layers.map { layer in
            var bytes = [UInt8](repeating: 0, count: image.size.width * image.size.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                layer.surface.readPixels(in: image.size.bounds, into: buffer,
                                         bytesPerRow: image.size.width * 4)
            }
            return bytes
        }
    }

    /// Direct byte writes for the in-bounds part of `rect`.
    mutating func fillRect(rect: PixelRect, color: ColorRGBA8, layer: Int) {
        let clipped = rect.intersection(size.bounds)
        guard !clipped.isEmpty else { return }
        let stride = size.width * 4
        for y in clipped.minY..<clipped.maxY {
            let rowStart = y * stride + clipped.minX * 4
            for x in clipped.minX..<clipped.maxX {
                let offset = rowStart + (x - clipped.minX) * 4
                layers[layer][offset] = color.red
                layers[layer][offset + 1] = color.green
                layers[layer][offset + 2] = color.blue
                layers[layer][offset + 3] = color.alpha
            }
        }
    }

    func pixel(x: Int, y: Int, layer: Int) -> [UInt8] {
        let offset = (y * size.width + x) * 4
        return Array(layers[layer][offset..<offset + 4])
    }
}

/// Compares every layer's full region byte for byte against the oracle, printing the first
/// differing pixel (spec 0008 *Test support*).
func assertMatches(_ image: LayeredImage, _ oracle: ReferenceCanvas,
                   _ comment: Comment = "",
                   sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(image.size == oracle.size, "canvas size \(comment)", sourceLocation: sourceLocation)
    #expect(image.layers.count == oracle.layers.count, "layer count \(comment)",
            sourceLocation: sourceLocation)
    guard image.layers.count == oracle.layers.count else { return }
    for (layerIndex, layer) in image.layers.enumerated() {
        var actual = [UInt8](repeating: 0, count: oracle.size.width * oracle.size.height * 4)
        actual.withUnsafeMutableBytes { buffer in
            layer.surface.readPixels(in: oracle.size.bounds, into: buffer,
                                     bytesPerRow: oracle.size.width * 4)
        }
        let expected = oracle.layers[layerIndex]
        guard actual != expected else { continue }
        for pixel in 0..<(oracle.size.width * oracle.size.height) {
            let offset = pixel * 4
            if Array(actual[offset..<offset + 4]) != Array(expected[offset..<offset + 4]) {
                Issue.record(
                    "layer \(layerIndex) pixel (\(pixel % oracle.size.width), \(pixel / oracle.size.width)): actual \(Array(actual[offset..<offset + 4])) != expected \(Array(expected[offset..<offset + 4])) \(comment)",
                    sourceLocation: sourceLocation
                )
                break
            }
        }
        return  // one report per layer maximum
    }
}
