import CoreGraphics
import Foundation

// MARK: - Shared path / point helpers (spec 0019)

extension CGPath {
    /// The path with `transform` applied; `nil` when CoreGraphics cannot (a
    /// non-invertible transform — e.g. a zero-width scale box mid-drag — yields no
    /// transformed geometry).
    func copying(using transform: CGAffineTransform) -> CGPath? {
        var transform = transform
        return copy(using: &transform)
    }
}

extension CGPoint {
    /// Both components finite. (`CGRect.isFinite` is package-level in the macOS 26 SDK
    /// and `CGPoint` has none, so components are checked directly — the same stance as
    /// `MaskRasterizer.rectIsFinite`.)
    var componentsAreFinite: Bool { x.isFinite && y.isFinite }
}

// MARK: - Handles and gestures (spec 0019; shared with 0020)

/// The eight transform nubs Paint.NET's Move tools draw around the selection frame
/// (MoveTools.html "Control Nubs"), in hit-test tie order. Coordinates are the box's
/// local (unrotated) space; angles are degrees, positive = clockwise on screen (the
/// y-down `CGAffineTransform(rotationAngle:)` sense).
enum TransformHandle: CaseIterable, Sendable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// The nub's unit position in the box: (-1,-1) (0,-1) (1,-1) (1,0) (1,1) (0,1)
    /// (-1,1) (-1,0).
    var unit: (x: Int, y: Int) {
        switch self {
        case .topLeft: (-1, -1)
        case .top: (0, -1)
        case .topRight: (1, -1)
        case .right: (1, 0)
        case .bottomRight: (1, 1)
        case .bottom: (0, 1)
        case .bottomLeft: (-1, 1)
        case .left: (-1, 0)
        }
    }

    var isCorner: Bool { unit.x != 0 && unit.y != 0 }
}

/// The gesture a pointer press starts (Paint.NET `MoveToolBase.DetermineMoveMode`).
enum TransformGesture: Sendable, Equatable {
    case translate
    case scale(TransformHandle)
    case rotate
}

/// The box the handles sit on, in local (unrotated) coordinates. `box` may be flipped
/// (`minX > maxX`) after a nub is dragged past the opposite edge; `rigid` (rotation +
/// translation only) maps local → canvas.
struct TransformBox: Sendable, Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var center: CGPoint {
        CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// The handle's position in this box: unit −1 → min, 0 → center, +1 → max per axis.
    func localPoint(for handle: TransformHandle) -> CGPoint {
        let unit = handle.unit
        return CGPoint(
            x: unit.x < 0 ? minX : unit.x > 0 ? maxX : center.x,
            y: unit.y < 0 ? minY : unit.y > 0 ? maxY : center.y
        )
    }
}

/// The outline transform state of one Move-tool context (Paint.NET's Move-tool
/// "context"): the source bounds R0, the current local box R, the rigid local → canvas
/// map, and the accumulated rotation. Pure value type — `applying` returns a new session
/// so every drag event recomputes from the mouse-down snapshot (spec 0019).
struct TransformSession: Sendable, Equatable {
    /// R0: the source outline's bounding box at session start — never flipped,
    /// width/height > 0, so the per-axis scale never divides by zero.
    let sourceBounds: TransformBox
    /// R: the current local box; may be flipped or pass through zero width.
    private(set) var box: TransformBox
    /// local → canvas, rotation + translation; identity at session start.
    private(set) var rigid: CGAffineTransform
    /// The accumulated rotation in degrees, normalized to (−180, 180].
    private(set) var angle: Double

