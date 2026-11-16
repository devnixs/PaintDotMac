import Foundation

/// The complete undoable document state (spec 0008 Scope §1). Every history item mutates
/// only a `DocumentState` — anything that becomes undoable later is added *here*, never
/// beside it. 0013 adds `selection: Selection`; later specs add their undoable state the
/// same way.
struct DocumentState: Sendable, Equatable {
    var image: LayeredImage

    init(image: LayeredImage) {
        self.image = image
    }
}
