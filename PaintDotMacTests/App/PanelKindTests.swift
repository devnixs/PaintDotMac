import AppKit
import Foundation
import Testing
@testable import PaintDotMac

/// Panel metadata (spec 0006 *Test plan*): titles, ⌥⌘1–4 key equivalents, persistence
/// names under the `panel.` prefix, and the Paint.NET default frames.
@MainActor
struct PanelKindTests {
    @Test func titlesAndOrder() {
        #expect(PanelKind.allCases == [.tools, .history, .layers, .colors])
        #expect(PanelKind.tools.title == "Tools")
        #expect(PanelKind.history.title == "History")
        #expect(PanelKind.layers.title == "Layers")
        #expect(PanelKind.colors.title == "Colors")
    }

    @Test func keyEquivalents() {
        #expect(PanelKind.tools.menuKeyEquivalent == "1")
        #expect(PanelKind.history.menuKeyEquivalent == "2")
        #expect(PanelKind.layers.menuKeyEquivalent == "3")
        #expect(PanelKind.colors.menuKeyEquivalent == "4")
        #expect(PanelKind.menuKeyEquivalentModifiers == [.command, .option])
    }

    @Test func persistenceNames() {
        #expect(PanelKind.tools.frameAutosaveName == "panel.tools")
        #expect(PanelKind.history.frameAutosaveName == "panel.history")
        #expect(PanelKind.layers.frameAutosaveName == "panel.layers")
        #expect(PanelKind.colors.frameAutosaveName == "panel.colors")
        #expect(PanelKind.tools.visibilityDefaultsKey == "panel.tools.visible")
        #expect(PanelKind.colors.visibilityDefaultsKey == "panel.colors.visible")
        for kind in PanelKind.allCases {
            #expect(kind.frameAutosaveName.hasPrefix("panel."))
            #expect(kind.visibilityDefaultsKey.hasPrefix("panel."))
        }
    }

    @Test func identifiers() {
        #expect(PanelKind.tools.accessibilityIdentifier == "toolsPanel")
        #expect(PanelKind.history.accessibilityIdentifier == "historyPanel")
        #expect(PanelKind.layers.accessibilityIdentifier == "layersPanel")
        #expect(PanelKind.colors.accessibilityIdentifier == "colorsPanel")
        for kind in PanelKind.allCases {
            #expect(kind.menuItemIdentifier.rawValue == "menu.window.panel.\(kind.rawValue)")
        }
    }

    @Test func panelWindowIdentifierRecognition() {
        #expect(PanelKind.isPanelWindowIdentifier(NSUserInterfaceItemIdentifier("panel.tools")))
        #expect(!PanelKind.isPanelWindowIdentifier(DocumentWindowController.windowIdentifier))
        #expect(!PanelKind.isPanelWindowIdentifier(nil))
    }

    @Test func onlyToolsIsNonResizable() {
        #expect(!PanelKind.tools.isResizable)
        #expect(PanelKind.history.isResizable)
        #expect(PanelKind.layers.isResizable)
        #expect(PanelKind.colors.isResizable)
    }

    // MARK: - Default frames (hand-computed, spec 0006)

    @Test func defaultFramesMainScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        #expect(PanelKind.defaultFrame(for: .tools, size: CGSize(width: 76, height: 120),
                                       visibleFrame: visible)
                    == CGRect(x: 16, y: 764, width: 76, height: 120))
        #expect(PanelKind.defaultFrame(for: .history, size: CGSize(width: 220, height: 260),
                                       visibleFrame: visible)
                    == CGRect(x: 1204, y: 624, width: 220, height: 260))
        #expect(PanelKind.defaultFrame(for: .layers, size: CGSize(width: 220, height: 260),
                                       visibleFrame: visible)
                    == CGRect(x: 1204, y: 41, width: 220, height: 260))
        #expect(PanelKind.defaultFrame(for: .colors, size: CGSize(width: 220, height: 260),
                                       visibleFrame: visible)
                    == CGRect(x: 16, y: 41, width: 220, height: 260))
    }

    @Test func defaultFramesSecondaryScreenLeftOfMain() {
        let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(PanelKind.defaultFrame(for: .tools, size: CGSize(width: 100, height: 100),
                                       visibleFrame: visible)
                    == CGRect(x: -1904, y: 964, width: 100, height: 100))
    }
}
