import Foundation

/// Tools Window sections (Paint.NET's ToolsWindow.html headings), in window order.
enum ToolPanelGroup: String, CaseIterable, Sendable {
    case selection
    case move
    case view
    case fill
    case drawing
    case photo
    case textAndShape
}

/// Everything the UI and the shortcut layer need to know about a tool.
struct ToolDescriptor: Sendable, Equatable {
    let id: ToolID
    let displayName: String
    let shortcutKey: Character
    let group: ToolPanelGroup
    /// SF Symbol name (`ToolSymbolTests` proves it resolves).
    let symbolName: String
    /// True when the tool can hold an uncommitted edit (Finish button appears).
    let supportsPendingEdits: Bool

    /// The Tools panel tooltip: Paint.NET shows the name and the shortcut.
    var helpText: String { "\(displayName) (\(shortcutKey.uppercased()))" }
}

/// The tool table, the implemented-tool registry, the single-key shortcut gate, and the
/// group-cycle resolver (spec 0006; PRD §5.3, D-13, D-35).
@MainActor
struct ToolRegistry {
    /// Exactly the spec 0006 table, in `ToolID.allCases` order (== Paint.NET's Tools window
    /// order). Group membership of Color Picker / Clone Stamp / Recolor follows the
    /// documented headings; "Line / Curve" follows the PRD's spelling.
    nonisolated static let allDescriptors: [ToolDescriptor] = [
        ToolDescriptor(id: .rectangleSelect, displayName: "Rectangle Select", shortcutKey: "s",
                       group: .selection, symbolName: "rectangle.dashed", supportsPendingEdits: false),
        ToolDescriptor(id: .lassoSelect, displayName: "Lasso Select", shortcutKey: "s",
                       group: .selection, symbolName: "lasso", supportsPendingEdits: false),
        ToolDescriptor(id: .ellipseSelect, displayName: "Ellipse Select", shortcutKey: "s",
                       group: .selection, symbolName: "circle.dashed", supportsPendingEdits: false),
        ToolDescriptor(id: .magicWand, displayName: "Magic Wand", shortcutKey: "s",
                       group: .selection, symbolName: "wand.and.stars", supportsPendingEdits: false),
        ToolDescriptor(id: .moveSelectedPixels, displayName: "Move Selected Pixels", shortcutKey: "m",
                       group: .move, symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                       supportsPendingEdits: true),
        ToolDescriptor(id: .moveSelection, displayName: "Move Selection", shortcutKey: "m",
                       group: .move, symbolName: "selection.pin.in.out", supportsPendingEdits: false),
        ToolDescriptor(id: .zoom, displayName: "Zoom", shortcutKey: "z",
                       group: .view, symbolName: "magnifyingglass", supportsPendingEdits: false),
        ToolDescriptor(id: .pan, displayName: "Pan", shortcutKey: "h",
                       group: .view, symbolName: "hand.raised", supportsPendingEdits: false),
        ToolDescriptor(id: .paintBucket, displayName: "Paint Bucket", shortcutKey: "f",
                       group: .fill, symbolName: "drop.fill", supportsPendingEdits: false),
        ToolDescriptor(id: .gradient, displayName: "Gradient", shortcutKey: "g",
                       group: .fill, symbolName: "circle.lefthalf.filled", supportsPendingEdits: false),
        ToolDescriptor(id: .paintbrush, displayName: "Paintbrush", shortcutKey: "b",
                       group: .drawing, symbolName: "paintbrush.pointed", supportsPendingEdits: false),
        ToolDescriptor(id: .eraser, displayName: "Eraser", shortcutKey: "e",
                       group: .drawing, symbolName: "eraser", supportsPendingEdits: false),
        ToolDescriptor(id: .pencil, displayName: "Pencil", shortcutKey: "p",
                       group: .drawing, symbolName: "pencil", supportsPendingEdits: false),
        ToolDescriptor(id: .colorPicker, displayName: "Color Picker", shortcutKey: "k",
                       group: .drawing, symbolName: "eyedropper", supportsPendingEdits: false),
        ToolDescriptor(id: .cloneStamp, displayName: "Clone Stamp", shortcutKey: "l",
                       group: .photo, symbolName: "seal", supportsPendingEdits: false),
        ToolDescriptor(id: .recolor, displayName: "Recolor", shortcutKey: "r",
                       group: .photo, symbolName: "paintpalette", supportsPendingEdits: false),
        ToolDescriptor(id: .text, displayName: "Text", shortcutKey: "t",
                       group: .textAndShape, symbolName: "textformat", supportsPendingEdits: true),
        ToolDescriptor(id: .lineCurve, displayName: "Line / Curve", shortcutKey: "o",
                       group: .textAndShape, symbolName: "line.diagonal", supportsPendingEdits: true),
        ToolDescriptor(id: .shapes, displayName: "Shapes", shortcutKey: "o",
                       group: .textAndShape, symbolName: "square.on.circle", supportsPendingEdits: true),
    ]

