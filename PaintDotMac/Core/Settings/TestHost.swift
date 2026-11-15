import Foundation

/// Detects that the app is running as the test host for `PaintDotMacTests` instead of for the
/// user (PRD §4 Testing, AGENTS.md *Headless testing*). Lives in `Core` so `AppDefaults` can use
/// it; pure Foundation.
///
/// **Contract for every later spec:** while `TestHost.isActive` is true, the app never opens a
/// window, panel, sheet, or alert on its own at launch — no untitled document, no panels (0006),
/// no Settings window (0046), no crash-recovery prompt (0047), no restored windows. Code that
/// would show something at launch checks `TestHost.isActive` first.
enum TestHost {
    /// The scheme's test action sets `PAINTDOTMAC_HEADLESS_TESTS=1`; `XCTestConfigurationFilePath`
    /// is present in every hosted test run. Neither is set on a normal launch from Finder or
    /// Xcode's Run action.
    static func isActive(environment: [String: String]) -> Bool {
        environment["PAINTDOTMAC_HEADLESS_TESTS"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
    }

    static let isActive: Bool = isActive(environment: ProcessInfo.processInfo.environment)
}