    /// `nil` for an empty, non-finite, or non-positive-sized rect.
    init?(sourceBounds rect: CGRect) {
        let rect = rect.standardized
        guard rect.origin.componentsAreFinite, rect.size.width.isFinite,
              rect.size.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
        let box = TransformBox(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
        self.sourceBounds = box
        self.box = box
        self.rigid = .identity
        self.angle = 0
    }

    /// The source canvas → current canvas map: the per-axis box map R0 → R, then the
    /// rigid part. A flipped R gives a negative scale (a flip).
    var outlineTransform: CGAffineTransform {
        let sx = (box.maxX - box.minX) / (sourceBounds.maxX - sourceBounds.minX)
        let sy = (box.maxY - box.minY) / (sourceBounds.maxY - sourceBounds.minY)
        let boxMap = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                       tx: box.minX - sourceBounds.minX * sx,
                                       ty: box.minY - sourceBounds.minY * sy)
        return boxMap.concatenating(rigid)
    }

    /// The frame's corners in canvas space, order TL, TR, BR, BL (valid for any winding,
    /// including a flipped box).
    var canvasCorners: [CGPoint] {
        [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ].map { $0.applying(rigid) }
    }

    func canvasPosition(of handle: TransformHandle) -> CGPoint {
        box.localPoint(for: handle).applying(rigid)
    }

    /// The rotation center: the box center mapped to canvas.
    var canvasCenter: CGPoint { box.center.applying(rigid) }

    /// Non-nil exactly when `outlineTransform` is a pure integer translation — the mask
    /// can then be shifted pixel-exactly instead of re-rasterized (spec 0019).
    var integerTranslation: (dx: Int, dy: Int)? {
        let t = outlineTransform
        guard t.a.isFinite, t.b.isFinite, t.c.isFinite, t.d.isFinite,
              t.tx.isFinite, t.ty.isFinite,
              abs(t.a - 1) <= 1e-9, abs(t.b) <= 1e-9,
              abs(t.c) <= 1e-9, abs(t.d - 1) <= 1e-9 else { return nil }
        let rx = t.tx.rounded(.toNearestOrAwayFromZero)
        let ry = t.ty.rounded(.toNearestOrAwayFromZero)
        guard abs(t.tx - rx) <= 1e-9, abs(t.ty - ry) <= 1e-9,
              let dx = Int(exactly: rx), let dy = Int(exactly: ry) else { return nil }
        return (dx, dy)
    }

    /// The session after applying `gesture` from `start` to `current` (both canvas
    /// points) to *this* session — the tool calls it with the mouse-down snapshot on
    /// every drag event, so the gesture is absolute. A non-finite point leaves the
    /// session unchanged.
    func applying(_ gesture: TransformGesture, from start: CGPoint, to current: CGPoint,
                  modifiers: ToolModifiers) -> TransformSession {
        guard start.componentsAreFinite, current.componentsAreFinite else { return self }
        switch gesture {
        case .translate:
            let offset = TransformHandles.translation(from: start, to: current)
            return translatedBy(dx: offset.dx, dy: offset.dy)
        case .rotate:
            return applyingRotation(from: start, to: current, shift: modifiers.contains(.shift))
        case .scale(let handle):
            return applyingScale(handle, from: start, to: current, modifiers: modifiers)
        }
    }

    /// Paint.NET's integer document offset (`rigid = rigid · T(dx, dy)`).
    func translatedBy(dx: Int, dy: Int) -> TransformSession {
        var result = self
        result.rigid = rigid.concatenating(
            CGAffineTransform(translationX: Double(dx), y: Double(dy)))
        return result
    }

    // MARK: - Rotate

