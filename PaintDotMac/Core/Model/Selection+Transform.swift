import CoreGraphics
import Foundation

// Selection transforms (spec 0019): apply a committed `TransformSession` to a selection.
// Pixels are never touched — this rebuilds both halves of `Selection` (the vector path
// and its mask) from the session's rigid frame transform.
extension Selection {
    /// The selection after `session`'s rigid frame transform, or `nil` when the result
    /// is empty or fully off-canvas.
    ///
    /// - An **integer translation** (`session.integerTranslation`) shifts the mask
    ///   pixel-exactly (`SelectionMask.translated(dx:dy:)`) — the Magic Wand's dithered
    ///   masks survive repeated nudges — and translates the path.
    /// - Anything else re-rasterizes the source outline transformed by
    ///   `session.outlineTransform` through `init(path:canvasSize:antialiased:)` — the
    ///   same boolean-clipped rasterization the Rectangle Select uses — so off-canvas
    ///   parts of the source are dropped (0013) and the result is always valid.
    ///
    /// The session holds the selection that was active at gesture start, so a shape
    /// dragged off-canvas and back inside one session returns in full.
    @MainActor
    static func transformed(_ selection: Selection, by session: TransformSession,
                            antialiased: Bool) -> Selection? {
        if let (dx, dy) = session.integerTranslation {
            let path = selection.path.copying(using: session.outlineTransform)
                ?? CGPath(rect: .zero, transform: nil)
            return Selection(mask: selection.mask.translated(dx: dx, dy: dy),
                             outline: path)
        }
        let outline = selection.path.copying(using: session.outlineTransform)
            ?? CGPath(rect: .zero, transform: nil)
        return Selection(path: outline, canvasSize: selection.canvasSize,
                         antialiased: antialiased)
    }
}
