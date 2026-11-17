import AppKit

/// The transform frame, nubs, live outline, and rotation-center marker of the Move tools
/// (spec 0019; extended by 0020 for its pixel transform UI), drawn by `ToolOverlayView`.
/// Everything maps through `transform.canvasToViewAffine` — never a Y flip inline
/// (CAN-6).
@MainActor
enum TransformHandlesOverlay {
    static func draw(_ preview: TransformHandlesPreview, transform: CanvasTransform,
                     in ctx: CGContext) {
        let affine = transform.canvasToViewAffine
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineJoin(.miter)

        // The live outline while dragging: the static marching-ants style (0013's
        // constants) — a 1 pt white line under a 1 pt black line dashed [4, 4].
        if let outline = preview.outline, let viewPath = outline.copying(using: affine) {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.addPath(viewPath)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(MarchingAnts.lineWidth)
            ctx.strokePath()

            ctx.addPath(viewPath)
            ctx.setLineDash(phase: 0, lengths: MarchingAnts.dashPattern)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // The frame: a 1 pt line, 50 % black over 50 % white, solid.
        let corners = preview.corners.map { $0.applying(affine) }
        addQuad(corners, to: ctx)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.strokePath()
        addQuad(corners, to: ctx)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.strokePath()

        guard preview.showsHandles else { return }

        // The eight nubs, `TransformHandles.handleSize` squares in view space at the
        // frame's corners (circles, as Paint.NET draws corner nubs) and edge midpoints
        // (squares): white fill, 1 pt black stroke.
        let side = TransformHandles.handleSize
        let positions = nubPositions(corners: corners)
        for (index, position) in positions.enumerated() {
            let isCornerIndex = index == 0 || index == 2 || index == 4 || index == 6
            let rect = CGRect(x: position.x - side / 2, y: position.y - side / 2,
                              width: side, height: side)
            let path = isCornerIndex
                ? CGPath(ellipseIn: rect, transform: nil)
                : CGPath(rect: rect, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // The rotation-center marker: a 10 pt circle with a cross, same stroke.
        if let center = preview.center {
            let point = center.applying(affine)
            let radius: CGFloat = 5
            ctx.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                      width: radius * 2, height: radius * 2))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                      width: radius * 2, height: radius * 2))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: point.x - radius, y: point.y))
            ctx.addLine(to: CGPoint(x: point.x + radius, y: point.y))
            ctx.move(to: CGPoint(x: point.x, y: point.y - radius))
            ctx.addLine(to: CGPoint(x: point.x, y: point.y + radius))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.strokePath()
        }
    }

    private static func addQuad(_ corners: [CGPoint], to ctx: CGContext) {
        guard corners.count == 4 else { return }
        ctx.move(to: corners[0])
        ctx.addLine(to: corners[1])
        ctx.addLine(to: corners[2])
        ctx.addLine(to: corners[3])
        ctx.closePath()
    }

    /// The 8 nub positions in view space: the frame's corners and edge midpoints, in
    /// `TransformHandle.allCases` order (TL, T, TR, R, BR, B, BL, L).
    private static func nubPositions(corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return [] }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        return [
            corners[0],
            midpoint(corners[0], corners[1]),
            corners[1],
            midpoint(corners[1], corners[2]),
            corners[2],
            midpoint(corners[2], corners[3]),
            corners[3],
            midpoint(corners[3], corners[0]),
        ]
    }
}
