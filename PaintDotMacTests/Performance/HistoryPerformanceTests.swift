import XCTest
@testable import PaintDotMac

/// NF-1: history work happens once per stroke at `mouseUp` — a diff over the dirty tiles
/// with the identity fast path, never per frame. Thresholds are gross-regression guards;
/// the measured times are recorded in the spec's Verification status. Timed with
/// `DispatchWallTime` (the repo's perf pattern is `measure` + `XCTClockMetric`, but the
/// PRD §6 thresholds must fail the build, which `measure` cannot do).
final class HistoryPerformanceTests: XCTestCase {
    private func fullWhiteImage(_ width: Int, _ height: Int) -> LayeredImage {
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        surface.fill(.white)
        return LayeredImage(surface: surface)
    }

    private func allTiles(columns: Int, rows: Int) -> Set<TileCoordinate> {
        var set = Set<TileCoordinate>()
        for row in 0..<rows {
            for column in 0..<columns {
                set.insert(TileCoordinate(column: column, row: row))
            }
        }
        return set
    }

    /// 4000×3000 layer, every tile changed: `TileDiff.between` + `commit`. Fail above 150 ms.
    func testFullLayerDiffAndCommit() throws {
        let before = fullWhiteImage(4000, 3000)
        var after = before
        after.layers[0].surface.fill(ColorRGBA8(red: 255, green: 0, blue: 0))

        // Warm up, then measure the `mouseUp` work of a full-layer effect.
        for _ in 0..<2 { try diffAndCommit(before: before, after: after) }
        let iterations = 5
        var lastByteCost = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            lastByteCost = try diffAndCommit(before: before, after: after)
        }
        let average = Double(DispatchTime.now().uptimeNanoseconds - start)
            / 1_000_000 / Double(iterations)
        print("HistoryPerformanceTests.testFullLayerDiffAndCommit: "
              + String(format: "%.1f ms average over %d runs (byteCost %d)",
                       average, iterations, lastByteCost))
        XCTAssertLessThan(average, 150,
                          "full-layer diff + commit regressed past 150 ms (NF-1)")
    }

    /// 4000×3000, one changed tile scanned among all 192 candidate tiles (the identity
    /// fast path does the skipping) + commit. Fail above 5 ms (NF-1's frame is 16 ms).
    func testOneTileStrokeCommit() throws {
        let base = fullWhiteImage(4000, 3000)
        var stroke = base
        fillRect(&stroke, layer: 0, rect: PixelRect(x: 1024, y: 1024, width: 4, height: 4),
                 color: .black)
        let candidates = allTiles(columns: 16, rows: 12)

        try diffAndCommit(before: base, after: stroke, candidates: candidates)
        let iterations = 20
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            try diffAndCommit(before: base, after: stroke, candidates: candidates)
        }
        let average = Double(DispatchTime.now().uptimeNanoseconds - start)
            / 1_000_000 / Double(iterations)
        print("HistoryPerformanceTests.testOneTileStrokeCommit: "
              + String(format: "%.2f ms average over %d runs", average, iterations))
        XCTAssertLessThan(average, 5,
                          "one-tile stroke commit regressed past 5 ms (NF-1)")
    }

    @discardableResult
    private func diffAndCommit(before: LayeredImage, after: LayeredImage,
                               candidates: Set<TileCoordinate>? = nil) throws -> Int {
        let layerID = before.layers[0].id
        var candidateMap: [Layer.ID: Set<TileCoordinate>]?
        if let candidates { candidateMap = [layerID: candidates] }
        let diff = try TileDiff.between(before: before, after: after, candidates: candidateMap)
        var stack = HistoryStack(base: .openImage)
        var live = DocumentState(image: after)
        stack.perform(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff),
                      on: &live)
        return diff.byteCost
    }
}
