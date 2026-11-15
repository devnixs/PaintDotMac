import Foundation

/// The canvas display-filter decision (spec 0003, CAN-3): nearest neighbor at or above 100 %,
/// mipmapped area downsampling below.
enum CanvasSampling: Equatable, Sendable {
    /// `zoom ≥ 1`: one device pixel samples exactly one texel (hard-edged image pixels).
    case nearest
    /// `zoom < 1`: area-weighted average taken from mip `level`.
    case areaAverage(level: Int)

    /// `floor(log2(1 / minimumZoom))` = `floor(log2(100))` = 6; a tile is 4×4 texels there.
    static let maximumLevel = 6

    /// The filter for a zoom. Powers of two land on the exact level (0.5 → 1, 0.25 → 2) —
    /// `level` is the largest `k ≤ maximumLevel` with `zoom · 2^k ≤ 1 + 1e-12`, so binary
    /// floating-point error cannot push an exact power onto the wrong level.
    static func forZoom(_ zoom: Double) -> CanvasSampling {
        guard zoom.isFinite, zoom < 1 else { return .nearest }
        var level = 0
        while level < maximumLevel, zoom * exp2(Double(level + 1)) <= 1 + 1e-12 {
            level += 1
        }
        return .areaAverage(level: level)
    }

    /// 0 for `.nearest`; the mip level for `.areaAverage`.
    var level: Int {
        switch self {
        case .nearest: 0
        case .areaAverage(let level): level
        }
    }
}
