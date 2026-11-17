import Foundation
import Observation

/// The Layer Properties dialog's view model (spec 0025 item 9, PRD L-2, D-34). Paint.NET's
/// dialog edits name, visibility, blend mode, and opacity 0–255; every change previews
/// live through the injected `apply` (never a history step — live preview writes go
/// through `UndoBridge.updateLiveState` in the window controller), **Cancel** re-applies
/// the original and closes with no step, and **OK** returns the one "Layer Properties"
/// step (the stack ignores it when `isNoOp`, H-6).
///
/// `onDismiss` and `onCommit` are wired by the presenting window controller (dismiss the
/// sheet; commit the OK item); unit tests spy `apply` and leave them nil.
@MainActor
@Observable
final class LayerPropertiesDialogModel {
    let layerID: Layer.ID
    /// The properties at open time — Cancel restores exactly these, and OK's `before`.
    let original: LayerProperties
    /// The blend modes offered, `BlendMode.allCases` in enum order — only implemented
    /// modes exist, so "Normal" alone until 0026/0027 add cases (D-15).
    let blendModeOptions: [BlendMode] = BlendMode.allCases
    /// The live-edited properties. Every change previews via `apply`; the opacity slider
    /// and field always show the same value (`opacityText` follows).
    var edited: LayerProperties {
        didSet {
            opacityText = String(edited.opacity)
            apply(edited)
        }
    }
    /// The opacity number field's text (0–255, clamped/rounded on commit).
    var opacityText: String
    /// Wired by the presenter: close the sheet.
    var onDismiss: (() -> Void)?
    /// Wired by the presenter: record the OK step (`undoBridge.commit`).
    var onCommit: ((LayerPropertiesHistoryItem) -> Void)?

    private let apply: (LayerProperties) -> Void

    init(layerID: Layer.ID, original: LayerProperties,
         apply: @escaping (LayerProperties) -> Void) {
        self.layerID = layerID
        self.original = original
        self.edited = original
        self.opacityText = String(original.opacity)
        self.apply = apply
    }

    /// Cancel: restore the live preview to the original properties and close — no step.
    func cancel() {
        apply(original)
        onDismiss?()
    }

    /// OK: close and return the single "Layer Properties" step (nil-free — the stack
    /// drops it when nothing changed). The document state already holds `edited`
    /// (live preview), so the controller just commits.
    func ok() -> LayerPropertiesHistoryItem? {
        let item = LayerPropertiesHistoryItem.properties(layerID: layerID,
                                                         before: original, after: edited)
        onDismiss?()
        onCommit?(item)
        return item
    }

    /// Commits the opacity text field (Return / focus loss): parse with the current
    /// opacity as fallback — a rejected or clamped-to-same input applies nothing — and
    /// resync the field text to the authoritative value.
    func commitOpacityText() {
        let parsed = Self.parseOpacity(opacityText, fallback: edited.opacity)
        if parsed != edited.opacity {
            edited.opacity = parsed      // live-preview apply
        }
        opacityText = "\(edited.opacity)"
    }

    /// The opacity field's rule (spec item 9): trim; an integer clamps to 0…255
    /// ("300" → 255, "-5" → 0); a decimal rounds half up ("127.5" → 128); empty or
    /// non-numeric keeps the last valid value.
    static func parseOpacity(_ text: String, fallback: UInt8) -> UInt8 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed) {
            return UInt8(min(255, max(0, value)))
        }
        if let value = Double(trimmed), value.isFinite {
            // Round half up: +0.5 then floor (127.5 → 128, −3.5 → −3 then clamped to 0).
            return UInt8(min(255.0, max(0.0, (value + 0.5).rounded(.down))))
        }
        return fallback
    }
}
