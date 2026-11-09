# PRD — PaintDotMac

A native macOS raster image editor inspired by Paint.NET.

| | |
|---|---|
| **Status** | Draft v0.2 (open questions Q-1/Q-2 and the planning decisions D-1 to D-37 resolved; see §12) |
| **Author** | Raphael |
| **Date** | 2026-11-04 |
| **Project type** | Personal / learning project |
| **Platform** | macOS (Swift, SwiftUI + AppKit, Metal) |

---

## 1. Summary

Paint.NET is a fast, approachable, free image editor for Windows. It sits between MS Paint and Photoshop: you get layers, selections, adjustments, effects, and unlimited history without a professional tool's complexity. There is no direct equivalent on macOS. Preview is too limited, and the closest alternatives (Pixelmator Pro, Affinity Photo, Acorn) are either paid or heavier.

PaintDotMac is a native macOS app that recreates Paint.NET's **workflow and feel**: its floating tool windows, single-key tool shortcuts, history panel, and menus of adjustments and effects. It is built with Apple technologies (Swift, AppKit/SwiftUI, Metal, Core Image, ImageIO) and follows Mac conventions.

Because this is a learning project, the architecture, code clarity, and incremental milestones matter as much as the feature list.

## 2. Goals and non-goals

### 2.1 Goals
1. **G1. A familiar Paint.NET workflow on Mac.** The same tool set, panel layout (Tools, History, Layers, Colors), menu structure, and single-letter tool shortcuts. Ctrl maps to Cmd, and macOS conventions apply.
2. **G2. A fast, native feel.** Rendering is Metal-accelerated. Brush strokes and panning stay smooth on large images.
3. **G3. A core MVP first, then iteration.** v1.0 ships layers, selections, core tools, undo/history, the standard adjustments, and a first set of effects. More effects arrive in later releases.
4. **G4. A clean, extensible architecture.** Adding a new effect or adjustment should take one self-contained file plus registration. This keeps an internal plugin system possible later.
5. **G5. Learning value.** The project should exercise modern Swift: concurrency, Metal compute, Core Image, document-based apps, and undo management.

### 2.2 Non-goals (v1.0)
- Reading or writing Paint.NET `.pdn` files.
- Loading Paint.NET plugins (they are .NET/Windows/DirectX-bound) or a third-party plugin API.
- Photoshop `.psd` import or export.
- Windows or Linux versions.
- Vector editing, non-destructive adjustment layers, or layer masks (possible later).
- RAW photo development, CMYK, or print workflows.
- Animation or multi-frame editing (frames of animated GIFs and WebPs are flattened or the first frame is used).
- Public distribution (Mac App Store or DMG), monetization, or localization (English only).

## 3. Target user

| Persona | Needs |
|---|---|
| **Primary: the author** | Wants to learn native Mac graphics development and have a useful everyday editor. |
| **Paint.NET switcher** | Has moved from Windows to Mac and misses Paint.NET's speed and muscle memory. |
| **Casual editor** | Crops, resizes, annotates screenshots, does light retouching, and makes simple compositions with layers. Finds Preview too limited and Photoshop too much. |

### Key use cases
1. Open a screenshot, crop it, add arrows, text, and highlight rectangles, then export a PNG.
2. Open a photo, adjust levels, curves, and hue/saturation, sharpen, resize, and export a JPEG at a chosen quality.
3. Build a simple composite from several images on separate layers, using blend modes and opacity.
4. Paste from the clipboard into a new image, edit it, and copy the result back to the clipboard.
5. Undo any number of steps, or jump back to any earlier state from the History panel.

## 4. Platform and technical constraints

