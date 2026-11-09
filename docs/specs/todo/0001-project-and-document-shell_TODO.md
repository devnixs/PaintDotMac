# 0001 — Create the XcodeGen project and a document app that opens PNG and JPEG images

> Source: PRD.md §5.1 APP-1; §4 (Project, Distribution, Minimum OS, Testing, UI rows); §5.11 "Saving" (`autosavesInPlace` off); §5.12 (menu shortcuts used here); §12 D-1, D-3, D-4, D-6; AGENTS.md *Tech stack*, *Build and test*, *Spec workflow*; spec-writer skill "The first spec is always the foundation".
> Milestone: M0
> Depends on: none

## Context

The repository has no application code, no Xcode project, and no `.gitignore` (only `PRD.md`, `AGENTS.md`, `CLAUDE.md`, `.agents/`, and `docs/specs/`). `AGENTS.md` *Build and test* still describes the commands as "the intended setup". The quality gate (`.agents/skills/spec-implementer/scripts/quality-gate.sh`) stops at step 1 with "no Xcode project". Every later spec builds on this one.

What this spec delivers:

- **The project** (PRD §4, D-3). `project.yml` is the source of truth for XcodeGen. It defines scheme `PaintDotMac` with targets `PaintDotMac` (app), `PaintDotMacTests` (Swift Testing, hosted in the app), and `PaintDotMacUITests` (XCUITest). The bundle ID is `com.thera-engineering.paintdotmac`, the minimum OS is macOS 15, and the code uses Swift 6 strict concurrency. Signing is ad hoc with no team, no sandbox, and hardened runtime off. Debug builds the native architecture only and Release builds a universal binary.
- **The app shell** (PRD §4 UI row, D-4). The app uses the AppKit lifecycle: `main.swift` + `AppDelegate`, an AppKit main menu built in code, `NSDocumentController.shared`, the `PaintDocument` (`NSDocument`) subclass, and one `DocumentWindowController` per document. Don't use the SwiftUI `App`/`DocumentGroup` lifecycle.
- **APP-1:** each image opens in its own window, and native macOS window tabs work (`tabbingMode = .automatic` with a shared `tabbingIdentifier`). Windows follow the user's "Prefer tabs when opening documents" setting. *Window > Merge All Windows*, *Show Tab Bar*, and the related items work. `.automatic` is chosen over `.preferred` because APP-1 says "each image is its own window, and native window tabs are supported".
- **Read-only PNG/JPEG.** A temporary `PlaceholderImageView` displays the image. Spec 0002 replaces the decoded `CGImage` with `LayeredImage`, and 0003 replaces the placeholder with the Metal `CanvasView`. Saving starts in 0005, so in this spec the PNG/JPEG document types have the **Viewer** role and the Save items are disabled.
- **D-36 test hooks** (PRD §4 Testing row). `#if DEBUG` code handles `-UITestOpen <path>` (opens a fixture) and `-UITestResetDefaults YES` (clears `tool.*` and panel defaults). AppKit itself honors `-ApplePersistenceIgnoreState YES`.
- **UI test harness.** `UITestApp` generates fixture images at test time into a temp directory and launches the app with the hooks. It also has helpers for menus and canvas drags that later specs reuse.
- **A green gate.** The default `quality-gate.sh` run (no `--sanitizers`) is the bar: clean build with zero warnings, all unit and UI tests ran with none failed or skipped, and the launch smoke test passes for empty, PNG, and JPEG launches.

Environment facts the implementer must know:

