import Foundation

extension HistoryIcon {
    /// The SF Symbol name for this step's History-panel row (spec 0010; PRD H-1). A plain
    /// string — Core imports no AppKit (rule 1); `HistoryPanelView` builds the `Image` and
    /// `HistoryIconSymbolTests` proves every name resolves on the supported OS. The
    /// exhaustive switch with no `default` makes a new `HistoryIcon` case fail to compile
    /// until its symbol row is added. The tool cases reuse the `ToolRegistry` descriptor
    /// symbols, so a history row and its tool button look alike.
    var symbolName: String {
        switch self {
        case .openImage: "photo"
        case .newImage: "doc.badge.plus"
        case .rectangleSelect: "rectangle.dashed"
        case .lassoSelect: "lasso"
        case .ellipseSelect: "circle.dashed"
        case .magicWand: "wand.and.stars"
        case .moveSelectedPixels: "arrow.up.and.down.and.arrow.left.and.right"
        case .moveSelection: "selection.pin.in.out"
        case .paintBucket: "drop.fill"
        case .gradient: "circle.lefthalf.filled"
        case .paintbrush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .pencil: "pencil"
        case .cloneStamp: "seal"
        case .recolor: "paintpalette"
        case .text: "textformat"
        case .lineCurve: "line.diagonal"
        case .shapes: "square.on.circle"
        case .selectAll: "square.dashed.inset.filled"
        case .deselect: "square.dashed"
        case .invertSelection: "arrow.left.arrow.right.square"
        case .eraseSelection: "delete.left"
        case .fillSelection: "square.fill"
        case .cut: "scissors"
        case .paste: "doc.on.clipboard"
        case .cropToSelection: "crop"
        case .resizeImage: "arrow.up.left.and.arrow.down.right"
        case .resizeCanvas: "aspectratio"
        case .flipRotate: "rotate.right"
        case .layerAdd: "plus.square.on.square"
        case .layerDelete: "minus.square"
        case .layerDuplicate: "square.on.square"
        case .layerMerge: "square.stack.3d.down.right"
        case .layerMove: "arrow.up.arrow.down"
        case .layerProperties: "slider.horizontal.3"
        case .layerVisibility: "eye"
        case .flatten: "square.stack"
        case .importLayer: "square.and.arrow.down"
        case .adjustment: "slider.vertical.3"
        case .effect: "sparkles"
        case .generic: "clock.arrow.circlepath"
        }
    }
}
