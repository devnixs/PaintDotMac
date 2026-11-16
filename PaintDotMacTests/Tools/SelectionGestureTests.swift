import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// `SelectionGesture` (spec 0014 *Test plan*): the floor-to-pixel rule, Paint.NET's finish
/// truth table, the sticky per-pixel `hasMoved`, and the non-finite guards.
struct SelectionGestureTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: t)
    }

    @Test func pixelFloors() {
        #expect(SelectionGesture.pixel(for: CGPoint(x: 3.99, y: 0.0)) == PixelPoint(x: 3, y: 0))
        #expect(SelectionGesture.pixel(for: CGPoint(x: -0.5, y: -0.01)) == PixelPoint(x: -1, y: -1))
        #expect(SelectionGesture.pixel(for: CGPoint(x: CGFloat.nan, y: 5)) == nil)
        #expect(SelectionGesture.pixel(for: CGPoint(x: 5, y: CGFloat.infinity)) == nil)
        #expect(SelectionGesture.pixel(for: CGPoint(x: 2e9, y: 0)) == nil)
        #expect(SelectionGesture.pixel(for: CGPoint(x: -1e9 - 1, y: 0)) == nil)
    }

    @Test func outcomeTable() {
        // All 2 × 2 × 2 × 2 of (replace/union, hasMoved, duration, empty).
        for mode in [SelectionCombineMode.replace, .union] {
            for moved in [false, true] {
                for duration in [0.03, 0.2] {
                    for empty in [false, true] {
                        let outcome = SelectionGesture.outcome(
                            mode: mode, hasMoved: moved, duration: duration,
                            shapeIsEmpty: empty)
                        if mode == .replace {
                            #expect(outcome == (moved && duration > 0.05 && !empty ? .emit : .clear),
                                    "replace moved=\(moved) t=\(duration) empty=\(empty)")
                        } else {
                            #expect(outcome == (!moved || empty ? .reset : .emit),
                                    "union moved=\(moved) t=\(duration) empty=\(empty)")
                        }
                    }
                }
            }
        }
        // Boundary: a held time of exactly 50 ms is still "too quick" for Replace.
        #expect(SelectionGesture.outcome(mode: .replace, hasMoved: true, duration: 0.05,
                                         shapeIsEmpty: false) == .clear)
        // The append modes behave like Union regardless of duration.
        for mode in [SelectionCombineMode.exclude, .intersect, .xor] {
            #expect(SelectionGesture.outcome(mode: mode, hasMoved: false, duration: 0.2,
                                             shapeIsEmpty: false) == .reset)
            #expect(SelectionGesture.outcome(mode: mode, hasMoved: true, duration: 0.03,
                                             shapeIsEmpty: false) == .emit)
            #expect(SelectionGesture.outcome(mode: mode, hasMoved: true, duration: 0.2,
                                             shapeIsEmpty: true) == .reset)
        }
    }

    @Test func hasMovedIsSticky() throws {
        // Sub-pixel jitter inside the anchor pixel is still a click (D-44c); leaving the
        // pixel moves the drag, and coming back does not un-move it.
        var gesture = try #require(SelectionGesture(event: event(10.1, 10.1, 1.0),
                                                    pickerMode: .replace))
        gesture.update(with: event(10.9, 10.8, 1.01))
        #expect(!gesture.hasMoved)
        gesture.update(with: event(11.0, 10.5, 1.02))
        #expect(gesture.hasMoved)
        gesture.update(with: event(10.2, 10.2, 1.03))
        #expect(gesture.hasMoved, "sticky once the pointer left the anchor pixel")
        #expect(gesture.currentPixel == PixelPoint(x: 10, y: 10))
    }

    @Test func nonFiniteAndHugeLocations() throws {
        #expect(SelectionGesture(event: event(.nan, 3, 1.0), pickerMode: .replace) == nil)
        var gesture = try #require(SelectionGesture(event: event(5, 5, 1.0),
                                                    pickerMode: .replace))
        gesture.update(with: event(.nan, 5, 1.1))
        #expect(gesture.currentPixel == PixelPoint(x: 5, y: 5), "non-finite updates are dropped")
        gesture.update(with: event(1e300, 5, 1.2))
        #expect(gesture.currentPixel == PixelPoint(x: 5, y: 5), "enormous updates are dropped")
        #expect(!gesture.hasMoved)
    }
}