- **Versions:** Xcode 26.3 (17C529), macOS 26.6.2, XcodeGen 2.46.0 at `/opt/homebrew/bin/xcodegen`, `jq` at `/usr/bin/jq`.
- **Developer Mode is currently disabled** (`DevToolsSecurity -status`). UI tests can't run until the user enables it and approves the Accessibility prompt. That is a user blocker, not a code bug (see *Manual verification*).
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
  - **Target `PaintDotMacUITests`** (`type: bundle.ui-testing`):
    - `sources: [PaintDotMacUITests]`, `dependencies: [{ target: PaintDotMac }]`.
    - settings: `GENERATE_INFOPLIST_FILE: YES`, `PRODUCT_BUNDLE_IDENTIFIER: com.thera-engineering.paintdotmac.uitests`, `TEST_TARGET_NAME: PaintDotMac`.
  - **Scheme `PaintDotMac`**:
    - `build.targets`: `PaintDotMac: all`, `PaintDotMacTests: [test]`, `PaintDotMacUITests: [test]`.
    - `run.config: Debug`.
    - `test.config: Debug` with `targets: [{ name: PaintDotMacTests, parallelizable: false }, { name: PaintDotMacUITests, parallelizable: false }]` and `commandLineArguments: { "-ApplePersistenceIgnoreState YES": true }`. The hosted unit tests then never restore windows from earlier UI-test sessions.
    - `archive.config: Release`, `profile.config: Release`, `analyze.config: Debug`.
  - The gate builds with `-destination 'platform=macOS,arch=$(uname -m)'`, so check that this destination resolves with the generated scheme.

### App (platform glue, `PaintDotMac/App/`)

- **`App/main.swift`** creates `NSApplication.shared` and assigns an `AppDelegate`. It keeps a strong reference to the delegate in a file-level `let`, because `NSApplication.delegate` is weak. It then calls `NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)` and loads no nib.
- **`App/AppDelegate.swift`** contains `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`.
  - `applicationWillFinishLaunching(_:)` does two things:
    1. In `#if DEBUG` only: it parses `LaunchOptions(arguments: ProcessInfo.processInfo.arguments)`. If `resetsDefaults` is set, it calls `LaunchOptions.resetDefaults(in: .standard, domainName: Bundle.main.bundleIdentifier ?? "com.thera-engineering.paintdotmac")` before anything reads defaults.
    2. It then calls `MainMenu.install(in: NSApp)`.
  - `applicationDidFinishLaunching(_:)`, in `#if DEBUG` only, opens `fixtureURLs` **sequentially in argument order**. It uses `NSDocumentController.shared.openDocument(withContentsOf:display: true)` and opens the next URL from the completion handler, so the window and tab order is deterministic. If an open fails, it calls `NSApp.presentError(error)` and continues with the next URL. The programmatic API does not present errors itself.
  - `applicationShouldOpenUntitledFile(_:) -> false`. This is permanent: the app never opens an untitled document at launch, also after the New Image dialog exists (0005), so an empty launch shows only the menu bar. New images come only from File > New (⌘N).
  - `applicationShouldTerminateAfterLastWindowClosed(_:) -> false` (the Mac document-app convention).
  - `applicationSupportsSecureRestorableState(_:) -> true`.
  - The delegate does **not** implement `application(_:open:)` or `application(_:openFiles:)`. Without them, Apple Events from Finder, `open -a`, and the gate's smoke test go to `NSDocumentController.shared`. Drops on the Dock icon and the app (FMT-C) are spec 0030.
