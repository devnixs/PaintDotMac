# 0001 — Create the XcodeGen project and a document app that opens PNG and JPEG images

> Source: PRD.md §5.1 APP-1; §4 (Project, Distribution, Minimum OS, Testing, UI rows); §5.11 "Saving" (`autosavesInPlace` off); §5.12 (menu shortcuts used here); §12 D-1, D-3, D-4, D-6; AGENTS.md *Tech stack*, *Build and test*, *Spec workflow*; spec-writer skill "The first spec is always the foundation".
> Milestone: M0
> Depends on: none

## Context

The repository has no application code, no Xcode project, and no `.gitignore` (only `PRD.md`, `AGENTS.md`, `CLAUDE.md`, `.agents/`, and `docs/specs/`). `AGENTS.md` *Build and test* still describes the commands as "the intended setup". The quality gate (`.agents/skills/spec-implementer/scripts/quality-gate.sh`) stops at step 1 with "no Xcode project". Every later spec builds on this one.

What this spec delivers:

- **The project** (PRD §4, D-3). `project.yml` is the source of truth for XcodeGen. It defines scheme `PaintDotMac` with targets `PaintDotMac` (app) and `PaintDotMacTests` (Swift Testing, hosted in the app), with no UI test target (all tests are headless, PRD §4 Testing). The bundle ID is `com.thera-engineering.paintdotmac`, the minimum OS is macOS 15, and the code uses Swift 6 strict concurrency. Signing is ad hoc with no team, no sandbox, and hardened runtime off. Debug builds the native architecture only and Release builds a universal binary.
- **The app shell** (PRD §4 UI row, D-4). The app uses the AppKit lifecycle: `main.swift` + `AppDelegate`, an AppKit main menu built in code, `NSDocumentController.shared`, the `PaintDocument` (`NSDocument`) subclass, and one `DocumentWindowController` per document. Don't use the SwiftUI `App`/`DocumentGroup` lifecycle.
- **APP-1:** each image opens in its own window, and native macOS window tabs work (`tabbingMode = .automatic` with a shared `tabbingIdentifier`). Windows follow the user's "Prefer tabs when opening documents" setting. *Window > Merge All Windows*, *Show Tab Bar*, and the related items work. `.automatic` is chosen over `.preferred` because APP-1 says "each image is its own window, and native window tabs are supported".
- **Read-only PNG/JPEG.** A temporary `PlaceholderImageView` displays the image. Spec 0002 replaces the decoded `CGImage` with `LayeredImage`, and 0003 replaces the placeholder with the Metal `CanvasView`. Saving starts in 0005, so in this spec the PNG/JPEG document types have the **Viewer** role and the Save items are disabled.
- **Windowless test-host mode** (PRD §4 Testing, AGENTS.md *Headless testing*). Every automated test is headless: there is no UI test target, no `-UITest*` launch hook, and no launch smoke test. The tests run hosted in the app; when the app is a test host, it never activates and never opens a window, so a test run can't disturb the user's work and a crash can't leave windows behind.
- **Headless test harness.** `FixtureFiles` writes fixture images at test time into a temp directory, and `HeadlessAssertions` checks that no window became visible. Later specs reuse both. Integration tests open documents in-process with `display: false` and build window controllers offscreen.
- **A green gate.** The default `quality-gate.sh` run (no `--sanitizers`) is the bar: clean build with zero warnings, all headless tests ran with none failed or skipped, the headless checks pass, and no crash report was written.

Environment facts the implementer must know:

- **Versions:** Xcode 26.3 (17C529), macOS 26.6.2, XcodeGen 2.46.0 at `/opt/homebrew/bin/xcodegen`, `jq` at `/usr/bin/jq`.
- **Sanitizers are UNAVAILABLE** on this Mac. Nothing in this spec may depend on `--sanitizers`.

## User story

As a Paint.NET switcher, I can open PNG and JPEG files in PaintDotMac in several ways: with File > Open, Open Recent, Finder's "Open With", or `open -a`. Each image appears in its own window, and those windows can be merged into native tabs. I see a standard Mac menu bar laid out like Paint.NET's (File, Edit, View, Window, Help). The app never crashes on a broken file; it shows an alert instead.

## Scope & changes

### Repository and project (platform/build)

