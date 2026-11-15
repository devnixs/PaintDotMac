import Testing
@testable import PaintDotMac

/// All expected values hand-computed from spec 0004 (2.54 cm per inch; two decimals, half
/// away from zero; "." separator; invalid DPI → 96).
@Suite(.serialized)
struct MeasurementUnitTests {
    @Test func rawValuesAndNames() {
        #expect(MeasurementUnit.pixels.rawValue == "px")
        #expect(MeasurementUnit.inches.rawValue == "in")
        #expect(MeasurementUnit.centimeters.rawValue == "cm")
        #expect(MeasurementUnit.pixels.displayName == "Pixels")
        #expect(MeasurementUnit.inches.displayName == "Inches")
        #expect(MeasurementUnit.centimeters.displayName == "Centimeters")
        #expect(MeasurementUnit.allCases == [.pixels, .inches, .centimeters])
    }

    @Test func pixelsFormat() {
        #expect(MeasurementUnit.pixels.format(pixels: 800, dpi: 96) == "800")
        #expect(MeasurementUnit.pixels.format(pixels: -3, dpi: 96) == "-3")
        #expect(MeasurementUnit.pixels.format(pixels: 0, dpi: 96) == "0")
    }

    @Test func inchesFormat() {
        let inches = MeasurementUnit.inches
        // 800/96 = 8.3333… → 8.33; 600/96 = 6.25; 600/300 = 2; −1/96 = −0.0104… → −0.01.
        #expect(inches.format(pixels: 800, dpi: 96) == "8.33")
        #expect(inches.format(pixels: 600, dpi: 96) == "6.25")
        #expect(inches.format(pixels: 600, dpi: 300) == "2.00")
        #expect(inches.format(pixels: -1, dpi: 96) == "-0.01")
        #expect(inches.format(pixels: 0, dpi: 96) == "0.00")
    }

    @Test func centimetersFormat() {
        // 800/96·2.54 = 21.1666… → 21.17; 2000/96·2.54 = 52.9166… → 52.92;
        // 300/300·2.54 = 2.54.
        #expect(MeasurementUnit.centimeters.format(pixels: 800, dpi: 96) == "21.17")
        #expect(MeasurementUnit.centimeters.format(pixels: 2000, dpi: 96) == "52.92")
        #expect(MeasurementUnit.centimeters.format(pixels: 300, dpi: 300) == "2.54")
    }

    @Test func roundsHalfAwayFromZero() {
        // 600/96·2.54 = 15.875 exactly → 15.88; −12/96 = −0.125 exactly → −0.13.
        #expect(MeasurementUnit.centimeters.format(pixels: 600, dpi: 96) == "15.88")
        #expect(MeasurementUnit.inches.format(pixels: -12, dpi: 96) == "-0.13")
    }

    @Test func negativeZeroPrintsZero() {
        // A tiny negative value whose rounded centesimal is −0 must print "0.00":
        // −1 / 100000 in = −0.00001 in → ·100 = −0.001 → rounds to −0.
        #expect(MeasurementUnit.inches.format(pixels: 0, dpi: 96) == "0.00")
        #expect(MeasurementUnit.inches.format(pixels: -1, dpi: 100_000) == "0.00")
    }

    @Test func formatPointAndSize() {
        #expect(MeasurementUnit.pixels.formatPoint(PixelPoint(x: 12, y: -5), dpi: 96) == "12, -5")
        #expect(MeasurementUnit.pixels.formatSize(PixelSize(width: 800, height: 600), dpi: 96)
                == "800 × 600")
        #expect(MeasurementUnit.inches.formatSize(PixelSize(width: 800, height: 600), dpi: 96)
                == "8.33 × 6.25")
    }

    @Test func invalidDPIFallsBackTo96() {
        #expect(MeasurementUnit.sanitizedDPI(0) == 96)
        #expect(MeasurementUnit.sanitizedDPI(-72) == 96)
        #expect(MeasurementUnit.sanitizedDPI(.nan) == 96)
        #expect(MeasurementUnit.sanitizedDPI(300) == 300)
        #expect(MeasurementUnit.inches.format(pixels: 96, dpi: 0) == "1.00")
    }

    @Test func decimalSeparatorIsLocaleIndependent() {
        // The strings must never contain "," (the app is English-only; "," separates the
        // cursor coordinates). Equality with the expected hand values already proves it.
        let inches = MeasurementUnit.inches.format(pixels: 800, dpi: 96)
        let centimeters = MeasurementUnit.centimeters.format(pixels: 800, dpi: 96)
        #expect(inches == "8.33" && !inches.contains(","))
        #expect(centimeters == "21.17" && !centimeters.contains(","))
    }
}