- **`App/LaunchOptions.swift`** contains `struct LaunchOptions: Equatable, Sendable`. It is pure Foundation and always compiled, so the parser can be unit-tested. Only `AppDelegate` gates its *use* behind `#if DEBUG`, so Release builds ignore the flags.
  - `init(arguments: [String])` follows these parsing rules:
    - `-UITestOpen <path>` may appear several times. Each value appends `URL(fileURLWithPath: path)` to `fixtureURLs: [URL]` in order.
    - A `-UITestOpen` that is the last argument is ignored. So is one whose next argument starts with `-`. That next argument is then parsed normally.
    - `-UITestResetDefaults <value>` sets `resetsDefaults: Bool`. `YES`, `true`, and `1` (case-insensitive) give `true`, and anything else gives `false`. A bare `-UITestResetDefaults` at the very end also gives `true`.
    - All other arguments are ignored, for example `-ApplePersistenceIgnoreState YES`, `-NSDocumentRevisionsDebugMode YES`, and `argv[0]`. The process path in `argv[0]` must not become a fixture.
    - **Why key/value pairs:** AppKit reads `-Key value` pairs into the argument defaults domain. A bare flag followed by a path would turn the path into a stray argument, which AppKit may try to open as a file. That is why the harness always passes `-UITestResetDefaults YES`.
  - `static let resettableKeyPrefixes = ["tool.", "panel.", "NSWindow Frame panel."]`. These cover tool options (AGENTS.md rule 6), panel state, and panel frame-autosave entries. The panel autosave names chosen by 0006 must start with `panel.`. Later specs that persist other UI state the UI tests depend on append their prefix here, with a test: 0004 appends `"settings."` and 0007 appends `"colors."`, giving the final list `["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]` (PRD §4 Testing, D-37).
  - `static func shouldReset(key: String) -> Bool` returns true when the key has one of those prefixes. The match is case-sensitive.
  - `static func resetDefaults(in defaults: UserDefaults, domainName: String)` removes every key in `defaults.persistentDomain(forName: domainName)` for which `shouldReset` is true.
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
    - `identifier = NSUserInterfaceItemIdentifier("documentWindow")`. UI tests count document windows with it, which keeps them separate from the floating panels that 0006 adds;
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
    - This is a contract. 0003's `CanvasView` must keep the `canvas` identifier and this value format, so `LaunchUITests` keeps passing.
    - If XCUITest doesn't surface `AXValue` for the image role, use role `.group` instead and keep the identifier and value. Record that choice in the Verification status.
  - `static func imageRect(imageSize: CGSize, in bounds: CGRect) -> CGRect` is pure and unit-tested. It scales to fit and never upscales.
    - If `bounds` has width ≤ 0 or height ≤ 0, or `imageSize` has a side ≤ 0, it returns `.zero`.
    - Otherwise `scale = min(1, bounds.width / image.width, bounds.height / image.height)` and `size = image × scale`.
    - The origin is `bounds.origin + floor((bounds.size − size) / 2)`, and the size is not rounded.

### Tests and harness

- **`PaintDotMacTests/`**: the unit tests listed in the Test plan. Images for document-read tests are encoded in the test with a private helper in `PaintDocumentTests.swift` (CGContext + `CGImageDestination`). `PaintDotMacTests/Support/TestImages.swift` belongs to 0002, so don't create it here.
- **`PaintDotMacUITests/Support/UITestApp.swift`**: the reusable harness, specified in full below.
- **`PaintDotMacUITests/LaunchUITests.swift`**: the UI tests.

`UITestApp` is `@MainActor final class UITestApp` and uses XCTest + ImageIO + UniformTypeIdentifiers:

- `let app = XCUIApplication()`.
- `let fixtureDirectory: URL` is `FileManager.default.temporaryDirectory/PaintDotMacUITests/<UUID>/`. `init() throws` creates it.
- Fixture writers. Each one returns the URL in `fixtureDirectory`:
  - `func makePNG(named: String, width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> URL` draws a solid color in sRGB and writes it with `CGImageDestination`.
  - `func makeJPEG(named:width:height:rgba:) throws -> URL` does the same, writing an opaque JPEG at quality 0.9.
  - `func makeFile(named: String, contents: Data) throws -> URL` writes raw bytes, for corrupt fixtures.
- `func launch(opening fixtures: [URL] = [], resetDefaults: Bool = true, extraArguments: [String] = [])` builds `app.launchArguments` in this order:
  1. `["-ApplePersistenceIgnoreState", "YES"]`
  2. `["-UITestResetDefaults", resetDefaults ? "YES" : "NO"]`
  3. `["-UITestOpen", path]` for each fixture
  4. `extraArguments`

  It then calls `app.launch()`.
- Queries:
  - `var documentWindows: XCUIElementQuery` is `app.windows.matching(identifier: "documentWindow")`.
  - `var canvas: XCUIElement` is the first descendant (any type) with identifier `canvas` in the frontmost document window.