- **`.gitignore`** (new, repo root). It ignores `build/`, `DerivedData/`, `*.xcodeproj`, `*.xcworkspace`, `xcuserdata/`, `*.xcresult`, `.DS_Store`, and `.swiftpm/`.
- **`project.yml`** (new, repo root). Run `xcodegen generate` after creating it. Never hand-edit `PaintDotMac.xcodeproj`.
  - `name: PaintDotMac`; `options: { deploymentTarget: { macOS: "15.0" }, createIntermediateGroups: true }`.
  - `settings.base`:
    - `SWIFT_VERSION: "6.0"`, `MACOSX_DEPLOYMENT_TARGET: "15.0"`, `MARKETING_VERSION: "0.1.0"`, `CURRENT_PROJECT_VERSION: "1"`.
    - `CODE_SIGN_IDENTITY: "-"`, `CODE_SIGN_STYLE: Manual`, `DEVELOPMENT_TEAM: ""` (ad hoc signing, D-3).
    - `ENABLE_HARDENED_RUNTIME: NO`, `ENABLE_APP_SANDBOX: NO`. Add no entitlements file.
    - `DEAD_CODE_STRIPPING: YES`, `ENABLE_USER_SCRIPT_SANDBOXING: YES`. These avoid Xcode's "recommended settings" noise.
  - `settings.configs`: `Debug: { ONLY_ACTIVE_ARCH: YES }`, `Release: { ONLY_ACTIVE_ARCH: NO }`. `ARCHS` stays at the default `$(ARCHS_STANDARD)`, which gives arm64 + x86_64 in Release.
  - Leave `SWIFT_DEFAULT_ACTOR_ISOLATION` **unset**, so the default stays `nonisolated`. Later `Core` types must not become main-actor by default, because heavy pixel work runs off the main actor (AGENTS.md rule 7). UI types are marked `@MainActor` explicitly.
  - **Target `PaintDotMac`** (`type: application`, `platform: macOS`):
    - `sources: [PaintDotMac]`, recursive, so the folders that later specs add (`Core/`, `UI/`, `Canvas/`, `.metal` shaders) are picked up automatically. Exclude `Info.plist` from the sources.
    - `PRODUCT_BUNDLE_IDENTIFIER: com.thera-engineering.paintdotmac`, `PRODUCT_NAME: PaintDotMac`.
    - `info: { path: PaintDotMac/Info.plist, properties: … }`. XcodeGen generates this file, and it is committed. Edit the properties in `project.yml`, never the plist.
      - `CFBundleName`/`CFBundleDisplayName: PaintDotMac`
      - `CFBundleExecutable: $(EXECUTABLE_NAME)` (the gate reads this key)
      - `CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)`
      - `CFBundlePackageType: APPL`
      - `CFBundleShortVersionString: $(MARKETING_VERSION)`
      - `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`
      - `LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)`
      - `NSPrincipalClass: NSApplication`
      - `LSApplicationCategoryType: public.app-category.graphics-design`
      - `NSHumanReadableCopyright: ""`
      - no `NSMainNibFile`, no `NSMainStoryboardFile`
      - `CFBundleDocumentTypes` with two entries:
        1. `CFBundleTypeName: "PNG image"`, `LSItemContentTypes: [public.png]`, `CFBundleTypeRole: Viewer`, `LSHandlerRank: Alternate`, `NSDocumentClass: $(PRODUCT_MODULE_NAME).PaintDocument`
        2. `CFBundleTypeName: "JPEG image"`, the same keys with `public.jpeg`
      - `public.png` and `public.jpeg` are system UTIs, so there are no `UTImportedTypeDeclarations` or `UTExportedTypeDeclarations`. 0005 changes PNG to `Editor`, and 0028/0029 add more types.
  - **Target `PaintDotMacTests`** (`type: bundle.unit-test`):
    - `sources: [PaintDotMacTests]`, `dependencies: [{ target: PaintDotMac }]`.
    - settings: `GENERATE_INFOPLIST_FILE: YES`, `PRODUCT_BUNDLE_IDENTIFIER: com.thera-engineering.paintdotmac.tests`, `TEST_HOST: $(BUILT_PRODUCTS_DIR)/PaintDotMac.app/Contents/MacOS/PaintDotMac`, `BUNDLE_LOADER: $(TEST_HOST)`.
    - Tests are hosted so they can `@testable import PaintDotMac` and use `NSApp`/`Bundle.main`.
  - **No UI test target.** Don't add a `bundle.ui-testing` target or a `PaintDotMacUITests/` folder; the gate fails if either exists.
  - **Scheme `PaintDotMac`**:
    - `build.targets`: `PaintDotMac: all`, `PaintDotMacTests: [test]`.
    - `run.config: Debug`.
    - `test.config: Debug` with `targets: [{ name: PaintDotMacTests, parallelizable: false }]`, `environmentVariables: { PAINTDOTMAC_HEADLESS_TESTS: "1" }`, and `commandLineArguments: { "-ApplePersistenceIgnoreState YES": true }`. The hosted test app then runs in test-host mode and never restores windows.
    - `archive.config: Release`, `profile.config: Release`, `analyze.config: Debug`.
  - The gate builds with `-destination 'platform=macOS,arch=$(uname -m)'`, so check that this destination resolves with the generated scheme.

### App (platform glue, `PaintDotMac/App/`)

- **`App/main.swift`** creates `NSApplication.shared` and assigns an `AppDelegate`. It keeps a strong reference to the delegate in a file-level `let`, because `NSApplication.delegate` is weak. If `TestHost.isActive`, it calls `NSApp.setActivationPolicy(.prohibited)` (no Dock icon, never activates, no windows on screen). It then calls `NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)` and loads no nib. If `.prohibited` stops Xcode from hosting the tests, use `.accessory` instead and record that in the Verification status; the no-window rules below still apply.
- **`Core/Settings/TestHost.swift`** contains `enum TestHost`. It is pure Foundation and lives in `Core` so `AppDefaults` can use it.
  - `static func isActive(environment: [String: String]) -> Bool` returns true when `environment["PAINTDOTMAC_HEADLESS_TESTS"] == "1"` or `environment["XCTestConfigurationFilePath"] != nil`.
  - `static let isActive: Bool = isActive(environment: ProcessInfo.processInfo.environment)`.
  - **Contract for every later spec:** when `TestHost.isActive`, the app opens no window, panel, sheet, or alert on its own at launch (no untitled document, no panels from 0006, no Settings window, no crash-recovery prompt from 0047, no restored windows). Code that would show something at launch checks `TestHost.isActive` first.
- **`Core/Settings/AppDefaults.swift`** contains `enum AppDefaults`, so tests can never change the user's real preferences (the hosted test app has the same bundle ID as the real app).
  - `static let shared: UserDefaults` is `.standard` normally. In test-host mode it is `UserDefaults(suiteName: "com.thera-engineering.paintdotmac.headless-tests")`, whose persistent domain is removed when it is first created, so every test run starts clean.
  - `static func frameAutosaveName(_ name: String) -> String` returns `name` normally and `"test." + name` in test-host mode. On first use in test-host mode, it removes every `.standard` key that starts with `NSWindow Frame test.`. AppKit always writes frame autosaves to `.standard`, so this keeps test runs away from the user's real window and panel frames.
  - **Contract for every later spec:** app code reads and writes preferences only through `AppDefaults.shared` (or an injected `UserDefaults` whose default argument is `AppDefaults.shared`), never `UserDefaults.standard`, and passes every `setFrameAutosaveName` / `frameAutosaveName` through `AppDefaults.frameAutosaveName(_:)`. Unit tests still inject their own `UserDefaults(suiteName:)`.
- **`App/AppDelegate.swift`** contains `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`.
  - `applicationWillFinishLaunching(_:)` calls `MainMenu.install(in: NSApp)`.
  - `applicationShouldOpenUntitledFile(_:) -> false`. This is permanent: the app never opens an untitled document at launch, also after the New Image dialog exists (0005), so an empty launch shows only the menu bar. New images come only from File > New (⌘N).
  - `applicationShouldTerminateAfterLastWindowClosed(_:) -> false` (the Mac document-app convention).
  - `applicationSupportsSecureRestorableState(_:) -> true`.
  - The delegate does **not** implement `application(_:open:)` or `application(_:openFiles:)`. Without them, Apple Events from Finder and `open -a` go to `NSDocumentController.shared`. Drops on the Dock icon and the app (FMT-C) are spec 0030.
