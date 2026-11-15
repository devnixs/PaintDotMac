import AppKit
import Foundation

@testable import PaintDotMac

/// A private pasteboard (AGENTS.md *Headless testing*: the user's clipboard is off limits).
/// `DocumentHarness.newImage` releases it with `releaseGlobally()` after the New Image flow
/// reads it; a leaked named pasteboard would be process-local garbage either way.
func makePrivatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("PaintDotMacTests-\(UUID().uuidString)"))
}

/// Puts a generated PNG (deterministic gradient, opaque) on `pasteboard` as a clipboard
/// image, the way a screenshot or Copy would.
func writeImage(width: Int, height: Int, to pasteboard: NSPasteboard) {
    let bytes = TestImages.rgbaBytes(width: width, height: height) { x, y in
        ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: UInt8((x &+ y) % 256), alpha: 255)
    }
    let data = TestImages.encode(TestImages.cgImage(width: width, height: height, bytes: bytes), as: .png)
    pasteboard.setData(data, forType: .png)
}
