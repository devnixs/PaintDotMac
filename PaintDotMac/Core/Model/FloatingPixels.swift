import CoreGraphics
import Foundation

/// The exact pre-session state an Escape cancels back to (spec 0020 item 2). CoW-shared
/// with the layer surface and selection it captured — no pixel copy.
struct FloatingRestorePoint: Sendable, Equatable {
    /// The layer before the session (CoW-shared).
    let layerSurface: TiledSurface
    /// The selection before the session.
    let selection: Selection?
    /// The step that was current before the session's first step.
    let baseStepID: HistoryStep.ID
}

/// Pixels lifted off a layer (or pasted; 0021) that float over it until finished
/// (spec 0020 item 2; Paint.NET `MoveTool`'s `MaskedSurface`, MoveTools.html). Stored in
/// `DocumentState`, so undo/redo restores it exactly (0021 relies on this: one undo
/// cancels a floating paste).
///
/// The live layer always shows `underlay ⊕ resampled source` (`render`); the hole (the
/// lifted region cleared to transparent unless `duplicate`) lives in `underlay`, so any
/// transform re-renders from the pristine inputs — the pixels themselves are never
/// resampled twice. Off-canvas pixels are kept while floating (moving off the canvas and
/// back restores them); finishing drops them.
struct FloatingPixels: Sendable, Equatable {
    /// One floating session (lift or paste); survives every step of the session.
    let id: UUID
    /// The layer the pixels float over and are finished into.
    let layerID: Layer.ID
    /// Canvas rect of `source` at lift time (non-empty).
    let sourceRect: PixelRect
    /// The lifted pixels, straight RGBA8, size = `sourceRect.size`, coverage-weighted.
    /// Never clipped to the canvas.
    let source: TiledSurface
    /// The selection travelling with the pixels (lift-time canvas coordinates);
    /// `nil` only for a paste fully off-canvas.
    let outline: Selection?
    /// The layer beneath the floating pixels — the hole punched, unless duplicated.
    var underlay: TiledSurface
    /// 0019's session, created with `sourceBounds = sourceRect.cgRect`.
    var session: TransformSession
    /// Exact pre-session state, for Escape.
    let restore: FloatingRestorePoint

    /// The lift/paste-time canvas → canvas map (source canvas → current canvas).
    var affine: CGAffineTransform { session.outlineTransform }

    /// D-21: nearest-neighbor for integer translations/scales, bilinear otherwise.
    var resamplingMode: ResamplingMode { Resampler.mode(for: affine) }

    /// The canvas region the floating pixels can paint.
    var destinationBounds: PixelRect {
        Resampler.destinationBounds(sourceRect: sourceRect, transform: affine,
                                    mode: resamplingMode)
            .intersection(underlay.size.bounds)
    }

    /// `Tile.byteCount × source.allocatedTileCount` — the lift step's pixel cost.
    var byteCount: Int { Tile.byteCount * source.allocatedTileCount }

    /// The outline carried to the canvas coordinates of the current session (0019's
    /// `Selection.transformed` — exact mask shift on the integer-translation path).
    @MainActor
    func transformedSelection(antialiased: Bool) -> Selection? {
        outline.map { Selection.transformed($0, by: session, antialiased: antialiased) } ?? nil
    }