- **No launch hooks.** There is no `LaunchOptions` type and no `-UITest*` argument. Tests configure the app in-process. Persisted UI state still uses the key prefixes `tool.`, `panel.` (panel autosave names start with `panel.`), `colors.`, and `settings.`, and tests that touch persistence use a throwaway `UserDefaults(suiteName:)`.
- **`App/MainMenu.swift`** contains `@MainActor enum MainMenu`.
  - `static func make() -> NSMenu` builds the whole menu bar in code. It has no side effects on `NSApp`.
  - `static func install(in app: NSApplication)` sets `app.mainMenu = make()`. It then sets `app.servicesMenu` (the Services submenu), `app.windowsMenu` (the Window menu), and `app.helpMenu` (the Help menu), finding each menu by its identifier.
  - Every top-level `NSMenuItem` has an `identifier`: `menu.app`, `menu.file`, `menu.edit`, `menu.view`, `menu.window`, `menu.help`. The Services item is `menu.app.services` and the Open Recent item is `menu.file.openRecent`.
  - **Later specs only add items.** They insert the Image, Layers, Adjustments, and Effects top-level menus, in that order, between View and Window, which is Paint.NET's order.
  - Items with a `nil` action are deliberate placeholders. AppKit auto-disables them until a later spec wires them up.
  - Every action is sent to the first responder (`target = nil`).
  - The exact contents are in this table. "—" is a separator, and key equivalents are lowercase, with the modifiers in `keyEquivalentModifierMask`:

    | Menu (title) | Item title | Key | Modifiers | Action |
    |---|---|---|---|---|
    | `PaintDotMac` (app menu) | About PaintDotMac | | | `orderFrontStandardAboutPanel(_:)` |
    | | — | | | |
    | | Settings… | `,` | ⌘ | `nil` (placeholder → 0046) |
    | | — | | | |
    | | Services ▸ (empty submenu) | | | |
    | | — | | | |
    | | Hide PaintDotMac | `h` | ⌘ | `hide(_:)` |
    | | Hide Others | `h` | ⌥⌘ | `hideOtherApplications(_:)` |
    | | Show All | | | `unhideAllApplications(_:)` |
    | | — | | | |
    | | Quit PaintDotMac | `q` | ⌘ | `terminate(_:)` |
    | `File` | New… | `n` | ⌘ | `nil` (placeholder → 0005 New Image dialog) |
    | | Open… | `o` | ⌘ | `openDocument(_:)` |
    | | Open Recent ▸ containing **Clear Menu** | | | `clearRecentDocuments(_:)` |
    | | — | | | |
    | | Close | `w` | ⌘ | `performClose(_:)` |
    | | Save | `s` | ⌘ | `saveDocument(_:)` |
    | | Save As… | `s` | ⇧⌘ | `saveDocumentAs(_:)` |
    | `Edit` | Undo | `z` | ⌘ | `undo(_:)` |
    | | Redo | `z` | ⇧⌘ | `redo(_:)` (no ⌘Y alias, D-12) |
    | | — | | | |
    | | Cut | `x` | ⌘ | `cut(_:)` |
    | | Copy | `c` | ⌘ | `copy(_:)` |
    | | Paste | `v` | ⌘ | `paste(_:)` |
    | | — | | | |
    | | Select All | `a` | ⌘ | `selectAll(_:)` |
    | `View` | Enter Full Screen | `f` | ⌃⌘ | `toggleFullScreen(_:)` |
    | `Window` | Minimize | `m` | ⌘ | `performMiniaturize(_:)` |
    | | Zoom | | | `performZoom(_:)` |
    | | — | | | |
    | | Bring All to Front | | | `arrangeInFront(_:)` |
    | `Help` | *(no items; AppKit adds the search field because it is `helpMenu`)* | | | |

  - **Open Recent:** AppKit fills the submenu automatically because it contains the `clearRecentDocuments(_:)` item.
  - **Items AppKit adds by itself:** don't add any of these by hand. AppKit inserts the tab items into the Window menu (Show Previous Tab, Show Next Tab, Move Tab to New Window, Merge All Windows) and into the View menu (Show Tab Bar, Show All Tabs). It also adds the window-tiling items and the Edit menu's dictation and emoji items. The manual check below confirms that nothing appears twice.

### Document (platform glue, `PaintDotMac/Document/`)

- **`Document/PaintDocument.swift`** contains `final class PaintDocument: NSDocument`.
  - `override class var autosavesInPlace: Bool { false }` (D-6 / §5.11 Saving).
  - `override class var readableTypes: [String] { ["public.png", "public.jpeg"] }`.
  - `override class func canConcurrentlyReadDocuments(ofType:) -> Bool { false }`, so reading happens on the main thread for now.
  - `private(set) var image: CGImage?`, the decoded image. 0002 replaces it with `LayeredImage`.
  - `var imagePixelSize: CGSize?` is the `image` width and height in pixels.
  - `override func read(from data: Data, ofType typeName: String) throws`:
    1. If `typeName` is not in `readableTypes`, throw `CocoaError(.fileReadUnknown)`.
    2. Create a `CGImageSource` from `data`. Throw `CocoaError(.fileReadCorruptFile)` if any of these hold:
       - there is no source;
       - `CGImageSourceGetCount == 0`;
       - `CGImageSourceGetStatusAtIndex(source, 0) != .statusComplete` (this catches truncated files);
       - `CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true])` returns nil;
       - the image has width or height 0.
    3. Content is decoded by sniffing, not by extension. A JPEG named `.png` opens.
    4. Color conversion, ICC handling, and size limits are 0002's job (FMT-B, APP-10).
  - `override func makeWindowControllers()` calls `addWindowController(DocumentWindowController(image:))` with the decoded image. If `image` is nil, it adds no controller. That case can't happen after a successful read.
  - `override func data(ofType:) throws -> Data` throws `CocoaError(.fileWriteUnknown)`, because writing arrives in 0005.
  - `override func validateUserInterfaceItem(_:) -> Bool` returns `false` for `saveDocument(_:)`, `saveDocumentAs(_:)`, `saveDocumentTo(_:)`, `revertDocumentToSaved(_:)`, and `duplicateDocument(_:)`, and calls `super` otherwise. 0005 removes these overrides.
- **`Document/DocumentWindowController.swift`** contains `@MainActor final class DocumentWindowController: NSWindowController`.
  - `init(image: CGImage)` builds the window in code with no nib. 0002/0003 will change the parameter to the document model. The window is configured as follows:
    - `NSWindow(contentRect:styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)`;
    - `tabbingMode = .automatic` and `tabbingIdentifier = "com.thera-engineering.paintdotmac.document"`;
    - `identifier = NSUserInterfaceItemIdentifier("documentWindow")`. Tests and later code find document windows with it, which keeps them separate from the floating panels that 0006 adds;
    - `minSize = 320×240`;
    - the content view is a `PlaceholderImageView` that fills it (autoresizing width + height).
  - `shouldCascadeWindows = true`, and the window is centered on first show.
  - The content size comes from `initialContentSize`, using the `visibleFrame` of `NSScreen.main`, or 1440×900 if there is no screen.
  - `required init?(coder:)` is marked `@available(*, unavailable)` and calls `fatalError("not used")`.
  - The window title comes from the default `NSDocument.displayName`.
  - `static func initialContentSize(imageSize: CGSize, visibleFrameSize: CGSize) -> CGSize` is pure and unit-tested. One image pixel counts as one point. It computes `maximum = (floor(visible.width × 0.8), floor(visible.height × 0.8))` and `minimum = (480, 360)`. For each axis, the result is `min(max(image, minimum), max(maximum, minimum))`.

