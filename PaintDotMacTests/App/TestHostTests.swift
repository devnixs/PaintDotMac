import AppKit
import Foundation
import Testing
@testable import PaintDotMac

@MainActor
@Suite(.serialized)
struct TestHostTests {
    @Test func detectsHeadlessFlag() {
        #expect(TestHost.isActive(environment: ["PAINTDOTMAC_HEADLESS_TESTS": "1"]))
    }

    @Test func detectsXCTestConfiguration() {
        #expect(TestHost.isActive(environment: ["XCTestConfigurationFilePath": "/x"]))
    }

    @Test func normalLaunchIsNotTestHost() {
        #expect(!TestHost.isActive(environment: [:]))
        #expect(!TestHost.isActive(environment: ["PAINTDOTMAC_HEADLESS_TESTS": "0"]))
    }

    /// The hosted run must use the throwaway suite, never the user's real preferences.
    @Test func defaultsAreIsolated() throws {
        let defaults = AppDefaults.shared
        #expect(defaults !== UserDefaults.standard)
        defaults.set(1, forKey: "tool.test.marker")
        defer { defaults.removeObject(forKey: "tool.test.marker") }
        #expect(UserDefaults.standard.object(forKey: "tool.test.marker") == nil)
    }

    @Test func frameAutosaveNamesArePrefixed() {
        #expect(AppDefaults.frameAutosaveName("panel.tools") == "test.panel.tools")
    }

    @Test func runningAsTestHost() throws {
        #expect(TestHost.isActive)
        // `.prohibited`: no Dock icon, never activates. The fallback `.accessory` is recorded in
        // the spec's Verification status only if it was taken; `.regular` is always wrong here.
        #expect(NSApp.activationPolicy() == .prohibited)
    }

    @Test func noWindowsAtLaunch() async {
        await TestRunGate.withLock {
            #expect(NSDocumentController.shared.documents.isEmpty)
            HeadlessAssertions.noVisibleWindows()
        }
    }
}
