# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## Project
**PaintDotMac** is a native macOS raster image editor inspired by Paint.NET. It is a personal learning project.
The full requirements are in [`PRD.md`](./PRD.md). Read it before starting any feature work, and cite requirement IDs (for example `T-11`, `ADJ-4`) in commits and pull requests.

## Tech stack
- **Swift 6** with strict concurrency checking enabled.
- **AppKit app lifecycle**: `NSApplication` with an app delegate, `NSDocumentController`, an `NSDocument` subclass with one `NSWindowController` per document, the AppKit main menu, floating `NSPanel`s, `NSPasteboard`, and an `MTKView` canvas for precise mouse and tablet events.
- **SwiftUI** for the panel contents, the tool options bar, the status bar, dialogs, and the Settings window, hosted in `NSHostingView`/`NSHostingController`. Don't use the SwiftUI `App`/`DocumentGroup` lifecycle.
- **Metal** for on-screen canvas compositing and custom kernels. **Core Image** (Metal-backed `CIContext`) for adjustments and effects where it fits. A deterministic CPU compositor in `Core` is the reference used for export, flatten, merge, and Copy Merged (PRD §4).
- **ImageIO** for codecs. **OpenRaster (`.ora`)** is the native layered format; its ZIP container is our own code in `Core/IO` (no ZIP dependency).
- Minimum target: **macOS 15**. Built with Xcode 26. Primary hardware: Apple Silicon.
- **XcodeGen**: `project.yml` is the source of truth. The generated `PaintDotMac.xcodeproj` is git-ignored; never hand-edit `project.pbxproj`. Run `xcodegen generate` after adding or removing files or targets. Scheme `PaintDotMac`; targets `PaintDotMac`, `PaintDotMacTests`, `PaintDotMacUITests`; bundle ID `com.thera-engineering.paintdotmac`; ad hoc signing, not sandboxed.
- Tests: **Swift Testing** for unit, golden-image, and integration tests; **XCTest** only for `measure` performance tests; **XCUITest** for UI tests.
- **No third-party dependencies** without a written justification in the pull request or commit message.

## Repository layout (target)
```
PaintDotMac/
  App/         AppDelegate, main menu (Commands), panel controllers, Settings window
  UI/          SwiftUI views: Tools, Layers, History, Colors panels; ToolOptionsBar; StatusBar; effect dialogs
  Canvas/      MTKView canvas, input handling, overlays (selection ants, handles)
  Document/    NSDocument subclass, NSWindowController, autosave, read/write glue
  Core/        Pure Swift — MUST NOT import AppKit, SwiftUI, Cocoa, or UIKit
    Model/     Document, Layer, TiledSurface, Selection
    History/   HistoryStack, HistoryItem, NSUndoManager bridge
    Tools/     Tool protocol + one file per tool
    Effects/   ImageEffect protocol, parameter schema, Adjustments/, Effects/<Category>/
    Operations/ Document commands that produce HistoryItems (erase/fill selection, crop, resize, flip, layer ops, paste)
    Rendering/ CPU reference compositor, Metal compositor, blend-mode shaders (.metal), Core Image bridge
    IO/        ImageIO codecs, ZIP container, OpenRaster reader/writer
    Settings/  Typed app settings (defaults, keys)
    Shortcuts/ Keyboard shortcut table (PRD §5.12)
PaintDotMacTests/    Unit, golden-image (Golden/), and integration tests
PaintDotMacUITests/  XCUITest UI tests
project.yml          XcodeGen spec
```

## Architecture rules
1. **`Core` has no UI dependencies.** It may import `Foundation`, `CoreGraphics`, `CoreImage`, `CoreText`, `ImageIO`, `Metal`, `UniformTypeIdentifiers`, `Compression`, `simd`, and `Accelerate`, but never `AppKit`, `SwiftUI`, `Cocoa`, or `UIKit`.
2. **Every pixel change goes through history.** A tool or effect produces a `HistoryItem` that stores tile diffs. Never mutate a layer's pixels outside the history system.
3. **Tiles everywhere.** `TiledSurface` uses 256×256 tiles. Dirty-region tracking, undo diffs, and GPU uploads all work per tile.
4. **Pixel format.** Store 8-bit-per-channel sRGB RGBA, straight (non-premultiplied) alpha. Premultiply only inside the compositor. Keep the pixel format behind an abstraction so 16-bit or P3 support can be added later.
5. **Effects are data-driven.** Each adjustment or effect is one file that conforms to `ImageEffect`, declares a parameter schema, and is registered in the effects registry. Its dialog and live preview are generated from the schema. Never hand-write a dialog per effect.
6. **Tools** conform to the `Tool` protocol (`mouseDown`/`mouseDragged`/`mouseUp`, options model, `commit`/`cancel`). Store each tool's options in `UserDefaults` under the key `tool.<id>.<option>`.
7. **Concurrency.** UI and document state live on `@MainActor`. Effects and heavy pixel work run off the main actor, check `Task.isCancelled`, and report progress.
8. **Selections** are a vector path plus a cached, rasterized 8-bit antialiased mask. Painting and effects are clipped to the mask.
9. **Shortcuts** follow PRD §5.12: Ctrl → ⌘ and Alt → ⌥, macOS-reserved shortcuts win, and single-key tool shortcuts only fire when no text field has focus.

