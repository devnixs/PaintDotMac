import Foundation
import Testing

@testable import PaintDotMac

/// The normative 8-bit combine algebra (spec 0013 Scope §1).
struct SelectionCombineModeTests {
    @Test(.timeLimit(.minutes(1))) func exhaustiveTable() {
        // All 65,536 (a, b) pairs against the table computed inline in the test.
        for a in UInt8.min...UInt8.max {
            for b in UInt8.min...UInt8.max {
                #expect(SelectionCombineMode.replace.combine(a, b) == b, "replace (\(a),\(b))")
                #expect(SelectionCombineMode.union.combine(a, b) == Swift.max(a, b),
                        "union (\(a),\(b))")
                #expect(SelectionCombineMode.exclude.combine(a, b) == a &- Swift.min(a, b),
                        "exclude (\(a),\(b))")
                #expect(SelectionCombineMode.intersect.combine(a, b) == Swift.min(a, b),
                        "intersect (\(a),\(b))")
                #expect(SelectionCombineMode.xor.combine(a, b) == Swift.max(a, b) &- Swift.min(a, b),
                        "xor (\(a),\(b))")
            }
        }
    }

    @Test func displayNames() {
        #expect(SelectionCombineMode.allCases.map(\.displayName)
                == ["Replace", "Add (Union)", "Subtract", "Intersect", "Invert (Xor)"],
                "Paint.NET SelectionTools.html names in allCases order (0014's picker)")
    }
}
