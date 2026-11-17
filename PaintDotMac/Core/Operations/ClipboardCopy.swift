import Foundation

/// Edit > Copy / Cut pixel logic (spec 0021; PRD E-2; Paint.NET EditMenu.html). The write
/// side of the clipboard, kept apart from `PastePlanner`'s read side. Pure — the platform
/// glue owns the pasteboard itself.
enum ClipboardCopy {
    /// Copy (E-2): the pixels to put on the clipboard.
    ///
    /// - selection == nil → the whole active layer (`size == image.size`), pixels
    ///   unchanged (including the color under alpha 0).
    /// - selection != nil → a surface of `selection.bounds.size`; per pixel p in bounds
    ///   with coverage `c = mask.coverage(p)` and active-layer pixel s:
    ///   `c == 0` → `(0,0,0,0)`; otherwise `(s.r, s.g, s.b, mul255(s.a, c))` — the color
    ///   is kept even when the scaled alpha lands on 0 (FMT-B). Output (0, 0) corresponds
    ///   to canvas (bounds.x, bounds.y).
    ///
    /// Copy is never a history step and never changes the document (state is read-only).
    static func copiedSurface(from state: DocumentState) -> TiledSurface {
        let layer = state.image.layers[state.image.activeLayerIndex]
        guard let selection = state.selection else { return layer.surface }
        let bounds = selection.bounds
        let source = layer.surface.readPixels(in: bounds)
        let mask = selection.mask
        let width = bounds.width
        let height = bounds.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let canvasY = bounds.minY + row
            let rowBase = row * width * 4
            for column in 0..<width {
                let coverage = mask.coverage(x: bounds.minX + column, y: canvasY)
                guard coverage != 0 else { continue }  // (0,0,0,0) — the untouched zeros
                let offset = rowBase + column * 4
                bytes[offset] = source[offset]
                bytes[offset + 1] = source[offset + 1]
                bytes[offset + 2] = source[offset + 2]
                bytes[offset + 3] = BlendOps.mul255(source[offset + 3], coverage)
            }
        }
        var surface = TiledSurface(size: bounds.size)
        surface.writePixels(bytes, to: PixelRect(origin: .zero, size: bounds.size))
        return surface
    }

    /// Cut (E-2): "remove a selected portion of the active layer AND store a copy of it
    /// in the clipboard"; the selection is cleared afterwards. Enabled iff
    /// `state.selection != nil` — returns `nil` otherwise.
    ///
    /// One "Cut" step: 0018's `EraseSelection.erase(_:mask:)` diff on the active layer
    /// plus the deselect, so one undo restores pixels and selection. Erasing an already
    /// transparent region still records the step — the selection changes, so it is never
    /// a no-op while a selection exists. The erase math is 0018's, not reimplemented;
    /// 0018's `makeHistoryItem` is not reused because its step is named "Erase Selection".
    static func cut(_ state: DocumentState) -> (surface: TiledSurface, item: any HistoryItem)? {
        guard let selection = state.selection,
              state.image.layers.indices.contains(state.image.activeLayerIndex) else { return nil }
        let layer = state.image.layers[state.image.activeLayerIndex]
        let surface = copiedSurface(from: state)
        let erased = EraseSelection.erase(layer.surface, mask: selection.mask)
        let item = CompositeHistoryItem(name: "Cut", icon: .cut, items: [
            TileDiffHistoryItem(name: "Cut", icon: .cut, diff: TileDiff.between(
                before: layer.surface, after: erased.surface,
                layerID: layer.id, candidates: erased.touched)),
            SelectionHistoryItem(name: "Cut", icon: .cut, before: selection, after: nil),
        ])
        return (surface, item)
    }
}