- `func menuItem(_ menu: String, _ item: String) -> XCUIElement` returns `app.menuBars.menuBarItems[menu].menus.menuItems[item]`.
- `func chooseMenuItem(_ menu: String, _ item: String)` clicks the menu bar item and then the item.
- `func dragOnCanvas(from: CGVector, to: CGVector, holdDuration: TimeInterval = 0.05)` drags between normalized offsets of `canvas` with `press(forDuration:thenDragTo:)`. It is for later specs.
- `func waitForDocumentWindowCount(_ n: Int, timeout: TimeInterval = 10) -> Bool` waits with an `NSPredicate` expectation.
- `func tearDown()` terminates the app if it is running and deletes `fixtureDirectory`.
- Every `waitForExistence` uses a 10 s timeout.
- The harness never calls `XCTSkip` (the gate fails on skipped tests).

### AGENTS.md (the implementer updates it in this change)

- Replace the placeholder text in *Build and test* with the real commands, and remove "The Xcode project or Swift package is created in milestone M0. Until then…". Add a note that UI tests need Developer Mode and the Accessibility prompt approved, and that they take over the mouse and keyboard.

```bash
xcodegen generate                                                     # after adding/removing files or targets
xcodebuild -scheme PaintDotMac -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData build
xcodebuild -scheme PaintDotMac -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData test -only-testing:PaintDotMacTests
xcodebuild -scheme PaintDotMac -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData test -only-testing:PaintDotMacUITests
.agents/skills/spec-implementer/scripts/quality-gate.sh                # the final word, after every spec
```

- No PRD change. Every decision used here is already in PRD §4/§12.

## Acceptance criteria

- [ ] `xcodegen generate` produces `PaintDotMac.xcodeproj` with scheme `PaintDotMac` and the targets `PaintDotMac`, `PaintDotMacTests`, and `PaintDotMacUITests`. The scheme's test action runs both test targets. → the quality gate (steps 1, 4: the UI target ran).
- [ ] `.gitignore` ignores `build/`, `*.xcodeproj`, and `DerivedData/`. `git status` after a gate run shows no build products. → manual check (`git status --porcelain` lists only source files).
- [ ] Bundle ID `com.thera-engineering.paintdotmac`, `LSMinimumSystemVersion` 15.0, principal class `NSApplication`, not sandboxed. → `SmokeTests.bundleIdentifier`, `SmokeTests.minimumSystemVersion`, `SmokeTests.principalClass`, `SmokeTests.notSandboxed`.
- [ ] PNG and JPEG document types map to `PaintDocument` with the Viewer role. → `SmokeTests.documentTypesMapPNGAndJPEGToPaintDocument`.
- [ ] Ad hoc signature, no hardened runtime. The Debug build is native-arch only and the Release build is universal. → manual (`codesign`/`lipo` commands below). The Release check runs with the end-of-batch `--release` gate.
- [ ] The app launches with no window when no document is given, and keeps running when the last window closes. → `AppDelegateTests.noUntitledDocumentAndNoTerminateOnLastClose`, `LaunchUITests.testEmptyLaunchShowsMenuBarOnly`, gate smoke (empty launch).
- [ ] Opening a valid PNG or JPEG shows one document window. Its title starts with the file's base name and its `canvas` element reports the image's pixel size. → `LaunchUITests.testOpensPNGFixture`, `LaunchUITests.testOpensJPEGFixture`, `PaintDocumentTests.readsPNG`, `PaintDocumentTests.readsJPEG`.
- [ ] A corrupt, truncated, empty, or unsupported file never crashes the app. It shows the standard "couldn’t be opened" alert and the app keeps running. → `PaintDocumentTests.rejectsGarbage`, `.rejectsTruncatedPNG`, `.rejectsEmptyData`, `.rejectsUnsupportedType`, `LaunchUITests.testCorruptFixtureShowsAlertAndAppSurvives`.
- [ ] Two open documents can be merged into native tabs of one window (APP-1). → `LaunchUITests.testTwoDocumentsMergeIntoTabs`, `DocumentWindowControllerTests.windowSupportsTabbing`.
- [ ] File > Close (⌘W) closes the document window without a prompt (nothing is edited). → `LaunchUITests.testCloseWithCommandW`.
- [ ] The menu bar has exactly the menus and items in the *Scope* table, with the listed shortcuts and actions. → `MainMenuTests.*`, `LaunchUITests.testMenuBarAndPlaceholderEnablement`.
- [ ] New…, Save, Save As…, Undo, and Cut/Copy/Paste are disabled while a document is open. Open… is enabled. Nothing crashes when these items are clicked or pressed. → `PaintDocumentTests.saveActionsAreDisabled`, `LaunchUITests.testMenuBarAndPlaceholderEnablement`.
- [ ] `autosavesInPlace` is false. → `PaintDocumentTests.doesNotAutosaveInPlace`.
- [ ] The `-UITestOpen` and `-UITestResetDefaults` launch hooks parse as specified. Resetting removes only `tool.*`, `panel.*`, and `NSWindow Frame panel.*` keys. → `LaunchOptionsTests.*`. The hooks work in the real app. → every `LaunchUITests` test, because each one launches through them.
- [ ] The window content size and the placeholder image rect follow the formulas. → `DocumentWindowControllerTests.initialContentSize*`, `PlaceholderImageViewTests.*`.
- [ ] AGENTS.md *Build and test* lists the real commands. → reviewer check.
- [ ] The quality gate (default run, no `--sanitizers`) is green: clean build with zero warnings, all unit and UI tests passed, none skipped, UI target ran, and the launch smoke test passed (empty, PNG, JPEG). → `quality-gate.sh`.
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → the gate's launch smoke step.

