import AppKit
import Foundation

/// Reflection over AppKit/SwiftUI accessibility trees for headless panel tests (0006):
/// the objects SwiftUI hosting hands out are informal `NSAccessibility` objects, reached by
/// selector. Test support only — the app never uses this.
enum AX {
    /// SwiftUI vends accessibility elements only while an accessibility client is active —
    /// exactly what the `AXEnhancedUserInterface` flag signals (VoiceOver sets it). Wrap any
    /// SwiftUI-tree read in this (the pattern proven by 0004's status-bar test).
    ///
    /// The setter goes in through the selector, like every other accessor in this file:
    /// `accessibilitySetValue(_:forAttribute:)` is a 10.10-era deprecation with no replacement
    /// for this attribute, and the build must stay warning-free.
    @MainActor
    static func withAccessibilityClient<T>(_ body: () throws -> T) rethrows -> T {
        setEnhancedUserInterface(true)
        defer { setEnhancedUserInterface(false) }
        return try body()
    }

    private static let enhancedUserInterfaceSelector = NSSelectorFromString(
        "accessibilitySetValue:forAttribute:"
    )

    @MainActor
    private static func setEnhancedUserInterface(_ enabled: Bool) {
        // AppKit answers this on every app; the guard only keeps a hypothetical future
        // removal from crashing a test run.
        guard NSApp.responds(to: enhancedUserInterfaceSelector) else { return }
        NSApp.perform(enhancedUserInterfaceSelector,
                      with: NSNumber(value: enabled),
                      with: "AXEnhancedUserInterface" as NSString)
    }

    /// Presses the button with `identifier`, releasing the (possibly SwiftUI-owned) element
    /// before the accessibility client flag flips back — element wrappers must never
    /// outlive the tree that vended them.
    @MainActor
    static func pressButton(inRoot root: NSObject, identifier target: String) -> Bool {
        withAccessibilityClient {
            guard let element = first(inRoot: root, identifier: target) else { return false }
            let pressed = press(element)
            withExtendedLifetime(element) {}
            return pressed
        }
    }

    /// Whether the element with `identifier` carries the selected trait (element released
    /// inside the client scope, as in `pressButton`).
    @MainActor
    static func isSelected(inRoot root: NSObject, identifier target: String) -> Bool {
        withAccessibilityClient {
            let selected = first(inRoot: root, identifier: target).map(isSelected) ?? false
            return selected
        }
    }

    /// Depth-first walk of the accessibility tree rooted at `root`.
    static func walk(_ root: NSObject, _ visit: (NSObject) -> Void) {
        var seen = Set<ObjectIdentifier>()
        func step(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            visit(object)
            for child in children(of: object) { step(child) }
        }
        step(root)
    }

    static func children(of object: NSObject) -> [NSObject] {
        array(object, "accessibilityChildren")
    }

    static func identifier(of object: NSObject) -> String? {
        string(object, "accessibilityIdentifier")
    }

    static func role(of object: NSObject) -> String? {
        string(object, "accessibilityRole")
    }

    static func label(of object: NSObject) -> String? {
        string(object, "accessibilityLabel")
    }

    static func value(of object: NSObject) -> String? {
        string(object, "accessibilityValue")
    }

    /// The selected trait (SwiftUI `.isSelected`).
    static func isSelected(_ object: NSObject) -> Bool {
        boolValue(object, "isSelected")
            || boolValue(object, "isAccessibilitySelected")
            || boolValue(object, "accessibilitySelected")
    }

    static func press(_ object: NSObject) -> Bool {
        boolValue(object, "accessibilityPerformPress")
    }

    static func identifiers(inRoot root: NSObject) -> Set<String> {
        var found: Set<String> = []
        walk(root) { object in
            if let identifier = identifier(of: object), !identifier.isEmpty {
                found.insert(identifier)
            }
        }
        return found
    }

    static func first(inRoot root: NSObject, identifier target: String) -> NSObject? {
        var found: NSObject?
        walk(root) { object in
            if found == nil, identifier(of: object) == target { found = object }
        }
        return found
    }

    /// Any element whose label, title, or value is `text` (the placeholder's merged
    /// `Text` element does not advertise the plain static-text role).
    static func containsStaticText(inRoot root: NSObject, _ text: String) -> Bool {
        var found = false
        walk(root) { object in
            if label(of: object) == text || value(of: object) == text
                || string(object, "accessibilityTitle") == text {
                found = true
            }
        }
        return found
    }

    // MARK: - Selector invocation (informal `NSAccessibility` accessors)

    /// The accessor call itself goes through `perform` — SwiftUI's internal accessibility
    /// nodes answer the AppKit selectors dynamically (the pattern proven by 0004's
    /// `ZoomPanStatusBarIntegrationTests`).
    private static func a11yValue(_ object: NSObject, _ selectorName: String) -> Any? {
        let selector = Selector(selectorName)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func string(_ object: NSObject, _ selectorName: String) -> String? {
        a11yValue(object, selectorName) as? String
    }

    private static func array(_ object: NSObject, _ selectorName: String) -> [NSObject] {
        (a11yValue(object, selectorName) as? [Any])?.compactMap { $0 as? NSObject } ?? []
    }

    /// Accessors returning `BOOL` (first argument is the receiver, second the selector).
    private static func boolValue(_ object: NSObject, _ selectorName: String) -> Bool {
        let selector = Selector(selectorName)
        guard object.responds(to: selector), let implementation = object.method(for: selector)
        else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(implementation, to: Function.self)(object, selector).boolValue
    }
}

/// Lets SwiftUI hosting views process queued updates (selection highlights, values) between
/// synthesized actions and assertions.
@MainActor
func pumpMainRunLoop(for seconds: TimeInterval = 0.3) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}
