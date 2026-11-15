import Foundation

/// Why a size was refused (APP-10).
enum ImageLimitError: Error, Equatable, Sendable {
    /// A side < 1 or > 65,535.
    case dimensionsOutOfRange(width: Int, height: Int)
    /// `width × height × bytesPerPixel` overflows `Int`.
    case byteCountOverflow(width: Int, height: Int)
    /// The byte count exceeds the injectable memory cap.
    case exceedsMemoryCap(requiredBytes: Int, capBytes: Int)
}

/// Image size limits (APP-10, D-8, D-32). `validate` runs on header values before any pixel
/// memory is allocated; specs 0005, 0021, and 0035/0036 call the same method.
struct ImageLimits: Equatable, Sendable {
    static let minimumSide = 1
    /// Paint.NET's limit (APP-10).
    static let maximumSide = 65_535

    /// Injectable; compared with `width × height × bytesPerPixel`.
    var memoryCapBytes: Int

    init(memoryCapBytes: Int) {
        self.memoryCapBytes = memoryCapBytes
    }

    /// The limits the app uses (PRD APP-10, D-32).
    static var standard: ImageLimits {
        ImageLimits(memoryCapBytes: defaultMemoryCap(physicalMemory: ProcessInfo.processInfo.physicalMemory))
    }

    /// Physical memory / 4 (D-32). Decoding briefly holds about three copies of the pixels
    /// (ImageIO's cache, the vImage buffer, the tiles), so a quarter of RAM keeps the peak
    /// below physical memory. Clamped to `Int.max`.
    static func defaultMemoryCap(physicalMemory: UInt64) -> Int {
        // Absurd inputs (bigger than `Int.max`) saturate to the largest usable cap.
        guard physicalMemory <= UInt64(Int.max) else { return Int.max }
        return Int(physicalMemory / 4)
    }

    /// `width × height × bytesPerPixel` with overflow checks; `nil` when it overflows or any
    /// factor is negative.
    static func byteCount(width: Int, height: Int, bytesPerPixel: Int) -> Int? {
        guard width >= 0, height >= 0, bytesPerPixel > 0 else { return nil }
        let area = width.multipliedReportingOverflow(by: height)
        guard !area.overflow else { return nil }
        let bytes = area.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        guard !bytes.overflow else { return nil }
        return bytes.partialValue
    }

    /// Checks dimensions, then overflow, then the cap (equal to the cap is allowed), throwing
    /// the first failure; returns the byte count. Never traps on any `Int` input.
    @discardableResult
    func validate(width: Int, height: Int, format: PixelFormat = .rgba8) throws(ImageLimitError) -> Int {
        guard (Self.minimumSide...Self.maximumSide).contains(width),
              (Self.minimumSide...Self.maximumSide).contains(height)
        else {
            throw .dimensionsOutOfRange(width: width, height: height)
        }
        guard let bytes = Self.byteCount(width: width, height: height, bytesPerPixel: format.bytesPerPixel)
        else {
            throw .byteCountOverflow(width: width, height: height)
        }
        guard bytes <= memoryCapBytes else {
            throw .exceedsMemoryCap(requiredBytes: bytes, capBytes: memoryCapBytes)
        }
        return bytes
    }
}
