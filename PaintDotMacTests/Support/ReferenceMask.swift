import Foundation
import Testing

@testable import PaintDotMac

/// The independent per-pixel `[UInt8]` reference mask (spec 0013 *Test plan*): the oracle
/// for `SelectionMask`. Values come from the test's own coverage function or grid, never
/// from `SelectionMask`, so the mask algebra is checked against the normative table.
struct ReferenceMask: Equatable {
    let size: PixelSize
    let bytes: [UInt8]   // row-major width × height

    init(size: PixelSize, coverage: (_ x: Int, _ y: Int) -> UInt8) {
        self.size = size
        var bytes = [UInt8](repeating: 0, count: max(0, size.width) * max(0, size.height))
        for y in 0..<size.height {
            for x in 0..<size.width { bytes[y * size.width + x] = coverage(x, y) }
        }
        self.bytes = bytes
    }

    func coverage(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < size.width, y < size.height else { return 0 }
        return bytes[y * size.width + x]
    }

    /// The normative per-pixel table, computed inline (the same formulas the spec lists —
    /// deliberately re-derived here, not called from `SelectionCombineMode.combine`).
    func combined(with other: ReferenceMask, mode: SelectionCombineMode) -> ReferenceMask {
        precondition(other.size == size)
        return ReferenceMask(size: size) { x, y in
            let a = coverage(x, y)
            let b = other.coverage(x, y)
            switch mode {
            case .replace: return b
            case .union: return Swift.max(a, b)
            case .exclude: return a &- Swift.min(a, b)
            case .intersect: return Swift.min(a, b)
            case .xor: return Swift.max(a, b) &- Swift.min(a, b)
            }
        }
    }

    func inverted() -> ReferenceMask {
        ReferenceMask(size: size) { x, y in 255 &- coverage(x, y) }
    }

    var isEmpty: Bool { bytes.allSatisfy { $0 == 0 } }

    /// Pointwise equality of two implementations against this oracle.
    func matches(_ mask: SelectionMask, comment: Comment) {
        guard mask.size == size else {
            Issue.record("size mismatch \(mask.size) vs \(size): \(comment)")
            return
        }
        var firstMismatch: String?
        for y in 0..<size.height {
            for x in 0..<size.width where mask.coverage(x: x, y: y) != coverage(x, y) {
                firstMismatch = "(\(x), \(y)): \(mask.coverage(x: x, y: y)) != \(coverage(x, y))"
                break
            }
            if firstMismatch != nil { break }
        }
        if let firstMismatch {
            Issue.record("coverage mismatch at \(firstMismatch): \(comment)")
        }
    }
}
