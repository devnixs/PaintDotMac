import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// Shared selection-tool options (spec 0014 *Test plan*): the Paint.NET modifier table,
/// the exact `tool.rectangleSelect.*` keys and Paint.NET defaults, the mode/quality/clipping
/// display names, the cross-tool sharing, sanitization, and the Fixed Size unit conversion.
@MainActor
struct SelectionToolOptionsTests {
    @Test func combineModeTable() {
        // Paint.NET `SelectionTool.OnMouseDown`: Ctrl tested before Alt; right = right or
        // Control-click (0006 delivers both as `.secondary`); otherwise the picker.
        for picker in [SelectionCombineMode.replace, .intersect] {
            let rows: [(ToolMouseButton, ToolModifiers, SelectionCombineMode)] = [
                (.primary, [], picker),
                (.secondary, [], picker),
                (.secondary, [.control], picker),
                (.primary, [.command], .union),
                (.primary, [.option], .exclude),
                (.secondary, [.command], .xor),
                (.secondary, [.option], .intersect),
                (.secondary, [.command, .control], .xor),
                (.primary, [.command, .option], .union),   // ⌘ wins over ⌥
                (.secondary, [.command, .option], .xor),
                (.primary, [.shift], picker),              // Shift never changes the mode
                (.primary, [.shift, .option], .exclude),
            ]
            for (button, modifiers, expected) in rows {
                #expect(SelectionToolOptions.combineMode(picker: picker, button: button,
                                                         modifiers: modifiers) == expected,
                        "picker \(picker.rawValue) button \(button) \(modifiers)")
            }
        }
    }

    @Test func keysAndDefaults() throws {
        #expect(SelectionToolOptions.combineMode.defaultsKey == "tool.rectangleSelect.selectionMode")
        #expect(SelectionToolOptions.quality.defaultsKey == "tool.rectangleSelect.selectionQuality")
        #expect(SelectionToolOptions.drawMode.defaultsKey == "tool.rectangleSelect.drawMode")
        #expect(SelectionToolOptions.fixedWidth.defaultsKey == "tool.rectangleSelect.fixedWidth")
        #expect(SelectionToolOptions.fixedHeight.defaultsKey == "tool.rectangleSelect.fixedHeight")
        #expect(SelectionToolOptions.fixedUnit.defaultsKey == "tool.rectangleSelect.fixedUnit")

        let store = InMemoryToolOptionStore()
        #expect(store.value(SelectionToolOptions.combineMode) == .replace)
        #expect(store.value(SelectionToolOptions.quality) == .antialiased)
        #expect(store.value(SelectionToolOptions.drawMode) == .normal)
        #expect(store.value(SelectionToolOptions.fixedWidth) == 4)
        #expect(store.value(SelectionToolOptions.fixedHeight) == 3)
        #expect(store.value(SelectionToolOptions.fixedUnit) == .inches)

        // Display names — Paint.NET's, exactly (the mode names come from 0013).
        #expect([SelectionCombineMode.replace.displayName,
                 SelectionCombineMode.union.displayName,
                 SelectionCombineMode.exclude.displayName,
                 SelectionCombineMode.intersect.displayName,
                 SelectionCombineMode.xor.displayName]
                    == ["Replace", "Add (Union)", "Subtract", "Intersect", "Invert (Xor)"])
        #expect(SelectionQuality.allCases.map(\.displayName) == ["Pixelated", "Antialiased"])
        #expect(SelectionDrawMode.allCases.map(\.displayName)
                    == ["Normal", "Fixed Ratio", "Fixed Size"])
        #expect(SelectionCombineMode.replace.macModifierHint.isEmpty)
        #expect([SelectionCombineMode.union.macModifierHint,
                 SelectionCombineMode.exclude.macModifierHint,
                 SelectionCombineMode.intersect.macModifierHint,
                 SelectionCombineMode.xor.macModifierHint]
                    == ["⌘-drag", "⌥-drag", "⌥-right-drag", "⌘-right-drag"])
    }

    /// D-44d: every selection tool reads and writes the same two keys — a mode written for
    /// Rectangle Select is what an Ellipse Select gesture uses.
    @Test func sharedKeys() throws {
        let store = InMemoryToolOptionStore()
        store.setValue(SelectionCombineMode.union, for: SelectionToolOptions.combineMode)
        #expect(store.value(SelectionToolOptions.quality) == .antialiased)

        let context = FakeToolContext()
        context.memoryOptions.setValue(SelectionCombineMode.union,
                                       for: SelectionToolOptions.combineMode)
        let existing = Selection(rect: CGRect(x: 0, y: 0, width: 4, height: 4),
                                 canvasSize: context.image.size)
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: existing))
        let stepsBefore = context.history.steps.count

        let tool = EllipseSelectTool()
        func event(_ x: Double, _ y: Double, _ t: TimeInterval) -> ToolEvent {
            ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: .primary,
                      modifiers: [], clickCount: 1, pressure: 1, timestamp: t)
        }
        // A disjoint ellipse; with the stored Union picker the result keeps the old rect.
        tool.mouseDown(event(20, 20, 1.0), context: context)
        tool.mouseDragged(event(40, 40, 1.1), context: context)
        tool.mouseUp(event(40, 40, 1.2), context: context)

        #expect(context.history.steps.count == stepsBefore + 1)
        #expect(context.history.steps.last?.name == "Ellipse Select")
        let selection = try #require(context.selection)
        #expect(selection.bounds.contains(PixelPoint(x: 1, y: 1)),
                "the stored Union picker combined instead of replacing")
    }

    @Test func sanitization() {
        let store = InMemoryToolOptionStore()
        store.setStoredValue(-5.0, forKey: SelectionToolOptions.fixedWidth.defaultsKey)
        #expect(store.value(SelectionToolOptions.fixedWidth) == 0.01)
        store.setStoredValue(0.0, forKey: SelectionToolOptions.fixedHeight.defaultsKey)
        #expect(store.value(SelectionToolOptions.fixedHeight) == 0.01)
        store.setStoredValue(Double.nan, forKey: SelectionToolOptions.fixedWidth.defaultsKey)
        #expect(store.value(SelectionToolOptions.fixedWidth) == 4, "non-numeric reads default")
        store.setStoredValue("bogus", forKey: SelectionToolOptions.combineMode.defaultsKey)
        #expect(store.value(SelectionToolOptions.combineMode) == .replace)
    }

    @Test func fixedSizeInPixelsBasics() {
        #expect(SelectionToolOptions.fixedSizeInPixels(width: 100, height: 50, unit: .pixels,
                                                        dpi: 72) == PixelSize(width: 100, height: 50))
        #expect(SelectionToolOptions.fixedSizeInPixels(width: 4, height: 3, unit: .inches,
                                                        dpi: 96) == PixelSize(width: 384, height: 288))
        #expect(SelectionToolOptions.fixedSizeInPixels(width: 2.54, height: 1.27, unit: .centimeters,
                                                        dpi: 96) == PixelSize(width: 96, height: 48))
        #expect(SelectionToolOptions.fixedSizeInPixels(width: 1, height: 1, unit: .inches,
                                                        dpi: 0) == PixelSize(width: 96, height: 96),
                "DPI 0 sanitizes to 96")
        #expect(SelectionToolOptions.fixedSizeInPixels(width: 0.4, height: 0.4, unit: .pixels,
                                                        dpi: 96) == PixelSize(width: 1, height: 1),
                "minimum 1 pixel")
    }

    @Test func fixedSizeClamped() {
        #expect(SelectionToolOptions.fixedSizeInPixels(width: 1000, height: 1, unit: .inches,
                                                        dpi: 300) == PixelSize(width: 65535, height: 300),
                "clamped to the max side")
        #expect(SelectionToolOptions.fixedSizeInPixels(width: .nan, height: 1, unit: .pixels,
                                                        dpi: 96) == PixelSize(width: 1, height: 1),
                "non-finite gives 1")
    }
}
