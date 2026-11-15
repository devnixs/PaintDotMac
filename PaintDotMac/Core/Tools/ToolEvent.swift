import CoreGraphics
import Foundation

/// Every Paint.NET tool, in the Tools window's order (spec 0006; PRD §5.3). Declaration order
/// is the panel order and the base of D-13's key-group cycling. The raw values are the stable
/// IDs used in `UserDefaults` keys (`tool.<id>.<option>`, TOOL-C) and accessibility identifiers.
enum ToolID: String, CaseIterable, Sendable {
    case rectangleSelect
    case lassoSelect
    case ellipseSelect
    case magicWand
    case moveSelectedPixels
    case moveSelection
    case zoom
    case pan
    case paintBucket
    case gradient
    case paintbrush
    case eraser
    case pencil
    case colorPicker
    case cloneStamp
    case recolor
    case text
    case lineCurve
    case shapes
}

/// The tool-visible mouse button (TOOL-A). The dispatcher maps Control-left to `.secondary`
/// and keeps `.control` in the modifiers, so tools never see raw buttons.
enum ToolMouseButton: Sendable, Equatable {
    case primary
    case secondary
}

/// The four modifier flags a tool may check, independent of AppKit (rule 1).
struct ToolModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let shift = ToolModifiers(rawValue: 1 << 0)
    static let option = ToolModifiers(rawValue: 1 << 1)
    static let control = ToolModifiers(rawValue: 1 << 2)
    static let command = ToolModifiers(rawValue: 1 << 3)
}

/// One mouse event delivered to the active tool (spec 0006). Coordinates are 0003's:
/// `location` is canvas space (image pixels, origin top-left, y down) and `viewLocation` is
/// view space (AppKit points, origin bottom-left, y up) for screen-space thresholds. The
/// `CanvasInputRouter` drops events whose conversion is not finite.
struct ToolEvent: Sendable, Equatable {
    var location: CGPoint
    var viewLocation: CGPoint
    var button: ToolMouseButton
    var modifiers: ToolModifiers
    /// `NSEvent.clickCount` on mouseDown; 0 for dragged/moved events.
    var clickCount: Int
    /// Reserved for TOOL-D (0055); always 1.0 until then.
    var pressure: Double
    var timestamp: TimeInterval
}

/// A key identified by virtual key code first, then by a single typed character (spec 0006).
enum ToolKey: Sendable, Equatable {
    /// `charactersIgnoringModifiers` lowercased, exactly one `Character`.
    case character(Character)
    case returnKey
    case enter
    case escape
    case delete
    case forwardDelete
    case tab
    case space
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case other(keyCode: UInt16)

    init(keyCode: UInt16, charactersIgnoringModifiers: String) {
        switch keyCode {
        case 36: self = .returnKey
        case 76: self = .enter
        case 53: self = .escape
        case 51: self = .delete
        case 117: self = .forwardDelete
        case 48: self = .tab
        case 49: self = .space
        case 123: self = .leftArrow
        case 124: self = .rightArrow
        case 125: self = .downArrow
        case 126: self = .upArrow
        default:
            if charactersIgnoringModifiers.count == 1,
               let character = charactersIgnoringModifiers.lowercased().first {
                self = .character(character)
            } else {
                self = .other(keyCode: keyCode)
            }
        }
    }
}

/// One key event delivered to the active tool.
struct ToolKeyEvent: Sendable, Equatable {
    var key: ToolKey
    var characters: String
    var modifiers: ToolModifiers
    var isRepeat: Bool
}