    /// Lifts the selected pixels of the active layer (Paint.NET `MoveTool.OnMouseDown`:
    /// the selection becomes a `MaskedSurface` and, unless Ctrl is held, the layer's
    /// selected region is cleared to transparent).
    ///
    /// Per pixel of `sourceRect` with coverage `cov = mask(x, y)`: the source pixel is
    /// the layer pixel with `alpha' = mul255(alpha, cov)`; the hole pixel is the layer
    /// pixel with `alpha' = mul255(alpha, 255 − cov)`; `alpha' == 0` → `(0,0,0,0)` in
    /// both (D-27). Outside `sourceRect` the underlay shares the layer's tiles; with
    /// `duplicate` the whole underlay *is* the unchanged layer.
    ///
    /// `nil` when `state.selection == nil` or the active layer index is invalid — the
    /// tool Selects All first (item 6), and 0025 keeps the layer index valid.
    static func lift(from state: DocumentState, duplicate: Bool,
                     baseStepID: HistoryStep.ID) -> FloatingPixels? {
        guard let selection = state.selection,
              state.image.layers.indices.contains(state.image.activeLayerIndex) else { return nil }
        let layer = state.image.layers[state.image.activeLayerIndex]
        let sourceRect = selection.bounds
        guard !sourceRect.isEmpty else { return nil }
        // Non-empty integer rect with positive width/height — `TransformSession.init`
        // only rejects empty/non-finite rects, so this is an invariant, not a user path.
        guard let session = TransformSession(sourceBounds: sourceRect.cgRect) else { return nil }

        let width = sourceRect.width
        let height = sourceRect.height
        let layerPixels = layer.surface.readPixels(in: sourceRect)
        let mask = selection.mask
        var sourceBytes = [UInt8](repeating: 0, count: width * height * 4)
        var holeBytes: [UInt8]? = duplicate ? nil : [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            let alpha = layerPixels[offset + 3]
            guard alpha != 0 else { continue }
            let coverage = Int(mask.coverage(x: sourceRect.minX + index % width,
                                             y: sourceRect.minY + index / width))
            if coverage != 0 {
                let lifted = BlendOps.mul255(alpha, UInt8(coverage))
                if lifted != 0 {
                    sourceBytes[offset] = layerPixels[offset]
                    sourceBytes[offset + 1] = layerPixels[offset + 1]
                    sourceBytes[offset + 2] = layerPixels[offset + 2]
                    sourceBytes[offset + 3] = lifted
                }
            }
            if holeBytes != nil {  // hole pass (only when !duplicate)
                let kept = BlendOps.mul255(alpha, UInt8(255 - coverage))
                if kept != 0 {  // alpha' == 0 stays (0,0,0,0) — D-27
                    holeBytes?[offset] = layerPixels[offset]
                    holeBytes?[offset + 1] = layerPixels[offset + 1]
                    holeBytes?[offset + 2] = layerPixels[offset + 2]
                    holeBytes?[offset + 3] = kept
                }
            }
        }
        var source = TiledSurface(size: sourceRect.size)
        source.writePixels(sourceBytes, to: PixelRect(origin: .zero, size: sourceRect.size))
        var underlay = layer.surface
        if let holeBytes {
            underlay.writePixels(holeBytes, to: sourceRect)
        }
        return FloatingPixels(
            id: UUID(),
            layerID: layer.id,
            sourceRect: sourceRect,
            source: source,
            outline: state.selection,
            underlay: underlay,
            session: session,
            restore: FloatingRestorePoint(layerSurface: layer.surface,
                                          selection: state.selection,
                                          baseStepID: baseStepID))
    }

    /// 0021's Paste: the clipboard surface floats at `origin` (the paste factory and the
    /// "Paste" step's inputs; 0021's `PasteStep` records the step and relies on item 10's
    /// policy to activate this tool). `sourceRect` may extend past the canvas; the
    /// outline is clipped and `nil` when nothing remains.
    static func paste(_ surface: TiledSurface, at origin: PixelPoint, into state: DocumentState,
                      baseStepID: HistoryStep.ID) -> FloatingPixels {
        let sourceRect = PixelRect(origin: origin, size: surface.size)
        let layer = state.image.layers[state.image.activeLayerIndex]
        // Guaranteed: surfaces are ≥ 1×1 (APP-10), so `sourceRect` is non-empty — the
        // same invariant `lift` comments (`!` for a guaranteed-initialized case).
        let session = TransformSession(sourceBounds: sourceRect.cgRect)!
        return FloatingPixels(
            id: UUID(),
            layerID: layer.id,
            sourceRect: sourceRect,
            source: surface,
            outline: Selection(rect: sourceRect.cgRect, canvasSize: state.image.size),
            underlay: layer.surface,
            session: session,
            restore: FloatingRestorePoint(layerSurface: layer.surface,
                                          selection: state.selection,
                                          baseStepID: baseStepID))
    }

