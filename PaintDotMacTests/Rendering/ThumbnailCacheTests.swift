import Foundation
import Testing

@testable import PaintDotMac

/// `ThumbnailCache` (spec 0025 item 6): staleness by generation *and* tile storage, the
/// snapshot-undo generation-collision case, and `retain(only:)` for deleted layers.
struct ThumbnailCacheTests {
    private let id = Layer.ID()
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    private let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)

    private func image(_ fill: ColorRGBA8) -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: 8, height: 8))
        surface.fill(fill)
        return surface
    }

    /// A 240×240 two-tile canvas: pixel (0,0) allocates tile (0,0) only.
    private func oneCornerPixel() -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: 300, height: 300))
        surface.setPixel(.black, at: PixelPoint(x: 0, y: 0))
        return surface
    }

    @Test func emptyCacheNeedsRenderThenStores() {
        var cache = ThumbnailCache()
        let surface = image(.white)
        #expect(cache.needsRender(layerID: id, surface: surface))
        #expect(cache.thumbnail(for: id) == nil)
        let rendered = ThumbnailImage(size: PixelSize(width: 1, height: 1), pixels: [.white])
        cache.store(rendered, for: id, surface: surface)
        #expect(!cache.needsRender(layerID: id, surface: surface))
        #expect(cache.thumbnail(for: id) == rendered)
    }

    @Test func mutationRaisesGeneration() {
        var cache = ThumbnailCache()
        var surface = image(.white)
        cache.store(ThumbnailImage(size: PixelSize(width: 1, height: 1), pixels: [.white]),
                    for: id, surface: surface)
        #expect(!cache.needsRender(layerID: id, surface: surface))
        surface.setPixel(red, at: PixelPoint(x: 4, y: 4))   // generation + 1
        #expect(cache.needsRender(layerID: id, surface: surface))
    }

    /// The collision the spec names: a snapshot undo can restore an *older* surface
    /// whose `generation` number equals the cached, newer one's. The tile-storage
    /// comparison catches it (a mutated copy never shares the mutated tile).
    @Test func generationCollisionDetectedByStorage() {
        var cache = ThumbnailCache()
        let s0 = oneCornerPixel()                 // generation g
        var s1 = s0                               // mutated → generation g + 1
        s1.setPixel(red, at: PixelPoint(x: 0, y: 0))
        cache.store(ThumbnailImage(size: PixelSize(width: 1, height: 1), pixels: [red]),
                    for: id, surface: s1)
        #expect(!cache.needsRender(layerID: id, surface: s1))

        var s2 = s0                               // a *different* surface…
        s2.setPixel(blue, at: PixelPoint(x: 0, y: 0))   // …that reaches generation g + 1
        #expect(s2.generation == s1.generation, "fixture: the generations collide")
        #expect(cache.needsRender(layerID: id, surface: s2),
                "different tile storage must re-render despite equal generations")
    }

    /// A restored surface that is tile-for-tile the *same* storage is not stale.
    @Test func equalStorageSameGenerationIsFresh() {
        var cache = ThumbnailCache()
        let s0 = oneCornerPixel()
        cache.store(ThumbnailImage(size: PixelSize(width: 1, height: 1), pixels: [.black]),
                    for: id, surface: s0)
        let copy = s0                             // COW copy: every tile shares storage
        #expect(copy.generation == s0.generation)
        #expect(!cache.needsRender(layerID: id, surface: copy))
    }

    /// A surface whose tiles differ only by *presence* is stale even when the
    /// generations collide (the stored surface has tile (0,0), this one has tile (1,1),
    /// both one mutation from empty).
    @Test func tilePresenceDifferenceIsStale() {
        var cache = ThumbnailCache()
        let s0 = oneCornerPixel()
        cache.store(ThumbnailImage(size: PixelSize(width: 1, height: 1), pixels: [.black]),
                    for: id, surface: s0)
        var other = TiledSurface(size: PixelSize(width: 300, height: 300))
        other.setPixel(.black, at: PixelPoint(x: 299, y: 299))
        #expect(other.generation == s0.generation, "fixture: the generations collide")
        #expect(cache.needsRender(layerID: id, surface: other))
    }

    @Test func retainDropsDeletedLayers() {
        var cache = ThumbnailCache()
        let a = Layer.ID(), b = Layer.ID()
        let rendered = ThumbnailImage(size: PixelSize(width: 1, height: 1), pixels: [.white])
        cache.store(rendered, for: a, surface: image(.white))
        cache.store(rendered, for: b, surface: image(.black))
        cache.retain(only: [a])
        #expect(cache.thumbnail(for: a) == rendered)
        #expect(cache.thumbnail(for: b) == nil)
        #expect(cache.needsRender(layerID: b, surface: image(.black)))
    }
}