### Canvas placeholder (platform glue + one pure helper, `PaintDotMac/Canvas/`)

- **`Canvas/PlaceholderImageView.swift`** contains `@MainActor final class PlaceholderImageView: NSView` with `init(image: CGImage)`. It is temporary and is replaced by `CanvasView` in 0003.
  - **Drawing:** it fills `bounds` with `NSColor.windowBackgroundColor` and draws the image into `imageRect`.
    - It draws through the current `CGContext`, so the view is not flipped and the image appears upright.
    - The interpolation is `.none` when the image is drawn at its pixel size and `.high` when it is scaled down.
  - **Responder:** it does not accept first responder and implements no edit actions, so Cut/Copy/Paste/Select All stay disabled.
  - **Accessibility:** `isAccessibilityElement = true`, role `.image`, identifier `"canvas"`, label `"Canvas"`, and value `"<width> × <height>"`. The value is the pixel size with U+00D7 and single spaces, for example `"64 × 48"`.
    - This is a contract. 0003's `CanvasView` must keep the `canvas` identifier and this value format, so VoiceOver and the integration tests keep working.
  - `static func imageRect(imageSize: CGSize, in bounds: CGRect) -> CGRect` is pure and unit-tested. It scales to fit and never upscales.
    - If `bounds` has width ≤ 0 or height ≤ 0, or `imageSize` has a side ≤ 0, it returns `.zero`.
    - Otherwise `scale = min(1, bounds.width / image.width, bounds.height / image.height)` and `size = image × scale`.
    - The origin is `bounds.origin + floor((bounds.size − size) / 2)`, and the size is not rounded.

### Tests and harness

- **`PaintDotMacTests/`**: the unit tests listed in the Test plan. Images for document-read tests are encoded in the test with a private helper in `PaintDocumentTests.swift` (CGContext + `CGImageDestination`). `PaintDotMacTests/Support/TestImages.swift` belongs to 0002, so don't create it here.
- **`PaintDotMacTests/Support/FixtureFiles.swift`**: `final class FixtureFiles` writes fixture files for integration tests.
  - `let directory: URL` is `FileManager.default.temporaryDirectory/PaintDotMacTests/<UUID>/`. `init() throws` creates it; `func removeAll()` deletes it (call it at the end of each test, also on failure, for example from `deinit`).
  - `func makePNG(named: String, width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> URL` draws a solid color in sRGB and writes it with `CGImageDestination`.
  - `func makeJPEG(named:width:height:rgba:) throws -> URL` does the same, writing an opaque JPEG at quality 0.9.
  - `func makeFile(named: String, contents: Data) throws -> URL` writes raw bytes, for corrupt fixtures.
- **`PaintDotMacTests/Support/HeadlessAssertions.swift`**: `@MainActor enum HeadlessAssertions`.
  - `static func noVisibleWindows(sourceLocation: SourceLocation = #_sourceLocation)` records an issue for every window in `NSApp.windows` with `isVisible == true`, naming its class and identifier.
  - `static func closeAllDocuments()` closes every document in `NSDocumentController.shared.documents` with `close()` (never through a path that can prompt) so tests don't leak documents into each other.
  - Every integration test that creates a document or window calls both at its end.
- **`PaintDotMacTests/Support/DocumentHarness.swift`**: `@MainActor final class DocumentHarness`, the in-process replacement for UI-test drivers. Later specs extend it (0003 adds canvas drags in image coordinates, 0005 adds `newImage` and `exportPNG`, 0006 adds tool keys) and write their user-story tests against it.
  - `static func open(_ url: URL) async throws -> DocumentHarness` opens through `NSDocumentController.shared.openDocument(withContentsOf:display: false)`, then calls `makeWindowControllers()`. Never `showWindows()`.
  - `let document: PaintDocument`, `var windowController: DocumentWindowController`, `var window: NSWindow` (built, never ordered on screen).
  - `func target(for action: Selector) -> AnyObject?` mirrors AppKit's action lookup without a key window: the window's first responder and its `nextResponder` chain, then the window, its controller, the document, `NSDocumentController.shared`, `NSApp`, and `NSApp.delegate`; it returns the first object that `responds(to:)` the action.
  - `func isEnabled(_ action: Selector) -> Bool` builds an `NSMenuItem` with that action and asks the target's `validateUserInterfaceItem(_:)` / `validateMenuItem(_:)` (true if the target implements neither; false if there is no target), which is what AppKit's menu auto-enabling does.
  - `func perform(_ action: Selector, sender: Any? = nil)` sends the action to `target(for:)` with `NSApp.sendAction(_:to:from:)` using that explicit target, and records an issue if there is none.
  - `func key(_ characters: String, modifiers: NSEvent.ModifierFlags = [])` synthesizes `keyDown`/`keyUp` with `NSEvent.keyEvent(…windowNumber: window.windowNumber…)` and delivers them to `window.firstResponder` (menu key equivalents are not dispatched this way; menu shortcuts are covered by the menu-table tests plus `perform`).
  - `func mouse(_ type: NSEvent.EventType, at pointInWindow: CGPoint, modifiers:, clickCount:, pressure:) -> NSEvent` builds a mouse event for this window; later specs' drag helpers use it and call the view's `mouseDown(with:)`/`mouseDragged(with:)`/`mouseUp(with:)` (or the right-mouse variants) directly.
  - `func close()` calls `document.close()`. It never goes through a path that can show a save sheet.
- **`PaintDotMacTests/App/TestHostTests.swift`** and **`PaintDotMacTests/Document/DocumentOpenIntegrationTests.swift`**: the test-host and integration tests listed in the Test plan.

### AGENTS.md (the implementer updates it in this change)

- Replace the placeholder text in *Build and test* with the real commands, and remove "The Xcode project or Swift package is created in milestone M0. Until then…". Add a note that the tests are headless (no UI tests; the hosted app runs windowless) and that the user runs the app by hand for the manual checks.

```bash
xcodegen generate                                                     # after adding/removing files or targets
xcodebuild -scheme PaintDotMac -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData build
xcodebuild -scheme PaintDotMac -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData test -only-testing:PaintDotMacTests
.agents/skills/spec-implementer/scripts/quality-gate.sh                # the final word, after every spec
```

- No PRD change. Every decision used here is already in PRD §4/§12 (headless-only testing: §4 Testing, D-3).