    private func applyingRotation(from start: CGPoint, to current: CGPoint,
                                  shift: Bool) -> TransformSession {
        let center = canvasCenter
        // atan2 is meaningless at the center itself: delta 0, session unchanged.
        if start == center || current == center { return self }
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let currentAngle = atan2(current.y - center.y, current.x - center.x)
        let rawDelta = Self.normalizedDegrees((currentAngle - startAngle) * 180 / .pi)
        var total = angle + rawDelta
        var delta = rawDelta
        if shift {
            // Shift snaps the *total* angle; the rigid part applies only the difference.
            total = TransformHandles.constrainAngle(total)
            delta = total - angle
        }
        var result = self
        // World-space rotation about the frame's center: the existing rigid applies
        // first, then `T(c) · R(δ) · T(−c)` (CoreGraphics applies a concatenated
        // transform after the receiver, so the rotation must be the appended part).
        result.rigid = rigid.concatenating(
            CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: delta * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y))
        result.angle = Self.normalizedDegrees(total)
        return result
    }

    /// Degrees into (−180, 180].
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value <= -180 { value += 360 }
        if value > 180 { value -= 360 }
        return value
    }

    // MARK: - Scale

    private func applyingScale(_ handle: TransformHandle, from start: CGPoint,
                               to current: CGPoint, modifiers: ToolModifiers) -> TransformSession {
        // The drag delta in the box's local axes (rotation only, no translation), so
        // grabbing a nub off-center doesn't jump.
        let inverse = rigid.inverted()   // a rotation: always invertible
        let linear = CGAffineTransform(a: inverse.a, b: inverse.b,
                                       c: inverse.c, d: inverse.d, tx: 0, ty: 0)
        let local = CGPoint(x: current.x - start.x, y: current.y - start.y).applying(linear)
        let unit = handle.unit
        let aboutCenter = modifiers.contains(.option)
        var newBox = box

        if unit.x != 0 {
            if aboutCenter {
                // The handle's edge moves by d, the opposite edge by −d: the center
                // stays put.
                if unit.x > 0 {
                    newBox.maxX += local.x
                    newBox.minX -= local.x
                } else {
                    newBox.minX += local.x
                    newBox.maxX -= local.x
                }
            } else if unit.x > 0 {
                newBox.maxX += local.x
            } else {
                newBox.minX += local.x
            }
        }
        if unit.y != 0 {
            if aboutCenter {
                if unit.y > 0 {
                    newBox.maxY += local.y
                    newBox.minY -= local.y
                } else {
                    newBox.minY += local.y
                    newBox.maxY -= local.y
                }
            } else if unit.y > 0 {
                newBox.maxY += local.y
            } else {
                newBox.minY += local.y
            }
        }

        if modifiers.contains(.shift), handle.isCorner {
            // Paint.NET `ConstrainScaling`: keep the R0 proportions of the session
            // start, `best = min(newW / liftedW, newH / liftedH)` (by magnitude, signs
            // kept so a flip survives), re-placed around the same anchor. Shift on an
            // edge nub does nothing (`allowConstrain = false`).
            let source = sourceBounds
            let sourceWidth = source.maxX - source.minX
            let sourceHeight = source.maxY - source.minY
            let sx = (newBox.maxX - newBox.minX) / sourceWidth
            let sy = (newBox.maxY - newBox.minY) / sourceHeight
            let best = min(abs(sx), abs(sy))
            let width = Self.sign(sx) * best * sourceWidth
            let height = Self.sign(sy) * best * sourceHeight
            if aboutCenter {
                let center = box.center
                newBox.minX = center.x - width / 2
                newBox.maxX = center.x + width / 2
                newBox.minY = center.y - height / 2
                newBox.maxY = center.y + height / 2
            } else if unit.x > 0 {
                newBox.maxX = box.minX + width
            } else {
                newBox.minX = box.maxX - width
            }
            if unit.y > 0 {
                newBox.maxY = box.minY + height
            } else {
                newBox.minY = box.maxY - height
            }
        }

        var result = self
        result.box = newBox
        return result
    }

    /// sign with sign(0) = +1.
    private static func sign(_ value: Double) -> Double { value < 0 ? -1 : 1 }
}

// MARK: - Handle metrics and pure helpers

enum TransformHandles {
    /// The drawn nub square side, view points.
    static let handleSize: Double = 7
    /// The nub grab radius, view points.
    static let handleHitRadius: Double = 6
    /// The rotate corridor just outside the frame edge, view points (Paint.NET 4+ docs).
    static let rotateCorridorWidth: Double = 20

