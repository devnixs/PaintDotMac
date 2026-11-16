import CoreGraphics
import Foundation

/// The pure display decisions for the animated "marching ants" selection outline
/// (spec 0013; PRD CAN-7, NF-7). The AppKit side (`Canvas/MarchingAntsOverlay.swift`)
/// renders these; the mode table and the dash geometry are decided here so tests can pin
/// them without a window.
enum MarchingAnts {
    /// Points; a black dashed line over a solid white line (Paint.NET's outline).
    static let lineWidth: CGFloat = 1
    /// Points; black dashes over the white underline.
    static let dashPattern: [CGFloat] = [4, 4]
    /// The dash-cycle length — one full phase of the `lineDashPhase` animation.
    static let phasePeriod: CGFloat = 8   // = sum of the dash pattern
    /// One phase period per 0.5 s (render-server driven, no per-frame main-thread work).
    static let animationDuration: TimeInterval = 0.5

    enum Mode: String, Sendable {
        case hidden
        case animated
        case `static`
    }

    /// No selection → `.hidden`; Reduce Motion → `.static` (NF-7); else `.animated`.
    static func mode(hasSelection: Bool, reduceMotion: Bool) -> Mode {
        guard hasSelection else { return .hidden }
        return reduceMotion ? .static : .animated
    }

    /// The selection outline in view space, transformed by `canvasToViewAffine` — the
    /// only Y-flip on the overlay path (CAN-6).
    static func viewPath(for selection: Selection, transform: CanvasTransform) -> CGPath {
        var affine = transform.canvasToViewAffine
        return selection.path.copy(using: &affine) ?? CGPath(rect: .zero, transform: nil)
    }
}
