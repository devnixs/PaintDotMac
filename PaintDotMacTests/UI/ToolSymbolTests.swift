import AppKit
import Testing
@testable import PaintDotMac

/// Every `ToolDescriptor.symbolName` resolves as an SF Symbol on this OS (spec 0006
/// *Test plan* — the Tools panel and options bar draw these).
struct ToolSymbolTests {
    @Test(arguments: ToolRegistry.allDescriptors)
    func symbolResolves(descriptor: ToolDescriptor) {
        #expect(NSImage(systemSymbolName: descriptor.symbolName, accessibilityDescription: nil)
                    != nil, "\(descriptor.id.rawValue): \(descriptor.symbolName)")
    }
}