    /// The gesture for a pointer press (Paint.NET `DetermineMoveMode`, in view points so
    /// the feel is the same at every zoom and backing scale): right button → rotate;
    /// else the nearest nub within `handleHitRadius` → scale (ties: `allCases` order);
    /// else inside the frame quad → translate; else within the corridor of a frame edge
    /// → rotate; else → translate.
    static func hitTest(viewPoint: CGPoint, session: TransformSession,
                        canvasToView: CGAffineTransform,
                        button: ToolMouseButton) -> TransformGesture {
        guard viewPoint.componentsAreFinite else { return .translate }
        if button == .secondary { return .rotate }
        var nearestIndex: Int?
        var nearestDistance = Double.greatestFiniteMagnitude
        for (index, handle) in TransformHandle.allCases.enumerated() {
            let position = session.canvasPosition(of: handle).applying(canvasToView)
            let distance = hypot(position.x - viewPoint.x, position.y - viewPoint.y)
            if distance <= handleHitRadius, distance < nearestDistance {
                nearestIndex = index
                nearestDistance = distance
            }
        }
        if let nearestIndex { return .scale(TransformHandle.allCases[nearestIndex]) }
        let corners = session.canvasCorners.map { $0.applying(canvasToView) }
        if pointInQuad(viewPoint, corners: corners) { return .translate }
        if distanceToQuad(viewPoint, corners: corners) <= rotateCorridorWidth { return .rotate }
        return .translate
    }

    /// The rounded integer document offset of a drag (translate): half away from zero,
    /// non-finite → (0, 0), clamped to ±1,000,000.
    static func translation(from start: CGPoint, to current: CGPoint) -> (dx: Int, dy: Int) {
        guard start.componentsAreFinite, current.componentsAreFinite else { return (0, 0) }
        return (axis(current.x - start.x), axis(current.y - start.y))
    }

    private static func axis(_ delta: Double) -> Int {
        let rounded = delta.rounded(.toNearestOrAwayFromZero)
        // Compare as Doubles first: `Int(1e300)` would trap even though it is finite.
        guard abs(rounded) <= 1_000_000 else { return rounded > 0 ? 1_000_000 : -1_000_000 }
        return Int(rounded)
    }

    /// Paint.NET's `ConstrainAngle`: the nearest multiple of 15°, ties going up, the
    /// result re-mapped into (−180, 180].
    static func constrainAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var angle = degrees
        while angle < 0 { angle += 360 }
        let whole = Int(angle)
        let lower = Double(whole / 15 * 15)
        let upper = lower + 15
        let lowerDiff = angle - lower
        let upperDiff = upper - angle
        var result = lowerDiff < upperDiff ? lower : upper
        if result > 180 { result -= 360 }
        return result
    }

    /// The arrow-key nudge (Paint.NET `OnKeyPress`): 1 px, × 10 with ⌘ (Ctrl); any other
    /// key → nil. `isRepeat` does not matter.
    static func nudge(for event: ToolKeyEvent) -> (dx: Int, dy: Int)? {
        let step = event.modifiers.contains(.command) ? 10 : 1
        switch event.key {
        case .leftArrow: return (-step, 0)
        case .rightArrow: return (step, 0)
        case .upArrow: return (0, -step)
        case .downArrow: return (0, step)
        default: return nil
        }
    }

    // MARK: - Geometry helpers

    /// Even-odd point-in-polygon over the four corners; works for any winding,
    /// including flipped and degenerate (zero-area) quads — those contain no point.
    private static func pointInQuad(_ point: CGPoint, corners: [CGPoint]) -> Bool {
        var inside = false
        var previous = corners[3]
        for current in corners {
            if (current.y > point.y) != (previous.y > point.y) {
                let xAtPoint = current.x
                    + (point.y - current.y) * (previous.x - current.x) / (previous.y - current.y)
                if point.x < xAtPoint { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    /// The distance from `point` to the quad's nearest edge segment.
    private static func distanceToQuad(_ point: CGPoint, corners: [CGPoint]) -> Double {
        var best = Double.greatestFiniteMagnitude
        var previous = corners[3]
        for current in corners {
            best = min(best, distanceToSegment(point, from: current, to: previous))
            previous = current
        }
        return best
    }

    private static func distanceToSegment(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