## Acceptance criteria

- [ ] `xcodegen generate` produces `PaintDotMac.xcodeproj` with scheme `PaintDotMac` and the targets `PaintDotMac` and `PaintDotMacTests`, and no UI test target. The scheme's test action runs `PaintDotMacTests` with `PAINTDOTMAC_HEADLESS_TESTS=1`. → the quality gate (steps 1, 2: headless checks, 4).
- [ ] `.gitignore` ignores `build/`, `*.xcodeproj`, and `DerivedData/`. `git status` after a gate run shows no build products. → manual check (`git status --porcelain` lists only source files).
- [ ] Bundle ID `com.thera-engineering.paintdotmac`, `LSMinimumSystemVersion` 15.0, principal class `NSApplication`, not sandboxed. → `SmokeTests.bundleIdentifier`, `SmokeTests.minimumSystemVersion`, `SmokeTests.principalClass`, `SmokeTests.notSandboxed`.
- [ ] PNG and JPEG document types map to `PaintDocument` with the Viewer role. → `SmokeTests.documentTypesMapPNGAndJPEGToPaintDocument`.
- [ ] Ad hoc signature, no hardened runtime. The Debug build is native-arch only and the Release build is universal. → manual (`codesign`/`lipo` commands below). The Release check runs with the end-of-batch `--release` gate.
- [ ] The app launches with no window when no document is given, and keeps running when the last window closes. → `AppDelegateTests.noUntitledDocumentAndNoTerminateOnLastClose`; the real launch → manual step 4.
- [ ] Opening a valid PNG or JPEG gives one document with one document window. Its title starts with the file's base name and its `canvas` element reports the image's pixel size. → `DocumentOpenIntegrationTests.opensPNGThroughDocumentController`, `.opensJPEGThroughDocumentController`, `PaintDocumentTests.readsPNG`, `PaintDocumentTests.readsJPEG`; on screen → manual step 4.
- [ ] A corrupt, truncated, empty, or unsupported file never crashes the app. It shows the standard "couldn’t be opened" alert and the app keeps running. → `PaintDocumentTests.rejectsGarbage`, `.rejectsTruncatedPNG`, `.rejectsEmptyData`, `.rejectsUnsupportedType`, `DocumentOpenIntegrationTests.corruptFileFailsWithoutDocument`; the alert → manual step 7.
- [ ] Two open documents can be merged into native tabs of one window (APP-1). → `DocumentWindowControllerTests.windowSupportsTabbing`, `DocumentOpenIntegrationTests.twoDocumentsShareTabbingIdentifier`; merging → manual step 5.
- [ ] File > Close (⌘W) closes the document window without a prompt (nothing is edited). → `MainMenuTests.fileMenuItems` (Close is ⌘W → `performClose:`), `DocumentOpenIntegrationTests.uneditedDocumentClosesWithoutPrompt`.
- [ ] The menu bar has exactly the menus and items in the *Scope* table, with the listed shortcuts and actions. → `MainMenuTests.*`.
- [ ] New…, Save, Save As…, Undo, and Cut/Copy/Paste are disabled while a document is open. Open… is enabled. Nothing crashes when these items are clicked or pressed. → `PaintDocumentTests.saveActionsAreDisabled`, `MainMenuTests.placeholdersHaveNoAction`; clicking them in the real app → manual step 4.
- [ ] `autosavesInPlace` is false. → `PaintDocumentTests.doesNotAutosaveInPlace`.
- [ ] Test-host mode is detected from the environment, and while the tests run the app is not activatable and shows no window. → `TestHostTests.*`; every integration test ends with `HeadlessAssertions.noVisibleWindows()`.
- [ ] No UI test target, no `-UITest*` launch hook, and no window-showing call in the tests. → the gate's headless checks.
- [ ] The window content size and the placeholder image rect follow the formulas. → `DocumentWindowControllerTests.initialContentSize*`, `PlaceholderImageViewTests.*`.
- [ ] AGENTS.md *Build and test* lists the real commands. → reviewer check.
- [ ] The quality gate (default run, no `--sanitizers`) is green: clean build with zero warnings, headless checks passed, all tests passed, none skipped, and no crash report during the run. → `quality-gate.sh`.
- [ ] The real app launches, opens a PNG and a JPEG, and stays up. → manual step 4 (the gate never launches the app).

## Edge cases

- **Empty file (0 bytes), random bytes, or a PNG truncated to half its bytes:** `read` throws `CocoaError(.fileReadCorruptFile)`, NSDocument shows its standard alert, and no window opens.
- **Unsupported type name**, for example `com.compuserve.gif` passed directly to `read`: it throws `CocoaError(.fileReadUnknown)`. In the real app the Open panel doesn't offer such files, because only PNG/JPEG are declared.
- **A JPEG whose name ends in `.png`:** it opens by content, without an error.
- **A missing file passed to `openDocument(withContentsOf:display:)`:** the completion handler gets an error and no document is added; nothing crashes.
- **The same file opened twice:** NSDocumentController brings the existing window forward instead of opening a second one (standard behavior). Don't override it.
- **Very small images (1×1):** the window opens at the 480×360 minimum, and the image draws at 1×1 pt, centered.
- **Very large images:** the window is capped at 80% of the visible screen and the image is scaled down to fit. Memory and size limits (APP-10) are 0002's job. 0001 does not test giant images.
- **Window resized smaller than the image:** the image is re-fitted. `imageRect` never returns NaN or negative sizes, and it returns `.zero` for empty bounds.
- **Test-host detection in a normal launch:** neither environment variable is set when the user launches the app from Finder or Xcode's Run action, so `TestHost.isActive` is false and the app behaves normally.
- **Clicking a placeholder item** (New…, Settings…): it is disabled because its action is nil, so clicking it does nothing.
- **Pressing ⌘S in 0001:** Save is disabled by `validateUserInterfaceItem`, so it does nothing. `data(ofType:)` throws if it is ever reached, and NSDocument presents that as an alert, not a crash.
- **State restoration:** the scheme's test action passes `-ApplePersistenceIgnoreState YES` to the hosted test app, so it never restores windows from the user's own sessions.

## Test plan

Expected values below are hand-computed from the formulas in *Scope*. Use Swift Testing (`@Suite`, `@Test`, `#expect`/`#require`) in `PaintDotMacTests`, and mark suites that touch AppKit `@MainActor`.

### Unit tests

**`PaintDotMacTests/SmokeTests.swift`** (reads `Bundle.main`, which is the host app)