## Edge cases

- **Empty file (0 bytes), random bytes, or a PNG truncated to half its bytes:** `read` throws `CocoaError(.fileReadCorruptFile)`, NSDocument shows its standard alert, and no window opens.
- **Unsupported type name**, for example `com.compuserve.gif` passed directly to `read`: it throws `CocoaError(.fileReadUnknown)`. In the real app the Open panel doesn't offer such files, because only PNG/JPEG are declared.
- **A JPEG whose name ends in `.png`:** it opens by content, without an error.
- **`-UITestOpen` with a missing path:** the open fails, `NSApp.presentError` shows an alert, and the app keeps running. Any remaining fixtures still open.
- **`-UITestOpen` at the end of the arguments, or followed by another flag:** it is ignored. It never crashes and never yields an empty URL.
- **The same file opened twice:** NSDocumentController brings the existing window forward instead of opening a second one (standard behavior). Don't override it.
- **Very small images (1×1):** the window opens at the 480×360 minimum, and the image draws at 1×1 pt, centered.
- **Very large images:** the window is capped at 80% of the visible screen and the image is scaled down to fit. Memory and size limits (APP-10) are 0002's job. 0001 does not test giant images.
- **Window resized smaller than the image:** the image is re-fitted. `imageRect` never returns NaN or negative sizes, and it returns `.zero` for empty bounds.
- **Release builds:** `-UITestOpen` and `-UITestResetDefaults` have no effect because their use is compiled out. The parser still exists and is harmless.
- **Clicking a placeholder item** (New…, Settings…): it is disabled because its action is nil, so clicking it does nothing.
- **Pressing ⌘S in 0001:** Save is disabled by `validateUserInterfaceItem`, so it does nothing. `data(ofType:)` throws if it is ever reached, and NSDocument presents that as an alert, not a crash.
- **State restoration:** tests and the gate pass `-ApplePersistenceIgnoreState YES`, and the scheme's test action passes it to hosted unit tests too.

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

**`PaintDotMacTests/App/LaunchOptionsTests.swift`**

