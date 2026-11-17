import CoreGraphics
import Foundation

/// The E-6 prompt's answer (spec 0021). A `nil` choice means "no prompt was needed" and
/// behaves like `.keepCanvasSize`.
enum PasteCanvasChoice: Sendable {
    case expandCanvas
    case keepCanvasSize
}

/// Where the pasted pixels land, and what the canvas becomes (spec 0021 item 3).
struct PastePlan: Equatable, Sendable {
    /// nil = canvas unchanged.
    var newCanvasSize: PixelSize?
    /// Top-left of the pasted pixels in (new) canvas coordinates.
    var origin: PixelPoint
    var pastedRect: PixelRect
}

/// Paste placement and the E-6 expand decision (spec 0021; PRD E-6; Paint.NET
/// EditMenu.html "Paste": zoomed in, "the pixels will be placed within the current
/// viewport, regardless of where it originally came from").
enum PastePlanner {
    /// E-6: true iff clipboard width > canvas width or clipboard height > canvas height
    /// (strict `>` — a clipboard image exactly the canvas size never prompts).
    static func needsExpansionPrompt(clipboardSize: PixelSize, canvasSize: PixelSize) -> Bool {
        clipboardSize.width > canvasSize.width || clipboardSize.height > canvasSize.height
    }

    /// Placement (Paint.NET "placed within the current viewport"):
    /// - choice == `.expandCanvas` (only meaningful when `needsExpansionPrompt`):
    ///   newCanvasSize = (max(cw, iw), max(ch, ih)) anchored top-left; origin (0, 0).
    /// - otherwise: origin (0, 0) when the canvas point (0, 0) lies inside
    ///   `visibleCanvasRect` (closed on the top-left edges — the usual state, including a
    ///   canvas smaller than the view, whose visible rect has a negative min); else the
    ///   floor of the visible top-left, clamped into `0…side − 1` so the origin is always
    ///   a canvas pixel. The pasted rect may still extend beyond the canvas;
    ///   `Selection(rect:canvasSize:)` clips its outline.
    ///
    /// `visibleCanvasRect` is 0004's `CanvasTransform.visibleCanvasRect` (canvas
    /// coordinates, y down).
    static func plan(clipboardSize: PixelSize, canvasSize: PixelSize,
                     visibleCanvasRect: CGRect, choice: PasteCanvasChoice?) -> PastePlan {
        if choice == .expandCanvas {
            let newSize = PixelSize(width: max(canvasSize.width, clipboardSize.width),
                                    height: max(canvasSize.height, clipboardSize.height))
            return PastePlan(newCanvasSize: newSize, origin: .zero,
                             pastedRect: PixelRect(origin: .zero, size: clipboardSize))
        }
        let origin = PixelPoint(
            x: visibleCanvasRect.minX <= 0 ? 0
                : clampedOrigin(floor(visibleCanvasRect.minX), limit: canvasSize.width),
            y: visibleCanvasRect.minY <= 0 ? 0
                : clampedOrigin(floor(visibleCanvasRect.minY), limit: canvasSize.height)
        )
        return PastePlan(newCanvasSize: nil, origin: origin,
                         pastedRect: PixelRect(origin: origin, size: clipboardSize))
    }

    /// E-6 expansion as a document snapshot (anchor top-left): every layer grows to
    /// `newSize` with its existing pixels at the same coordinates; the new area of the
    /// bottom layer (index 0) is `background` (the secondary color — Paint.NET's Resize
    /// Canvas convention), every other layer's new area stays transparent (0,0,0,0).
    /// Layer ids, names, visibility, opacity, blend mode, dpi, and activeLayerIndex are
    /// kept; the selection is nil in the after-state (the paste replaces it anyway).
    /// 0036 (Resize Canvas) may re-express this through its `ResizeCanvas` — the behavior
    /// must stay the same.
    ///
    /// `limits` validates `newSize` (APP-10 / D-8): an expansion beyond them throws
    /// before any pixel is touched.
    static func expandedState(_ state: DocumentState, to newSize: PixelSize,
                              background: ColorRGBA8,
                              limits: ImageLimits) throws(ImageLimitError) -> DocumentState {
        try limits.validate(width: newSize.width, height: newSize.height)
        let layers = state.image.layers.enumerated().map { index, layer -> Layer in
            var surface = TiledSurface(size: newSize)
            // Bottom layer only: the new area carries the background color; the old
            // canvas area below keeps the layer's own pixels (transparent stays
            // transparent). `writePixels` writes over the fill inside the old bounds and
            // leaves unallocated zero tiles unallocated.
            if index == 0 { surface.fill(background) }
            surface.writePixels(layer.surface.readPixels(in: layer.surface.bounds),
                                to: layer.surface.bounds)
            return Layer(id: layer.id, name: layer.name, surface: surface,
                         isVisible: layer.isVisible, opacity: layer.opacity,
                         blendMode: layer.blendMode)
        }
        let image = LayeredImage(size: newSize, dpi: state.image.dpi, layers: layers,
                                 activeLayerIndex: state.image.activeLayerIndex)
        return DocumentState(image: image, selection: nil, floatingPixels: nil)
    }

    /// floor(x) clamped into `0…limit − 1`; a non-finite or negative coordinate past the
    /// `<= 0` branch cannot occur, but the clamp keeps a corrupt transform in-canvas.
    private static func clampedOrigin(_ value: Double, limit: Int) -> Int {
        guard value.isFinite else { return limit - 1 }
        return min(max(Int(value), 0), limit - 1)
    }
}
