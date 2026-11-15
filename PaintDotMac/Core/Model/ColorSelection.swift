import Foundation

/// Which of the Colors panel's two slots is active (C-1, D-31): the one the wheel, sliders,
/// and hex field edit, and the one `C` moves the outline to.
enum ColorSlot: String, CaseIterable, Sendable {
    case primary
    case secondary

    /// The other slot — the wheel's right-click target (Paint.NET's "inactive" slot) and
    /// `C`'s next stop.
    var other: ColorSlot { self == .primary ? .secondary : .primary }

    /// VoiceOver's label for the slot's swatch (spec 0007).
    var accessibilityLabel: String { self == .primary ? "Primary color" : "Secondary color" }

    var swatchIdentifier: String { "colors.\(rawValue)" }
}

/// The app-wide primary/secondary pair (C-1). Colors are **not** a history step and are not
/// per document: switching documents never changes them.
struct ColorSelection: Equatable, Sendable {
    /// Paint.NET's default pair, restored by the reset button and D.
    static let defaultPrimary = ColorRGBA8.black
    static let defaultSecondary = ColorRGBA8.white
    static let `default` = ColorSelection(primary: defaultPrimary, secondary: defaultSecondary)

    var primary: ColorRGBA8
    var secondary: ColorRGBA8

    subscript(slot: ColorSlot) -> ColorRGBA8 {
        get { slot == .primary ? primary : secondary }
        set {
            if slot == .primary { primary = newValue } else { secondary = newValue }
        }
    }

    /// The X key and the double-headed arrow button.
    mutating func swap() {
        let previousPrimary = primary
        primary = secondary
        secondary = previousPrimary
    }

    /// The D key and the black/white reset icon.
    mutating func reset() {
        primary = Self.defaultPrimary
        secondary = Self.defaultSecondary
    }
}

/// The three bare-key color commands of the Colors panel (C-1, PRD §5.12, D-31).
enum ColorKeyCommand: Equatable, Sendable {
    case swap
    case reset
    case switchSlot

    /// `.swap` for X, `.reset` for D, `.switchSlot` for C — only with no ⌘, ⌥, or ⌃ (Shift and
    /// Caps Lock are ignored, so `"X"` arrives here too). Everything else is `nil`, which keeps
    /// ⌘X, ⌘D, and ⌘C on their menu paths.
    static func command(forCharactersIgnoringModifiers characters: String, command: Bool,
                        option: Bool, control: Bool) -> ColorKeyCommand? {
        guard !command, !option, !control else { return nil }
        switch characters {
        case "x", "X": return .swap
        case "d", "D": return .reset
        case "c", "C": return .switchSlot
        default: return nil
        }
    }
}

/// The `colors.*` preferences (C-1: colors are app-wide and persisted). Wraps an injected
/// `UserDefaults` so tests use a throwaway suite; `AppModel` owns the only production instance
/// (main-actor isolated for that reason, not because `UserDefaults` needs it).
@MainActor
struct ColorSelectionStore {
    static let primaryKey = "colors.primary"
    static let secondaryKey = "colors.secondary"
    static let panelExpandedKey = "colors.panelExpanded"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
    }

    /// Each slot falls back to its own default independently: a bad `colors.secondary` never
    /// resets a good `colors.primary`. A stored 6-digit value reads as opaque.
    func load() -> ColorSelection {
        ColorSelection(
            primary: load(Self.primaryKey, fallback: ColorSelection.defaultPrimary),
            secondary: load(Self.secondaryKey, fallback: ColorSelection.defaultSecondary)
        )
    }

    /// Always `#RRGGBBAA`, uppercase.
    func save(_ selection: ColorSelection) {
        defaults.set(ColorHex.format(selection.primary, includeAlpha: true),
                     forKey: Self.primaryKey)
        defaults.set(ColorHex.format(selection.secondary, includeAlpha: true),
                     forKey: Self.secondaryKey)
    }

    /// Paint.NET opens the Colors window in its compact state, so the default is `false`.
    func loadPanelExpanded() -> Bool {
        defaults.object(forKey: Self.panelExpandedKey) as? Bool ?? false
    }

    func savePanelExpanded(_ expanded: Bool) {
        defaults.set(expanded, forKey: Self.panelExpandedKey)
    }

    private func load(_ key: String, fallback: ColorRGBA8) -> ColorRGBA8 {
        guard let text = defaults.object(forKey: key) as? String,
              let parsed = ColorHex.parse(text)
        else { return fallback }
        return parsed.color(alpha: 255)
    }
}
