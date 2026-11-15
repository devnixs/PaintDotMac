import AppKit
import Foundation

@testable import PaintDotMac

/// A `NewImagePresenting` that replays a script instead of showing a dialog: each `.edit`
/// rewrites fields the way typing would, `.ok` calls `onOK` with the current form and records
/// its result (an accepted OK ends the "session"), and `.cancel` ends it immediately.
/// Nothing is ever shown (AGENTS.md *Headless testing*).
@MainActor
final class ScriptedNewImagePresenter: NewImagePresenting {
    enum Step {
        case edit(width: String? = nil, height: String? = nil, resolution: String? = nil)
        case ok
        case cancel
    }

    /// Every form the presenter was opened with, in order.
    private(set) var presentedForms: [NewImageForm] = []
    /// The form passed to `onOK` at each OK press.
    private(set) var okForms: [NewImageForm] = []
    /// What each `onOK` returned.
    private(set) var okResults: [Bool] = []

    let steps: [Step]

    init(steps: [Step] = [.ok]) {
        self.steps = steps
    }

    func present(form: NewImageForm, onOK: @escaping (NewImageForm) -> Bool) -> Bool {
        presentedForms.append(form)
        var current = form
        for step in steps {
            switch step {
            case .edit(let width, let height, let resolution):
                if let width { current.widthText = width }
                if let height { current.heightText = height }
                if let resolution { current.resolutionText = resolution }
            case .ok:
                okForms.append(current)
                let accepted = onOK(current)
                okResults.append(accepted)
                if accepted { return true }
            case .cancel:
                return false
            }
        }
        // The script ran out without an accepted OK: the dialog was never confirmed.
        return false
    }
}

/// An `AlertPresenting` that records alerts instead of showing a modal `NSAlert`.
@MainActor
final class RecordingAlertPresenter: AlertPresenting {
    struct Alert: Equatable {
        let message: String
        let informativeText: String?
    }

    private(set) var alerts: [Alert] = []

    func showAlert(message: String, informativeText: String?) {
        alerts.append(Alert(message: message, informativeText: informativeText))
    }
}
