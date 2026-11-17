import Foundation

/// Edit > Erase Selection (spec 0018; PRD E-4, §5.12, D-45, D-27, H-6; Paint.NET
/// EditMenu.html): every pixel inside the selection becomes transparent black, the edge
/// is scaled by the selection's antialiased coverage, and the selection is removed
/// afterwards ("The selection outline is removed following the completion of the
/// action"). `state.selection == nil` means the whole layer is editable (TOOL-B, D-40),
/// so ⌫ with no selection clears the whole active layer — D-45(a). One
/// `CompositeHistoryItem` "Erase Selection" carries the pixel diff and the deselect, so
/// one ⌘Z restores both.
enum EraseSelection {
    /// Menu title and history step (Paint.NET spelling).
    static let name = "Erase Selection"
    static let icon: HistoryIcon = .eraseSelection

    /// One pixel; `coverage` is the selection mask value 0…255. Exactly
    /// `EraseOps.erase(p, strength: 255, coverage: coverage)` — the closed form
    /// `m == 0 ? p : (a·(255−m) + 127) / 255`, `0 → (0,0,0,0)`, RGB untouched — so the
    /// app has one erase rule (0011). `EraseSelectionTests` proves both forms equal for
    /// all 65,536 `(a, m)` pairs.
    static func erasePixel(_ p: ColorRGBA8, coverage: UInt8) -> ColorRGBA8 {
        EraseOps.erase(p, strength: 255, coverage: coverage)
    }

    /// The erased surface and the tiles it replaced (the `TileDiff` candidates).
    /// `mask == nil` behaves as every tile `.full` (no selection = the whole layer).
    ///
    /// Per tile: `.empty` or an unallocated surface tile is skipped (erasing
    /// `(0,0,0,0)` changes nothing); a `.full` tile becomes `nil` in O(1); a `.partial`
    /// tile copies its bytes and applies `erasePixel` where the coverage is non-zero
    /// (out-of-canvas mask bytes are always 0, so the edge padding stays zero). Partial
    /// tiles are independent, so their results are computed concurrently and written
    /// serially — bit-identical to a serial loop. A partial result that is fully
    /// transparent is stored as `nil`.
    static func erase(_ surface: TiledSurface, mask: SelectionMask?)
        -> (surface: TiledSurface, touched: Set<TileCoordinate>)
    {
        var result = surface
        var touched: Set<TileCoordinate> = []
        var jobs: [PartialEraseJob] = []
        for row in 0..<surface.tileRows {
            for column in 0..<surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                guard let tile = surface.tile(at: coordinate) else { continue }
                switch mask?.tile(at: coordinate) ?? .full {
                case .empty:
                    continue
                case .full:
                    result.setTile(nil, at: coordinate)   // O(1) — no pixel loop
                    touched.insert(coordinate)
                case .partial(let storage):
                    jobs.append(PartialEraseJob(coordinate: coordinate, tile: tile, storage: storage))
                }
            }
        }
        guard !jobs.isEmpty else { return (result, touched) }
        let partialJobs = jobs   // the copy-on-write reference the concurrent tasks read
        let boxes = partialJobs.map { _ in ErasedTileBox() }
        DispatchQueue.concurrentPerform(iterations: partialJobs.count) { index in
            boxes[index].tile = erasedPartialTile(partialJobs[index])
        }
        for (index, job) in partialJobs.enumerated() {
            // The tile was allocated (the loop only queues allocated tiles), so replacing
            // it — with a tile or with `nil` — is a real write.
            result.setTile(boxes[index].tile, at: job.coordinate)
            touched.insert(job.coordinate)
        }
        return (result, touched)
    }

    /// Always true for an open document: with no selection the whole active layer is
    /// editable (D-45(a)), so the command can never be a "wrong state" no-op.
    static func isEnabled(in state: DocumentState) -> Bool { true }

    /// The single "Erase Selection" step, or `nil` when nothing would change (H-6): the
    /// pixel item is omitted when the diff is empty and the deselect item when there is
    /// no selection, so `change` follows 0013's merge table (`.pixels`, `.selection`, or
    /// `.pixelsAndSelection`). Erasing an already-transparent area while a selection
    /// exists still records one deselect-only step.
    static func makeHistoryItem(for state: DocumentState) -> (any HistoryItem)? {
        let layer = state.image.layers[state.image.activeLayerIndex]
        let (erased, touched) = erase(layer.surface, mask: state.selection?.mask)
        let diff = TileDiff.between(before: layer.surface, after: erased,
                                    layerID: layer.id, candidates: touched)
        var items: [any HistoryItem] = []
        if !diff.isEmpty {
            items.append(TileDiffHistoryItem(name: name, icon: icon, diff: diff))
        }
        if let selection = state.selection {
            items.append(SelectionHistoryItem(name: name, icon: icon,
                                              before: selection, after: nil))
        }
        guard !items.isEmpty else { return nil }
        let item = CompositeHistoryItem(name: name, icon: icon, items: items)
        return item.isNoOp ? nil : item
    }

    // MARK: - Partial-tile machinery

    /// One queued `.partial` mask tile with its (allocated) surface tile.
    private struct PartialEraseJob {
        let coordinate: TileCoordinate
        let tile: Tile
        let storage: SelectionMaskTileStorage
    }

    /// One partial tile's computed result (`nil` = fully transparent). Each
    /// `concurrentPerform` task writes only its own box — the same pattern as
    /// `SelectionMaskTileBox` — so the unchecked conformance is safe.
    private final class ErasedTileBox: @unchecked Sendable {
        var tile: Tile?
    }

    /// The erased copy of one partial tile: `erasePixel` on every pixel whose coverage
    /// byte is non-zero (in-canvas only — out-of-canvas bytes are always 0, so the edge
    /// padding is preserved). `nil` when the result is fully transparent.
    private static func erasedPartialTile(_ job: PartialEraseJob) -> Tile? {
        var copy = job.tile
        copy.withUnsafeMutableBytes { pixels in
            job.storage.bytes.withUnsafeBytes { coverage in
                for index in 0..<coverage.count {
                    let m = coverage[index]
                    guard m != 0 else { continue }
                    let offset = index * 4
                    // The closed form of `erasePixel` (identical to
                    // `EraseOps.erase(_, strength: 255, coverage: m)` for every input).
                    let newAlpha = (UInt32(pixels[offset + 3]) * (255 - UInt32(m)) + 127) / 255
                    if newAlpha == 0 {
                        pixels[offset] = 0
                        pixels[offset + 1] = 0
                        pixels[offset + 2] = 0
                        pixels[offset + 3] = 0
                    } else {
                        pixels[offset + 3] = UInt8(newAlpha)
                    }
                }
            }
        }
        return copy.isFullyTransparent ? nil : copy
    }
}

