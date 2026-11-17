import Foundation

/// The icon identity of a history step (PRD H-1). Core holds no image names or SF Symbols;
/// 0010 maps these cases to symbols in `UI/HistoryIcon+Symbol.swift`. Every tool case's raw
/// value is the matching `ToolID` raw value (0006); `colorPicker`, `zoom`, and `pan` have no
/// case because they never record steps. Later specs add cases (and their symbols) as they
/// need them.
enum HistoryIcon: String, CaseIterable, Sendable {
    // Base steps.
    case openImage
    case newImage

    // Tools (raw value = the tool's `ToolID`).
    case rectangleSelect
    case lassoSelect
    case ellipseSelect
    case magicWand
    case moveSelectedPixels
    case moveSelection
    case paintBucket
    case gradient
    case paintbrush
    case eraser
    case pencil
    case cloneStamp
    case recolor
    case text
    case lineCurve
    case shapes

    // Commands and dialogs.
    case selectAll
    case deselect
    case invertSelection
    case eraseSelection
    case fillSelection
    case cut
    case paste
    case cropToSelection
    case resizeImage
    case resizeCanvas
    case flipRotate
    case layerAdd
    case layerDelete
    case layerDuplicate
    case layerMerge
    case layerMove
    case layerProperties
    case layerVisibility
    case flatten
    case importLayer
    case adjustment
    case effect

    /// Fallback for steps without a dedicated icon.
    case generic
}
