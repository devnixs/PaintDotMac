import AppKit

/// The E-6 expand prompt's decision seam (spec 0021 item 7; PRD E-6). `completion` runs
/// with the user's answer; `nil` means Cancel — nothing happens, the clipboard is
/// untouched. A `nil` presenter means "no prompt available" and behaves like Cancel.
/// Headless tests install `ScriptedPasteExpandPrompt` or nil, so no sheet ever shows
/// (AGENTS.md *Headless testing*).
@MainActor
protocol PasteExpandPrompting {
    func choose(completion: @escaping (PasteCanvasChoice?) -> Void)
}

/// The real E-6 prompt: the three-button alert as a window sheet (Paint.NET's
/// "The image is too large for the canvas. Do you want to expand the canvas to fit it?").
/// Return = "Expand canvas" (default button), Escape = "Cancel".
@MainActor
final class ModalPasteExpandPrompt: PasteExpandPrompting {
    private let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func choose(completion: @escaping (PasteCanvasChoice?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "The image being pasted is larger than the canvas."
        alert.informativeText = "Do you want to expand the canvas to fit it?"
        let expand = alert.addButton(withTitle: "Expand canvas")
        let keep = alert.addButton(withTitle: "Keep canvas size")
        let cancel = alert.addButton(withTitle: "Cancel")
        expand.setAccessibilityIdentifier("pasteExpand.expand")
        keep.setAccessibilityIdentifier("pasteExpand.keep")
        cancel.setAccessibilityIdentifier("pasteExpand.cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.expandCanvas)
            case .alertSecondButtonReturn: completion(.keepCanvasSize)
            default: completion(nil)  // Cancel or the close box
            }
        }
    }
}
