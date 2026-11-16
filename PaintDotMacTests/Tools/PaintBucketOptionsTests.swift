import Foundation
import Testing

@testable import PaintDotMac

/// `PaintBucketOptions` (spec 0017 *Test plan*): Paint.NET defaults, the exact
/// `tool.paintBucket.*` key layout independent of the Magic Wand's copies (TOOL-C), and
/// the fallback/clamp rules for bad stored values.
@MainActor
struct PaintBucketOptionsTests {
    @Test func defaultsMatchPaintNET() {
        let options = PaintBucketOptions.default
        #expect(options.fillMode == .similarColor)
        #expect(options.floodMode == .contiguous)
        #expect(options.tolerance == FloodTolerance(percent: 50))
        #expect(options.tolerance.percent == 50)
        #expect(options.samplingMode == .layer)
        #expect(options.antialiasing == true)
        #expect(options.blendMode == .normal)
        // An empty store loads exactly the defaults.
        #expect(PaintBucketOptions.load(from: InMemoryToolOptionStore()) == options)
    }

    @Test func roundTripThroughStore() {
        let store = InMemoryToolOptionStore()
        var options = PaintBucketOptions.default
        options.fillMode = .selection
        options.floodMode = .global
        options.tolerance = FloodTolerance(percent: 87)
        options.samplingMode = .image
        options.antialiasing = false
        options.blendMode = .normal
        options.save(to: store)

        // Every option reads back through the same keys.
        #expect(PaintBucketOptions.load(from: store) == options)

        // The keys are exactly `tool.paintBucket.*` (TOOL-C), stored in 0016's formats.
        #expect(store.storedValue(forKey: "tool.paintBucket.fillMode") as? String == "selection")
        #expect(store.storedValue(forKey: "tool.paintBucket.floodMode") as? String == "global")
        #expect(store.storedValue(forKey: "tool.paintBucket.samplingMode") as? String == "image")
        #expect(store.storedValue(forKey: "tool.paintBucket.blendMode") as? String == "normal")
        #expect(store.storedValue(forKey: "tool.paintBucket.antialiasing") as? Bool == false)
        #expect(store.storedValue(forKey: "tool.paintBucket.tolerance") as? Int == 87)

        // The Magic Wand's keys are untouched — the tools are independent (0016).
        for name in ["fillMode", "floodMode", "tolerance", "samplingMode",
                     "antialiasing", "blendMode"] {
            #expect(store.storedValue(forKey: "tool.magicWand.\(name)") == nil, "key \(name)")
        }
    }

    @Test func invalidStoredValues() {
        let store = InMemoryToolOptionStore()
        // Out-of-range tolerance clamps on read (0016's key range).
        store.setStoredValue(-5, forKey: "tool.paintBucket.tolerance")
        #expect(PaintBucketOptions.load(from: store).tolerance == FloodTolerance(percent: 0))
        store.setStoredValue(400, forKey: "tool.paintBucket.tolerance")
        #expect(PaintBucketOptions.load(from: store).tolerance == FloodTolerance(percent: 100))

        // Unknown raw strings read as the defaults; mixed with a valid sibling.
        store.setStoredValue("foo", forKey: "tool.paintBucket.fillMode")
        store.setStoredValue("foo", forKey: "tool.paintBucket.floodMode")
        store.setStoredValue("foo", forKey: "tool.paintBucket.samplingMode")
        store.setStoredValue("foo", forKey: "tool.paintBucket.blendMode")
        let loaded = PaintBucketOptions.load(from: store)
        #expect(loaded.fillMode == .similarColor)
        #expect(loaded.floodMode == .contiguous)
        #expect(loaded.samplingMode == .layer)
        #expect(loaded.blendMode == .normal)
        #expect(loaded.tolerance == FloodTolerance(percent: 100), "the clamp persists")

        // A stored value of the wrong type (a string for the Bool) also falls back.
        store.setStoredValue("yes", forKey: "tool.paintBucket.antialiasing")
        #expect(PaintBucketOptions.load(from: store).antialiasing == true)
    }
}
