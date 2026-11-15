import Testing
@testable import PaintDotMac

/// TOOL-C option storage: key format, type bridging, defaults, clamping (spec 0006 *Test
/// plan*). All expected values are hand-computed from the spec's bridging rules.
@MainActor
struct ToolOptionStoreTests {
    private enum Mode: String, ToolOptionValue {
        case a
        case b
    }

    @Test func defaultsKeyFormat() {
        #expect(ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 2.0).defaultsKey
                    == "tool.paintbrush.width")
        #expect(ToolOptionKey(tool: .zoom, name: "mode", defaultValue: "x").defaultsKey
                    == "tool.zoom.mode")
    }

    @Test func missingReturnsDefault() {
        let store = InMemoryToolOptionStore()
        #expect(store.value(ToolOptionKey(tool: .pan, name: "missing", defaultValue: 7)) == 7)
        #expect(store.value(ToolOptionKey(tool: .pan, name: "missing", defaultValue: 1.5)) == 1.5)
        #expect(store.value(ToolOptionKey(tool: .pan, name: "missing", defaultValue: true)) == true)
        #expect(store.value(ToolOptionKey(tool: .pan, name: "missing", defaultValue: "x")) == "x")
    }

    @Test func roundTripTypes() {
        let store = InMemoryToolOptionStore()
        let boolKey = ToolOptionKey(tool: .pan, name: "flag", defaultValue: false)
        let intKey = ToolOptionKey(tool: .pan, name: "count", defaultValue: 0)
        let doubleKey = ToolOptionKey(tool: .pan, name: "ratio", defaultValue: 0.0)
        let stringKey = ToolOptionKey(tool: .pan, name: "label", defaultValue: "")
        let modeKey = ToolOptionKey(tool: .pan, name: "mode", defaultValue: Mode.a)

        store.setValue(true, for: boolKey)
        store.setValue(-12, for: intKey)
        store.setValue(2.5, for: doubleKey)
        store.setValue("hello", for: stringKey)
        store.setValue(.b, for: modeKey)

        #expect(store.value(boolKey) == true)
        #expect(store.value(intKey) == -12)
        #expect(store.value(doubleKey) == 2.5)
        #expect(store.value(stringKey) == "hello")
        #expect(store.value(modeKey) == .b)
        // Enums store the raw string.
        #expect(store.storedValue(forKey: "tool.pan.mode") as? String == "b")
    }

    @Test func wrongTypeReturnsDefault() {
        let store = InMemoryToolOptionStore()
        let intKey = ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 2)
        let doubleKey = ToolOptionKey(tool: .paintbrush, name: "opacity", defaultValue: 1.0)
        let boolKey = ToolOptionKey(tool: .paintbrush, name: "aa", defaultValue: true)
        let stringKey = ToolOptionKey(tool: .paintbrush, name: "label", defaultValue: "d")
        let modeKey = ToolOptionKey(tool: .paintbrush, name: "mode", defaultValue: Mode.a)

        store.setStoredValue("abc", forKey: "tool.paintbrush.width")
        #expect(store.value(intKey) == 2)
        store.setStoredValue(2.5, forKey: "tool.paintbrush.width")
        #expect(store.value(intKey) == 2, "a non-integral number is not an Int")
        store.setStoredValue(Double.nan, forKey: "tool.paintbrush.opacity")
        #expect(store.value(doubleKey) == 1.0, "a non-finite double reads as missing")
        store.setStoredValue(Double.infinity, forKey: "tool.paintbrush.opacity")
        #expect(store.value(doubleKey) == 1.0)
        store.setStoredValue(5, forKey: "tool.paintbrush.aa")
        #expect(store.value(boolKey) == true, "5 is neither 0 nor 1")
        store.setStoredValue(1, forKey: "tool.paintbrush.aa")
        #expect(store.value(boolKey) == true, "NSNumber 1 reads as true")
        store.setStoredValue(0, forKey: "tool.paintbrush.aa")
        #expect(store.value(boolKey) == false, "NSNumber 0 reads as false")
        store.setStoredValue(true, forKey: "tool.paintbrush.width")
        #expect(store.value(intKey) == 2, "a Bool is not an Int")
        store.setStoredValue(7, forKey: "tool.paintbrush.label")
        #expect(store.value(stringKey) == "d", "only a String reads as String")
        store.setStoredValue("zzz", forKey: "tool.paintbrush.mode")
        #expect(store.value(modeKey) == .a)
    }

    @Test func rangeClampsOnReadAndWrite() {
        let store = InMemoryToolOptionStore()
        let key = ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 2, range: 1...2000)
        store.setValue(5000, for: key)
        #expect(store.storedValue(forKey: "tool.paintbrush.width") as? Int == 2000)
        #expect(store.value(key) == 2000)
        store.setStoredValue(0, forKey: "tool.paintbrush.width")
        #expect(store.value(key) == 1, "raw values written elsewhere are clamped on read")
    }

    @Test func keysEqualByToolAndName() {
        let a = ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 2)
        let b = ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 99)
        let c = ToolOptionKey(tool: .eraser, name: "width", defaultValue: 2)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
    }

    @Test func removeValueRestoresDefault() {
        let store = InMemoryToolOptionStore()
        let key = ToolOptionKey(tool: .pan, name: "x", defaultValue: 5)
        store.setValue(42, for: key)
        #expect(store.value(key) == 42)
        store.removeValue(for: key)
        #expect(store.value(key) == 5)
        #expect(store.storedValue(forKey: "tool.pan.x") == nil)
    }

    /// Seeded round trip: whatever is written (in range / finite) reads back unchanged.
    @Test(arguments: [UInt64(0x5EED_0006_0002)])
    func randomRoundTrip(seed: UInt64) {
        var random = SeededRandom(seed: SeededRandom.resolvedSeed(default: seed))
        let store = InMemoryToolOptionStore()
        let intKey = ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 2, range: 1...2000)
        let doubleKey = ToolOptionKey(tool: .gradient, name: "angle", defaultValue: 0.0,
                                      range: -360.0...360.0)
        let boolKey = ToolOptionKey(tool: .paintbrush, name: "aa", defaultValue: true)
        let stringKey = ToolOptionKey(tool: .text, name: "font", defaultValue: "System")

        for _ in 0..<200 {
            let intValue = random.int(in: 1...2000)
            store.setValue(intValue, for: intKey)
            #expect(store.value(intKey) == intValue, random.comment)

            let doubleValue = random.double(in: -360...360)
            store.setValue(doubleValue, for: doubleKey)
            #expect(store.value(doubleKey) == doubleValue, random.comment)

            let boolValue = random.int(in: 0...1) == 1
            store.setValue(boolValue, for: boolKey)
            #expect(store.value(boolKey) == boolValue, random.comment)

            let letters = (0..<6).map { _ in Character(UnicodeScalar(UInt8(97 + random.int(in: 0...25)))) }
            let stringValue = String(letters)
            store.setValue(stringValue, for: stringKey)
            #expect(store.value(stringKey) == stringValue, random.comment)
        }
    }
}
