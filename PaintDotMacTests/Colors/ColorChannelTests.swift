import Testing

@testable import PaintDotMac

/// Channel ranges and names (C-2: H 0–360, S/V 0–100, R/G/B/Alpha 0–255).
struct ColorChannelTests {
    @Test func ranges() {
        #expect(ColorChannel.red.range == 0...255)
        #expect(ColorChannel.green.range == 0...255)
        #expect(ColorChannel.blue.range == 0...255)
        #expect(ColorChannel.alpha.range == 0...255)
        #expect(ColorChannel.hue.range == 0...360)
        #expect(ColorChannel.saturation.range == 0...100)
        #expect(ColorChannel.value.range == 0...100)
    }

    @Test func labels() {
        #expect(ColorChannel.red.label == "Red")
        #expect(ColorChannel.green.label == "Green")
        #expect(ColorChannel.blue.label == "Blue")
        #expect(ColorChannel.hue.label == "Hue")
        #expect(ColorChannel.saturation.label == "Saturation")
        #expect(ColorChannel.value.label == "Value")
        #expect(ColorChannel.alpha.label == "Alpha")
    }

    @Test func allCasesAreListedOnce() {
        #expect(ColorChannel.allCases.count == 7)
        #expect(Set(ColorChannel.allCases.map(\.rawValue)).count == 7)
    }
}
