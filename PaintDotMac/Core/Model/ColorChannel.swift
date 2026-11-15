import Foundation

/// One editable Colors-panel channel: the four 8-bit ones plus Paint.NET's H, S, V (C-2).
enum ColorChannel: String, CaseIterable, Sendable {
    case red
    case green
    case blue
    case hue
    case saturation
    case value
    case alpha

    /// Paint.NET's scales: R/G/B/A 0–255, H 0–360, S and V 0–100.
    var range: ClosedRange<Int> {
        switch self {
        case .red, .green, .blue, .alpha: 0...255
        case .hue: 0...360
        case .saturation, .value: 0...100
        }
    }

    /// The visible label; `label` is also the accessibility label, so the panel may abbreviate
    /// the text it draws.
    var label: String {
        switch self {
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .value: "Value"
        case .alpha: "Alpha"
        }
    }

    /// The panel's one-letter column label; every channel's label starts with a distinct letter.
    var shortLabel: String { String(label.prefix(1)) }

    var isRGBComponent: Bool {
        switch self {
        case .red, .green, .blue: true
        default: false
        }
    }

    var isHSVComponent: Bool {
        switch self {
        case .hue, .saturation, .value: true
        default: false
        }
    }

    /// Panel accessibility identifiers: `colors.red` / `colors.redField`.
    var sliderIdentifier: String { "colors.\(rawValue)" }
    var fieldIdentifier: String { "colors.\(rawValue)Field" }
}