| Area | Decision |
|---|---|
| **Language** | Swift 6 with strict concurrency checking. |
| **UI** | **AppKit app lifecycle** (`NSApplication`, `NSDocumentController`, one `NSWindowController` per document, AppKit main menu). SwiftUI is used for the panels, the tool options bar, the status bar, dialogs, and the Settings window, hosted in `NSHostingView`/`NSHostingController`. The canvas is an AppKit `MTKView` subclass, for precise mouse, tablet, and keyboard handling. (Decided 2026-11-04: AppKit gives the most reliable window tabs, autosave, floating `NSPanel`s, and canvas event handling.) |
| **Rendering** | Metal: a tiled canvas compositor and compute shaders for blending, used for on-screen display. A deterministic CPU compositor in `Core` is the reference implementation and is used for export, flatten, merge down, Copy Merged, and image-sampling tools; the Metal compositor must match it within ±1 per channel (golden tests). Core Image (with a Metal-backed `CIContext`) or Metal kernels for adjustments and effects. |
| **Image I/O** | ImageIO / `CGImageSource` / `CGImageDestination`. OpenRaster ZIP containers are read and written by our own minimal ZIP implementation in `Core` (DEFLATE through Apple's `Compression` framework, our own CRC-32); see §5.11. |
| **Document model** | `NSDocument` subclass, giving native open/save, autosave, recent files, and window tabs. Saving model: see §5.11 "Saving". |
| **Minimum OS** | **macOS 15 Sequoia** (resolved Q-1). Built with Xcode 26. |
| **Hardware** | Apple Silicon is the primary target. Debug builds the native architecture only; Release builds are universal (Intel on a best-effort basis). |
| **Distribution** | Personal use only: local builds on the author's Mac. Ad hoc signing ("Sign to Run Locally"), no development team, not sandboxed, hardened runtime off. |
| **Project** | **XcodeGen**: `project.yml` is the source of truth; the generated `PaintDotMac.xcodeproj` is git-ignored and never hand-edited. Scheme `PaintDotMac` with targets `PaintDotMac` (app), `PaintDotMacTests` (unit, golden-image, and integration tests), and `PaintDotMacUITests` (XCUITest). Bundle identifier `com.thera-engineering.paintdotmac`. |
| **Testing** | Swift Testing for unit, golden-image, and integration tests; XCTest only for `measure` performance tests; XCUITest for UI tests. `#if DEBUG` launch hooks make UI tests deterministic: `-UITestOpen <path>` opens a fixture document, `-ApplePersistenceIgnoreState YES` disables state restoration, and `-UITestResetDefaults` clears `tool.*`, `colors.*`, `settings.*`, and panel defaults and frames. Further test-only hooks (all `#if DEBUG`, listed in the specs that add them): `-UITestMemoryCapBytes <n>` (APP-10 cap), `-UITestSelectRect x,y,w,h` (initial selection, not a history step), `-UITestReduceMotion YES|NO`, `-UITestDropFiles <path>` (0030), `-UITestEffectSeed <n>` (0043), `-UITestUndoLimitPreset` (0046), `-UITestAutosaveDelay <s>` and `-UITestDiscardSavedState YES` (0047), `-PerfFrameProbe <path>` (0048, Debug/Benchmark only), `-UITestIncreaseContrast`, `-UITestReduceTransparency`, `-UITestAppearance light|dark`, `-UITestDumpAccessibilityCatalog <path>` (0049), `-UITestWindowContentSize WxH` (0051). Test-only environment variables: `RECORD_GOLDENS=1` (record golden images after oracle confirmation), `RECORD_SHORTCUT_DOCS=1` (regenerate `docs/shortcuts.md`), `PAINTDOTMAC_TEST_SEED` (override the seeded-random seed). Sanitizer runs are best-effort (they are unavailable on some macOS/Xcode combinations) and are never required for a spec to pass. |
| **Dependencies** | Prefer none. Any third-party Swift Package needs a stated justification. |

## 5. Functional requirements

Priority: **P0** = required for v1.0 · **P1** = targeted for v1.x · **P2** = later or nice to have.

### 5.1 Application shell and windows
| ID | Requirement | Pri |
|---|---|---|
| APP-1 | Document-based app: each image is its own window, and native macOS window tabs are supported. | P0 |
| APP-2 | Paint.NET-style panels: **Tools**, **History**, **Layers**, and **Colors**. In v1.0 they are four app-wide floating utility `NSPanel`s that follow the active document window; their frames are remembered with a frame autosave name. Each can be toggled from the Window menu: ⌥⌘1 Tools, ⌥⌘2 History, ⌥⌘3 Layers, ⌥⌘4 Colors (Paint.NET's F5–F8 order). Docking is APP-3. | P0 |
| APP-3 | Panels can be docked to the window or floated as utility panels (`NSPanel`). Their positions are remembered. | P1 |
| APP-4 | A tool options bar (Paint.NET's "Toolbar") at the top of each document window shows the active tool's settings: brush width, antialiasing, blend mode, fill mode, tolerance, and so on. | P0 |
| APP-5 | Status bar at the bottom of each document window: cursor position, selection size, image size, zoom level, units (px / in / cm). Every document has a resolution (DPI), read from the file's metadata or defaulting to 96 DPI (Paint.NET's default); it is stored in `.ora` (`xres`/`yres`) and written to flat formats. Inches and centimetres are derived from it. The unit is chosen from a status-bar popup and persisted; its default comes from Settings (APP-8). | P0 |
| APP-6 | Image thumbnail strip for switching between open documents (Paint.NET's image tabs). Native window tabs may cover this. | P2 |
| APP-7 | Light and dark mode, following the system. | P0 |
| APP-8 | Settings window: default units, checkerboard style, undo memory limit, default JPEG quality, and the option to restore panel positions. (P1, but built in M7 because NF-4 needs a configurable undo budget.) | P1 |
| APP-9 | **New Image** dialog (File > New, ⌘N): width, height (px), and resolution (1–10,000 DPI, decimals allowed). Defaults to the clipboard image's size (its DPI is ignored) when the clipboard holds an image, otherwise 800×600 at 96 DPI. An untouched new image has no unsaved changes (the edited state follows history). The new image has one opaque white layer named "Background", as in Paint.NET. | P0 |
| APP-10 | **Image limits.** Each side is 1–65,535 px (Paint.NET's limit). Creating, opening, pasting, or resizing to an image whose width × height × 4 overflows or exceeds the injectable memory cap is refused with an alert, never a crash. Tiles are sparse, so fully transparent tiles cost no memory. The default memory cap is physical memory ÷ 4. | P0 |

### 5.2 Canvas and navigation
| ID | Requirement | Pri |
|---|---|---|
| CAN-1 | Zoom from 1% to 3200%. Zoom in and out, Actual Size (⌘0), Zoom to Window, and Zoom to Selection. | P0 |
| CAN-2 | Trackpad pinch-to-zoom and two-finger scroll panning. Holding Space temporarily switches to the Pan tool. | P0 |
| CAN-3 | Nearest-neighbor rendering when zoomed above 100%, and high-quality downsampling when zoomed out. | P0 |
| CAN-4 | A checkerboard background shows transparency. | P0 |
| CAN-5 | An optional pixel grid at high zoom, plus rulers. | P1 |
| CAN-6 | Retina-aware rendering: one image pixel maps correctly to device pixels at every zoom level. **100% means one image pixel per device pixel** (as in Paint.NET on high-DPI displays and Photoshop), so a Retina screenshot is sharp at 100%. New windows open at min(100%, fit to window). There are no scroll bars in v1.0 (pan with gestures, Space, or the Pan tool). | P0 |
| CAN-7 | Selection outline drawn as animated "marching ants". | P0 |

### 5.3 Tools
Single-key shortcuts mirror Paint.NET. Pressing a key again within 1 second cycles forward (Shift+key cycles backward); otherwise it selects the group's first tool (Shift+key selects the group's last tool, as in Paint.NET: Shift+S is the Magic Wand). The app starts with the Paintbrush (the active tool is not remembered). Pressing a key repeatedly cycles through that key's tool group, in this order: **S** Rectangle Select → Lasso Select → Ellipse Select → Magic Wand; **M** Move Selected Pixels → Move Selection; **O** Line / Curve → Shapes. `[` and `]` (no modifier) decrease and increase the brush width, as in Paint.NET. Selection changes are history steps, as in Paint.NET ("Rectangle Select", "Deselect", "Invert Selection", and so on).

| ID | Tool | Key | Notes | Pri |
|---|---|---|---|---|
| T-1 | Rectangle Select | S | Selection modes: replace, union, exclude, intersect, invert (modifier keys plus a toolbar picker). Fixed ratio and fixed size options. | P0 |
| T-2 | Lasso Select | S | Freehand polygon. Two modes: Freeform (drag; closed with a straight line back to the start) and Polygon (click to add vertices; Return, double-click, or clicking the first vertex closes; Escape cancels). Self-intersecting outlines use the even-odd fill rule. | P0 |
| T-3 | Ellipse Select | S | | P0 |
| T-4 | Magic Wand | S | Tolerance, flood mode (contiguous or global), sampling (layer or image). Defaults: tolerance 50%, sampling Layer. Color matching uses Paint.NET 3.36's `CheckColor` metric (RGB differences weighted by the seed's alpha; no Paint.NET 5 Tolerance Alpha Mode), and contiguous fills are 4-connected. The result is pixel-aligned (not smoothed). The fill runs synchronously on click (0048 may move it off the main actor). | P0 |
| T-5 | Move Selected Pixels | M | Translate, plus rotate and scale with handles. Pixels stay "floating" until committed. Resampling is bilinear while dragging and on commit, and nearest-neighbor when the transform is an integer translation/scale with no rotation. | P0 |
| T-6 | Move Selection | M | Moves only the selection outline. | P0 |
| T-7 | Zoom | Z | Click to zoom in, Option-click to zoom out, drag a rectangle to zoom to it. | P0 |
| T-8 | Pan | H | | P0 |
| T-9 | Paint Bucket | F | Tolerance, contiguous or global fill, antialiasing, and an option to fill the selection. The fill is applied and committed on click (no live, editable fill). A **Fill** option chooses "Similar Color" (default) or "Selection" (fills the whole selection with its antialiased mask, or the whole layer with no selection). Antialiasing is a one-pixel 3×3 soft ring outside the region (coverage round(255·k/9)). Tolerance uses the same metric as the Magic Wand (T-4), with no Tolerance Alpha Mode option. | P0 |
| T-10 | Gradient | G | Linear, linear reflected, diamond, radial, and conical types. Color mode and transparency mode. | P0 |
| T-11 | Paintbrush | B | Width, hardness, antialiasing, blend mode. The blend-mode list offers the layer blend modes implemented so far (Normal first; the L-3 modes as they land). Tablet pressure is TOOL-D (P1). | P0 |
| T-12 | Eraser | E | Width, hardness, and antialiasing, as on the Paintbrush (no blend mode, as in Paint.NET). The strength is the alpha of the color slot in use (primary for left, secondary for right): alpha 255 erases fully. A fully erased pixel becomes (0,0,0,0); a partly erased pixel keeps its color. | P0 |
| T-13 | Pencil | P | Aliased, one pixel wide. | P0 |
| T-14 | Color Picker | K | Samples a single pixel or an averaged area (3×3 to 51×51, alpha-weighted), from the layer or the image (⌘-click forces Image, Paint.NET's Ctrl-click). After clicking: do not switch tool (default), switch to the previous tool, or switch to the Pencil. | P0 |
| T-15 | Clone Stamp | L | Option-click sets the source (Paint.NET uses Ctrl-click). | P1 |
| T-16 | Recolor | R | Replaces the secondary color with the primary color within a tolerance. | P1 |
| T-17 | Text | T | Font, size, bold, italic, underline, alignment, antialiasing. Fonts come from the system font list through Core Text; the default is the system font at 12 pt. Text stays editable until committed (switching tools, ⌘↩, or clicking outside the text). Paint.NET-style rasterized text, not text layers. | P0 |
| T-18 | Line / Curve | O | Editable Bézier handles before committing. Dash styles and arrowheads. | P0 |
| T-19 | Shapes | O | Rectangle, rounded rectangle, ellipse, and a starter set of other shapes. Outline, fill, or both. Editable until committed. | P0 |
| T-20 | Extended shape library (arrows, stars, callouts, and so on) | O | | P1 |

Shared tool requirements:
- **TOOL-A (P0):** Primary and secondary colors. Left-drag paints with the primary color and right-drag (or Control-drag) with the secondary.
- **TOOL-B (P0):** Painting is confined to the active selection.
- **TOOL-C (P0):** Each tool's settings persist between sessions.
- **TOOL-D (P1):** Tablet pressure (`NSEvent.pressure`) changes brush width and/or opacity.

### 5.4 Layers
| ID | Requirement | Pri |
|---|---|---|
| L-1 | Add, delete, duplicate, merge down, move up or down, and flatten layers. | P0 |
| L-2 | Layer properties: name, visibility, opacity (0–255, matching Paint.NET), blend mode. | P0 |
| L-3 | Blend modes: Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay, Difference, Negation, Lighten, Darken, Screen, Xor. Formulas follow Paint.NET's own `UserBlendOps` (Paint.NET's Xor is a per-channel color XOR, not Porter-Duff Xor). | P0 |
| L-4 | More blend modes from Paint.NET 5.x: Hard Light, Soft Light, Color, Luminosity, Hue, Saturation. | P1 |
| L-5 | Layers panel with live thumbnails, drag-to-reorder, and visibility checkboxes. | P0 |
| L-6 | Import an image file as a new layer. | P0 |
| L-7 | Layer-level flip horizontal/vertical, rotate, and zoom. | P1 |

### 5.5 Image operations (Image menu)
| ID | Requirement | Pri |
|---|---|---|
| IMG-1 | Crop to Selection. | P0 |
| IMG-2 | Resize Image: by percentage or absolute size, keep aspect ratio, resampling choice (bicubic, bilinear, nearest-neighbor, supersampling). | P0 |
| IMG-3 | Resize Canvas: anchor grid and new dimensions. | P0 |
| IMG-4 | Flip horizontal and vertical. Rotate 90° CW, 90° CCW, 180°. | P0 |
| IMG-5 | Flatten. | P0 |
| IMG-6 | Auto-crop (trim uniform borders). | P1 |

### 5.6 Selection and editing (Edit menu)
| ID | Requirement | Pri |
|---|---|---|
| E-1 | Undo and redo (⌘Z / ⇧⌘Z), unlimited within a memory budget. | P0 |
| E-2 | Cut, Copy, Copy Merged, Paste, Paste into New Layer, Paste into New Image. | P0 |
| E-3 | Select All, Deselect, Invert Selection. A selection that covers no pixels counts as no selection (the whole image is editable). Deselect and Invert Selection are disabled when nothing is selected. Selection steps mark the document as edited. | P0 |
| E-4 | Erase Selection (⌫ Delete or ⌦ Forward Delete), Fill Selection with the primary color (⌥⌫ or menu). (On a Mac, "Delete" is Paint.NET's Backspace, hence the remapping.) | P0 |
| E-5 | Clipboard interop through `NSPasteboard`. Copy writes PNG (with alpha) and TIFF. Paste reads PNG first, then TIFF, then file URLs. | P0 |
| E-6 | Paste larger than the canvas: prompt to expand the canvas. | P0 |

### 5.7 History panel
| ID | Requirement | Pri |
|---|---|---|
| H-1 | A list of every history step, each with an icon and a name ("Paintbrush", "Gaussian Blur", and so on). | P0 |
| H-2 | Clicking a step jumps to that state. Undone steps appear greyed out until a new action discards them. | P0 |
| H-3 | History is integrated with `NSUndoManager`, so the Edit menu and the panel stay in sync. | P0 |
| H-6 | An action that changes nothing adds no history step. A single step larger than the whole budget is still kept. "1 GB" means 1 GiB (1,073,741,824 bytes). Undoing doesn't change the active layer unless the step itself changed the layer stack. | P0 |
| H-5 | When the undo memory budget (NF-4) is exceeded, the oldest steps are dropped (never the base "Open Image"/"New Image" step) and disappear from the History panel. H-4 later replaces dropping with disk spillover. | P0 |
| H-4 | Memory budget with spillover of old steps to disk (scratch files in the app's caches directory). | P1 |

### 5.8 Adjustments (Adjustments menu)
| ID | Adjustment | Pri |
|---|---|---|
| ADJ-1 | Auto-Level | P0 |
| ADJ-2 | Black and White | P0 |
| ADJ-3 | Brightness / Contrast | P0 |
| ADJ-4 | Curves (luminosity and RGB) | P0 |
| ADJ-5 | Hue / Saturation | P0 |
| ADJ-6 | Invert Colors | P0 |
| ADJ-7 | Levels | P0 |
| ADJ-8 | Posterize | P0 |
| ADJ-9 | Sepia | P0 |
| ADJ-10 | Exposure, Vibrance, Temperature/Tint (beyond Paint.NET's set) | P2 |

All adjustments **(P0)**: apply to the active layer and selection, show a live canvas preview while the dialog is open, and support Cancel and "Repeat last" (⌘F).

### 5.9 Effects (Effects menu)
Effects are grouped as in Paint.NET.

| Category | v1.0 (P0) | v1.x (P1) | Later (P2) |
|---|---|---|---|
| **Blurs** | Gaussian Blur, Motion Blur | Radial, Zoom, Surface, Unfocus | Fragment, Bokeh |
| **Photo** | Sharpen, Vignette | Glow, Soften Portrait, Red Eye Removal | |
| **Noise** | Add Noise | Median, Reduce Noise | |
| **Stylize** | Emboss, Edge Detect | Outline, Relief | |
| **Distort** | Pixelate | Bulge, Twist, Polar Inversion, Tile Reflection | Frosted Glass, Dents |
| **Artistic** | | Ink Sketch, Pencil Sketch, Oil Painting | |
| **Render** | Clouds | Julia Fractal, Mandelbrot Fractal | |
| **Object** | | Drop Shadow, Outline Object | |

Shared effect requirements:
- **FX-A (P0):** One protocol (`ImageEffect`) with a declared parameter schema. The configuration dialog and the live preview are generated from that schema automatically.
- **FX-B (P0):** Effects run on the GPU: Core Image filters or custom Metal kernels. Each effect also has a straightforward CPU reference implementation in the test target, used as the golden-image oracle (±1 per channel). Random effects (Add Noise, Clouds, and so on) take an explicit seed parameter, so results are deterministic.
- **FX-E (P0):** Parameter names, ranges, and defaults follow Paint.NET's documentation (getpaint.net/doc/latest); where it is silent, Paint.NET 5's dialog defaults are used.
- **FX-C (P0):** Effects can be cancelled, and the preview is progressive on large images.
- **FX-D (P0):** Effects respect the selection and only change selected pixels, with antialiased edges.

### 5.10 Colors panel
| ID | Requirement | Pri |
|---|---|---|
| C-1 | Primary/secondary color swatches with a swap button (X) and a reset to black/white (D). C switches which slot the panel edits (Paint.NET). Colors are app-wide, persisted, and are not history steps. | P0 |
| C-2 | Color wheel, RGB/HSV sliders, hex entry, and alpha, as custom SwiftUI controls in the Paint.NET style (not `NSColorPanel`). | P0 |
| C-3 | Default palette of 96 colors (Paint.NET style). Palettes can be saved and loaded. | P1 |
| C-4 | An eyedropper that picks colors from anywhere on screen (`NSColorSampler`). | P1 |

### 5.11 File formats
| ID | Format | Read | Write | Pri |
|---|---|---|---|---|
| F-1 | **Native layered format.** Use **OpenRaster (`.ora`)**: a ZIP of PNG layers plus `stack.xml`. It is an open standard and also opens in Krita and GIMP. | ✓ | ✓ | P0 |
| F-2 | PNG | ✓ | ✓ | P0 |
| F-3 | JPEG (with a quality slider and live file-size estimate on export) | ✓ | ✓ | P0 |
| F-4 | HEIC | ✓ | ✓ | P0 |
| F-5 | TIFF, BMP, GIF (first frame) | ✓ | ✓ | P0 |
| F-6 | WebP (write only if the OS supports it through ImageIO) | ✓ | ~ | P0 / P1 |
| F-7 | TGA, DDS, ICO | ✓ | ✓ | P2 |

- **FMT-A (P0):** Saving a multi-layer image to a flat format asks for confirmation and flattens the image on export only.
- **FMT-B (P0):** Embedded ICC profiles are read on import, and pixels are converted into the working space (sRGB in v1). Images without a profile are assumed to be sRGB. EXIF orientation is applied to the pixels on open and is not written back on save. The color stored under fully transparent pixels is preserved when the source provides straight alpha. CMYK, grayscale, and 16-bit or float images are converted to 8-bit sRGB RGBA on open without a warning. Saving always embeds an sRGB profile.
- **FMT-D (P0):** Animated GIF and WebP files open as their first frame, without a warning (§2.2).
- **FMT-E (P0) OpenRaster details.** The ZIP container is our own minimal reader/writer in `Core` (§4). `mimetype` is the first entry and is stored uncompressed. ZIP64 and encrypted archives are rejected with an alert. Layer opacity 0–255 is written as `round(x / 255, 3 decimals)` and read back as `round(f × 255)`. Blend modes use the standard `composite-op` names where they exist (`svg:src-over` Normal, `svg:multiply`, `svg:plus` Additive, `svg:color-burn`, `svg:color-dodge`, `svg:overlay`, `svg:difference`, `svg:lighten`, `svg:darken`, `svg:screen`) and `paintdotmac:reflect`, `paintdotmac:glow`, `paintdotmac:negation`, `paintdotmac:xor` for the rest (Krita shows those as Normal). Unknown ops are read as Normal. Layers that are larger than the canvas or offset from it are cropped to the canvas on import.
- **Saving (P0).** `autosavesInPlace` is off, so a JPEG is never silently re-encoded. Crash-recovery autosave (NF-5) writes `.ora` to the system autosave location. ⌘S writes the document in its own format (with the FMT-A confirmation when a layered image goes to a flat format). New documents default to `.ora`. Closing a document with unsaved changes asks whether to save.
- **FMT-C (P0):** Drag and drop image files onto the Dock icon, an open window (to add as a layer), or the app (to open).

### 5.12 Keyboard shortcuts (Paint.NET → Mac mapping)
General rule: **Ctrl → ⌘, Alt → ⌥**. Mac system shortcuts take precedence where they conflict.

| Action | Paint.NET | PaintDotMac |
|---|---|---|
| New / Open / Save / Save As | Ctrl+N/O/S, Ctrl+Shift+S | ⌘N/O/S, ⇧⌘S |
| Undo / Redo | Ctrl+Z / Ctrl+Y | ⌘Z / ⇧⌘Z |
| Deselect | Ctrl+D | ⌘D |
| Invert Selection | Ctrl+I | ⌘I |
| Crop to Selection | Ctrl+Shift+X | ⇧⌘X |
| Resize Image / Canvas | Ctrl+R / Ctrl+Shift+R | ⌘R / ⇧⌘R |
| Add New Layer | Ctrl+Shift+N | ⇧⌘N |
| Paste into New Layer / Image | Ctrl+Shift+V / Ctrl+Alt+V | ⇧⌘V / ⌥⌘V |
| Invert Colors | Ctrl+Shift+I | ⇧⌘I |
| Hue/Saturation / Levels / Curves | Ctrl+Shift+U / Ctrl+L / Ctrl+Shift+M | ⇧⌘U / ⌘L / ⇧⌘M |
| Repeat last effect | Ctrl+F | ⌘F |
| Hide app *(Mac reserved)* | — | ⌘H (so the Pan tool uses **H** without a modifier) |
| Minimize *(Mac reserved)* | — | ⌘M |
| Merge Layer Down | Ctrl+M | ⌘E (⌘M is Minimize) |
| Duplicate Layer / Delete Layer | Ctrl+Shift+D / Ctrl+Shift+Delete | ⇧⌘D / ⇧⌘⌫ |
| Flatten | Ctrl+Shift+F | ⇧⌘F |
| Layer Properties | F4 / double-click | Double-click the layer row |
| Rotate 90° CW / 90° CCW / 180° | Ctrl+H / Ctrl+G / Ctrl+H+H or Ctrl+G+G (older versions: Ctrl+J) | ⌘] / ⌘[ / ⌘J (⌘H is Hide) |
| Select All | Ctrl+A | ⌘A |
| Zoom In / Zoom Out | Ctrl++ / Ctrl+- | ⌘= / ⌘− |
| Actual Size / Zoom to Window / Zoom to Selection | Ctrl+0 / Ctrl+B / Ctrl+Shift+B | ⌘0 / ⌘B / ⇧⌘B |
| Erase Selection / Fill Selection | Delete / Backspace | ⌫ or ⌦ / ⌥⌫ |
| Brush width down / up | [ / ] | [ / ] (no modifier) |
| Show Tools / History / Layers / Colors panel | F5 / F6 / F7 / F8 | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 |
| Redo alias | Ctrl+Y | none (⇧⌘Z only) |
| Switch active color slot | C | C |
| Tools | S, M, Z, H, F, G, B, E, P, K, L, R, T, O | Same; single keys, active when no text field has focus |

Before implementing, check each mapping against Paint.NET's current documentation and record any conflicts in `docs/shortcuts.md`.

## 6. Non-functional requirements

| ID | Category | Requirement |
|---|---|---|
| NF-1 | Performance | Paintbrush latency under 16 ms per frame (60 fps), and 120 fps on ProMotion displays, on a 4000×3000 image on an M1 or newer. |
| NF-2 | Performance | Opening a 24 MP JPEG takes under 1 s. Pan and zoom stay at 60 fps or better on a 10-layer 4K document. |
| NF-3 | Performance | Gaussian Blur (radius 20) on a 24 MP layer finishes in under 500 ms on an M1. |
| NF-4 | Memory | Tiled storage (for example 256×256 tiles). Undo stores only changed tiles, and the undo memory budget can be configured (default 1 GB). |
| NF-5 | Reliability | Autosave and crash recovery through `NSDocument` (autosave elsewhere, as `.ora`; see §5.11 "Saving"). No data loss on a crash. |
| NF-6 | Quality | The core engine (blending, selection, flood fill, resampling, file I/O) has unit tests, and blend modes have golden-image tests. |
| NF-7 | Accessibility | VoiceOver labels on all controls and panels. Full keyboard navigation of menus and dialogs. Respects the Reduce Motion setting (static marching ants). |
| NF-8 | Size | App bundle under 30 MB. |
| NF-9 | Color | Working space in v1 is 8-bit-per-channel sRGB RGBA. Pixels are stored straight (non-premultiplied, as in Paint.NET) and premultiplied only during compositing. |

## 7. Proposed architecture

```
PaintDotMac.app
├── App (AppKit)           App delegate, main menu/commands, panel controllers, window management, Settings window
├── UI (SwiftUI)           Panels (Tools, Layers, History, Colors), tool options bar, status bar, dialogs (hosted in NSHostingView)
├── Canvas (AppKit+Metal)  MTKView-based canvas view, input handling, overlay rendering (selection, handles)
├── Document               NSDocument subclass, NSWindowController, read/write, autosave
├── Core (pure Swift; no AppKit/SwiftUI imports; may use Foundation, CoreGraphics, CoreImage, CoreText,
│         ImageIO, Metal, UniformTypeIdentifiers, Compression, simd, Accelerate)
│   ├── Model              Document → [Layer] → TiledSurface (RGBA8 tiles), Selection (path + rasterized mask)
│   ├── History            HistoryStack of HistoryItems (tile diffs, layer ops), NSUndoManager bridge
│   ├── Tools              Tool protocol: mouseDown/Dragged/Up, options model, commit/cancel
│   ├── Effects            ImageEffect protocol + parameter schema; Adjustments and Effects registry
│   ├── Rendering          CPU reference compositor, Metal compositor (blend-mode shaders), Core Image bridge
│   └── IO                 ImageIO codecs, OpenRaster reader/writer
└── Tests                  Unit + golden-image tests for Core
```

Key design principles:
1. **Core has no UI dependencies.** It can be tested headlessly and could later sit behind a CLI.
2. **Everything that changes pixels is a command** that produces a `HistoryItem`. Nothing mutates layers outside the history system.
3. **Effects are data-driven.** A parameter schema generates both the dialog UI and the preview pipeline, so adding an effect is roughly a 50-line file.
4. **Tiles everywhere.** Rendering, dirty regions, undo diffs, and GPU uploads all work in units of tiles.
5. **Swift concurrency.** Effects run off the main actor, can be cancelled with `Task.cancel()`, and report progress.

## 8. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0: Skeleton** | Xcode project, document-based app, open a PNG/JPEG, display it on the Metal canvas with zoom and pan, export a PNG. | Can open, view, and re-save an image. |
| **M1: Paint** | Tiled surface, Paintbrush, Pencil, Eraser, Color Picker, Colors panel, undo/redo, History panel. | Can draw on an image and undo through the History panel. |
| **M2: Select** | Rectangle, ellipse, lasso, and magic wand selections. Move tools, cut/copy/paste, Crop to Selection, Paint Bucket, Gradient. | Use case 1 works, apart from text and shapes. |
| **M3: Layers** | Layers panel, blend modes, opacity, OpenRaster save/load, Paste into New Layer. | Use case 3 works, and an `.ora` round-trips through Krita. |
| **M4: Adjust** | Effect framework (schema → dialog → preview), all P0 adjustments, Resize Image, Resize Canvas, rotate and flip. | Use case 2 works, apart from Sharpen. |
| **M5: Shapes & Text** | Line/Curve, Shapes, Text tool. | Use case 1 works fully. |
| **M6: Effects** | All P0 effects. | Every P0 effect works with live preview and can be cancelled. |
| **M7: Polish (v1.0)** | Shortcut audit, settings (APP-8), performance pass against the NF targets, accessibility, crash recovery, app icon, end-to-end use-case tests. | All P0 requirements met. |
| **v1.x** | All P1 items: docked panels, pixel grid and rulers, palettes and screen eyedropper, tablet pressure, Clone Stamp, Recolor, extended shapes, more blend modes, layer flip/rotate/zoom, auto-crop, disk-backed history, WebP export, the P1 effects. P2 items are not planned. | |

## 9. Success criteria
Since this is a personal project, success is measured qualitatively and against the performance targets:
- The author uses PaintDotMac in place of Preview or other tools for everyday screenshot and photo edits.
- All five key use cases (§3) can be done without leaving the app.
- The NF-1 to NF-3 performance targets are met on the author's machine.
- Adding a new effect takes under one hour, which validates the architecture.
- Someone familiar with Paint.NET can find every P0 tool and menu item without help.

## 10. Risks and open questions

| # | Item | Notes / mitigation |
|---|---|---|
| R-1 | **Metal canvas complexity.** Tiled compositing, high-DPI handling, and zoom filtering are the hardest parts. | Build M0 first and prototype the canvas early. Fall back to Core Image compositing if needed. |
| R-2 | **Selection antialiasing and the magic wand** are hard to get right and fast. | Keep the selection as a vector path plus a cached rasterized 8-bit mask. |
| R-3 | **Shortcut conflicts** with macOS (⌘H, ⌘M, Ctrl-click, Space). | Use the mapping table in §5.12. Tool keys work without modifiers. |
| R-4 | **Scope creep.** The effect list is large. | Hold to the P0 list strictly. Effects are cheap to add once the framework exists. |


Resolved on 2026-11-04 (moved into their sections):
- **Q-1 Minimum macOS:** macOS 15 (§4).
- **Q-2 Pixel format:** the pixel format sits behind a `PixelFormat` abstraction in `TiledSurface`, but only RGBA8 straight sRGB is implemented in v1, with no 16-bit or P3 code paths (NF-9).

## 11. References
- Paint.NET: https://www.getpaint.net/ (product site), https://www.getpaint.net/doc/latest/ (documentation: tools, menus, shortcuts)
- OpenRaster specification: https://www.openraster.org/
- Apple: Metal, Core Image, ImageIO, `NSDocument`, `NSUndoManager`, and `NSPasteboard` documentation.

## 12. Decision log
Planning decisions made on 2026-11-04 when the PRD was split into specs (`docs/specs/todo/0001`–`0069`). Each one is already written into the section named.

| # | Decision | Where |
|---|---|---|
| D-1 | Minimum macOS 15 (Q-1). | §4 |
| D-2 | `PixelFormat` abstraction, RGBA8 sRGB only (Q-2). | NF-9, §10 |
| D-3 | XcodeGen, scheme and targets, bundle ID, ad hoc signing, test frameworks, UI-test launch hooks. | §4 |
| D-4 | AppKit app lifecycle with `NSDocument`; SwiftUI for panels, bars, dialogs, and Settings. | §4, §7 |
| D-5 | v1.0 panels are app-wide floating `NSPanel`s toggled with ⌥⌘1–4. | APP-2 |
| D-6 | `autosavesInPlace` off; `.ora` crash-recovery autosave; ⌘S keeps the document's format; new documents default to `.ora`. | §5.11 Saving, NF-5 |
| D-7 | Per-document DPI (default 96) drives in/cm units. | APP-5 |
| D-8 | Image size limits. | APP-10 |
| D-9 | Undo budget overflow drops the oldest steps. | H-5 |
| D-10 | New Image dialog. | APP-9 |
| D-11 | Clipboard formats and order. | E-5 |
| D-12 | Shortcut remappings (Merge Down, Rotate, Erase/Fill, layer, zoom, panels, brush width; no ⌘Y). | §5.12, E-4 |
| D-13 | Tool group cycling order; selection changes are history steps. | §5.3 |
| D-14 | Tablet pressure is P1 only. | T-11, TOOL-D |
| D-15 | Brush blend-mode list grows with the implemented layer blend modes. | T-11 |
| D-16 | CPU reference compositor; Metal for display only, ±1 parity. | §4 Rendering |
| D-17 | Paint.NET `UserBlendOps` formulas; Xor is color XOR. | L-3 |
| D-18 | Own ZIP implementation for OpenRaster; ORA blend-op names, opacity rounding, cropping of oversized layers. | §4, FMT-E |
| D-19 | Frameworks allowed in `Core`. | §7, AGENTS.md |
| D-20 | Custom SwiftUI color controls. | C-2 |
| D-21 | Move Selected Pixels resampling. | T-5 |
| D-22 | GPU effects with CPU reference oracles; seeded random effects; Paint.NET parameter ranges. | FX-B, FX-E |
| D-23 | Settings (APP-8) is built in M7. | APP-8, §8 |
| D-24 | Color management on open and save; CMYK/16-bit conversion; first frame of animations. | FMT-B, FMT-D |
| D-25 | Text tool fonts and commit gestures. | T-17 |
| D-26 | v1.x P1 items are planned (specs 0052–0069); P2 is not. | §8 |
| D-27 | Eraser options and strength (no blend mode; strength = color-slot alpha; full erase → transparent black). Paint.NET's tool-only "Overwrite" blend mode is not in v1.0. | T-12 |
| D-28 | Color Picker sampling sizes, ⌘-click Image sampling, after-click options and defaults. | T-14 |
| D-29 | 100% = one image pixel per device pixel; initial zoom min(100%, fit); 1% is the lowest preset; no scroll bars in v1.0. | CAN-6 |
| D-30 | New Image DPI range, clipboard DPI ignored, untouched new image is clean. | APP-9 |
| D-31 | C switches the active color slot. | C-1, §5.12 |
| D-32 | Default memory cap = physical memory ÷ 4. | APP-10 |
| D-33 | EXIF orientation applied on open; color under alpha 0 preserved. | FMT-B |
| D-34 | No-op edits add no step; oversized steps kept; 1 GiB; undo doesn't switch layers. | H-6 |
| D-35 | Tool-key cycling window (1 s, Shift reverses); start tool Paintbrush, not remembered. | §5.3 |
| D-36 | Until a panel's spec lands, its floating panel shows "Not available yet."; document windows follow the system "Prefer tabs" setting (`tabbingMode = .automatic`). | APP-1, APP-2 |
| D-37 | `-UITestResetDefaults` clears the `tool.`, `panel.`, `colors.`, and `settings.` defaults and panel frames. | §4 Testing |
| D-39 | Lasso Freeform/Polygon modes; even-odd fill. | T-2 |
| D-40 | Empty selection = no selection; Deselect/Invert disabled without a selection; selection steps mark the document edited; extra debug launch hooks. | E-3, §4 Testing |
| D-41 | Shift+tool key outside the cycling window selects the group's last tool. | §5.3 |
| D-42 | Paint Bucket: commit on click, Fill: Similar Color / Selection option, 3×3 antialiasing ring, no Tolerance Alpha Mode (user-confirmed). | T-9 |
| D-43 | Magic Wand defaults (50%, Layer), Paint.NET 3.36 tolerance metric, 4-connectivity, synchronous fill. | T-4 |
| D-38 | Brush strokes are continuous (no Spacing/Smoothing/Fill Style options in v1.0); brush tools show a brush-outline cursor. | T-11 |