    /// Writes `underlay ⊕ resampled source` over `region ∩ canvas` of `surface` (the
    /// live layer) — one `resample` + one blend + one `writePixels` per call, so
    /// untouched tiles keep their storage and generation. Pixels outside
    /// `destinationBounds` resample to transparent, and the normal blend returns the
    /// underlay bit-for-bit there.
    func render(into surface: inout TiledSurface, region: PixelRect) {
        let area = region.intersection(surface.bounds)
        guard !area.isEmpty else { return }
        let src = Resampler.resample(source, sourceOrigin: sourceRect.origin,
                                     transform: affine, mode: resamplingMode,
                                     destination: area)
        let dst = underlay.readPixels(in: area)
        // Blend in 256-row bands on `DispatchQueue.concurrentPerform`; each task fills
        // its own box and the boxes merge serially after the barrier (0013's unchecked-
        // box pattern, NF-1).
        let bandRows = 256
        let bandCount = (area.height + bandRows - 1) / bandRows
        let rowBytes = area.width * 4
        let boxes = (0..<bandCount).map { _ in BlendBandBox() }
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            let firstRow = band * bandRows
            let lastRow = min(area.height, firstRow + bandRows)
            var bandBytes = [UInt8](repeating: 0, count: (lastRow - firstRow) * rowBytes)
            for row in firstRow..<lastRow {
                let base = row * rowBytes
                var rowOffset = (row - firstRow) * rowBytes
                for column in 0..<area.width {
                    let offset = base + column * 4
                    let source = ColorRGBA8(red: src[offset], green: src[offset + 1],
                                            blue: src[offset + 2], alpha: src[offset + 3])
                    let blended: ColorRGBA8
                    if source.alpha == 0 {
                        // The normal blend returns the destination bit-for-bit here —
                        // also where `src` is just the untouched underlay.
                        blended = ColorRGBA8(red: dst[offset], green: dst[offset + 1],
                                             blue: dst[offset + 2], alpha: dst[offset + 3])
                    } else {
                        let under = ColorRGBA8(red: dst[offset], green: dst[offset + 1],
                                               blue: dst[offset + 2], alpha: dst[offset + 3])
                        blended = BlendOps.blend(.normal, dst: under, src: source, opacity: 255)
                    }
                    bandBytes[rowOffset] = blended.red
                    bandBytes[rowOffset + 1] = blended.green
                    bandBytes[rowOffset + 2] = blended.blue
                    bandBytes[rowOffset + 3] = blended.alpha
                    rowOffset += 4
                }
            }
            boxes[band].bytes = bandBytes
        }
        var out = [UInt8](repeating: 0, count: area.width * area.height * 4)
        for (band, box) in boxes.enumerated() {
            guard !box.bytes.isEmpty else { continue }
            let start = band * bandRows * rowBytes
            out.replaceSubrange(start..<(start + box.bytes.count), with: box.bytes)
        }
        surface.writePixels(out, to: area)
    }

    /// One mutable band buffer for the parallel blend (see `SelectionMaskTileBox`).
    private final class BlendBandBox: @unchecked Sendable {
        var bytes: [UInt8] = []
    }

    /// The same session with `surface` punched in as the underlay — ⌘-drag "stamp a
    /// copy": the current rendering stays behind while the pixels move on (Paint.NET
    /// "move or rotate a copy").
    func withUnderlay(_ surface: TiledSurface) -> FloatingPixels {
        var result = self
        result.underlay = surface
        return result
    }
}
