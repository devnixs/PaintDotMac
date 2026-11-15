import Testing

@testable import PaintDotMac

struct ImageLimitsTests {
    @Test func acceptsBoundaries() throws {
        let limits = ImageLimits(memoryCapBytes: .max)
        #expect(try limits.validate(width: 1, height: 1) == 4)
        #expect(try limits.validate(width: 65_535, height: 1) == 262_140)
        #expect(try limits.validate(width: 65_535, height: 65_535) == 17_179_344_900)
    }

    @Test func rejectsOutOfRangeSides() {
        let limits = ImageLimits(memoryCapBytes: .max)
        for (width, height) in [(0, 10), (10, 0), (-1, 10), (65_536, 1), (1, 65_536), (Int.min, 1)] {
            #expect(throws: ImageLimitError.dimensionsOutOfRange(width: width, height: height)) {
                try limits.validate(width: width, height: height)
            }
        }
    }

    @Test func byteCountOverflow() {
        #expect(ImageLimits.byteCount(width: Int.max, height: 2, bytesPerPixel: 4) == nil)
        #expect(ImageLimits.byteCount(width: 2, height: Int.max / 2 + 1, bytesPerPixel: 1) == nil)
        #expect(ImageLimits.byteCount(width: -1, height: 1, bytesPerPixel: 4) == nil)
        #expect(ImageLimits.byteCount(width: 3, height: 5, bytesPerPixel: 4) == 60)
    }

    @Test func validateNeverTrapsOnExtremeInputs() {
        let limits = ImageLimits(memoryCapBytes: 0)
        #expect(throws: (any Error).self) { try limits.validate(width: Int.min, height: Int.min) }
        #expect(throws: (any Error).self) { try limits.validate(width: Int.max, height: Int.max) }
    }

    @Test func memoryCapIsInclusive() throws {
        let atCap = ImageLimits(memoryCapBytes: 1_024)
        #expect(try atCap.validate(width: 16, height: 16) == 1_024)
        #expect(throws: ImageLimitError.exceedsMemoryCap(requiredBytes: 1_088, capBytes: 1_024)) {
            try atCap.validate(width: 16, height: 17)
        }
        let belowCap = ImageLimits(memoryCapBytes: 1_023)
        #expect(throws: ImageLimitError.exceedsMemoryCap(requiredBytes: 1_024, capBytes: 1_023)) {
            try belowCap.validate(width: 16, height: 16)
        }
    }

    @Test func checkOrder() {
        // Range is checked before the cap.
        let limits = ImageLimits(memoryCapBytes: 0)
        #expect(throws: ImageLimitError.dimensionsOutOfRange(width: 70_000, height: 1)) {
            try limits.validate(width: 70_000, height: 1)
        }
    }

    @Test func defaultCap() {
        #expect(ImageLimits.defaultMemoryCap(physicalMemory: 16 << 30) == 4 << 30)
        #expect(ImageLimits.defaultMemoryCap(physicalMemory: UInt64.max) == Int.max)
        #expect(ImageLimits.standard.memoryCapBytes > 0)
        #expect(ImageLimits.minimumSide == 1)
        #expect(ImageLimits.maximumSide == 65_535)
    }
}
