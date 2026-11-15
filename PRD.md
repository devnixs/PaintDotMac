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
| **Project** | **XcodeGen**: `project.yml` is the source of truth; the generated `PaintDotMac.xcodeproj` is git-ignored and never hand-edited. Scheme `PaintDotMac` with targets `PaintDotMac` (app) and `PaintDotMacTests` (unit, golden-image, and headless integration tests). There is no UI test target. Bundle identifier `com.thera-engineering.paintdotmac`. |
| **Testing** | Swift Testing for unit, golden-image, and integration tests; XCTest only for `measure` performance tests. **All automated tests are headless** (decided 2026-11-14): no XCUITest, no UI test target, no tests that launch the app as a separate process, no launch smoke test, and no test that puts a window, panel, sheet, or alert on screen. The tests run hosted in the app; in test-host mode (`PAINTDOTMAC_HEADLESS_TESTS=1`, set by the scheme's test action) the app sets its activation policy to `.prohibited` and opens no windows. UI code is tested in-process through offscreen views, synthesized `NSEvent`s, direct action calls, and injected presenters; test-only configuration is injected in-process (there are no `-UITest*` launch hooks; the only debug launch argument is `-PerfFrameProbe <path>` (0048), which the author passes by hand when profiling and no test uses). What only a person can check goes into each spec's manual verification checklist. Test-only environment variables: `RECORD_GOLDENS=1` (record golden images after oracle confirmation), `RECORD_SHORTCUT_DOCS=1` (regenerate `docs/shortcuts.md`), `PAINTDOTMAC_TEST_SEED` (override the seeded-random seed). Sanitizer runs are best-effort (they are unavailable on some macOS/Xcode combinations) and are never required for a spec to pass. |
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
| Zoom In / Zoom Out | Ctrl++ / Ctrl+- | ⌘= (⌘+ also) / ⌘− |
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
| D-3 | XcodeGen, scheme and targets, bundle ID, ad hoc signing, test frameworks, headless-only testing (no UI test target, no launch hooks; revised 2026-11-14). | §4 |
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
| D-37 | Superseded 2026-11-14 (headless-only testing): there is no `-UITestResetDefaults` hook; tests use a throwaway `UserDefaults` suite. Persisted UI state still lives under the `tool.`, `panel.`, `colors.`, and `settings.` prefixes. | §4 Testing |
| D-39 | Lasso Freeform/Polygon modes; even-odd fill. | T-2 |
| D-40 | Empty selection = no selection; Deselect/Invert disabled without a selection; selection steps mark the document edited. (Its debug launch hooks were dropped 2026-11-14 with headless-only testing.) | E-3, §4 Testing |
| D-41 | Shift+tool key outside the cycling window selects the group's last tool. | §5.3 |
| D-42 | Paint Bucket: commit on click, Fill: Similar Color / Selection option, 3×3 antialiasing ring, no Tolerance Alpha Mode (user-confirmed). | T-9 |
| D-43 | Magic Wand defaults (50%, Layer), Paint.NET 3.36 tolerance metric, 4-connectivity, synchronous fill. | T-4 |
| D-38 | Brush strokes are continuous (no Spacing/Smoothing/Fill Style options in v1.0); brush tools show a brush-outline cursor. | T-11 |

D-44 – D-95: the 221 open questions listed in the specs' *Open questions* sections, approved by the
user on 2026-11-15 ("accept all" — every recommendation as written in its spec, one row per spec).
Each spec's Open-questions section now points here; the corresponding spec implementers fold the
behavior into the named PRD sections as they build.

| # | Decision | Where |
|---|---|---|
| D-44 | 0014: (a) No resize handles after drawing a rectangle/ellipse selection; resizing is left to Move Selection → keep; (b) Zoom to Selection is disabled with no selection → disabled; (c) A drag counts as moved only when the pointer reaches another pixel → keep; (d) Selection mode and clipping are shared by all selection tools → keep. | spec 0014 |
| D-45 | 0018: (a) Erase/Fill Selection act on the whole layer when nothing is selected — as stated; (b) Fill Selection overwrites rather than blends (contrast Paste normal-blending, D-48) → overwrite; (c) Shift+⌫ (fill with the secondary color) is not mapped → unmapped. | spec 0018 |
| D-46 | 0019: (a) One history step per mouse-up and per arrow key; no "Finish Selection" step — as stated; (b) With no selection, Move Selection does Select All first — as stated; (c) An outline moved fully off the canvas becomes no selection but can be dragged back — as stated; (d) Include the rotation band outside the frame and ⌥ to scale about the center → include. | spec 0019 |
| D-47 | 0020: (a) Escape cancels the whole move (Paint.NET's Escape commits) → cancel; (b) The layer shows floating pixels; saving doesn't finish them — as stated; (c) Undo, redo, jump and save never finish floating pixels; other commands add "Finish Pixels" first — as stated; (d) Scale handles snap to whole pixels while unrotated — as stated. | spec 0020 |
| D-48 | 0021: (a) Cut leaves transparent black and deselects → yes; (b) Cut is disabled with no selection — as stated; (c) Paste into New Image puts the pixels on a white Background → yes; (d) Pasted pixels blend normally rather than overwrite → normal blend; (e) After a canvas-size change, keep the zoom and re-center — as stated. | spec 0021 |
| D-49 | 0022: (a) Crop makes unselected pixels transparent black and scales edge alpha by selection coverage — as stated; (b) The selection is kept after a crop, moved to the new origin — as stated. | spec 0022 |
| D-50 | 0023: (a) The Gradient's Antialiasing option only affects the selection edge — as stated; (b) Gradient colors are captured when the gradient is created → yes; (c) Transparency Mode follows Paint.NET's documented rule → follow Paint.NET. | spec 0023 |
| D-51 | 0024: (a) A duplicated layer is named "<name> copy" — as stated; (b) Merge Down merges a hidden upper layer anyway — as stated; (c) Flatten keeps the bottom layer's name — as stated; (d) Deleting a layer makes the layer below active — as stated; (e) Until 0029 lands, saving a layered image as PNG is refused — as stated; (f) Switching layers isn't a history step — as stated. | spec 0024 |
| D-52 | 0025: (a) History steps for the visibility checkbox are named "Hide Layer"/"Show Layer" — as stated; (b) Dragging a layer several positions is one history step — as stated. | spec 0025 |
| D-53 | 0026: Blend math can differ from Paint.NET by up to ±5/±7 on semi-transparent pixels (exact when both pixels are opaque) → accept. | spec 0026 |
| D-54 | 0028: (a) Non-integer DPI is rounded when saving .ora → round; (b) Layer groups in imported .ora files are flattened → flatten; (c) An .ora with a missing or damaged layer PNG is refused → refuse. | spec 0028 |
| D-55 | 0029: (a) The flatten-on-save prompt is asked once per document session per file and format — as stated; (b) JPEG export puts transparency onto white — as stated; (c) GIF export uses an alpha threshold of 128, with no dithering — as stated; (d) BMP files carry no sRGB profile (exception to FMT-B); 32-bit when any pixel is transparent — as stated; (e) HEIC is saved at fixed quality 0.90 with no dialog — as stated; (f) The JPEG Options dialog appears on every JPEG save; quality 0–100, default 95 — as stated; (g) Wording of the JPEG Options dialog and the "Flatten image?" prompt — as stated. | spec 0029 |
| D-56 | 0030: (a) An imported layer is named after the file, without extension — as stated; (b) Import or drop places pixels at (0,0); a single file floats, several files are placed directly — as stated; (c) Importing a layered .ora adds its composite as one layer — as stated; (d) Copy Merged is ⇧⌘C — as stated; (e) Import grows the canvas automatically with no prompt — as stated. | spec 0030 |
| D-57 | 0031: (a) One shared ⌘F "Repeat" for adjustments and effects — as stated; (b) Effect parameters are remembered for the session only — as stated; (c) Effects run on hidden layers — as stated; (d) Adjustments also change the color stored under fully transparent pixels — as stated; (e) The progress sheet appears after 0.5 s — as stated. | spec 0031 |
| D-58 | 0032: (a) Black and White ⇧⌘G, Sepia ⇧⌘E, Posterize ⇧⌘P → keep; (b) Sepia has no dialog — as stated; (c) Hue/Saturation uses exact integer math (differs from Paint.NET 3.36 by a few levels on under 0.5% of colors) → accept; (d) Saturation range 0–200, default 100 — as stated. | spec 0032 |
| D-59 | 0033: (a) The Levels histogram ignores alpha (Paint.NET 3.36) → mirror 3.36; (b) Paint.NET 3.36's Levels dialog quirks are not reproduced — as stated; (c) Auto-Level does nothing if any one channel is flat → mirror 3.36; (d) Auto-Level is ⇧⌘L — as stated. | spec 0033 |
| D-60 | 0034: (a) Curves points are removed only by right-click or Control-click → yes; (b) Curves keeps both the Luminosity and RGB curves — as stated; (c) Clicking near an existing point moves it instead of adding one — as stated. | spec 0034 |
| D-61 | 0035: (a) Resize Image clears the selection → clear; (b) Supersampling falls back to Bicubic when enlarging — as stated; (c) Bilinear and Bicubic use simple kernels that alias on big reductions → keep; (d) Changing the resolution keeps the print size, so the pixel count changes — as stated; (e) The Resize dialog starts from defaults every time; no extra Paint.NET 5 resamplers — as stated; (f) The print-size unit starts as cm when the status bar shows cm — as stated. | spec 0035 |
| D-62 | 0036: (a) Canvas Size fills new area with the secondary color on the bottom layer; no Fill choice — as stated; (b) With a centered anchor, an odd extra pixel goes on the right or bottom — as stated; (c) The selection is kept on the same pixels after Canvas Size — as stated; (d) Canvas Size dialog defaults; history step named "Canvas Size" — as stated; (e) Editing the resolution field changes the document's DPI — as stated. | spec 0036 |
| D-63 | 0037: Flip/Rotate Image transforms the selection along with the image → transform. | spec 0037 |
| D-64 | 0038: (a) Line/Curve is one Bézier with 4 handles plus drag-to-bend; no extra curve types — as stated; (b) ⌘Z while a line is still editable commits it, then undoes it — as stated; (c) Dash styles, cap styles and arrowhead size — as stated. | spec 0038 |
| D-65 | 0039: (a) Starter shapes: Paint.NET 5's Basic group (8 shapes) — as stated; (b) Outline drawn inside the box, pixel-exact highlight rectangles — as stated; (c) Shape editing gestures reuse Move Selection's handles — as stated; (d) One "Shapes" history step per shape — as stated; (e) Shapes tool defaults — as stated; (f) A / Shift+A cycle through shape types — as stated. | spec 0039 |
| D-66 | 0040: (a) Escape commits text (Paint.NET behavior) → commit; (b) Text size in points at the document's DPI (12 pt at 96 DPI = 16 px) — as stated; (c) Text tool has a Blend mode option — as stated; (d) No text clipboard; menu commands commit the text first — as stated; (e) Text being typed takes on primary-color changes live — as stated. | spec 0040 |
| D-67 | 0041: (a) Gaussian Blur: Paint.NET 3.36's kernel shape with exact math and edge clamping (not a bit-exact port) — as stated; (b) Motion Blur: same approach as Gaussian Blur — as stated; (c) No Paint.NET 5 extra blur options → omit. | spec 0041 |
| D-68 | 0042: (a) Sharpen has only Amount (1–20, default 2) — as stated; (b) Sharpen reproduces 3.36's off-by-one median exactly → keep; (c) Vignette follows Paint.NET's algorithm and ranges — as stated; (d) Vignette's center is relative to the selection bounds — as stated. | spec 0042 |
| D-69 | 0043: (a) ⌘F Repeat on Add Noise/Clouds uses a fresh random seed — as stated; (b) Parameter labels follow the Paint.NET 5 docs — as stated; (c) Clouds has 256 distinct patterns (byte seed, as in 3.36) — as stated; (d) Ranges and defaults from the 3.36 source — as stated; (e) Add Noise uses its own deterministic per-pixel random numbers, so output never matches Paint.NET pixel for pixel — as stated. | spec 0043 |
| D-70 | 0044: (a) Emboss and Edge Detect output fully opaque pixels → keep; (b) Emboss and Edge Detect clamp at the image edges → clamp; (c) Pixelate uses Paint.NET 3.36's corner-blend algorithm — as stated; (d) Edge Detect is the 3.36 angle-based version — as stated; (e) Angle range −180…180 — as stated. | spec 0044 |
| D-71 | 0045: (a) Go to Layer Above/Below are ⌥⇞/⌥⇟ — as stated; (b) Brightness/Contrast is ⇧⌘T — as stated; (c) Line/Curve's , . / keys are not mapped — as stated; (d) The other unmapped Paint.NET shortcuts stay unmapped — as stated; (e) Layer Rotate/Zoom has no shortcut (Paint.NET's collides with Redo) — as stated. | spec 0045 |
| D-72 | 0046: (a) "Checkerboard style" = brightness and size popups — as stated; (b) "Restore panel positions" = a Reset Panel Positions button — as stated; (c) The Settings unit and the status-bar unit are the same setting — as stated; (d) Lowering the undo limit applies immediately; presets from 256 MB to 8 GB — as stated; (e) Settings is one grouped pane; changes apply immediately — as stated. | spec 0046 |
| D-73 | 0047: (a) Autosave runs 30 s after a change — as stated; (b) Recovery restores the layers as displayed, but not the selection or undo history — as stated; (c) The recovered autosave wins over a changed original file — as stated; (d) No recovery UI of our own; macOS window restoration only — as stated. | spec 0047 |
| D-74 | 0048: (a) New Benchmarks target, scheme and build configuration — as stated; (b) Benchmarks run only with the gate's `--benchmarks` option — as stated; (c) If an NF target can't be met on your Mac, you decide whether to relax it or add a follow-up spec — as stated; (d) "120 fps" is tested as at most 8.33 ms of work per frame; real 120 Hz is a manual check — as stated; (e) While a background Magic Wand fill is running, a second click is ignored and other actions cancel it — as stated. | spec 0048 |
| D-75 | 0049: (a) VoiceOver reads the canvas as the image size, with zoom/layer/tool in its help text — as stated; (b) What Increase Contrast changes — as stated; (c) The color wheel is adjustable with VoiceOver but isn't in the Tab order — as stated; (d) Curves points can't be edited from the keyboard — as stated; (e) Keyboard model for the panels and lists — as stated. | spec 0049 |
| D-76 | 0050: (a) App icon: white paintbrush and canvas frame on orange #D9480F → accepted as proposed; (b) No custom .ora document icon — as stated; (c) Version set to 1.0.0, build number 1 — as stated; (d) About panel shows "© 2026 Thera Engineering" with no credits line — as stated; (e) The 30 MB size limit means 30,000,000 bytes of the universal Release app — as stated. | spec 0050 |
| D-77 | 0051: (a) All NF requirements count as P0 for the coverage test — as stated; (b) Which statements without an ID count as P0 requirements — as stated; (c) Use case 2's test starts from a PNG photo — as stated; (d) withdrawn: no `-UITestWindowContentSize` launch hook — tests are headless (PRD §4 Testing). | spec 0051 |
| D-78 | 0052: (a) Docking is done with commands, not dragging — as stated; (b) Tools docks on the left; History, Layers and Colors stack on the right — as stated; (c) By default all panels float — as stated; (d) Reset Panel Positions also resets the dock layout — as stated; (e) Docked History/Layers show their own window's document; a window widens to fit its docks — as stated. | spec 0052 |
| D-79 | 0053: (a) Pixel Grid is ⌘' — as stated; (b) Rulers is ⌥⌘R — as stated; (c) Grid and ruler toggles are app-wide, saved, and off by default — as stated; (d) The pixel grid appears from 200% zoom, with the look specified — as stated; (e) Ruler details; no guides — as stated. | spec 0053 |
| D-80 | 0054: (a) The default 96-color palette is transcribed from a Paint.NET palette file — as stated; (b) The screen eyedropper sets the active color slot — as stated; (c) How lenient palette-file parsing is — as stated; (d) Add Color mode ends after one replacement — as stated; (e) Palettes save and load by name, as in Paint.NET, with no file dialogs — as stated. | spec 0054 |
| D-81 | 0055: (a) Force Touch trackpad pressure is ignored — as stated; (b) Pressure Sensitivity option (Off/Size/Opacity/Both), default Size — as stated; (c) Width at zero pressure is 10% of the brush width, linear response — as stated; (d) The pressure option is always shown — as stated; (e) The brush outline shows the full width, not the pressure width — as stated. | spec 0055 |
| D-82 | 0056: (a) Clone Stamp keeps a fixed (aligned) offset only — as stated; (b) Clone Stamp gets a Layer/Image sampling option — as stated; (c) A source outside the canvas counts as transparent — as stated; (d) Dragging with no source set does nothing; a hint is shown — as stated; (e) Clone Stamp uses the Paintbrush defaults — as stated. | spec 0056 |
| D-83 | 0057: (a) Recolor has "Once" and "Secondary Color" sampling, default Secondary Color — as stated; (b) Recolor shifts alpha too (Paint.NET 4/5 behavior) — as stated; (c) Recolor's color match is all-or-nothing — as stated; (d) Recolor has pressure sensitivity and uses the Magic Wand's tolerance — as stated. | spec 0057 |
| D-84 | 0058: (a) Names of the extended shapes — as stated; (b) Shape geometry defined by the spec (Paint.NET shows only icons) — as stated; (c) The Rounded Rectangle Callout has a fixed 10% corner radius — as stated; (d) Grouped shape picker; A cycles through all 29 shapes — as stated. | spec 0058 |
| D-85 | 0059: (a) The extra blend modes use the W3C formulas (Paint.NET doesn't define them) — as stated; (b) They are added after Xor in the menus — as stated. | spec 0059 |
| D-86 | 0060: (a) Rotate/Zoom controls (angle, pan, zoom, sampling) — as stated; (b) Layer flips ignore the selection; Rotate/Zoom works like an effect — as stated; (c) Add Layers ▸ Rotate 180°; menu and history names — as stated; (d) The Rotate/Zoom dialog always opens at defaults and isn't a Repeat target — as stated. | spec 0060 |
| D-87 | 0061: (a) Auto-Crop is a PaintDotMac addition on ⌥⌘X (not found in Paint.NET's docs) — as stated; (b) The border color is the top-left pixel — as stated; (c) Exact color match, no tolerance — as stated; (d) The selection is kept after Auto-Crop — as stated; (e) Auto-Crop with nothing to trim does nothing, with no message — as stated; (f) Auto-Crop sits right after Crop to Selection in the Image menu — as stated. | spec 0061 |
| D-88 | 0062: (a) History stored on disk is limited to 4× the undo limit, keeping at least 2 GiB free — as stated; (b) The Settings note becomes "older history steps are moved to disk" — as stated; (c) A warning appears if history on disk can't be read — as stated; (d) A "Loading History" progress sheet for long jumps — as stated; (e) History files go in ~/Library/Caches/PaintDotMac/History/ — as stated. | spec 0062 |
| D-89 | 0063: (a) WebP export only where ImageIO can write it; no libwebp dependency → no libwebp; (b) No WebP "Lossless" checkbox — as stated; (c) A WebP Options sheet, default quality 95 — as stated; (d) WebP may lack an embedded sRGB profile, as with BMP — as stated. | spec 0063 |
| D-90 | 0064: (a) Radial and Zoom Blur keep 3.36's sampling layout but with smooth sampling — as stated; (b) Surface Blur and Unfocus handle transparency correctly, unlike 3.36 — as stated; (c) Blur center range is −1…1 of the selection bounds — as stated; (d) No Paint.NET 5 extras for Zoom/Radial Blur — as stated; (e) Unfocus is kept (Paint.NET 5 replaced it with Bokeh) — as stated; (f) Surface Blur is slow at large radii; only measured, not optimized → accept. | spec 0064 |
| D-91 | 0065: (a) Glow and Soften Portrait are built from our own blur and adjustments — as stated; (b) Red Eye Removal uses 3.36's parameters plus a hint to select the eyes first — as stated; (c) Red Eye Removal uses exact integer math — as stated. | spec 0065 |
| D-92 | 0066: (a) Median, Reduce Noise and Outline reproduce 3.36's off-by-one exactly — as stated; (b) Outline keeps a 3.36 transparency bug → keep (fidelity to 3.36); (c) Median stays under Noise, as the PRD says — as stated; (d) Relief uses the same approach as Edge Detect — as stated; (e) No Paint.NET 5 Quality options — as stated. | spec 0066 |
| D-93 | 0067: (a) Distort effects use 3.36's geometry with smooth sampling — as stated; (b) Center and radius are relative to the selection bounds — as stated; (c) Paint.NET 3.36 parameter sets only — as stated; (d) Labels "Scale", "Offset" and "Amount / Direction" — as stated. | spec 0067 |
| D-94 | 0068: (a) Ink Sketch keeps the source transparency → keep; (b) Oil Painting is a bit-exact port of 3.36 — as stated; (c) Ink and Pencil Sketch are built from our own Glow and Blur — as stated; (d) Ranges and defaults from the 3.36 source — as stated. | spec 0068 |
| D-95 | 0069: (a) Fractals computed in single precision (pixels near the set boundary differ from Paint.NET) — as stated; (b) Fractals fit the selection and have a Blend mode — as stated; (c) Drop Shadow parameters and math — as stated; (d) Outline Object (a plugin, not a Paint.NET effect) defined by the spec → keep, as a PaintDotMac addition defined by the spec. | spec 0069 |