- `emptyArguments`: `LaunchOptions(arguments: [])` gives `fixtureURLs == []` and `resetsDefaults == false`.
- `processPathIsNotAFixture`: `["/path/PaintDotMac"]` gives `fixtureURLs == []`.
- `singleOpen`: `["/app", "-UITestOpen", "/tmp/a.png"]` gives `fixtureURLs == [URL(fileURLWithPath: "/tmp/a.png")]`.
- `multipleOpensKeepOrder`: `-UITestOpen /tmp/b.jpg -UITestOpen /tmp/a.png` gives `[b.jpg, a.png]`, in that order.
- `openWithoutValueAtEndIsIgnored`: `["/app", "-UITestOpen"]` gives `[]`.
- `openFollowedByFlagIsIgnoredAndFlagStillParsed`: `["/app", "-UITestOpen", "-UITestResetDefaults", "YES"]` gives `fixtureURLs == []` and `resetsDefaults == true`.
- `resetValues`: parameterized. `YES`, `yes`, `true`, `1` → true. `NO`, `false`, `0`, `maybe` → false. A bare trailing `-UITestResetDefaults` → true.
- `ignoresUnrelatedArguments`: `["/app", "-ApplePersistenceIgnoreState", "YES", "-NSDocumentRevisionsDebugMode", "YES", "-UITestOpen", "/tmp/x.png"]` gives `fixtureURLs == [/tmp/x.png]` and `resetsDefaults == false`.
- `shouldResetKeys`: parameterized.
  - true for `tool.paintbrush.width`, `tool.x`, `panel.tools.visible`, `NSWindow Frame panel.tools`;
  - false for `toolbarStyle`, `Tool.paintbrush.width`, `panels`, `NSWindow Frame documentWindow`, `NSRecentDocuments`, `""`. (`settings.*` and `colors.*` keys are deliberately not listed: 0004 and 0007 make them resettable and add their own cases.)
- `resetDefaultsRemovesOnlyResettableKeys`:
  1. Create `UserDefaults(suiteName: "PaintDotMacTests.\(UUID())")`.
  2. Set `tool.paintbrush.width = 5`, `panel.layers.visible = true`, `NSWindow Frame panel.tools = "0 0 100 100 …"`, `toolbarStyle = "x"`, and `other = 1`.
  3. Call `resetDefaults(in:domainName:)` with the suite name.
  4. Expect the first three keys to be nil. Expect `toolbarStyle == "x"` and `other == 1`.
  5. Clean up with `removePersistentDomain(forName:)`.
- `resetDefaultsOnEmptyDomainIsNoOp`: an unknown domain name causes no crash and no change.

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

### Integration tests

`PaintDocumentTests.makeWindowControllersCreatesOneDocumentWindow` goes from read to window. The real-app open path is covered by the UI tests.

### UI tests (`PaintDotMacUITests/LaunchUITests.swift`)

Write the tests as a `@MainActor final class LaunchUITests: XCTestCase` with `continueAfterFailure = false`. Each test builds a `UITestApp` in `setUp` and calls `harness.tearDown()` in `tearDown`.

- `testEmptyLaunchShowsMenuBarOnly`: launch without fixtures. The menu bar item "File" exists, `documentWindows.count == 0` after 2 s, and `app.state == .runningForeground`.
- `testOpensPNGFixture`: generate `launch-fixture.png` (64×48, opaque (200, 100, 50)) and launch with it.
  - `waitForDocumentWindowCount(1)` succeeds.
  - The document window's title has the prefix `launch-fixture`. Don't check the extension, because the Finder "show extensions" setting decides whether it is shown.
  - `canvas` exists and `canvas.value as? String == "64 × 48"`.
- `testOpensJPEGFixture`: the same with `launch-fixture.jpg` at 40×30, expecting `"40 × 30"`.
- `testCorruptFixtureShowsAlertAndAppSurvives`: generate `corrupt.png` with the contents `"not an image"` and launch with it.
  - An alert appears: `app.dialogs.firstMatch` or `app.sheets.firstMatch`, whichever is present, within 10 s.
  - Its static texts include one containing `"corrupt"`, the file name in the message.
  - Click its default button ("OK"). `documentWindows.count == 0` and `app.state == .runningForeground`.
