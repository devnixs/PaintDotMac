import AppKit
import Foundation
import Testing
@testable import PaintDotMac

/// Reads `Bundle.main`, which during a hosted run is the built app (spec 0001 *SmokeTests*).
struct SmokeTests {
    @Test func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.thera-engineering.paintdotmac")
    }

    @Test func minimumSystemVersion() throws {
        try #require(string("LSMinimumSystemVersion") == "15.0")
    }

    @Test func principalClass() throws {
        try #require(string("NSPrincipalClass") == "NSApplication")
    }

    @Test func notSandboxed() {
        #expect(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil)
    }

    @Test func documentTypesMapPNGAndJPEGToPaintDocument() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let entries = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(entries.count == 2)

        let contentTypes = entries.map { $0["LSItemContentTypes"] as? [String] }
        #expect(contentTypes == [["public.png"], ["public.jpeg"]])

        for entry in entries {
            #expect(entry["CFBundleTypeRole"] as? String == "Viewer")
            #expect(entry["LSHandlerRank"] as? String == "Alternate")
            let className = try #require(entry["NSDocumentClass"] as? String)
            // Proves the $(PRODUCT_MODULE_NAME) expansion worked and resolves to our class.
            #expect(NSClassFromString(className) === (PaintDocument.self as AnyClass))
        }
    }

    private func string(_ key: String) throws -> String {
        try #require(Bundle.main.infoDictionary?[key] as? String, "Info.plist has no \(key)")
    }
}