- `bundleIdentifier`: `Bundle.main.bundleIdentifier == "com.thera-engineering.paintdotmac"`.
- `minimumSystemVersion`: `LSMinimumSystemVersion == "15.0"`.
- `principalClass`: `NSPrincipalClass == "NSApplication"`.
- `notSandboxed`: `ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil`.
- `documentTypesMapPNGAndJPEGToPaintDocument`: `CFBundleDocumentTypes` has exactly two entries.
  - Their `LSItemContentTypes` are `["public.png"]` and `["public.jpeg"]`.
  - Both have `CFBundleTypeRole == "Viewer"` and `LSHandlerRank == "Alternate"`.
  - `NSClassFromString(entry["NSDocumentClass"]) === PaintDocument.self`, which proves the `$(PRODUCT_MODULE_NAME)` expansion worked.

**`PaintDotMacTests/App/TestHostTests.swift`** (`@MainActor`)

- `detectsHeadlessFlag`: `TestHost.isActive(environment: ["PAINTDOTMAC_HEADLESS_TESTS": "1"]) == true`.
- `detectsXCTestConfiguration`: `isActive(environment: ["XCTestConfigurationFilePath": "/x"]) == true`.
- `normalLaunchIsNotTestHost`: `isActive(environment: [:]) == false`, and `["PAINTDOTMAC_HEADLESS_TESTS": "0"]` gives false.
- `defaultsAreIsolated`: in the hosted run, `AppDefaults.shared !== UserDefaults.standard`; writing `tool.test.marker = 1` to `AppDefaults.shared` leaves `UserDefaults.standard.object(forKey: "tool.test.marker") == nil` (remove the key afterwards).
- `frameAutosaveNamesArePrefixed`: in the hosted run, `AppDefaults.frameAutosaveName("panel.tools") == "test.panel.tools"`.
- `runningAsTestHost`: in the hosted run, `TestHost.isActive == true` and `NSApp.activationPolicy() == .prohibited` (or `.accessory` if the fallback was taken).
- `noWindowsAtLaunch`: `NSDocumentController.shared.documents.isEmpty` and `HeadlessAssertions.noVisibleWindows()` passes before any test opens anything.

**`PaintDotMacTests/App/MainMenuTests.swift`** (`@MainActor`)

- `topLevelMenusInOrder`: `MainMenu.make().items.map(\.submenu?.title)` is `["PaintDotMac", "File", "Edit", "View", "Window", "Help"]`. The identifiers are `menu.app`, `menu.file`, `menu.edit`, `menu.view`, `menu.window`, `menu.help`.
- One test per menu: `appMenuItems`, `fileMenuItems`, `editMenuItems`, `viewMenuItems`, `windowMenuItems`, `helpMenuIsEmpty`.
  - Each compares the full ordered list of `(title, keyEquivalent, keyEquivalentModifierMask ∩ [.command, .shift, .option, .control], action)` with the *Scope* table. A separator is `isSeparatorItem`.
  - Write each expected row literally in the test. For example, Redo must be `("Redo", "z", [.command, .shift], #selector(UndoManager.redo))`. If no class exposes the selector, use the `NSSelectorFromString("redo:")` form.
- `placeholdersHaveNoAction`: Settings… and New… have `action == nil`. When their target specs wire them up, those specs update this test.
- `openRecentContainsClearMenu`: the item `menu.file.openRecent` has a submenu with one item, "Clear Menu", whose action is `clearRecentDocuments:`.
- `noRedoAliasCommandY`: no item anywhere in the tree has key `y` with only ⌘.
- `noDuplicateShortcuts`: across the whole tree, no two enabled-action items share the same (key, modifiers) pair.
- `installSetsSpecialMenus`: runs against the hosted `NSApp`.
  1. Save `NSApp.mainMenu` and the other special menus, then call `MainMenu.install(in: NSApp)`.
  2. Expect `NSApp.windowsMenu?.title == "Window"`, `NSApp.helpMenu?.title == "Help"`, and `NSApp.servicesMenu` to be the Services submenu.
  3. Restore the saved menus afterwards.

**`PaintDotMacTests/App/AppDelegateTests.swift`** (`@MainActor`)

- `noUntitledDocumentAndNoTerminateOnLastClose`: for `AppDelegate()`, `applicationShouldOpenUntitledFile(NSApp) == false`, `applicationShouldTerminateAfterLastWindowClosed(NSApp) == false`, and `applicationSupportsSecureRestorableState(NSApp) == true`.

**`PaintDotMacTests/Document/PaintDocumentTests.swift`** (`@MainActor`)

The private helper `encode(width:height:rgba:type:) -> Data` draws a solid sRGB image and encodes it with `CGImageDestination`.

- `readsPNG`: read 64×48 PNG data with type `public.png`. Expect `imagePixelSize == CGSize(width: 64, height: 48)`.
- `readsJPEG`: read 40×30 JPEG data with type `public.jpeg`. Expect 40×30.
- `readsOnePixel`: a 1×1 PNG gives 1×1.
- `readsJPEGDataDeclaredAsPNG`: JPEG bytes with type `public.png` give 40×30 and no error.
- `pngPixelRoundTrip`: read a PNG made of one opaque (200, 100, 50, 255) color, then redraw `image` into an RGBA8 sRGB bitmap. The pixel at (0, 0) must be exactly (200, 100, 50, 255). This proves the decoded image is the file's content, not just its size.
- `rejectsGarbage`: `Data("not an image".utf8)` throws a `CocoaError` with code `.fileReadCorruptFile`, and `image` stays nil.
- `rejectsTruncatedPNG`: the first `count / 2` bytes of a 256×256 PNG with random-ish content throw `.fileReadCorruptFile`. Use a deterministic gradient, so IDAT spans most of the file.
- `rejectsEmptyData`: `Data()` throws `.fileReadCorruptFile`.
- `rejectsUnsupportedType`: valid PNG bytes with type `com.compuserve.gif` throw `.fileReadUnknown`.
- `doesNotAutosaveInPlace`: `PaintDocument.autosavesInPlace == false`.
- `readableTypes`: `PaintDocument.readableTypes == ["public.png", "public.jpeg"]`.
- `saveActionsAreDisabled`: after a successful read, `validateUserInterfaceItem` returns false for an `NSMenuItem` with each of `saveDocument:`, `saveDocumentAs:`, `saveDocumentTo:`, `revertDocumentToSaved:`, and `duplicateDocument:`.
- `writingThrows`: `data(ofType: "public.png")` throws `CocoaError(.fileWriteUnknown)`.
- `makeWindowControllersCreatesOneDocumentWindow`: after a read, `makeWindowControllers()` produces exactly one `DocumentWindowController`. Its window has identifier `documentWindow`, and its content view is a `PlaceholderImageView`. Close the window at the end of the test.