    /// The table is static and covers every `ToolID` (`ToolRegistryTests.idsMatchAllCases`);
    /// a missing row is a programming error, not a user path.
    private static let descriptorByID: [ToolID: ToolDescriptor] = Dictionary(
        uniqueKeysWithValues: allDescriptors.map { ($0.id, $0) }
    )

    static func descriptor(for id: ToolID) -> ToolDescriptor {
        guard let descriptor = descriptorByID[id] else {
            preconditionFailure("ToolRegistry.allDescriptors has no row for \(id.rawValue)")
        }
        return descriptor
    }

    /// Every single-key tool letter, implemented or not (the gate consumes them all so an
    /// unimplemented tool never types into a field). `x`/`d` arrive with 0007, `[`/`]` with 0009.
    nonisolated static let allShortcutKeys: Set<Character> = Set(allDescriptors.map(\.shortcutKey))

    private let factories: [ToolID: @MainActor () -> any Tool]

    init(factories: [ToolID: @MainActor () -> any Tool]) {
        self.factories = factories
    }

    /// The app's registry. Each later tool spec adds one line here.
    static func standard() -> ToolRegistry {
        ToolRegistry(factories: [
            .zoom: { ZoomTool() },
            .pan: { PanTool() },
            .paintbrush: { PaintbrushTool() },
        ])
    }

    /// Implemented tools in `ToolID.allCases` order.
    var implementedIDs: [ToolID] {
        ToolID.allCases.filter { factories[$0] != nil }
    }

    func isImplemented(_ id: ToolID) -> Bool { factories[id] != nil }

    func makeTool(_ id: ToolID) -> (any Tool)? { factories[id]?() }

    /// The implemented tools sharing a shortcut key, in `ToolID.allCases` order — D-13's
    /// cycle order (S: Rectangle Select → Lasso → Ellipse → Magic Wand; M: Move Selected
    /// Pixels → Move Selection; O: Line / Curve → Shapes).
    func shortcutGroup(for key: Character) -> [ToolID] {
        implementedIDs.filter { Self.descriptor(for: $0).shortcutKey == key }
    }

    /// Decision (PRD §5.3, D-35): the app starts with the Paintbrush — the Pan tool until
    /// 0009 registers it — and the active tool is never persisted.
    var defaultToolID: ToolID {
        for candidate in [ToolID.paintbrush, .pan] where isImplemented(candidate) {
            return candidate
        }
        guard let first = implementedIDs.first else {
            preconditionFailure("ToolRegistry has no implemented tools")
        }
        return first
    }
}

/// Which kind of window is key right now — the single-key shortcuts work over document
/// windows and the floating panels, never over sheets, dialogs, Settings, or other apps'
/// windows (PRD §5.12).
enum ToolKeyWindowKind: Sendable {
    case document
    case panel
    case other
}

/// The one gate guarding every single-key shortcut (tool letters here; X/D in 0007; `[`/`]`
/// in 0009). Shift is allowed — it steers the group cycle.
struct ToolShortcutGate: Sendable {
    static func allows(modifiers: ToolModifiers, keyWindow: ToolKeyWindowKind,
                       textInputHasFocus: Bool, toolCapturesKeyboard: Bool,
                       gestureInProgress: Bool) -> Bool {
        guard !modifiers.contains(.command), !modifiers.contains(.option),
              !modifiers.contains(.control) else { return false }
        guard keyWindow != .other else { return false }
        return !textInputHasFocus && !toolCapturesKeyboard && !gestureInProgress
    }
}

/// D-35's group cycling, matching Paint.NET's "less than a second apart": a press less than
/// 1 s after the previous press of the same key cycles forward from the active tool, Shift
/// cycles backward; any other press selects the group's first tool, or with Shift its last
/// (Shift+S is the Magic Wand). Auto-repeat presses never reach `resolve`.
struct ToolShortcutResolver: Sendable {
    static let cycleInterval: TimeInterval = 1.0

    private var lastPress: (key: Character, time: TimeInterval)?

    /// `s` lowercased, exactly one `Character`, and a member of `allShortcutKeys`; else nil.
    /// Caps Lock or Shift producing "S" still yields `s` — Shift comes from the modifiers.
    static func toolKey(fromCharactersIgnoringModifiers s: String) -> Character? {
        let lowered = s.lowercased()
        guard lowered.count == 1, let key = lowered.first,
              ToolRegistry.allShortcutKeys.contains(key) else { return nil }
        return key
    }

    mutating func resolve(key: Character, shift: Bool, group: [ToolID],
                          activeTool: ToolID, timestamp: TimeInterval) -> ToolID? {
        var cycling = false
        if let last = lastPress, last.key == key,
           timestamp - last.time < Self.cycleInterval, group.contains(activeTool) {
            cycling = true
        }
        lastPress = (key, timestamp)
        guard !group.isEmpty else { return nil }
        if cycling, let index = group.firstIndex(of: activeTool) {
            let count = group.count
            let next = shift ? (index - 1 + count) % count : (index + 1) % count
            return group[next]
        }
        return shift ? group.last : group.first
    }
}
