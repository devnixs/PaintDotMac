import Foundation
import Testing
@testable import PaintDotMac

/// D-35 group cycling: 1 s window, Shift reverses, other keys reset (spec 0006 *Test plan*).
/// Timestamps are in seconds; group S is the four selection tools.
struct ToolShortcutResolverTests {
    private let groupS: [ToolID] = [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand]

    // MARK: - toolKey parsing

    @Test(arguments: [
        ("s", "s"), ("S", "s"), ("h", "h"), ("o", "o"),
    ])
    func toolKeyParsingAccepts(_ testCase: (String, Character)) {
        #expect(ToolShortcutResolver.toolKey(fromCharactersIgnoringModifiers: testCase.0) == testCase.1)
    }

    @Test(arguments: ["x", "", "ss", "1", "["])
    func toolKeyParsingRejects(_ text: String) {
        #expect(ToolShortcutResolver.toolKey(fromCharactersIgnoringModifiers: text) == nil)
    }

    // MARK: - Cycling

    @Test func firstPressSelectsFirst() {
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .pan, timestamp: 0) == .rectangleSelect)
    }

    @Test func cyclesForward() {
        var resolver = ToolShortcutResolver()
        var active = ToolID.pan
        let steps: [(TimeInterval, ToolID)] = [
            (0.0, .rectangleSelect),   // first press: group's first
            (0.5, .lassoSelect),       // 0.5 s apart: cycle
            (0.9, .ellipseSelect),
            (1.3, .magicWand),
            (1.7, .rectangleSelect),   // wraps
        ]
        for (time, expected) in steps {
            let result = resolver.resolve(key: "s", shift: false, group: groupS,
                                          activeTool: active, timestamp: time)
            #expect(result == expected, "at t=\(time) with active \(active)")
            active = result ?? active
        }
    }

    @Test func shiftStartsAtLastAndCyclesBackward() {
        var resolver = ToolShortcutResolver()
        // Paint.NET: "Magic Wand: Shift+S" — Shift with no prior cycle picks the group's last.
        #expect(resolver.resolve(key: "s", shift: true, group: groupS,
                                 activeTool: .pan, timestamp: 0) == .magicWand)
        #expect(resolver.resolve(key: "s", shift: true, group: groupS,
                                 activeTool: .magicWand, timestamp: 0.4) == .ellipseSelect)
        // Same key within the window, no Shift: cycles forward again from the active tool.
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .ellipseSelect, timestamp: 0.8) == .magicWand)
    }

    @Test func cycleWindowBoundary() {
        // 0.999 s cycles; exactly 1.0 s restarts ("less than a second apart").
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .pan, timestamp: 0) == .rectangleSelect)
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .rectangleSelect, timestamp: 0.1) == .lassoSelect)
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .lassoSelect, timestamp: 0.1 + 0.999) == .ellipseSelect)

        var restart = ToolShortcutResolver()
        #expect(restart.resolve(key: "s", shift: false, group: groupS,
                                activeTool: .pan, timestamp: 0) == .rectangleSelect)
        #expect(restart.resolve(key: "s", shift: false, group: groupS,
                                activeTool: .rectangleSelect, timestamp: 0.1) == .lassoSelect)
        #expect(restart.resolve(key: "s", shift: false, group: groupS,
                                activeTool: .lassoSelect, timestamp: 0.1 + 1.0) == .rectangleSelect)
    }

    @Test func otherKeyResetsCycle() {
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .pan, timestamp: 0) == .rectangleSelect)
        #expect(resolver.resolve(key: "m", shift: false,
                                 group: [.moveSelectedPixels, .moveSelection],
                                 activeTool: .rectangleSelect, timestamp: 0.2) == .moveSelectedPixels)
        // Within 1 s of the S press, but the last key was M → S starts fresh.
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .moveSelectedPixels, timestamp: 0.4) == .rectangleSelect)
    }

    @Test func activeOutsideGroupStartsFresh() {
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .pan, timestamp: 0) == .rectangleSelect)
        // The user clicked Pan in the panel in between — S starts the group again.
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .pan, timestamp: 0.3) == .rectangleSelect)
    }

    @Test func partialGroupCycles() {
        var resolver = ToolShortcutResolver()
        let group: [ToolID] = [.rectangleSelect, .magicWand]
        #expect(resolver.resolve(key: "s", shift: false, group: group,
                                 activeTool: .pan, timestamp: 0) == .rectangleSelect)
        #expect(resolver.resolve(key: "s", shift: false, group: group,
                                 activeTool: .rectangleSelect, timestamp: 0.3) == .magicWand)
        #expect(resolver.resolve(key: "s", shift: false, group: group,
                                 activeTool: .magicWand, timestamp: 0.6) == .rectangleSelect)
    }

    @Test func singleToolGroupStays() {
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "z", shift: false, group: [.zoom],
                                 activeTool: .zoom, timestamp: 0) == .zoom)
        #expect(resolver.resolve(key: "z", shift: false, group: [.zoom],
                                 activeTool: .zoom, timestamp: 0.2) == .zoom)
    }

    @Test func emptyGroupReturnsNil() {
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "x", shift: false, group: [],
                                 activeTool: .pan, timestamp: 0) == nil)
    }

    /// Caps Lock or Shift producing "S" must not by itself mean Shift — direction comes from
    /// the `shift` flag only (`toolKey` already lowercases).
    @Test func capsLockIsNotShift() {
        let key = ToolShortcutResolver.toolKey(fromCharactersIgnoringModifiers: "S")
        #expect(key == "s")
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .pan, timestamp: 0) == .rectangleSelect)
        #expect(resolver.resolve(key: "s", shift: false, group: groupS,
                                 activeTool: .rectangleSelect, timestamp: 0.2) == .lassoSelect)
    }

    // MARK: - Property test

    /// Seeded round trip: `n` presses of a group's key (all inside the 1 s window, forward or
    /// backward) land back on the tool you started from.
    @Test(arguments: [UInt64(0x5EED_0006_0001)])
    func fullCycleReturnsToStart(seed: UInt64) {
        var random = SeededRandom(seed: SeededRandom.resolvedSeed(default: seed))
        for caseNumber in 0..<200 {
            let size = random.int(in: 1...4)
            let group = Array(groupS.prefix(size))
            let startIndex = random.int(in: 0...(size - 1))
            let shift = random.int(in: 0...1) == 1
            var resolver = ToolShortcutResolver()
            // Prime the cycle: a press selects something inside the group.
            var active = resolver.resolve(key: "s", shift: false, group: group,
                                          activeTool: .pan, timestamp: 0)
            // Re-anchor the active tool to the chosen start (as clicking in the panel does).
            active = group[startIndex]
            var time = 0.1
            for press in 0..<size {
                time += Double(random.int(in: 1...900)) / 1000.0  // < 1 s apart
                active = resolver.resolve(key: "s", shift: shift, group: group,
                                          activeTool: active ?? .pan, timestamp: time)
                #expect(active != nil,
                        "case \(caseNumber): press \(press) resolved nil \(random.comment)")
            }
            let failure = "case \(caseNumber): size \(size) start \(group[startIndex].rawValue) "
                + "shift \(shift) \(random.comment)"
            #expect(active == group[startIndex], "\(failure)")
        }
    }
}
