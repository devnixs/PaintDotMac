import CoreGraphics
import Foundation

/// `CGPath` is not `Sendable` in the macOS 26 SDK; an immutable `CGPath` is thread-safe
/// (CoreGraphics documents path construction as producing an immutable, freely shareable
/// object), so the unchecked box is sound — every mutation path in the app builds a new
/// path instead.
private struct SendablePath: @unchecked Sendable {
    let path: CGPath
}

/// The selection value: a vector outline plus its cached, rasterized 8-bit antialiased
/// mask (AGENTS rule 8, PRD §7, spec 0013). The mask is normative for every pixel
/// operation; the path is for display (marching ants) and later transforms (0019).
///
/// **"No selection" is `nil`** everywhere: `DocumentState.selection == nil` means the
/// whole image is editable, no ants are drawn, and `paintClipMask` is nil. A `Selection`
/// value is never empty — every initializer and operation that would produce an all-zero
/// mask (zero-area path, path outside the canvas, `A ⊕ A`, `A ∖ A`, disjoint intersection,
/// inverting a full selection) returns `nil` instead (PRD E-3, D-40).
struct Selection: Sendable, Equatable {
    let canvasSize: PixelSize
    private let storedPath: SendablePath
    /// Canvas coordinates, normalized, clipped to the canvas rect.
    var path: CGPath { storedPath.path }
    /// Coverage used for every pixel operation; normative.
    let mask: SelectionMask
    /// 64 + 32 × path element count, counted once with `applyWithBlock` — the history
    /// byte estimate for the outline (NF-4).
    let pathByteEstimate: Int

    var bounds: PixelRect { mask.bounds }

    init?(path: CGPath, canvasSize: PixelSize, antialiased: Bool = true,
          fillRule: CGPathFillRule = .winding) {
        guard !canvasSize.isEmpty, MaskRasterizer.rectIsFinite(path.boundingBoxOfPath) else {
            return nil
        }
        let normalized = path.normalized(using: fillRule)
        guard !normalized.isEmpty else { return nil }
        let clipped = normalized.intersection(Self.canvasPath(canvasSize))
        let mask = MaskRasterizer.rasterize(clipped, size: canvasSize, antialiased: antialiased)
        guard !mask.isEmpty else { return nil }
        self.init(canvasSize: canvasSize, path: clipped, mask: mask)
    }

    init?(rect: CGRect, canvasSize: PixelSize, antialiased: Bool = true) {
        guard MaskRasterizer.rectIsFinite(rect), !canvasSize.isEmpty else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        let clipped = rect.standardized.intersection(canvas)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let path = CGPath(rect: clipped, transform: nil)
        let mask = MaskRasterizer.rasterize(path, size: canvasSize, antialiased: antialiased)
        guard !mask.isEmpty else { return nil }
        self.init(canvasSize: canvasSize, path: path, mask: mask)
    }

    /// 0016 Magic Wand: mask from `FloodFill`, outline traced by 0016. Stores the outline
    /// clipped to the canvas and the given mask unchanged.
    init?(mask: SelectionMask, outline: CGPath) {
        guard !mask.isEmpty, !mask.size.isEmpty else { return nil }
        let clipped = outline.isEmpty ? outline : outline.intersection(Self.canvasPath(mask.size))
        self.init(canvasSize: mask.size, path: clipped, mask: mask)
    }

    private init(canvasSize: PixelSize, path: CGPath, mask: SelectionMask) {
        self.canvasSize = canvasSize
        self.storedPath = SendablePath(path: path)
        self.mask = mask
        var count = 0
        path.applyWithBlock { elementPointer in
            _ = elementPointer
            count += 1
        }
        self.pathByteEstimate = 64 + 32 * count
    }

    /// "Select All": the whole canvas, `O(tiles)` with no rasterization and no byte
    /// storage. Precondition: non-empty size (images are ≥ 1×1, APP-10).
    static func all(canvasSize: PixelSize) -> Selection {
        precondition(!canvasSize.isEmpty,
                     // Programmer error: documents are ≥ 1×1 (APP-10).
                     "Select All needs a non-empty canvas size")
        return Selection(canvasSize: canvasSize, path: canvasPath(canvasSize),
                         mask: .full(size: canvasSize))
    }

    /// The ants then also run along the canvas border, as in Paint.NET. `nil` when
    /// everything was selected (inverting Select All deselects).
    func inverted() -> Selection? {
        let invertedMask = mask.inverted()
        guard !invertedMask.isEmpty else { return nil }
        // Canvas minus the outline as a nonzero-winding compound produced by the
        // CoreGraphics boolean: the ants run along both the canvas border and the hole,
        // as in Paint.NET (EditMenu.html).
        let outline = Self.canvasPath(canvasSize).subtracting(path)
        return Selection(canvasSize: canvasSize, path: outline, mask: invertedMask)
    }

    func combined(with operand: Selection?, mode: SelectionCombineMode) -> Selection? {
        Self.combine(self, operand, mode: mode, canvasSize: canvasSize)
    }

    /// Combination of two selections (or `nil` = the empty set for the algebra). The mask
    /// is the exact per-pixel algebra of the operand masks — never re-rasterized from the
    /// combined path; the path is the CoreGraphics path boolean. The mask is normative
    /// for pixels (the two can differ only in edge-pixel antialiasing). A size mismatch is
    /// a defined no-op returning `existing` (unreachable through the app).
    static func combine(_ existing: Selection?, _ operand: Selection?,
                        mode: SelectionCombineMode, canvasSize: PixelSize) -> Selection? {
        if let existing, existing.canvasSize != canvasSize { return existing }
        if let operand, operand.canvasSize != canvasSize { return existing }
        guard existing != nil || operand != nil else { return nil }
        let combinedMask = (existing?.mask ?? SelectionMask(size: canvasSize))
            .combined(with: operand?.mask ?? SelectionMask(size: canvasSize), mode: mode)
        guard !combinedMask.isEmpty else { return nil }
        let combinedPath = combinePaths(existing?.path, operand?.path, mode: mode)
        return Selection(canvasSize: canvasSize, path: combinedPath, mask: combinedMask)
    }

    static func == (lhs: Selection, rhs: Selection) -> Bool {
        lhs.canvasSize == rhs.canvasSize && lhs.mask == rhs.mask
            && CFEqual(lhs.path, rhs.path)
    }

    // MARK: - Internals

    private static func canvasPath(_ size: PixelSize) -> CGPath {
        CGPath(rect: CGRect(x: 0, y: 0, width: size.width, height: size.height),
               transform: nil)
    }

    private static func combinePaths(_ a: CGPath?, _ b: CGPath?,
                                     mode: SelectionCombineMode) -> CGPath {
        let empty = CGPath(rect: .zero, transform: nil)
        switch mode {
        case .replace:
            return b ?? empty
        case .union:
            guard let a else { return b ?? empty }
            guard let b else { return a }
            return a.union(b)
        case .exclude:
            guard let a else { return empty }
            guard let b else { return a }
            return a.subtracting(b)
        case .intersect:
            guard let a, let b else { return empty }
            return a.intersection(b)
        case .xor:
            guard let a else { return b ?? empty }
            guard let b else { return a }
            return a.symmetricDifference(b)
        }
    }
}
