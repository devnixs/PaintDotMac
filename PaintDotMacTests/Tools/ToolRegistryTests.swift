import Testing
@testable import PaintDotMac

/// The tool table, registry, groups, and default tool (spec 0006 *Test plan*).
@MainActor
struct ToolRegistryTests {
    @Test func idsMatchAllCases() {
        #expect(ToolRegistry.allDescriptors.map(\.id) == ToolID.allCases)
        #expect(ToolID.allCases.count == 19)
        #expect(Set(ToolID.allCases).count == 19)
    }

    @Test func rawValuesAreDefaultsIDs() {
        #expect(ToolID.allCases.map(\.rawValue) == [
            "rectangleSelect", "lassoSelect", "ellipseSelect", "magicWand",
            "moveSelectedPixels", "moveSelection", "zoom", "pan", "paintBucket", "gradient",
            "paintbrush", "eraser", "pencil", "colorPicker", "cloneStamp", "recolor",
            "text", "lineCurve", "shapes",
        ])
    }

    @Test func descriptorsMatchTable() {
        // The spec table, literally: (id, displayName, key, group, supportsPendingEdits).
        let table: [(ToolID, String, Character, ToolPanelGroup, Bool)] = [
            (.rectangleSelect, "Rectangle Select", "s", .selection, false),
            (.lassoSelect, "Lasso Select", "s", .selection, false),
            (.ellipseSelect, "Ellipse Select", "s", .selection, false),
            (.magicWand, "Magic Wand", "s", .selection, false),
            (.moveSelectedPixels, "Move Selected Pixels", "m", .move, true),
            (.moveSelection, "Move Selection", "m", .move, false),
            (.zoom, "Zoom", "z", .view, false),
            (.pan, "Pan", "h", .view, false),
            (.paintBucket, "Paint Bucket", "f", .fill, false),
            (.gradient, "Gradient", "g", .fill, false),
            (.paintbrush, "Paintbrush", "b", .drawing, false),
            (.eraser, "Eraser", "e", .drawing, false),
            (.pencil, "Pencil", "p", .drawing, false),
            (.colorPicker, "Color Picker", "k", .drawing, false),
            (.cloneStamp, "Clone Stamp", "l", .photo, false),
            (.recolor, "Recolor", "r", .photo, false),
            (.text, "Text", "t", .textAndShape, true),
            (.lineCurve, "Line / Curve", "o", .textAndShape, true),
            (.shapes, "Shapes", "o", .textAndShape, true),
        ]
        let rows = ToolRegistry.allDescriptors.map {
            ($0.id, $0.displayName, $0.shortcutKey, $0.group, $0.supportsPendingEdits)
        }
        #expect(rows.count == table.count)
        for (row, expected) in zip(rows, table) {
            #expect(row.0 == expected.0 && row.1 == expected.1 && row.2 == expected.2
                        && row.3 == expected.3 && row.4 == expected.4,
                    "descriptor row \(expected.0.rawValue)")
            #expect(ToolRegistry.descriptor(for: row.0).displayName == row.1)
        }
        #expect(ToolRegistry.descriptor(for: .zoom).helpText == "Zoom (Z)")
        #expect(ToolRegistry.descriptor(for: .lineCurve).helpText == "Line / Curve (O)")
    }

    @Test func allShortcutKeys() {
        #expect(ToolRegistry.allShortcutKeys
                    == Set(["s", "m", "z", "h", "f", "g", "b", "e", "p", "k", "l", "r", "t", "o"]))
        // 0007's color keys are not tool keys yet.
        #expect(!ToolRegistry.allShortcutKeys.contains("x"))
        #expect(!ToolRegistry.allShortcutKeys.contains("d"))
    }

    @Test func standardRegistersPaintbrush() {
        // Later tool specs extend this list as they register their tool (0011 added the
        // Eraser and the Pencil; 0012 the Color Picker; 0014 the two selection tools).
        #expect(ToolRegistry.standard().implementedIDs
                    == [.rectangleSelect, .ellipseSelect, .zoom, .pan, .paintbrush, .eraser,
                        .pencil, .colorPicker])
        #expect(ToolRegistry.standard().makeTool(.zoom) is ZoomTool)
        #expect(ToolRegistry.standard().makeTool(.pan) is PanTool)
        #expect(ToolRegistry.standard().makeTool(.rectangleSelect) is RectangleSelectTool)
        #expect(ToolRegistry.standard().makeTool(.ellipseSelect) is EllipseSelectTool)
        #expect(ToolRegistry.standard().makeTool(.paintbrush) is PaintbrushTool)
        #expect(ToolRegistry.standard().makeTool(.eraser) is EraserTool)
        #expect(ToolRegistry.standard().makeTool(.pencil) is PencilTool)
        #expect(ToolRegistry.standard().makeTool(.colorPicker) is ColorPickerTool)
        #expect(ToolRegistry.standard().makeTool(.recolor) == nil)
        #expect(ToolRegistry.standard().isImplemented(.zoom))
    }

    /// 0014 *Acceptance*: S cycles the two implemented selection tools (D-13 — Lasso and
    /// Magic Wand slot in later by `ToolID.allCases` order with no further change).
    @Test func selectionGroupHasRectangleAndEllipse() {
        let registry = ToolRegistry.standard()
        #expect(registry.shortcutGroup(for: "s") == [.rectangleSelect, .ellipseSelect])
        var resolver = ToolShortcutResolver()
        // 1st S (fresh) → Rectangle; within 1 s again → Ellipse; again → Rectangle.
        #expect(resolver.resolve(key: "s", shift: false,
                                 group: [.rectangleSelect, .ellipseSelect],
                                 activeTool: .paintbrush, timestamp: 0.0) == .rectangleSelect)
        #expect(resolver.resolve(key: "s", shift: false,
                                 group: [.rectangleSelect, .ellipseSelect],
                                 activeTool: .rectangleSelect, timestamp: 0.5) == .ellipseSelect)
        #expect(resolver.resolve(key: "s", shift: false,
                                 group: [.rectangleSelect, .ellipseSelect],
                                 activeTool: .ellipseSelect, timestamp: 0.9) == .rectangleSelect)
        // Shift+S with no recent press → the group's last implemented tool.
        var fresh = ToolShortcutResolver()
        #expect(fresh.resolve(key: "s", shift: true,
                              group: [.rectangleSelect, .ellipseSelect],
                              activeTool: .paintbrush, timestamp: 5.0) == .ellipseSelect)
    }

    /// 0011 *Acceptance*: `p` and `e` are single-tool key groups once the tools are
    /// registered, they follow the Paintbrush in the panel order, and the app still starts
    /// on the Paintbrush (D-35).
    @Test func pencilAndEraserKeys() {
        let registry = ToolRegistry.standard()
        #expect(registry.shortcutGroup(for: "p") == [.pencil])
        #expect(registry.shortcutGroup(for: "e") == [.eraser])
        #expect(registry.implementedIDs
                    == [.rectangleSelect, .ellipseSelect, .zoom, .pan, .paintbrush, .eraser,
                        .pencil, .colorPicker],
                "paintbrush, eraser, pencil, color picker consecutively — ToolID.allCases order")
        #expect(registry.defaultToolID == .paintbrush)
    }

    private func stubRegistry(_ ids: [ToolID]) -> ToolRegistry {
        var factories: [ToolID: @MainActor () -> any Tool] = [:]
        for id in ids { factories[id] = { StubTool(id: id) } }
        return ToolRegistry(factories: factories)
    }

    /// All 19 tools implemented → the full D-13 cycle order.
    @Test func shortcutGroupsInCycleOrder() {
        let registry = stubRegistry(ToolID.allCases)
        #expect(registry.shortcutGroup(for: "s")
                    == [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand])
        #expect(registry.shortcutGroup(for: "m") == [.moveSelectedPixels, .moveSelection])
        #expect(registry.shortcutGroup(for: "o") == [.lineCurve, .shapes])
        #expect(registry.shortcutGroup(for: "z") == [.zoom])
        #expect(registry.shortcutGroup(for: "x") == [])
    }

    /// D-13 with a partially implemented group: only the implemented tools cycle.
    @Test func groupsExcludeUnimplemented() {
        let registry = stubRegistry([.magicWand, .rectangleSelect])
        #expect(registry.shortcutGroup(for: "s") == [.rectangleSelect, .magicWand])
    }

    /// D-35 (0009 landed): the app starts with the Paintbrush; the Pan tool is the fallback
    /// for registries without it; otherwise the first implemented tool.
    @Test func defaultTool() {
        #expect(ToolRegistry.standard().defaultToolID == .paintbrush)
        #expect(stubRegistry([.pan, .paintbrush]).defaultToolID == .paintbrush)
        #expect(stubRegistry([.zoom, .pan]).defaultToolID == .pan)
        #expect(stubRegistry([.zoom]).defaultToolID == .zoom)
    }

    /// 0009 *Acceptance*: the standard registry starts on the Paintbrush (D-35), B's group
    /// is just the Paintbrush today, and a fresh dispatcher starts there with no previous
    /// tool.
    @Test func defaultToolIsPaintbrush() {
        let registry = ToolRegistry.standard()
        #expect(registry.defaultToolID == .paintbrush)
        #expect(registry.implementedIDs.contains(.paintbrush))
        #expect(registry.shortcutGroup(for: "b") == [.paintbrush])
        let dispatcher = ToolDispatcher(registry: registry)
        #expect(dispatcher.activeToolID == .paintbrush)
        #expect(dispatcher.previousToolID == nil)
    }
}