## Build and test
The Xcode project or Swift package is created in milestone M0. Until then, these commands are the intended setup:
```bash
# Build
xcodebuild -scheme PaintDotMac -destination 'platform=macOS' build

# Test
xcodebuild -scheme PaintDotMac -destination 'platform=macOS' test
```
Keep this section updated as soon as the real project exists.

## Testing expectations
- New `Core` code needs unit tests: blending math, flood fill, selection operations, resampling, and codec round-trips.
- Blend modes and effects use **golden-image tests**. Store reference PNGs in `PaintDotMacTests/Golden/`, and compare with a small per-channel tolerance (±1) to allow for GPU differences.
- An OpenRaster round-trip test must preserve layer names, order, opacity, visibility, and blend mode.
- Don't commit large binary fixtures (over 1 MB). Generate them in tests instead.

## Code style
- Follow the Swift API Design Guidelines. Use 4-space indentation.
- Prefer `struct` and value semantics in `Core`. Use classes only for identity-bearing objects (document, layer storage) and for AppKit subclasses.
- No force unwraps (`!`) outside tests, except for `IBOutlet`-style guaranteed-initialized cases, each with a comment.
- Metal shaders live in `Core/Rendering/Shaders/*.metal`, with one blend mode per function and names that match the `BlendMode` enum.
- Name user-facing strings exactly as Paint.NET does where it makes sense ("Gaussian Blur", "Move Selected Pixels"), so the app stays familiar.

## Workflow for agents
1. Find the PRD requirement(s) for the task and work milestone by milestone (PRD §8). Don't start M(n+1) features while M(n) exit criteria are unmet unless asked.
2. Keep changes small and focused. One tool, effect, or panel per change where possible.
3. Run the build and the tests before reporting a task as done. Report failures honestly, with their output.
4. When you add a tool, effect, or shortcut, update the relevant table in `PRD.md` if behavior differs from what is written there.
5. Don't add dependencies, change the minimum macOS version, or change the native file format without asking first.
6. Performance targets are in PRD §6 (NF-1 to NF-4). If a change touches the canvas, compositing, or history, say how it affects them.

## Spec workflow
Work is planned and built through specs in `docs/specs/`:
- `todo/NNNN-<slug>_TODO.md`: ready-to-build specs. Numbers are global, never reused, and in dependency order (milestone by milestone).
- `done/NNNN-<slug>_COMPLETED.md`: shipped specs, each with a *Verification status* section.

The **spec-writer** skill (`.agents/skills/spec-writer/`) writes specs from the PRD or a request without implementing them. The **spec-implementer** skill (`.agents/skills/spec-implementer/`) builds the todo queue in order: one implementer sub-agent and then one independent reviewer sub-agent per spec. It commits each spec and moves it to `done/`.

A spec is done only when the quality gate is green:
```bash
.agents/skills/spec-implementer/scripts/quality-gate.sh                          # after every spec
.agents/skills/spec-implementer/scripts/quality-gate.sh --sanitizers --release   # end of every batch
```
The gate runs a clean build with zero warnings, every unit, golden, integration, and UI test (none failed, none skipped), and launch smoke tests that open a PNG and a JPEG and check for crash reports. UI tests need Developer Mode (`sudo DevToolsSecurity -enable`) and the test runner's Accessibility permission, and take over the mouse and keyboard while they run. The sanitizer step reports a sanitizer as UNAVAILABLE when it doesn't work on this Mac (currently the case on macOS 26.6 with Xcode 26.3); no spec may depend on sanitizers to pass.

## Commits
- Conventional style: `feat(tools): add Magic Wand (T-4)`, `fix(canvas): …`, `test(core): …`. Commits that implement a spec end with the spec ID: `feat(tools): add Magic Wand (T-4) [spec 0012]`.
- The repository is initialised (no commits yet). Only commit when asked.