- `testCloseWithCommandW`: open the PNG fixture, wait for the window, and press `app.typeKey("w", modifierFlags: .command)`. `waitForDocumentWindowCount(0)` succeeds, no sheet appears (nothing is edited), and the app is still running.
- `testTwoDocumentsMergeIntoTabs`: generate `first.png` (30×20) and `second.jpg` (50×40) and launch with both, in that order.
  1. Wait until both are open. With "Prefer tabs: In Full Screen" that means `documentWindows.count == 2`. If the user prefers tabs "Always", it means one window with two tabs.
  2. If "Merge All Windows" is enabled in the Window menu, choose it.
  3. Assert there is exactly one visible document window and its tab group shows two tabs whose titles start with `first` and `second`.
  4. **Fallback** if XCUITest can't see native tab buttons:
     - after the merge, `documentWindows.count == 1`;
     - Window > "Show Next Tab" is enabled;
     - choosing it switches the frontmost document window's title between the `first…` and `second…` prefixes, and `canvas.value` switches between `"30 × 20"` and `"50 × 40"`.

  Only the query may change. The assertion that there is one window with two documents switchable as tabs may not be weakened, and `XCTSkip` is not allowed.
- `testMenuBarAndPlaceholderEnablement`: open the PNG fixture.
  - The menu bar items include "PaintDotMac", "File", "Edit", "View", "Window", and "Help".
  - After clicking "File": "Open…" `isEnabled == true`, while "New…", "Save", and "Save As…" are `isEnabled == false`. Press Escape to close the menu.
  - In the Edit menu, "Undo", "Cut", "Copy", and "Paste" are disabled. Press Escape.
  - Press ⌘S and ⌘N: there is no sheet or alert, the app is still running, and `documentWindows.count == 1`.

### Performance

Not applicable. This spec has no canvas, compositing, or history, so NF-1 to NF-4 are unaffected.

### Quality gate

Run `.agents/skills/spec-implementer/scripts/quality-gate.sh` with **no** flags. It must end with `GREEN`:

- the clean Debug build has zero warnings in our sources;
- `tests: N passed, 0 failed, 0 skipped`, with the UI target present;
- `debug launch smoke: OK (empty, PNG, JPEG …)`.

Sanitizers are not part of the bar: they are UNAVAILABLE on this Mac. `--skip-ui` is not acceptable for this spec, because it is the spec that proves UI tests run. If UI tests can't run because Developer Mode is off or the Accessibility prompt is pending, stop and report that as a user blocker.

### Manual verification

1. **Enable Developer Mode (one-time, before the first gate run).** Run `sudo DevToolsSecurity -enable`, then `DevToolsSecurity -status`, which must print "Developer mode is currently enabled."
2. **Approve UI-test automation (first UI-test run).** Run the gate.
   - When macOS asks, allow the test runner (`PaintDotMacUITests-Runner` and/or Xcode's helper, as shown) in System Settings > Privacy & Security > Accessibility, then re-run the gate.
   - Don't touch the mouse or keyboard while the UI tests run.
   - If the prompt reappears after a rebuild (ad hoc signatures change between builds), approve it again and note that in the Verification status.
3. **Signing and architectures.**
   - `codesign -dv --verbose=2 build/DerivedData/Build/Products/Debug/PaintDotMac.app` shows `Signature=adhoc`, no `TeamIdentifier`, and no `runtime` flag.
   - `lipo -archs build/DerivedData/Build/Products/Debug/PaintDotMac.app/Contents/MacOS/PaintDotMac` prints only `arm64` on Apple Silicon.
   - After the end-of-batch `--release` gate, `lipo -archs build/PaintDotMac.app/Contents/MacOS/PaintDotMac` prints `x86_64 arm64`.
4. **Finder integration.** In Finder, right-click a PNG and a JPEG > Open With > PaintDotMac. Each one opens in a window.
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
