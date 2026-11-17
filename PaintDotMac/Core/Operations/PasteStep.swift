import Foundation

/// The "Paste" history step, built only from 0020's floating-pixels model (spec 0021
/// item 4) — no parallel paste state. One step carries, in order: the optional canvas
/// expansion snapshot, the rendered pixels, the selection, and the floating session.
/// Undo reverts them in reverse order (floating state, selection, pixels, then the
/// canvas size); redo re-applies.
enum PasteStep {
    /// Step name (Paint.NET's History spelling).
    static let name = "Paste"

    /// - `state`: the document before the paste — no floating pixels: the caller ran
    ///   `prepareForNavigation` first, which recorded "Finish Pixels" (0020 item 9).
    /// - `expanded`: `PastePlanner.expandedState(...)` when the user chose Expand, else
    ///   nil. `s0 = expanded ?? state` is the state the paste lands on.
    /// - `baseStepID`: the history's current step ID before the paste — Escape's exact
    ///   cancel target (0020), the step before "Paste".
    ///
    /// `FloatingPixels.paste` keeps the active layer unchanged as `underlay` while
    /// `render` paints the pasted pixels onto the live layer (0020's model — moving the
    /// pasted pixels reveals the original pixels, never a hole). Because the composite
    /// contains `FloatingPixelsHistoryItem(before: nil, after: floating)`, 0020's
    /// `stepStartsSession` recognizes this step as the start of the floating session,
    /// and `FloatingPixelsPolicy` activates Move Selected Pixels after the step.
    static func makeHistoryItem(surface: TiledSurface, plan: PastePlan, state: DocumentState,
                                expanded: DocumentState?,
                                baseStepID: HistoryStep.ID) -> CompositeHistoryItem {
        let s0 = expanded ?? state
        let floating = FloatingPixels.paste(surface, at: plan.origin, into: s0,
                                            baseStepID: baseStepID)
        let layer = s0.image.layers[s0.image.activeLayerIndex]
        var rendered = layer.surface
        floating.render(into: &rendered, region: floating.destinationBounds)
        var items: [any HistoryItem] = []
        if let expanded {
            items.append(DocumentSnapshotHistoryItem(name: name, icon: .paste,
                                                     before: state, after: expanded))
        }
        items.append(TileDiffHistoryItem(name: name, icon: .paste, diff: TileDiff.between(
            before: layer.surface, after: rendered, layerID: layer.id,
            candidates: Set(layer.surface.tileCoordinates(intersecting: floating.destinationBounds)))))
        items.append(SelectionHistoryItem(name: name, icon: .paste,
                                          before: s0.selection, after: floating.outline))
        items.append(FloatingPixelsHistoryItem(name: name, before: nil, after: floating))
        return CompositeHistoryItem(name: name, icon: .paste, items: items)
    }
}