/// The two Edit commands ⌫/⌦/⌥⌫ resolve to (spec 0018 Scope §4).
enum SelectionPixelCommand: CaseIterable, Sendable {
    case eraseSelection
    case fillSelection

    /// Mac virtual key codes: 51 = Delete (⌫, `kVK_Delete`), 117 = Forward Delete
    /// (⌦, `kVK_ForwardDelete`). Key codes, not characters: ⌫ delivers `"\u{7F}"`, ⌦
    /// `"\u{F728}"`, and ⌥ changes characters; keyboard layouts do not move these keys.
    static let deleteKeyCode: UInt16 = 51
    static let forwardDeleteKeyCode: UInt16 = 117

    /// ⌫ or ⌦ with no modifiers → `.eraseSelection`; ⌥⌫ → `.fillSelection`; anything
    /// else → `nil`. ⇧⌫ is left unhandled rather than silently erasing (Paint.NET maps
    /// it to "fill with the secondary color", which is out of scope); ⌥⌦, ⌘⌫ (0024
    /// reserves its space), ⌃⌫ and every other key return `nil` too.
    static func command(forKeyCode keyCode: UInt16, modifiers: ToolModifiers) -> SelectionPixelCommand? {
        switch (keyCode, modifiers) {
        case (deleteKeyCode, []), (forwardDeleteKeyCode, []): .eraseSelection
        case (deleteKeyCode, [.option]): .fillSelection
        default: nil
        }
    }

    /// Always true for an open document (both commands; D-45(a)).
    func isEnabled(in state: DocumentState) -> Bool {
        switch self {
        case .eraseSelection: EraseSelection.isEnabled(in: state)
        case .fillSelection: FillSelection.isEnabled(in: state)
        }
    }

    /// The router's decision for one key-down (spec 0018 Scope §8), pure so the table is
    /// unit-tested: resolve the chord; pass when it is not ours or the shared
    /// `ToolShortcutGate` rejects it (⌘/⌃, a dialog, a focused text field, a
    /// keyboard-capturing tool, or a live gesture); consume auto-repeat so holding the
    /// key records one step, not dozens. ⌥ is removed before the gate only here,
    /// because ⌥⌫ is the documented chord.
    static func selectionPixelShortcut(
        keyCode: UInt16, modifiers: ToolModifiers, isRepeat: Bool,
        keyWindow: ToolKeyWindowKind, textInputHasFocus: Bool,
        toolCapturesKeyboard: Bool, gestureInProgress: Bool
    ) -> SelectionPixelShortcutDecision {
        guard let command = command(forKeyCode: keyCode, modifiers: modifiers) else { return .pass }
        guard ToolShortcutGate.allows(modifiers: modifiers.subtracting(.option),
                                      keyWindow: keyWindow,
                                      textInputHasFocus: textInputHasFocus,
                                      toolCapturesKeyboard: toolCapturesKeyboard,
                                      gestureInProgress: gestureInProgress) else { return .pass }
        return isRepeat ? .consumeIgnored : .perform(command)
    }
}

/// What `SelectionPixelCommand.selectionPixelShortcut` decided (spec 0018 Test plan).
enum SelectionPixelShortcutDecision: Equatable, Sendable {
    /// Dispatch the command's responder-chain action.
    case perform(SelectionPixelCommand)
    /// Our key with auto-repeat: consume it and do nothing.
    case consumeIgnored
    /// Not ours (or the gate rejects it): let the event continue.
    case pass
}
