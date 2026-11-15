import Foundation

/// The pure model behind the Colors panel (C-1, C-2): which slot is active, the colors, and a
/// **per-slot HSV cache** so the hue survives grays and black — dragging Saturation to 0 and
/// back, or Value to 0 and back, keeps the color the user had. `AppModel` owns one instance and
/// saves it through `ColorSelectionStore` on every change.
struct ColorEditorState: Equatable, Sendable {
    private(set) var selection: ColorSelection
    /// Not persisted: every launch starts with Primary active (C-1).
    var activeSlot: ColorSlot
    private(set) var hsv: [ColorSlot: HSVColor]

    init(selection: ColorSelection) {
        self.selection = selection
        self.activeSlot = .primary
        self.hsv = Dictionary(uniqueKeysWithValues: ColorSlot.allCases.map { slot in
            (slot, HSVColor(rgb: selection[slot]))
        })
    }

    /// The slider/field readout for one channel. `slot` defaults to the active slot.
    func value(of channel: ColorChannel, slot explicitSlot: ColorSlot? = nil) -> Int {
        let slot = explicitSlot ?? activeSlot
        let color = selection[slot]
        let cache = self.cache(for: slot)
        return switch channel {
        case .red: Int(color.red)
        case .green: Int(color.green)
        case .blue: Int(color.blue)
        case .alpha: Int(color.alpha)
        case .hue: cache.displayHue
        case .saturation: cache.displaySaturation
        case .value: cache.displayValue
        }
    }

    /// One slider or numeric field moved, on the active slot. Out-of-range values clamp.
    mutating func set(_ channel: ColorChannel, to value: Int) {
        let slot = activeSlot
        let clamped = min(max(value, channel.range.lowerBound), channel.range.upperBound)
        if channel.isRGBComponent {
            var color = selection[slot]
            switch channel {
            case .red: color.red = UInt8(clamping: clamped)
            case .green: color.green = UInt8(clamping: clamped)
            case .blue: color.blue = UInt8(clamping: clamped)
            default: break
            }
            selection[slot] = color
            resyncCache(from: color, for: slot)
        } else if channel.isHSVComponent {
            let previous = cache(for: slot)
            let updated: HSVColor
            switch channel {
            case .hue: updated = HSVColor(hue: Double(clamped), saturation: previous.saturation,
                                          value: previous.value)
            case .saturation: updated = HSVColor(hue: previous.hue, saturation: Double(clamped),
                                                 value: previous.value)
            default: updated = HSVColor(hue: previous.hue, saturation: previous.saturation,
                                        value: Double(clamped))
            }
            hsv[slot] = updated
            selection[slot] = updated.rgb(alpha: selection[slot].alpha)
        } else {
            var color = selection[slot]
            color.alpha = UInt8(clamping: clamped)
            selection[slot] = color  // alpha-only edits never touch the cache
        }
    }

    /// An external set — the hex field, or 0012's Color Picker. Re-syncs that slot's cache.
    mutating func setColor(_ color: ColorRGBA8, for slot: ColorSlot) {
        selection[slot] = color
        resyncCache(from: color, for: slot)
    }

    /// A hex commit. Invalid text returns `false` and changes nothing; 6 digits keep the active
    /// slot's alpha, 8 digits set it too.
    @discardableResult
    mutating func applyHex(_ text: String) -> Bool {
        guard let parsed = ColorHex.parse(text) else { return false }
        setColor(parsed.color(alpha: selection[activeSlot].alpha), for: activeSlot)
        return true
    }

    /// A wheel click or drag on `slot`. The wheel is drawn at value 100 (C-2), so a slot whose
    /// cached value is 0 — the default black primary — would otherwise stay black forever: the
    /// first click raises it to 100. Alpha is kept.
    mutating func applyWheel(hue: Double, saturation: Double, to slot: ColorSlot) {
        let previous = cache(for: slot)
        let updated = HSVColor(hue: hue, saturation: saturation,
                               value: previous.value == 0 ? HSVColor.percentFull : previous.value)
        hsv[slot] = updated
        selection[slot] = updated.rgb(alpha: selection[slot].alpha)
    }

    /// X: the colors and their caches travel together; the active slot does not move.
    mutating func swap() {
        selection.swap()
        let primaryCache = cache(for: .primary)
        hsv[.primary] = cache(for: .secondary)
        hsv[.secondary] = primaryCache
    }

    /// D: defaults, with the caches Paint.NET's defaults map to — no leftovers from before.
    mutating func reset() {
        selection.reset()
        hsv = [
            .primary: HSVColor(hue: 0, saturation: 0, value: 0),
            .secondary: HSVColor(hue: 0, saturation: 0, value: HSVColor.percentFull),
        ]
    }

    /// C (D-31): move the outline. Colors and caches are untouched.
    mutating func switchActiveSlot() {
        activeSlot = activeSlot.other
    }

    private func cache(for slot: ColorSlot) -> HSVColor {
        hsv[slot] ?? HSVColor(rgb: selection[slot])
    }

    /// Re-sync after an RGB change: a gray keeps the cached hue, black keeps hue and saturation,
    /// anything else takes the converted value.
    private mutating func resyncCache(from color: ColorRGBA8, for slot: ColorSlot) {
        let converted = HSVColor(rgb: color)
        let previous = cache(for: slot)
        if converted.value == 0 {
            hsv[slot] = HSVColor(hue: previous.hue, saturation: previous.saturation, value: 0)
        } else if converted.saturation == 0 {
            hsv[slot] = HSVColor(hue: previous.hue, saturation: 0, value: converted.value)
        } else {
            hsv[slot] = converted
        }
    }
}