**`PaintDotMacTests/Document/DocumentWindowControllerTests.swift`** (`@MainActor`)

- `initialContentSizeSmallImageUsesMinimum`: image 64×48 on a 1440×900 screen gives 480×360.
- `initialContentSizeFitsMediumImage`: 800×600 on 1440×900 gives 800×600.
- `initialContentSizeCapsLargeImage`: 4000×3000 on 1440×900 gives 1152×720.
- `initialContentSizeMixedAxes`: 1000×200 on 1440×900 gives 1000×360.
- `initialContentSizeTinyScreenKeepsMinimum`: 4000×3000 on 500×400 gives 480×360.
- `windowSupportsTabbing`: `DocumentWindowController(image:)` with a 10×10 image has `tabbingMode == .automatic`, `tabbingIdentifier == "com.thera-engineering.paintdotmac.document"`, `minSize == 320×240`, and a style mask that contains `.titled`, `.closable`, `.miniaturizable`, and `.resizable`.

**`PaintDotMacTests/Canvas/PlaceholderImageViewTests.swift`** (`@MainActor`)

- `imageRectCentersWithoutUpscaling`: image 64×48 in (0, 0, 480, 360) gives (208, 156, 64, 48).
- `imageRectFloorsHalfPoints`: 64×48 in (0, 0, 481, 361) gives (208, 156, 64, 48).
- `imageRectScalesDownToFit`: 800×600 in (0, 0, 400, 400) gives (0, 50, 400, 300).
- `imageRectWideImage`: 1000×100 in (0, 0, 500, 500) gives (0, 225, 500, 50).
- `imageRectRespectsBoundsOrigin`: 64×48 in (10, 20, 480, 360) gives (218, 176, 64, 48).
- `imageRectEmptyBounds`: any image in (0, 0, 0, 100) or (0, 0, 100, 0) gives `.zero`, and the result never contains NaN.
- `imageRectZeroImage`: a 0×10 image gives `.zero`.
- `accessibilityContract`: a view with a 64×48 image has `accessibilityIdentifier() == "canvas"`, `accessibilityLabel() == "Canvas"`, `accessibilityValue() as? String == "64 × 48"`, and `isAccessibilityElement() == true`.

### Round-trip and property tests

There are no Core invariants yet. The one round trip in this spec is `pngPixelRoundTrip`: encode, then read, then check the exact pixel. Tile and undo property tests start in 0002 and 0008.

### Golden-image tests

None. Nothing is rendered yet that needs one.

### Integration tests (headless)

`PaintDocumentTests.makeWindowControllersCreatesOneDocumentWindow` goes from read to window.

**`PaintDotMacTests/Document/DocumentOpenIntegrationTests.swift`** (`@MainActor`, `.serialized`). Each test writes its fixtures with `FixtureFiles` and goes through `NSDocumentController.shared.openDocument(withContentsOf:display: false)` (directly, or through `DocumentHarness.open`), awaited with `withCheckedThrowingContinuation`. `display: false` means AppKit creates no window controller and shows nothing; the test calls `makeWindowControllers()` itself where it needs a window. Every test ends with `HeadlessAssertions.closeAllDocuments()` and `HeadlessAssertions.noVisibleWindows()`, and removes its fixtures.

