import AppKit
import Testing
@testable import PaintDotMac

@MainActor
@Suite(.serialized)
struct AppDelegateTests {
    @Test func noUntitledDocumentAndNoTerminateOnLastClose() {
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldOpenUntitledFile(NSApp) == false)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false)
        #expect(delegate.applicationSupportsSecureRestorableState(NSApp) == true)
    }
}
