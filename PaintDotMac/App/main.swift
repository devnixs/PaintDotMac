import AppKit

// `NSApplication.delegate` is weak; this file-level constant keeps the delegate alive for the
// lifetime of the process.
let appDelegate = AppDelegate()

let application = NSApplication.shared
application.delegate = appDelegate
if TestHost.isActive {
    // Windowless test-host mode (AGENTS.md *Headless testing*): no Dock icon, never activates,
    // no windows on screen.
    application.setActivationPolicy(.prohibited)
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
