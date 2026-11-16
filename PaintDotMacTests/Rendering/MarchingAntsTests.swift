import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `MarchingAnts` display decisions (spec 0013; CAN-7, NF-7).
struct MarchingAntsTests {
    @Test func modeTable() {
        #expect(MarchingAnts.mode(hasSelection: false, reduceMotion: false) == .hidden)
        #expect(MarchingAnts.mode(hasSelection: false, reduceMotion: true) == .hidden,
                "no selection hides the ants regardless of Reduce Motion")
        #expect(MarchingAnts.mode(hasSelection: true, reduceMotion: false) == .animated)
        #expect(MarchingAnts.mode(hasSelection: true, reduceMotion: true) == .static)
        #expect(MarchingAnts.Mode.hidden.rawValue == "hidden")
        #expect(MarchingAnts.Mode.animated.rawValue == "animated")
        #expect(MarchingAnts.Mode.static.rawValue == "static")
    }

    @Test func constants() {
        #expect(MarchingAnts.dashPattern == [4, 4])
        #expect(MarchingAnts.phasePeriod == 8, "the dash pattern sums to one phase period")
        #expect(MarchingAnts.animationDuration == 0.5)
        #expect(MarchingAnts.lineWidth == 1)
    }

    @Test func viewPathFollowsTransform() throws {
        let selection = try #require(Selection(
            rect: CGRect(x: 10, y: 10, width: 20, height: 20),
            canvasSize: PixelSize(width: 100, height: 100)))
        let transform = CanvasTransform(imageSize: PixelSize(width: 100, height: 100),
                                        viewSize: CGSize(width: 300, height: 300),
                                        backingScale: 2, zoom: 2,
                                        center: CGPoint(x: 50, y: 50))
        let path = MarchingAnts.viewPath(for: selection, transform: transform)
        let expected = transform.canvasRectToView(CGRect(x: 10, y: 10, width: 20, height: 20))
        let box = path.boundingBoxOfPath
        #expect(abs(box.minX - expected.minX) < 1e-9)
        #expect(abs(box.minY - expected.minY) < 1e-9)
        #expect(abs(box.maxX - expected.maxX) < 1e-9)
        #expect(abs(box.maxY - expected.maxY) < 1e-9)
        #expect(box == box.standardized, "view-space bbox is positive-size after the flip")
    }

    @Test func viewPathAtZoomExtremes() throws {
        let selection = Selection.all(canvasSize: PixelSize(width: 200, height: 200))
        for zoom in [CanvasTransform.minimumZoom, CanvasTransform.maximumZoom] {
            let transform = CanvasTransform(imageSize: PixelSize(width: 200, height: 200),
                                            viewSize: CGSize(width: 400, height: 400),
                                            backingScale: 2, zoom: zoom,
                                            center: CGPoint(x: 100, y: 100))
            let box = MarchingAnts.viewPath(for: selection, transform: transform)
                .boundingBoxOfPath
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0),
                           CGPoint(x: 0, y: 200), CGPoint(x: 200, y: 200)]
                .map(transform.canvasToView)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            #expect(box.width.isFinite && box.height.isFinite, "zoom \(zoom): finite path")
            #expect(abs(box.minX - xs.min()!) < 1e-9)
            #expect(abs(box.maxX - xs.max()!) < 1e-9)
            #expect(abs(box.minY - ys.min()!) < 1e-9)
            #expect(abs(box.maxY - ys.max()!) < 1e-9)
        }
    }
}
