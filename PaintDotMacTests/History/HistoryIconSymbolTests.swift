import AppKit
import Testing

@testable import PaintDotMac

/// Every `HistoryIcon` case maps to an SF Symbol that exists on this OS (spec 0010: the
/// History panel draws these), and the tool cases reuse the Tools panel's symbols so a
/// history row and its tool button look alike. `HistoryIcon.allCases` is `CaseIterable`
/// (0008), so a new case with no symbol row fails `HistoryIcon+Symbol.swift` at compile
/// time (exhaustive switch) and a wrong name fails here. `ToolRegistry.descriptor(for:)`
/// is `@MainActor`, so the suite runs there.
@MainActor
struct HistoryIconSymbolTests {
    @Test(arguments: HistoryIcon.allCases)
    func everyCaseHasAnExistingSymbol(icon: HistoryIcon) {
        #expect(NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)
                    != nil, "\(icon.rawValue): \(icon.symbolName)")
    }

    /// Literal spot-checks against the spec's mapping table.
    @Test func tableSpotChecks() {
        #expect(HistoryIcon.openImage.symbolName == "photo")
        #expect(HistoryIcon.newImage.symbolName == "doc.badge.plus")
        #expect(HistoryIcon.paintbrush.symbolName == "paintbrush.pointed")
        #expect(HistoryIcon.generic.symbolName == "clock.arrow.circlepath")
    }

    /// The tool cases' raw values are `ToolID` raw values (0008); their symbols must match
    /// `ToolRegistry`'s descriptors, the Tools panel's table (spec 0006).
    @Test func toolCasesMatchToolsPanel() {
        var checked = 0
        for icon in HistoryIcon.allCases {
            guard let tool = ToolID(rawValue: icon.rawValue) else { continue }
            #expect(icon.symbolName == ToolRegistry.descriptor(for: tool).symbolName,
                    "\(icon.rawValue)")
            checked += 1
        }
        #expect(checked == 16, "all 16 tool cases share the Tools panel symbols")
    }
}