- `opensPNGThroughDocumentController`: `launch-fixture.png` (64×48, opaque (200, 100, 50)).
  - The completion gives a `PaintDocument` with `imagePixelSize == 64×48`, and `NSDocumentController.shared.documents.count == 1`.
  - After `makeWindowControllers()`: one `DocumentWindowController`; its window has identifier `documentWindow`, `isVisible == false`, and a title with the prefix `launch-fixture` (don't check the extension; the Finder "show extensions" setting decides it).
  - The content view's `accessibilityValue() as? String == "64 × 48"`.
- `opensJPEGThroughDocumentController`: the same with `launch-fixture.jpg` at 40×30, expecting `"40 × 30"`.
- `corruptFileFailsWithoutDocument`: `corrupt.png` with the contents `"not an image"`. The completion gives `nil` and an error whose underlying `CocoaError` code is `.fileReadCorruptFile`; `documents` is empty. (The programmatic API doesn't present the error, so nothing appears on screen.)
- `missingFileFailsWithoutDocument`: a path in the fixture directory that doesn't exist gives an error and no document.
- `twoDocumentsShareTabbingIdentifier`: open `first.png` (30×20) and `second.jpg` (50×40). Two documents; after `makeWindowControllers()` on each, both windows have `tabbingMode == .automatic` and the same `tabbingIdentifier`, so AppKit can merge them (the merge itself → manual step 5).
- `harnessFindsDocumentActions`: through `DocumentHarness.open` on the PNG, `isEnabled(#selector(NSDocument.saveDocument(_:))) == false`, `isEnabled(#selector(NSDocument.saveDocumentAs(_:))) == false`, and `target(for: #selector(NSWindow.performClose(_:)))` is the window.
- `uneditedDocumentClosesWithoutPrompt`: open the PNG, build its window controller, check `isDocumentEdited == false`, call `close()`; `documents` is empty and no window is visible.

### Performance

Not applicable. This spec has no canvas, compositing, or history, so NF-1 to NF-4 are unaffected.

### Quality gate

Run `.agents/skills/spec-implementer/scripts/quality-gate.sh` with **no** flags. It must end with `GREEN`:

- the clean Debug build has zero warnings in our sources;
- `Test sources: headless` (no UI test target, no window-showing calls);
- `tests: N passed, 0 failed, 0 skipped` and `tests: no crash reports during the run`.

Sanitizers are not part of the bar: they are UNAVAILABLE on this Mac. The gate never launches the app; don't launch it yourself either (the user runs the manual checks).

### Manual verification

1. **The gate stays off screen.** While the gate runs, no PaintDotMac window, Dock icon, or alert appears, and no PaintDotMac process is left running afterwards (`pgrep -fl PaintDotMac.app` prints nothing).
2. **Empty launch.** Launch `build/DerivedData/Build/Products/Debug/PaintDotMac.app`: only the menu bar appears, with no window. Close nothing; the app keeps running.
3. **Signing and architectures.**
   - `codesign -dv --verbose=2 build/DerivedData/Build/Products/Debug/PaintDotMac.app` shows `Signature=adhoc`, no `TeamIdentifier`, and no `runtime` flag.
   - `lipo -archs build/DerivedData/Build/Products/Debug/PaintDotMac.app/Contents/MacOS/PaintDotMac` prints only `arm64` on Apple Silicon.
   - After the end-of-batch `--release` gate, `lipo -archs build/PaintDotMac.app/Contents/MacOS/PaintDotMac` prints `x86_64 arm64`.
4. **Finder integration.** In Finder, right-click a PNG and a JPEG > Open With > PaintDotMac. Each one opens in a window, titled with the file name, showing the image. ⌘W closes it without a prompt. In the File menu, New…, Save, and Save As… are disabled; in the Edit menu, Undo, Cut, Copy, and Paste are disabled; pressing ⌘S and ⌘N does nothing.
   - File > Open… only lets you pick PNG and JPEG files.
   - File > Open Recent lists the opened files, and "Clear Menu" empties the list.
5. **Tabs (APP-1).**
   - With System Settings > Desktop & Dock > "Prefer tabs when opening documents" at its default, two opened images are separate windows. Window > Merge All Windows makes them tabs, and View > Show Tab Bar / Show All Tabs work.
   - Set the preference to "Always": newly opened images join the existing window as tabs. Restore the preference afterwards.
6. **No duplicate menu items.** The View and Window menus contain no duplicated "Enter Full Screen", tab, or Minimize items. The Help menu shows the search field.
7. **Corrupt file from Finder.** Rename a text file to `broken.png` and open it with PaintDotMac. You get an alert that it couldn't be opened, and the app stays running.
8. **Appearance.** In both Light and Dark mode, the placeholder background follows the window background color. Full APP-7 checks are in 0049.

## Out of scope

- Converting decoded images into `LayeredImage`/`TiledSurface`, ICC/CMYK/16-bit conversion, DPI, and the APP-10 size limits: **0002**.
- The Metal canvas, zoom, checkerboard, and Retina mapping: **0003** (it replaces `PlaceholderImageView` but keeps the `canvas` accessibility identifier and value format).
- The status bar and the View menu zoom items: **0004**.
- File > New… (New Image dialog), saving PNG, Save/Save As enablement, the Editor role, and the close prompt for unsaved changes: **0005**.
- Panels, the Window menu panel toggles (⌥⌘1–4), and tool shortcuts: **0006**.
- Undo/redo behavior: **0008**. Edit menu selection and clipboard behavior: **0013**, **0018**, **0021**.
- The Image, Layers, Adjustments, and Effects menus: added by **0022/0024/0031** and others, inserted between View and Window.
- Drops on the Dock icon, the app, and windows (FMT-C): **0030**. The Settings window: **0046**. Crash-recovery autosave: **0047**. The app icon: **0050**. Formats other than PNG/JPEG: **0028/0029**.
- Shortcut table centralization: **0045**.

## Verification status

Implemented 2026-11-15 on Xcode 27.2 (27B52) / macOS 27.2 (26B118) / XcodeGen 2.46.0 (the
*Context* section's 26.x toolchain is superseded; nothing in this spec depended on the
difference beyond the notes below).

Quality gate (`quality-gate.sh`, default run, no flags) — **GREEN**:

- `Core imports: OK`; `Test sources: headless`
- `No compiler warnings.` (clean Debug build)
- `tests: 61 passed, 0 failed, 0 skipped (of 61)`
- `tests: no crash reports during the run`

Performance: not applicable (no canvas, compositing, or history in this spec).

Implementation notes (settled during the build):

- Test-host activation policy `.prohibited` works for the hosted test run; the `.accessory`
  fallback was **not** needed.
- On macOS 27 ImageIO reports `statusComplete` and returns a decodable image even for PNG/JPEG
  truncated mid-scan (verified against data-, URL-, and incremental-backed sources), so the
  spec's `CGImageSourceGetStatusAtIndex` guard alone cannot reject truncated files.
  `PaintDotMac/Core/IO/ContainerCompleteness.swift` (pure Foundation) checks the PNG chunk list
  and the JPEG marker walk instead; `PaintDocument.read` keeps every guard the spec lists and
  adds this one. Covered by `rejectsTruncatedPNG` and an added `rejectsTruncatedJPEG`.
- `NSApplication` manages the Services menu instance itself once a main menu is set on a
  running app, so `installSetsSpecialMenus` asserts the Services menu by title (the uninstall
  → `install` → assert sequence still fails if `MainMenu.install` drops an assignment); object
  identity of the constructed submenu is not observable.
- The Swift overlay renames `NSDocument.saveDocument(_:)`/`saveDocumentAs(_:)` to
  `save(_:)`/`saveAs(_:)`; the menu pins the AppKit action names via
  `NSSelectorFromString("saveDocument:")` / `("saveDocumentAs:")`, matching the spec table.
- Submenu parent items carry AppKit's own `submenuAction:` (AppKit assigns it when a submenu is
  attached); the menu-table tests list it for Services and Open Recent.
- `AGENTS.md` *Build and test* now lists the real commands (spec-mandated text). No PRD change,
  as planned.
- Mutation spot-checks, each caught by ≥1 test and restored: removing
  `makeWindowControllers()`'s controller (6 tests fail), removing the `app.windowsMenu`
  assignment in `MainMenu.install` (1), stubbing the `ContainerCompleteness` guard (2), and
  changing the shared `tabbingIdentifier` (2).

Manual verification steps (never run by the agent; the user runs them when convenient):

- [ ] 1. The gate stays off screen: while the gate runs, no PaintDotMac window, Dock icon, or alert appears, and `pgrep -fl PaintDotMac.app` prints nothing afterwards.
- [ ] 2. Empty launch of `build/DerivedData/Build/Products/Debug/PaintDotMac.app`: only the menu bar, no window; the app keeps running.
- [ ] 3. Signing/architectures: `codesign -dv --verbose=2` shows `Signature=adhoc`, no `TeamIdentifier`, no `runtime` flag; `lipo -archs` on the Debug binary prints only `arm64`; after the end-of-batch `--release` gate, `build/PaintDotMac.app` prints `x86_64 arm64`.
- [ ] 4. Finder integration: Open With → PaintDotMac for a PNG and a JPEG (own titled windows, image shown); ⌘W closes without prompt; New…, Save, Save As…, Undo, Cut, Copy, Paste disabled; ⌘S/⌘N do nothing; Open panel offers only PNG/JPEG; Open Recent lists files and "Clear Menu" empties it.
- [ ] 5. Tabs: separate windows by default, Window > Merge All Windows tabs them, View > Show Tab Bar / Show All Tabs work; with "Prefer tabs" set to "Always", new images join as tabs (restore the preference afterwards).
- [ ] 6. No duplicate menu items in View/Window; Help shows the search field.
- [ ] 7. Corrupt file from Finder (`broken.png`): "couldn’t be opened" alert, app keeps running.
- [ ] 8. Light and Dark mode: the placeholder background follows the window background color.

Review: _(to be filled by the reviewer: criteria traced, mutations tried, issues found, final
gate lines)_
