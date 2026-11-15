import Testing
@testable import PaintDotMac

@Suite(.serialized)
struct SpacePanStateTests {
    @Test func basicPan() {
        var state = SpacePanState()
        #expect(state.phase == .idle)
        #expect(state.cursor == .none)

        state.spaceDown(isRepeat: false)
        #expect(state.phase == .armed)
        #expect(state.cursor == .openHand)

        #expect(state.mouseDown() == true)
        #expect(state.phase == .panning)
        #expect(state.cursor == .closedHand)
        #expect(state.isPanning)

        state.mouseUp()  // Space still held
        #expect(state.phase == .armed)
        #expect(state.cursor == .openHand)

        state.spaceUp()
        #expect(state.phase == .idle)
        #expect(state.cursor == .none)
    }

    @Test func releaseSpaceMidDrag() {
        var state = SpacePanState()
        state.spaceDown(isRepeat: false)
        #expect(state.mouseDown() == true)
        state.spaceUp()
        #expect(state.phase == .panningSpaceReleased)
        #expect(state.isPanning)
        #expect(state.cursor == .closedHand)
        state.mouseUp()
        #expect(state.phase == .idle)
    }

    @Test func mouseDownWithoutSpace() {
        var state = SpacePanState()
        #expect(state.mouseDown() == false)
        #expect(state.phase == .idle)
    }

    @Test func autorepeatIgnored() {
        var state = SpacePanState()
        state.spaceDown(isRepeat: true)
        #expect(state.phase == .idle)
        state.spaceDown(isRepeat: false)
        state.spaceDown(isRepeat: true)
        #expect(state.phase == .armed)
    }

    @Test func spaceDuringPanIgnored() {
        var state = SpacePanState()
        state.spaceDown(isRepeat: false)
        _ = state.mouseDown()
        state.spaceDown(isRepeat: false)
        #expect(state.phase == .panning)
    }

    @Test func resetFromAnyPhase() {
        var idle = SpacePanState()
        idle.reset()
        #expect(idle.phase == .idle)

        var armed = SpacePanState()
        armed.spaceDown(isRepeat: false)
        armed.reset()
        #expect(armed.phase == .idle)

        var panning = SpacePanState()
        panning.spaceDown(isRepeat: false)
        _ = panning.mouseDown()
        panning.reset()
        #expect(panning.phase == .idle)

        var released = SpacePanState()
        released.spaceDown(isRepeat: false)
        _ = released.mouseDown()
        released.spaceUp()
        #expect(released.phase == .panningSpaceReleased)  // sanity: the phase is reachable
        released.reset()
        #expect(released.phase == .idle)
    }
}
