# 0045 — Move every shortcut into one audited `ShortcutTable`, generate `docs/shortcuts.md`, and check it against Paint.NET and macOS

> Source: PRD.md §5.12 (full table, "check each mapping against Paint.NET's current documentation and record any conflicts in `docs/shortcuts.md`"), §10 R-3 ("Shortcut conflicts with macOS (⌘H, ⌘M, Ctrl-click, Space). Use the mapping table in §5.12. Tool keys work without modifiers."), §5.3 (tool keys, D-13 cycling order, D-35, D-41), §5.6 E-4, §5.10 C-1, §12 D-12, D-13, D-25, D-31, D-35, D-41; AGENTS.md architecture rule 9 ("Shortcuts follow PRD §5.12: Ctrl → ⌘ and Alt → ⌥, macOS-reserved shortcuts win, and single-key tool shortcuts only fire when no text field has focus") and the `Core/Shortcuts/` layout entry.
> Paint.NET docs (fetched 2026-11-08; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Keyboard & Mouse Commands — https://paint.net/doc/latest/KeyboardMouseCommands.html (all Paint.NET values quoted below come from this page unless another page is named).
> Milestone: M7
> Depends on: 0044-stylize-and-distort-effects (and through it every spec 0001–0044 that adds a menu item or key; it refactors their code)

## Context

Every spec so far defines its own key equivalents inline, and each one says that 0045 centralizes them:

- `App/MainMenu.swift` (0001, `docs/specs/todo/0001-project-and-document-shell_TODO.md:100-140`) builds the menu bar in code with literal `keyEquivalent`/`keyEquivalentModifierMask` per item. Later specs add items the same way: 0004 View zoom items incl. a hidden `⌘+` alternate (`0004…:104-110`), 0005 File items (`0005…:146`), 0006 Window panel toggles ⌥⌘1–4 (`0006…:286`), 0013 Select All/Deselect/Invert Selection (`0013…:196-219`), 0014 Zoom to Selection ⇧⌘B (`0014…:175`), 0018 Erase/Fill Selection ⌫/⌥⌫ (`0018…:128-133`), 0021 clipboard (`0021…:307`), 0022/0035/0036/0037 Image menu (`0037…:111-119`), 0024 Layers menu (`0024…:156-169`; Go to Layer Above/Below deliberately get "none", "0045 audits"), 0025 Layer Properties… (no key, `0025…:150`), 0030 Copy Merged ⇧⌘C / Paste into New Layer ⇧⌘V / Import From File… (`0030…:220-224`), 0031 Adjustments/Effects menus generated from `ImageEffect.shortcut: EffectShortcut?` ("0045 later moves it into ShortcutTable", `0031…:88-99`, `:286`), 0032/0033/0034 adjustment shortcuts (`0032…:78-112`, `0033…:129-131`, `0034…:113`), 0046 (on disk, built after this spec) keeps "Settings…" ⌘, "coming from 0045's `ShortcutTable`" (`0046…:161`).
- Single-key shortcuts are scattered: 0006 `ToolRegistry.allDescriptors` has a literal `shortcutKey` column and `allShortcutKeys` (`0006…:135-170`); 0007 `ColorKeyCommand.command(forCharactersIgnoringModifiers:command:option:control:)` hard-codes x/d/c (`0007…:41`); 0009 hard-codes `[`/`]` in `CanvasInputRouter` (`0009…:114`); 0018 `SelectionPixelCommand.command(forKeyCode:modifiers:)` hard-codes key codes 51/117 (`0018…:110-121`); 0039 `ShapesTool.keyDown` hard-codes `a` / Shift+A (`0039…:133`); 0019/0020/0038/0039 use `TransformHandles.nudge(for:)` for arrows and ⌘-arrows (`0019…:88,102`); 0006's `Tool.keyDown` default maps Return/Enter → commit, Escape → cancel (`0006…:120`); 0040 maps ⌘↩ and Escape → commit for Text (`0040…:163-164`).
- All single-key shortcuts pass through one gate, `ToolShortcutGate.allows(modifiers:keyWindow:textInputHasFocus:toolCapturesKeyboard:gestureInProgress:)` (`0006…:169`), and `CanvasInputRouter.textInputHasFocus(in:)` (factored out by 0018, `0018…:136`). This spec keeps that gate and verifies it end to end.
- There is no `docs/shortcuts.md` yet, and nothing checks that the menu matches PRD §5.12, that no two items share a chord, or that no item takes a macOS-reserved chord. 0001's `MainMenuTests.noDuplicateShortcuts` only checks duplicates in the menu tree.

**Audit result against Paint.NET's Keyboard & Mouse Commands page** (recorded in `docs/shortcuts.md` through the table's status/notes; the full list is in *Scope* item 2):
- Matches by Ctrl → ⌘ / Alt → ⌥: New, Open, Close (Ctrl+W), Save, Save As, Undo, Cut, Copy, Copy Merged, Paste, Paste into New Layer, Paste into New Image, Select All, Deselect, Invert Selection, Zoom In/Out, Actual Size, Zoom to Window, Zoom to Selection, Crop to Selection, Resize, Canvas Size, Flatten, Add New Layer, Delete Layer, Duplicate Layer, Auto-Level, Black and White, Curves, Hue / Saturation, Invert Colors, Levels, Posterize, Sepia, Repeat (Ctrl+F), all tool letters, X (swap), C (switch active color), `[`/`]`, Space-drag pan, Shapes A / Shift+A.
- Remapped (decided, PRD §5.12 / D-12): Redo Ctrl+Y → ⇧⌘Z; Merge Layer Down Ctrl+M → ⌘E; Rotate 90° CW/CCW Ctrl+H/Ctrl+G → ⌘]/⌘[; panels F5–F8 → ⌥⌘1–4; Layer Properties F4 → double-click; Erase Selection Delete → ⌫ or ⌦; Fill Selection Backspace → ⌥⌫ (on a Mac keyboard the key labelled "delete" is Paint.NET's Backspace).
- **Paint.NET column correction:** PRD §5.12 lists Rotate 180° as "Ctrl+J". The current page lists "Ctrl + H + H or Ctrl + G + G" and no Ctrl+J (Ctrl+J was the 3.x binding). PaintDotMac keeps ⌘J (D-12); `docs/shortcuts.md` records the current Paint.NET value. No behavior question.
- **Paint.NET has a shortcut PaintDotMac's specs left out:** Brightness/Contrast "Ctrl + Shift + T" (0031 says "Paint.NET has none", which is wrong for the current docs) → Open question 2. Go to Layer Above/Below "Alt + PgUp / Alt + PgDn" (0024 deferred them) → Open question 1.
- **Not mapped in v1.0** (Paint.NET shortcut whose feature is not in v1.0, or whose key is taken on macOS) → Open questions 4–6.
- **PaintDotMac additions with no Paint.NET key on that page:** D (reset colors, PRD C-1), ⌘↩ commits text (D-25), ⌘, Settings (Mac standard; Paint.NET "Alt + X"), ⌃⌘F Enter Full Screen, ⌘H/⌥⌘H/⌘Q/⌘M (Mac standard).

## User story

As a PaintDotMac user coming from Paint.NET, every shortcut I know either works with Ctrl → ⌘ and Alt → ⌥ or has a documented Mac replacement in `docs/shortcuts.md`; no shortcut steals a macOS system shortcut; no two commands share a key; and typing letters into a text field (the New Image width, the hex field, the Text tool) types text instead of switching tools.

## Scope & changes

### Core (pure Swift, unit-tested; no AppKit)

1. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (new) — the single source of truth for every menu key equivalent, every global single-key shortcut, every tool-local key, and (documentation only) the pointer modifiers and macOS-provided shortcuts.

   ```swift
   public struct ShortcutModifiers: OptionSet, Sendable, Hashable {
       public let rawValue: UInt8
       public static let command, shift, option, control
   }

   public enum ShortcutKey: Hashable, Sendable {
       case character(Character)          // the lowercase AppKit keyEquivalent: "a"…"z", "0"…"9", "=", "-", "+", "[", "]", ","
       case backspace                     // ⌫ (Mac "delete"): menu keyEquivalent "\u{8}", key code 51
       case forwardDelete                 // ⌦: key code 117 (menu "\u{F728}")
       case returnKey, enter, escape, tab, space   // key codes 36, 76, 53, 48, 49
       case leftArrow, rightArrow, downArrow, upArrow // 123, 124, 125, 126
       case pageUp, pageDown              // ⇞ / ⇟: menu "\u{F72C}" / "\u{F72D}" (NSPageUpFunctionKey / NSPageDownFunctionKey), key codes 116 / 121
       public init?(keyCode: UInt16)      // only the non-character cases above; letters come from characters
       public var menuKeyEquivalent: String?   // nil for keys a menu item can't carry here (return, escape, tab, space, arrows)
       public var glyph: String           // "A" (uppercased letter), "=", "−" (U+2212 for "-"), "+", "[", "]", ",", "⌫", "⌦", "↩", "⌅", "⎋", "⇥", "Space", "←", "→", "↓", "↑", "⇞", "⇟"
   }

   public struct KeyChord: Hashable, Sendable {
       public let key: ShortcutKey
       public let modifiers: ShortcutModifiers
       public var displayString: String   // Mac order ⌃⌥⇧⌘ then glyph: "⇧⌘Z", "⌥⌫", "⌥⇞", "⌘−", "S", "⇧S"
   }

   public enum ShortcutContext: Hashable, Sendable {
       case menu                 // NSMenuItem key equivalents, app-wide
       case singleKey            // global single keys through CanvasInputRouter.handleShortcutKeyDown + ToolShortcutGate
       case anyPendingTool       // Tool.keyDown defaults (0006): Return/Enter commit, Escape cancel
       case tool(ToolID)         // tool-local keys reaching Tool.keyDown while that tool is active
       case pointer              // modifier-clicks/drags — documentation only, not dispatched from the table
       case system               // provided by AppKit/macOS (window tabs, full-screen tiling) — documentation only
   }

   public enum ShortcutDelivery: Hashable, Sendable {
       case menuItem             // the chord is the item's keyEquivalent
       case hiddenMenuAlternate  // a hidden item, allowsKeyEquivalentWhenHidden (0004's ⌘+)
       case keyMonitor           // handled by the local key monitor (0018's ⌦ alias; single keys)
       case toolKeyDown          // Tool.keyDown
       case documentation        // pointer and system rows
   }

   public struct ShortcutBinding: Hashable, Sendable {
       public let chord: KeyChord
       public let delivery: ShortcutDelivery
   }

   public enum ShortcutStatus: Hashable, Sendable {
       case matchesPaintNET                  // Paint.NET's chord with Ctrl → ⌘, Alt → ⌥ (or the identical single key)
       case remapped(reason: String)         // deliberate deviation, reason shown in docs
       case macStandard                      // Mac convention or PaintDotMac addition; Paint.NET has none or a non-mappable one
       case notMapped(reason: String)        // Paint.NET has a shortcut, PaintDotMac deliberately has none (bindings empty)
       case pendingDecision(question: Int)   // recommended value applied, awaiting the user (this spec's Open questions)
   }

   public struct ShortcutEntry: Sendable, Identifiable {
       public let id: String                 // stable, e.g. "edit.copyMerged", "tools.s", "colors.swap", "shapes.nextShape"
       public let action: String             // user-facing name, Paint.NET spelling ("Copy Merged", "Rotate 90° Clockwise")
       public let section: ShortcutSection   // grouping for docs: app, file, edit, view, image, layers, adjustments, effects, window, tools, colorsAndBrush, toolLocal, canvasAndPointer, system
       public let context: ShortcutContext
       public let menuItemIdentifier: String?   // NSMenuItem identifier for .menu entries ("menu.edit.copyMerged")
       public let effectID: String?          // ImageEffect.id for adjustment/effect items ("levels")
       public let tools: [ToolID]            // tools.* entries: the group in D-13 cycle order; [] otherwise
       public let bindings: [ShortcutBinding]   // first = primary (shown in menus); [] = no shortcut
       public let paintNET: String           // Paint.NET's keys exactly as the docs page writes them ("Ctrl + Shift + C"), "—" if none
       public let status: ShortcutStatus
       public let notes: String              // conflicts, deviations, PRD/D-refs; "" if nothing to add
       public let gesture: String?           // .pointer rows only ("⌘-click", "Space (hold) + drag"); nil otherwise
       public var suppressedWhileTextInput: Bool { get }  // true for every .menu/.singleKey binding without .command and without .control
   }

   public enum ShortcutTable {
       public static let entries: [ShortcutEntry]                 // the table in item 2, in docs order
       public static func entry(id: String) -> ShortcutEntry?
       public static func entry(menuItemIdentifier: String) -> ShortcutEntry?
       public static func menuChord(forMenuItem identifier: String) -> KeyChord?          // primary .menuItem binding
       public static func hiddenAlternates(forMenuItem identifier: String) -> [KeyChord]  // .hiddenMenuAlternate bindings
       public static func effectChord(effectID: String) -> KeyChord?
       public static func toolKey(for tool: ToolID) -> Character      // the tools.* entry containing it (invariant: every ToolID is in exactly one)
       public static var toolKeys: Set<Character> { get }             // == 0006's allShortcutKeys
       public static func singleKeyEntry(for chord: KeyChord) -> ShortcutEntry?   // .singleKey context lookup (letters via .character, ⌫/⌦ via keyCode)
       public static func toolLocalEntry(for chord: KeyChord, tool: ToolID) -> ShortcutEntry?
       public static func requiresCanvasFocus(menuItemIdentifier: String) -> Bool  // entry.suppressedWhileTextInput for menu items
   }
   ```
   - Pure data plus lookups; no `UserDefaults`, no AppKit. `ToolID` comes from `Core/Tools/Tool.swift` (0006); both are in Core.
   - `ShortcutTable.entries` is built once (a `static let` array literal). `entry(id:)` etc. are linear scans or a lazily built dictionary — performance is irrelevant (≈120 rows).

2. **The table** (`ShortcutTable.entries`, exactly these rows; ⓜ = `.menuItem`, ⓗ = `.hiddenMenuAlternate`, ⓚ = `.keyMonitor`, ⓣ = `.toolKeyDown`, ⓓ = `.documentation`). Identifiers marked † are added to items that had none (item 6).

   **App menu** (`section .app`, context `.menu`)
   | id | action | menu identifier | bindings | Paint.NET | status / notes |
   |---|---|---|---|---|---|
   | app.settings | Settings… | `menu.app.settings` † | ⌘, ⓜ | Alt + X | macStandard — "Mac standard. Paint.NET's Ctrl + , (Toggle Layer Visibility) can't be mapped because ⌘, is Settings." |
   | app.hide | Hide PaintDotMac | `menu.app.hide` † | ⌘H ⓜ | — | macStandard — "macOS reserved; the Pan tool uses H without a modifier (R-3). Paint.NET's Ctrl + H (Rotate 90° CW) is ⌘]." |
   | app.hideOthers | Hide Others | `menu.app.hideOthers` † | ⌥⌘H ⓜ | — | macStandard |
   | app.quit | Quit PaintDotMac | `menu.app.quit` † | ⌘Q ⓜ | Alt + F4 | macStandard |

   **File** (`.file`)
   | file.new | New… | `menu.file.new` | ⌘N ⓜ | Ctrl + N | matchesPaintNET |
   | file.open | Open… | `menu.file.open` † | ⌘O ⓜ | Ctrl + O | matchesPaintNET |
   | file.close | Close | `menu.file.close` † | ⌘W ⓜ | Ctrl + W or Ctrl + F4 | matchesPaintNET |
   | file.save | Save | `menu.file.save` | ⌘S ⓜ | Ctrl + S | matchesPaintNET |
   | file.saveAs | Save As… | `menu.file.saveAs` | ⇧⌘S ⓜ | Ctrl + Shift + S | matchesPaintNET |
   | file.saveAll | Save All | — | none | Ctrl + Alt + S | notMapped — "No Save All command in v1.0." (Q5) |
   | file.print | Print | — | none | Ctrl + P | notMapped — "Printing is not in v1.0 (PRD §2.2)." (Q5) |

   **Edit** (`.edit`)
   | edit.undo | Undo | `menu.edit.undo` † | ⌘Z ⓜ | Ctrl + Z | matchesPaintNET |
   | edit.redo | Redo | `menu.edit.redo` † | ⇧⌘Z ⓜ | Ctrl + Y | remapped — "Mac standard; no ⌘Y alias (D-12)." |
   | edit.cut | Cut | `menu.edit.cut` | ⌘X ⓜ | Ctrl + X or Shift + Delete | matchesPaintNET — "Shift + Delete alias not mapped (Q5)." |
   | edit.copy | Copy | `menu.edit.copy` | ⌘C ⓜ | Ctrl + C or Ctrl + Insert | matchesPaintNET — "Macs have no Insert key." |
   | edit.copyMerged | Copy Merged | `menu.edit.copyMerged` | ⇧⌘C ⓜ | Ctrl + Shift + C | pendingDecision(3) |
   | edit.paste | Paste | `menu.edit.paste` | ⌘V ⓜ | Ctrl + V or Shift + Insert | matchesPaintNET |
   | edit.pasteIntoNewLayer | Paste into New Layer | `menu.edit.pasteIntoNewLayer` | ⇧⌘V ⓜ | Ctrl + Shift + V | matchesPaintNET |
   | edit.pasteIntoNewImage | Paste into New Image | `menu.edit.pasteIntoNewImage` | ⌥⌘V ⓜ | Ctrl + Alt + V | matchesPaintNET |
   | edit.selectAll | Select All | `menu.edit.selectAll` | ⌘A ⓜ | Ctrl + A | matchesPaintNET |
   | edit.deselect | Deselect | `menu.edit.deselect` | ⌘D ⓜ | Ctrl + D or Enter | matchesPaintNET — "Enter does not deselect: Return commits pending edits (Q5)." |
   | edit.eraseSelection | Erase Selection | `menu.edit.eraseSelection` | ⌫ ⓜ, ⌫ ⓚ, ⌦ ⓚ | Delete | remapped — "Paint.NET's Delete = Mac ⌦; ⌫ added because Mac laptops have no ⌦ key (D-12, E-4). The menu shows ⌫; ⌦ goes through the key monitor (one key equivalent per item)." |
   | edit.fillSelection | Fill Selection | `menu.edit.fillSelection` | ⌥⌫ ⓜ, ⌥⌫ ⓚ | Backspace | remapped — "Plain ⌫ is Erase Selection on the Mac (D-12). Shift + Backspace (fill with secondary) is not mapped (0018)." |
   | edit.invertSelection | Invert Selection | `menu.edit.invertSelection` | ⌘I ⓜ | Ctrl + I | matchesPaintNET |

   (The ⌫/⌥⌫ ⓚ bindings exist because 0018's monitor handles both keys before the menu when the canvas has focus; the ⓜ and ⓚ bindings of one entry may share a chord — see the duplicate rule in item 3.)

   **View** (`.view`)
   | view.zoomIn | Zoom In | `menu.view.zoomIn` | ⌘= ⓜ, ⌘+ ⓗ | Ctrl + + | matchesPaintNET — "⌘= is the unshifted key; the hidden ⌘+ item keeps Ctrl + + muscle memory (0004)." |
   | view.zoomOut | Zoom Out | `menu.view.zoomOut` † | ⌘− ⓜ (key `-`) | Ctrl + - | matchesPaintNET |
   | view.zoomToWindow | Zoom to Window | `menu.view.zoomToWindow` † | ⌘B ⓜ | Ctrl + B | matchesPaintNET — "Paint.NET's second Ctrl + B restores the previous zoom; not in v1.0 (Q5)." |
   | view.zoomToSelection | Zoom to Selection | `menu.view.zoomToSelection` | ⇧⌘B ⓜ | Ctrl + Shift + B | matchesPaintNET |
   | view.actualSize | Actual Size | `menu.view.actualSize` † | ⌘0 ⓜ | Ctrl + 0 | matchesPaintNET |
   | view.enterFullScreen | Enter Full Screen | `menu.view.enterFullScreen` † | ⌃⌘F ⓜ | — | macStandard |

   **Image** (`.image`)
   | image.cropToSelection | Crop to Selection | `menu.image.cropToSelection` | ⇧⌘X ⓜ | Ctrl + Shift + X | matchesPaintNET |
   | image.resizeImage | Resize… | `menu.image.resizeImage` | ⌘R ⓜ | Ctrl + R | matchesPaintNET |
   | image.resizeCanvas | Canvas Size… | `menu.image.resizeCanvas` | ⇧⌘R ⓜ | Ctrl + Shift + R | matchesPaintNET |
   | image.rotate90Clockwise | Rotate 90° Clockwise | `menu.image.rotate90Clockwise` | ⌘] ⓜ | Ctrl + H | remapped — "⌘H is Hide (D-12)." |
   | image.rotate90CounterClockwise | Rotate 90° Counter-Clockwise | `menu.image.rotate90CounterClockwise` | ⌘[ ⓜ | Ctrl + G | remapped — "Paired with ⌘] (D-12). ⌘[/⌘] also mean Paint.NET's Ctrl + [ / ] (brush width × 5), which is not mapped." |
   | image.rotate180 | Rotate 180° | `menu.image.rotate180` | ⌘J ⓜ | Ctrl + H + H or Ctrl + G + G | remapped — "PRD §5.12 lists Ctrl + J (Paint.NET 3.x); current Paint.NET uses a double press. PaintDotMac keeps ⌘J (D-12)." |
   | image.flatten | Flatten | `menu.image.flatten` | ⇧⌘F ⓜ | Ctrl + Shift + F | matchesPaintNET |

   **Layers** (`.layers`)
   | layers.addNewLayer | Add New Layer | `menu.layers.addNewLayer` | ⇧⌘N ⓜ | Ctrl + Shift + N | matchesPaintNET |
   | layers.deleteLayer | Delete Layer | `menu.layers.deleteLayer` | ⇧⌘⌫ ⓜ | Ctrl + Shift + Delete | remapped — "Mac ⌫ stands in for Delete (no ⌦ on laptops), as for Erase Selection." |
   | layers.duplicateLayer | Duplicate Layer | `menu.layers.duplicateLayer` | ⇧⌘D ⓜ | Ctrl + Shift + D | matchesPaintNET |
   | layers.mergeLayerDown | Merge Layer Down | `menu.layers.mergeLayerDown` | ⌘E ⓜ | Ctrl + M | remapped — "⌘M is Minimize (D-12)." |
   | layers.goToLayerAbove | Go to Layer Above | `menu.layers.goToLayerAbove` | ⌥⇞ ⓜ | Alt + PgUp | pendingDecision(1) — "On keyboards without Page Up: fn-⌥-↑." |
   | layers.goToLayerBelow | Go to Layer Below | `menu.layers.goToLayerBelow` | ⌥⇟ ⓜ | Alt + PgDn | pendingDecision(1) — "fn-⌥-↓." |
   | layers.properties | Layer Properties… | `menu.layers.properties` | none | F4 | remapped — "Double-click the layer row (PRD §5.12); function keys need fn on Mac laptops." |
   | layers.toggleVisibility | Toggle Layer Visibility | — | none | Ctrl + , | notMapped — "⌘, is Settings; no menu item in v1.0 (eye button in the Layers panel)." (Q5) |
   | layers.rotateZoom | Rotate / Zoom | — | none | Ctrl + Shift + Z | notMapped — "⇧⌘Z is Redo; feature is P1 (0060)." (Q6) |
   | layers.goToTopBottom | Go to Top / Bottom Layer | — | none | Ctrl + Alt + PgUp / PgDn | notMapped — "No menu items in v1.0." (Q5) |

   **Adjustments** (`.adjustments`; menu identifier `menu.adjustments.<effectID>`, `effectID` set)
   | adjustments.autoLevel | Auto-Level | `menu.adjustments.autoLevel` | ⇧⌘L ⓜ | Ctrl + Shift + L | pendingDecision(3) |
   | adjustments.blackAndWhite | Black and White | `menu.adjustments.blackAndWhite` | ⇧⌘G ⓜ | Ctrl + Shift + G | pendingDecision(3) — "⇧⌘G is Go to Folder inside Open/Save panels (the panel handles it first while key); there is no Find menu." |
   | adjustments.brightnessContrast | Brightness / Contrast… | `menu.adjustments.brightnessContrast` | ⇧⌘T ⓜ | Ctrl + Shift + T | pendingDecision(2) — "New in this spec; 0031 had none." |
   | adjustments.curves | Curves… | `menu.adjustments.curves` | ⇧⌘M ⓜ | Ctrl + Shift + M | matchesPaintNET |
   | adjustments.hueSaturation | Hue / Saturation… | `menu.adjustments.hueSaturation` | ⇧⌘U ⓜ | Ctrl + Shift + U | matchesPaintNET |
   | adjustments.invertColors | Invert Colors | `menu.adjustments.invertColors` | ⇧⌘I ⓜ | Ctrl + Shift + I | matchesPaintNET |
   | adjustments.levels | Levels… | `menu.adjustments.levels` | ⌘L ⓜ | Ctrl + L | matchesPaintNET |
   | adjustments.posterize | Posterize… | `menu.adjustments.posterize` | ⇧⌘P ⓜ | Ctrl + Shift + P | pendingDecision(3) — "⇧⌘P is Page Setup in apps that print; no printing in v1.0." |
   | adjustments.sepia | Sepia | `menu.adjustments.sepia` | ⇧⌘E ⓜ | Ctrl + Shift + E | pendingDecision(3) |
   | adjustments.invertAlpha | Invert Alpha | — | none | Ctrl + Alt + I | notMapped — "Not an adjustment in v1.0." |

   (Menu titles as 0031–0034 spell them; use whatever `menuTitle` the registry produces — the docs show the `action` string.)

   **Effects** (`.effects`)
   | effects.repeat | Repeat | `menu.effects.repeat` | ⌘F ⓜ | Ctrl + F | matchesPaintNET — "Title becomes 'Repeat <name>' (0031)." |
   (No effect has a Paint.NET shortcut; every `menu.effects.<category>.<id>` item has none.)

   **Window** (`.window`)
   | window.minimize | Minimize | `menu.window.minimize` † | ⌘M ⓜ | — | macStandard — "macOS reserved; Merge Layer Down is ⌘E." |
   | window.panel.tools | Tools | `menu.window.panel.tools` | ⌥⌘1 ⓜ | F5 | remapped — "F-keys need fn on Mac laptops (D-5)." |
   | window.panel.history | History | `menu.window.panel.history` | ⌥⌘2 ⓜ | F6 | remapped |
   | window.panel.layers | Layers | `menu.window.panel.layers` | ⌥⌘3 ⓜ | F7 | remapped |
   | window.panel.colors | Colors | `menu.window.panel.colors` | ⌥⌘4 ⓜ | F8 | remapped |
   | window.resetPanel | Reset window | — | none | Ctrl + Shift + F5…F8 | notMapped — "Settings has Reset Panel Positions (0046)." |

   **Tools** (`.tools`, context `.singleKey`, ⓚ; each has bindings `k` and `⇧k`; `tools` in D-13 order)
   | tools.s | Rectangle Select → Lasso Select → Ellipse Select → Magic Wand | S, ⇧S | "S or Shift + S x4 — Rectangle Select …; S x4 or Shift + S — Magic Wand" | matchesPaintNET — "Again within 1 s cycles; Shift cycles back; Shift alone selects the last tool (D-35, D-41)." |
   | tools.m | Move Selected Pixels → Move Selection | M, ⇧M | M; M x2 or Shift + M | matchesPaintNET |
   | tools.z | Zoom | Z, ⇧Z | Z | matchesPaintNET |
   | tools.h | Pan | H, ⇧H | H | matchesPaintNET |
   | tools.f | Paint Bucket | F, ⇧F | F | matchesPaintNET |
   | tools.g | Gradient | G, ⇧G | G | matchesPaintNET |
   | tools.b | Paintbrush | B, ⇧B | B | matchesPaintNET |
   | tools.e | Eraser | E, ⇧E | E | matchesPaintNET |
   | tools.p | Pencil | P, ⇧P | P | matchesPaintNET |
   | tools.k | Color Picker | K, ⇧K | K | matchesPaintNET |
   | tools.l | Clone Stamp | L, ⇧L | L | matchesPaintNET — "Tool is P1 (0056); until then the key is consumed silently (0006)." |
   | tools.r | Recolor | R, ⇧R | R | matchesPaintNET — "P1 (0057); consumed silently until then." |
   | tools.t | Text | T, ⇧T | T | matchesPaintNET |
   | tools.o | Line / Curve → Shapes | O, ⇧O | O; O x2 or Shift + O | matchesPaintNET |

   **Colors and brush** (`.colorsAndBrush`, `.singleKey`, ⓚ)
   | colors.swap | Swap colors | X, ⇧X | X | matchesPaintNET |
   | colors.reset | Reset colors | D, ⇧D | — | macStandard — "PaintDotMac addition (PRD C-1); Paint.NET has only the reset button." |
   | colors.switchSlot | Switch active color | C, ⇧C | C | matchesPaintNET (D-31) |
   | brush.widthDown | Decrease brush width | [ | [ | matchesPaintNET |
   | brush.widthUp | Increase brush width | ] | ] | matchesPaintNET |
   | brush.widthStep5 | Brush width ± 5 | none | Ctrl + [ / Ctrl + ] | notMapped — "⌘[ / ⌘] are Rotate (0009)." |

   (Shift variants: 0006's gate allows Shift and 0007 accepts "X"/"D"/"C"; `[`/`]` with Shift produce `{`/`}`, so they have no Shift binding.)

   **Tool-local keys** (`.toolLocal`, ⓣ)
   | pending.commit | Commit pending edit | ↩, ⌅ | context `.anyPendingTool` | Enter | matchesPaintNET |
   | pending.cancel | Cancel pending edit | ⎋ | `.anyPendingTool` | Esc (commits in Paint.NET) | remapped — "Escape cancels, as on the Mac (0020 Q1, 0038, 0039)." |
   | text.commit | Commit text | ⌘↩ | `.tool(.text)` | — | macStandard (D-25) |
   | text.escape | Commit text (Escape) | ⎋ | `.tool(.text)` | Esc | matchesPaintNET — "Overrides pending.cancel for the Text tool (0040)." |
   | moveSelection.nudge | Nudge selection 1 px / 10 px | ←→↑↓, ⌘←⌘→⌘↑⌘↓ | `.tool(.moveSelection)` | Arrow keys / Ctrl + arrow keys | matchesPaintNET |
   | moveSelectedPixels.nudge | Nudge pixels | same 8 chords | `.tool(.moveSelectedPixels)` | same | matchesPaintNET |
   | lineCurve.nudge | Move Line/Curve | same 8 chords | `.tool(.lineCurve)` | same | matchesPaintNET |
   | shapes.nudge | Move shape | same 8 chords | `.tool(.shapes)` | same | matchesPaintNET |
   | shapes.nextShape | Next shape | A | `.tool(.shapes)` | A | pendingDecision(3) |
   | shapes.previousShape | Previous shape | ⇧A | `.tool(.shapes)` | Shift + A | pendingDecision(3) |
   | lineCurve.styleKeys | Start cap / line style / end cap | none | `.tool(.lineCurve)` | , / . / / | notMapped — "Not in 0038 (Q4)." |

   **Canvas and pointer** (`.canvasAndPointer`, ⓓ except Space, which 0004's `SpacePanState` owns)
   | canvas.spacePan | Pan while holding Space | Space (hold) + drag | `.pointer` | Spacebar + Left Mouse drag | matchesPaintNET |
   | canvas.middlePan | Pan | middle-button drag | `.pointer` | Middle Mouse drag | matchesPaintNET |
   | zoom.zoomOut | Zoom out (Zoom tool) | ⌥-click or right-click | `.pointer` | Right Mouse click | remapped — "Option added for one-button mice (T-7)." |
   | colorPicker.sampleImage | Sample the image (Color Picker) | ⌘-click | `.pointer` | Ctrl + click | matchesPaintNET (D-28) |
   | cloneStamp.setSource | Set source (Clone Stamp, P1) | ⌥-click | `.pointer` | Ctrl + Left Mouse click | remapped — "⌃-click is right-click on the Mac (T-15)." |
   | selection.add | Add (Union) | ⌘-drag | `.pointer` | Ctrl + Drag + Left | matchesPaintNET |
   | selection.subtract | Subtract | ⌥-drag | `.pointer` | Alt + Drag + Left | matchesPaintNET |
   | selection.xor | Invert (Xor) | ⌘-right-drag | `.pointer` | Ctrl + Drag + Right | matchesPaintNET |
   | selection.intersect | Intersect | ⌥-right-drag | `.pointer` | Alt + Drag + Right | matchesPaintNET |
   | secondaryColor | Paint with the secondary color | right-drag or ⌃-drag | `.pointer` | Right Mouse | remapped — "⌃-click = right-click (TOOL-A, R-3)." |
   | moveSelectedPixels.copy | Move a copy | ⌘-drag | `.pointer` | Ctrl + Drag | matchesPaintNET |
   (`.pointer` entries have `bindings: []`; their gesture text, as written in the PaintDotMac column above, is in `ShortcutEntry.gesture`.)

   **macOS-provided** (`.system`, ⓓ, `bindings` with their chords, status macStandard)
   | system.nextTab / system.previousTab | Show Next / Previous Tab | ⇧⌘], ⌃⇥ / ⇧⌘[, ⌃⇧⇥ | Ctrl + Tab or Ctrl + PgDn / Ctrl + Shift + Tab or Ctrl + PgUp | "Native window tabs (APP-1)." |
   | system.showAllTabs | Show All Tabs | ⇧⌘\ | — | |
   | system.switchImageNumber | Switch to image N | none | Ctrl + 1…9 / Alt + 1…9 | notMapped (Q5) |
   | system.scrollKeys | Scroll with PgUp/PgDn/Home/End | none | PgUp, PgDn, Home, End, Ctrl + Home/End | notMapped — "No scroll bars in v1.0 (D-29)." (Q5) |
   | system.spaceArrowPan | Pan with Space + arrows | none | Spacebar + arrow keys | notMapped (Q5) |

   The table's `notes` strings, `paintNET` strings, and `action` strings are written exactly as above (the implementer may only fix typos, and must then regenerate `docs/shortcuts.md`).

3. **Invariants enforced by tests** (no runtime checks needed; the table is static):
   - **Menu domain:** across all `.menu` entries, every `.menuItem` and `.hiddenMenuAlternate` chord is unique. The `.keyMonitor` bindings of an entry may repeat that same entry's `.menuItem` chord (⌫, ⌥⌫) but no other entry's chord.
   - **Single-key domain:** across `.singleKey` entries plus every `.keyMonitor` binding, chords are unique, and none equals a `.menu` chord of a different entry.
   - **Tool-local domain:** within each `.tool(id)`, chords are unique; a `.tool(id)` chord equal to an `.anyPendingTool` chord is allowed only for `text.escape` (an explicit override listed in `ShortcutTable.overrides = ["text.escape": "pending.cancel"]`); no tool-local chord equals a single-key chord (else 0006's monitor would eat it before `Tool.keyDown`) or a menu chord.
   - **Text-input rule:** every `.menu` binding without `.command` and without `.control` (⌫, ⌥⌫, ⌥⇞, ⌥⇟) has `suppressedWhileTextInput == true`, and every `.singleKey` entry has it by construction.
   - **Tools:** every `ToolID` is in exactly one `tools.*` entry; the per-key order equals D-13; the key set equals PRD §5.12's "S, M, Z, H, F, G, B, E, P, K, L, R, T, O".
   - **macOS-reserved chords** are used only by the entries allowed to own them (item 4).

4. **`PaintDotMac/Core/Shortcuts/SystemReservedShortcuts.swift`** (new) — `public enum SystemReservedShortcuts { public static let chords: [ReservedChord] }` with `struct ReservedChord { chord: KeyChord; owner: String /* "Hide", "Spotlight", … */; allowedEntryID: String? }`. Exactly:
   ⌘H (Hide → `app.hide`), ⌥⌘H (Hide Others → `app.hideOthers`), ⌘M (Minimize → `window.minimize`), ⌥⌘M (Minimize All), ⌘Q (Quit → `app.quit`), ⌘W (Close → `file.close`), ⌥⌘W (Close All), ⌘, (Settings → `app.settings`), ⌃⌘F (Enter Full Screen → `view.enterFullScreen`), ⌘` and ⇧⌘` (cycle windows), ⌘⇥ and ⇧⌘⇥ (app switcher), ⌘Space and ⌥⌘Space (Spotlight / Finder search), ⌃Space and ⌃⌥Space (input sources), ⌃⌘Space (Emoji & Symbols), ⌃⌘Q (Lock Screen), ⇧⌘Q and ⌥⇧⌘Q (Log Out), ⌥⌘⎋ (Force Quit), ⌥⌘D (Dock hiding), ⇧⌘3, ⇧⌘4, ⇧⌘5, ⇧⌘6, ⌃⇧⌘3, ⌃⇧⌘4 (screenshots), ⇧⌘/ (Help search), ⌘. (cancel), ⌃↑, ⌃↓, ⌃←, ⌃→ (Mission Control / Spaces), ⇧⌘[ , ⇧⌘], ⇧⌘\, ⌃⇥, ⌃⇧⇥ (window tabs → the `.system` entries), ⌃⌘D (Look Up).
   This list is a documentation constant and is also rendered into `docs/shortcuts.md` ("Reserved by macOS"). The test re-states it independently (Test plan).

5. **`PaintDotMac/Core/Shortcuts/ShortcutMarkdown.swift`** (new) — `public enum ShortcutMarkdown { public static func render(entries: [ShortcutEntry] = ShortcutTable.entries, reserved: [ReservedChord] = SystemReservedShortcuts.chords) -> String }`. Deterministic output (LF line endings, trailing newline, no dates):
   1. `# PaintDotMac keyboard shortcuts`, then the line `<!-- Generated from PaintDotMac/Core/Shortcuts/ShortcutTable.swift by ShortcutDocsTests. Do not edit by hand; run the tests with RECORD_SHORTCUT_DOCS=1 to regenerate. -->`.
   2. A "Conventions" paragraph: Ctrl → ⌘, Alt → ⌥, macOS-reserved shortcuts win, single keys work only when no text field has focus and no tool is capturing the keyboard (AGENTS.md rule 9); glyph legend (⌘ ⇧ ⌥ ⌃ ⌫ ⌦ ↩ ⌅ ⎋ ⇥ ⇞ ⇟); source line "Paint.NET values from https://paint.net/doc/latest/KeyboardMouseCommands.html (checked 2026-11-08)."
   3. One `##` section per `ShortcutSection` in enum order (titles: "App menu", "File", "Edit", "View", "Image", "Layers", "Adjustments", "Effects", "Window", "Tools", "Colors and brush", "Tool-local keys", "Canvas and pointer", "Provided by macOS"), each a table `| Action | PaintDotMac | Paint.NET | Status | Notes |`. PaintDotMac = the bindings' `displayString`s joined with " or " (duplicate display strings shown once; pointer rows show `gesture`; empty → "—"); Status = "Same as Paint.NET" / "Remapped" / "Mac standard" / "Not mapped" / "Pending decision (Q<n>)"; Notes = `remapped.reason` / `notMapped.reason` and `notes`, joined with " ".
   4. `## Conflicts and deviations` — every entry whose status isn't `.matchesPaintNET`, as a bulleted list "**<action>** — <PaintDotMac> instead of <Paint.NET>: <reason/notes>".
   5. `## Pending decisions` — every `.pendingDecision` entry with its question number (the section reads "None." once all are resolved).
   6. `## Reserved by macOS` — `| Shortcut | Used by | PaintDotMac |` with "not used" or the owning entry's action.
   `|` characters inside cells are escaped as `\|`.

6. **Glue-facing Core refactors (no behavior change except items 8–9):**
   - `Core/Tools/ToolRegistry.swift` (0006): the `allDescriptors` literal keeps its other columns but `shortcutKey` is `ShortcutTable.toolKey(for: id)`; `allShortcutKeys` becomes `ShortcutTable.toolKeys`. `shortcutGroup(for:)` stays (implemented tools filtered from the table's `tools` order). 0006's `ToolRegistryTests.descriptorsMatchTable` keeps passing unchanged (it is now a second, independent oracle).
   - `Core/Model/ColorSelection.swift` / wherever 0007 put `ColorKeyCommand`: `command(forCharactersIgnoringModifiers:command:option:control:)` keeps its signature and resolves through `ShortcutTable.singleKeyEntry(for:)` (`colors.swap` → `.swap`, `colors.reset` → `.reset`, `colors.switchSlot` → `.switchSlot`).
   - `Core/Tools/BrushEngine.swift` (0009, `BrushWidthAdjustable`): add `public enum BrushWidthKey { static func delta(forCharactersIgnoringModifiers: String, modifiers: ToolModifiers) -> Double? }` resolving `brush.widthDown`/`brush.widthUp` → −1/+1; the router calls it instead of comparing "[" / "]".
   - `Core/Operations/EraseSelection.swift` (0018): `SelectionPixelCommand.command(forKeyCode:modifiers:)` keeps its signature; it builds `KeyChord(key: ShortcutKey(keyCode:), modifiers:)` and returns the entry whose `.keyMonitor` binding matches (`edit.eraseSelection` / `edit.fillSelection`). 0018's tests keep passing.
   - `Core/Tools/ShapesTool.swift` (0039) and `TransformHandles.nudge(for:)` (0019): look up `shapes.nextShape`/`shapes.previousShape` and the `*.nudge` chords through `ShortcutTable.toolLocalEntry(for:tool:)`; nudge distance stays 1 / 10 px (`.command` = ×10). The `Tool.keyDown` default (0006) resolves `pending.commit`/`pending.cancel`; `TextTool` resolves `text.commit`/`text.escape`.
   - `Core/Effects/ImageEffect.swift` (0031): `shortcut` stops being a per-effect literal. Remove the `shortcut` property from every effect struct (0031 InvertColors, 0032 BlackAndWhite/Sepia/Posterize/HueSaturation, 0033 Levels/AutoLevel, 0034 Curves) and provide it in a protocol extension: `var shortcut: EffectShortcut? { ShortcutTable.effectChord(effectID: id).map(EffectShortcut.init) }`, with `EffectShortcut.init(_ chord: KeyChord)` mapping `ShortcutModifiers` → `EffectShortcut.Modifiers` and `.character(c)` → `key = String(c)`. Remove the requirement from the protocol body (keep it only as the extension) so no effect can define a second value. 0031–0034 metadata tests keep passing; BrightnessContrast's "no shortcut" assertion changes (item 9).

### Platform glue (AppKit; covered by UI tests and the hosted unit tests)

7. **`PaintDotMac/App/ShortcutTable+AppKit.swift`** (new): `extension NSEvent.ModifierFlags { init(_ m: ShortcutModifiers) }`, `extension ShortcutModifiers { init(_ flags: NSEvent.ModifierFlags) }` (only ⌘⇧⌥⌃), and `extension NSMenuItem { func applyShortcut(_ chord: KeyChord?) }` setting `keyEquivalent = chord?.key.menuKeyEquivalent ?? ""` and `keyEquivalentModifierMask = chord.map { NSEvent.ModifierFlags($0.modifiers) } ?? []`.

8. **`PaintDotMac/App/MainMenu.swift`** (refactor 0001–0044): every item is created through one helper `static func item(_ title: String, action: Selector?, identifier: String) -> NSMenuItem` that sets `identifier`, `target = nil`, and `applyShortcut(ShortcutTable.menuChord(forMenuItem: identifier))`; for each `ShortcutTable.hiddenAlternates(forMenuItem:)` chord it appends a hidden item (`isHidden = true`, `allowsKeyEquivalentWhenHidden = true`, same action, identifier `<identifier>.alternate`) directly after. No literal `keyEquivalent:` remains in `MainMenu.swift` except `""` for the submenu/separator constructors (a test greps the source, see Test plan). Menu titles, order, actions, and enablement stay exactly as 0001–0044 define them.
   - Add the † identifiers from item 2 to 0001's items (`menu.app.about`, `menu.app.settings`, `menu.app.hide`, `menu.app.hideOthers`, `menu.app.showAll`, `menu.app.quit`, `menu.file.open`, `menu.file.close`, `menu.edit.undo`, `menu.edit.redo`, `menu.view.zoomOut`, `menu.view.zoomToWindow`, `menu.view.actualSize`, `menu.view.enterFullScreen`, `menu.window.minimize`, `menu.window.zoom`, `menu.window.bringAllToFront`) — 0046 then gives `menu.app.settings` its action.
   - `makeAdjustmentsMenu(registry:)` / `makeEffectsMenu(registry:)` (0031) use the same helper with `menu.adjustments.<id>` / `menu.effects.<category>.<id>` (the chord comes from the table; `effect.shortcut` is no longer read by the menu).
   - **Behavior change 1 (Open question 1):** "Go to Layer Above" gets ⌥⇞ and "Go to Layer Below" ⌥⇟ (from the table). Their `validateMenuItem` (0024, `DocumentWindowController`) additionally requires `!textInputHasFocus && !activeTool.capturesKeyboard` — implement it generically: for every item where `ShortcutTable.requiresCanvasFocus(menuItemIdentifier:)` is true, `validateMenuItem` ANDs `!CanvasInputRouter.textInputHasFocus(in: NSApp.keyWindow) && !AppModel.shared.dispatcher.activeTool.capturesKeyboard`, replacing 0018's item-specific check for ⌫/⌥⌫ (same result for those two).
   - **Behavior change 2 (Open question 2):** "Brightness / Contrast…" gets ⇧⌘T.

9. **Tests to update in earlier specs' files** (this spec owns both behavior changes; 0024 and 0031 are not edited — their tests are updated here). Expected values come from the table *and* from the literal rows in this spec:
   - `PaintDotMacTests/App/MainMenuTests.swift`: `layersMenuItems` (0024, last extended by 0030/0025) — the "Go to Layer Above" row now expects key `"\u{F72C}"` with `[.option]`, "Go to Layer Below" `"\u{F72D}"` with `[.option]` (all other rows unchanged); every 0001 item test that checks identifiers gains the † identifiers from item 8; `noShortcutCollisions` (0024) and `noDuplicateShortcuts` (0001) stay green unchanged.
   - `PaintDotMacTests/App/MainMenuEffectsTests.swift`: `adjustmentsItems` (0031, final list from 0034) — the `("Brightness / Contrast…","",[],"brightnessContrast")` tuple becomes `("Brightness / Contrast…","t",[.command,.shift],"brightnessContrast")`; nothing else in the list changes.
   - `PaintDotMacTests/Effects/BrightnessContrastTests.swift`: the metadata test's "no shortcut" assertion (0031 item 9 / test plan) becomes `shortcut == EffectShortcut(key: "t", modifiers: [.command, .shift])`.
   - `PaintDotMacUITests/LayersMenuUITests.swift` (0024) and `EffectsUITests`/`BasicAdjustmentsUITests`/`LevelsUITests.testMenus` (0031–0033) assert order/enablement only and need no change.
   No other existing test should need a change; if one does, the refactor changed behavior and is wrong. 0031's statement "no shortcut (Paint.NET has none)" is superseded by this spec (the current Paint.NET docs list Ctrl + Shift + T).

10. **`docs/shortcuts.md`** (new, generated) — written by running `RECORD_SHORTCUT_DOCS=1` once (Test plan) and committed; never edited by hand.

11. **`CanvasInputRouter.handleShortcutKeyDown`** (0006/0007/0009/0018): unchanged order (tools → colors → brush width → erase/fill); only the lookups go through the table (item 6). The gate (`ToolShortcutGate.allows`) is unchanged.

12. **`project.yml`:** no change (new files are picked up by the source globs). Run `xcodegen generate`.

13. **PRD:** no edit in this spec (sub-agent rule). When the user answers the open questions, the batch owner adds the §5.12 rows (Copy Merged ⇧⌘C, Black and White ⇧⌘G, Sepia ⇧⌘E, Posterize ⇧⌘P, Auto-Level ⇧⌘L, Shapes A / Shift+A, Go to Layer Above/Below, Brightness / Contrast) and corrects the Rotate 180° Paint.NET cell to "Ctrl+H+H / Ctrl+G+G"; the implementer then extends the PRD-row literal list in `PRDShortcutRowsTests` and flips the entries' status from `pendingDecision` to `matchesPaintNET`, regenerating the doc.

No pixel or history change; NF-1 to NF-4 are unaffected. Core files import only Foundation (AGENTS.md rule 1).

## Acceptance criteria

- [ ] `Core/Shortcuts/ShortcutTable.swift` contains every row of *Scope* item 2 with exactly those chords, Paint.NET strings, statuses, and identifiers. → `ShortcutTableTests.everyRowLiteral`
- [ ] Every PRD §5.12 row is present in the table with its exact PaintDotMac value, and every row of the PRD table is accounted for. → `PRDShortcutRowsTests.rowsPresentWithExactValues`, `.prdTableHasNoUnmappedRows`
- [ ] No duplicate chords within a context domain (menu, single-key incl. key-monitor aliases, each tool's local keys), with only the listed same-entry/override exceptions. → `ShortcutConflictTests.menuChordsUnique`, `.singleKeyChordsUnique`, `.singleKeysDontShadowMenu`, `.toolLocalChordsUnique`, `.toolLocalNotShadowedBySingleKeysOrMenu`, `.onlyDeclaredOverrides`
- [ ] No menu or key shortcut uses a macOS-reserved chord, except the designated owners (Hide, Hide Others, Minimize, Quit, Close, Settings, Enter Full Screen). → `ShortcutConflictTests.noReservedChords`, `.reservedListMatchesIndependentList`
- [ ] Every item in `MainMenu.make()` has exactly the key equivalent and modifiers of its table entry; items without an entry have none; every table `.menu` entry with bindings exists in the menu. → `MainMenuShortcutTests.everyItemMatchesTable`, `.everyMenuEntryHasAnItem`, `.hiddenAlternatesMatch`, `.noLiteralKeyEquivalentsInSource`
- [ ] Tool descriptors, color keys, brush width keys, ⌫/⌦/⌥⌫, Shapes A/⇧A, nudges, and commit/cancel keys resolve from the table with unchanged behavior. → `ShortcutTableTests.toolKeysFromTable`, `.colorKeysFromTable`, `.brushWidthFromTable`, `.selectionPixelKeysFromTable`, `.shapesKeysFromTable`, `.nudgeFromTable`; all existing 0006/0007/0009/0018/0019/0039/0040 tests pass unchanged
- [ ] Every Ctrl → ⌘ / Alt → ⌥ claim ("Same as Paint.NET") is true when the Paint.NET string is translated mechanically. → `ShortcutTableTests.matchingEntriesFollowCtrlToCommandRule`
- [ ] Tool, color, and brush keys never fire while a text field has focus: typing in the New Image width field and in the Text tool types characters, the active tool and colors don't change. → `ShortcutAuditUITests.testKeysTypeIntoNewImageWidthField`, `.testKeysTypeIntoTextTool`; `ShortcutTableTests.nonCommandMenuChordsSuppressedWhileTextInput`
- [ ] ⌥⇞ / ⌥⇟ go to the layer above / below (enabled per 0024's rules, disabled while a text field or the Text tool has focus); ⇧⌘T opens Brightness / Contrast. → `ShortcutAuditUITests.testGoToLayerShortcuts`, `.testBrightnessContrastShortcut`; `MainMenuShortcutTests.goToLayerDisabledWhileTextInput`
- [ ] `docs/shortcuts.md` is byte-identical to `ShortcutMarkdown.render()` and lists the conflicts, deviations, pending decisions, and reserved chords. → `ShortcutDocsTests.docsFileMatchesTable`, `ShortcutMarkdownTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Hyphen vs minus:** the Zoom Out key equivalent is ASCII `-`; only the docs glyph is `−`. → `ShortcutKeyTests.minusGlyph`
- **`+` alternate:** ⌘+ is the keyEquivalent `+` with ⌘ only (AppKit infers Shift); it is hidden and must not count as a duplicate of ⌘=. → `MainMenuShortcutTests.hiddenAlternatesMatch`
- **⌫ in two deliveries:** the same chord as a menu item and a key-monitor binding of one entry is not a conflict; the same chord in two entries is. → `ShortcutConflictTests.sameEntryMenuAndMonitorAllowed`, `.crossEntryDuplicateDetected` (a synthetic table passed to the checker)
- **Shift on tool keys:** ⇧S is a single-key binding of `tools.s` (Magic Wand, D-41); ⇧A (Shapes) is tool-local and must not collide with a tool letter (A isn't one). → `ShortcutConflictTests.toolLocalNotShadowedBySingleKeysOrMenu`
- **Caps Lock:** unchanged from 0006 (`toolKey` lowercases; Shift is read from flags). → existing `ToolShortcutResolverTests.capsLockIsNotShift`
- **Page Up on laptops:** fn-⌥-↑ produces the ⇞ key code 116 with ⌥ (fn is not part of the chord). → manual 3
- **Menu chord without ⌘ while typing:** ⌫, ⌥⌫, ⌥⇞, ⌥⇟ are disabled while a text field or capturing tool has focus, so the keystroke reaches the field (Backspace deletes a character; ⌥⇞ moves the caret). → `MainMenuShortcutTests.goToLayerDisabledWhileTextInput`, `ShortcutAuditUITests.testKeysTypeIntoNewImageWidthField` (⌫ step)
- **Modal dialog key:** the New Image panel runs app-modal (`0005…:123`), so the key window is `.other` and the gate refuses single keys even before the text-focus check. Both are asserted.
- **Unimplemented tools (L, R):** still consumed silently (0006). → existing `ToolDispatcherTests.unimplementedKeyConsumed`
- **Non-US layouts:** `[`, `]`, `=` may need ⌥ or not exist; AppKit's key-equivalent matching handles what it can, and the menu still works by clicking. No remapping per layout in v1.0. → manual 4
- **Table typo / missing entry:** `ShortcutTable.toolKey(for:)` must not crash — it is total by the `everyToolInExactlyOneGroup` invariant test; the implementation may use a `precondition` with a comment only if that test exists (it does).
- **Docs out of date:** if the table changes without regenerating, `docsFileMatchesTable` fails and prints the first differing line and the regeneration command.
- **Repo path in tests:** `docs/shortcuts.md` and `PRD.md` are found from `#filePath` (`PaintDotMacTests/Shortcuts/…` → two levels up = repo root). If a file is missing the test fails with the path it looked for (never skipped).

## Test plan

- **Unit — `PaintDotMacTests/Shortcuts/ShortcutKeyTests.swift`:** `displayOrder` (`KeyChord(.character("z"), [.command, .shift]).displayString == "⇧⌘Z"`; `[.control, .option, .shift, .command]` + `a` → "⌃⌥⇧⌘A"); `glyphs` (each `ShortcutKey` case → the glyph in item 1); `minusGlyph` ("-" → "−" but `menuKeyEquivalent == "-"`); `menuKeyEquivalents` (backspace "\u{8}", forwardDelete "\u{F728}", pageUp "\u{F72C}", pageDown "\u{F72D}", returnKey nil); `keyCodes` (51→backspace, 117→forwardDelete, 116→pageUp, 121→pageDown, 36→returnKey, 76→enter, 53→escape, 123…126 arrows, 0 ("a") → nil).
- **Unit — `PaintDotMacTests/Shortcuts/ShortcutTableTests.swift`:**
  - `everyRowLiteral`: a literal array in the test of `(id, menuItemIdentifier, [displayString], paintNET, statusKind)` for every row of *Scope* item 2, compared to `ShortcutTable.entries` in order (independent re-statement; ids unique).
  - `everyToolInExactlyOneGroup`; `groupOrderMatchesD13` (s: rectangleSelect, lassoSelect, ellipseSelect, magicWand; m: moveSelectedPixels, moveSelection; o: lineCurve, shapes); `toolKeysFromTable`: `ToolRegistry.allDescriptors.map(\.shortcutKey)` == the 0006 literal key column, and `ToolRegistry.allShortcutKeys == ShortcutTable.toolKeys == Set("smzhfgbepklrto")`.
  - `colorKeysFromTable`: `ColorKeyCommand.command(...)` for "x","X","d","D","c","C" → swap/reset/switchSlot; with ⌘/⌥/⌃ → nil; "v" → nil.
  - `brushWidthFromTable`: `BrushWidthKey.delta` "[" → −1, "]" → +1, "{" → nil, "[" with ⌘ → nil.
  - `selectionPixelKeysFromTable`: (51, []) → erase, (117, []) → erase, (51, [.option]) → fill, (117, [.option]) → nil, (51, [.command]) → nil, (51, [.shift]) → nil.
  - `shapesKeysFromTable`: `toolLocalEntry(for: a, tool: .shapes)?.id == "shapes.nextShape"`, ⇧A → previousShape, A for `.paintbrush` → nil.
  - `nudgeFromTable`: `TransformHandles.nudge(for:)` ← (−1,0), → (1,0), ↑ (0,−1), ↓ (0,1), ⌘← (−10,0); `a` → nil.
  - `effectShortcutsFromTable`: for every effect in `EffectRegistry.standard`, `effect.shortcut == ShortcutTable.effectChord(effectID: effect.id).map(EffectShortcut.init)`; explicit: levels → ("l", [.command]), invertColors → ("i", [.command, .shift]), brightnessContrast → ("t", [.command, .shift]), gaussianBlur → nil.
  - `nonCommandMenuChordsSuppressedWhileTextInput`: the set of menu identifiers with `requiresCanvasFocus == true` is exactly `{menu.edit.eraseSelection, menu.edit.fillSelection, menu.layers.goToLayerAbove, menu.layers.goToLayerBelow}`; every `.singleKey` entry has `suppressedWhileTextInput`; and `ToolShortcutGate.allows(modifiers: [], keyWindow: .document, textInputHasFocus: true, toolCapturesKeyboard: false, gestureInProgress: false) == false` for each single-key chord (with Shift where bound).
  - `matchingEntriesFollowCtrlToCommandRule`: a small translator **in the test target** (`PaintNETChordTranslator`, the oracle) parses each `.matchesPaintNET` entry's first Paint.NET alternative ("Ctrl + Shift + C" → ⇧⌘C; "Alt + PgUp" → ⌥⇞; "Ctrl + +" → ⌘+; "Ctrl + -" → ⌘-; single letters → that letter; "Arrow keys" / "Ctrl + arrow keys" → the 4/8 arrow chords; "Enter" → ↩; "Esc" → ⎋; "[" → "["; gesture strings are skipped for `.pointer` rows) and asserts the result is among the entry's bindings. Entries whose Paint.NET value is not translatable must not be `.matchesPaintNET` (e.g. "Ctrl + H + H").
- **Unit — `PaintDotMacTests/Shortcuts/ShortcutConflictTests.swift`:** the checks are a pure function `ShortcutConflicts.find(in: [ShortcutEntry]) -> [ShortcutConflict]` in the test support file (`PaintDotMacTests/Support/ShortcutConflicts.swift`), run on the real table (expect `[]`) and on synthetic tables (expect the specific conflict):
  - `menuChordsUnique`, `singleKeyChordsUnique`, `singleKeysDontShadowMenu`, `toolLocalChordsUnique`, `toolLocalNotShadowedBySingleKeysOrMenu`, `onlyDeclaredOverrides` (real table → `[]`).
  - `sameEntryMenuAndMonitorAllowed` (synthetic entry with ⌫ ⓜ + ⌫ ⓚ → no conflict); `crossEntryDuplicateDetected` (two menu entries with ⌘E → one `.duplicate(chord: ⌘E, ids: [..])`); `toolLetterShadowsToolLocalDetected` (synthetic `.tool(.shapes)` binding `b` → conflict).
  - `noReservedChords`: an independent literal list in the test (the item 4 chords re-typed) → no entry other than its allowed owner has a binding equal to any of them; and the menu tree from `MainMenu.make()` contains none of them except the owners (catches items added outside the table).
  - `reservedListMatchesIndependentList`: `SystemReservedShortcuts.chords.map(\.chord)` as a set == the test's literal set.
- **Unit — `PaintDotMacTests/Shortcuts/PRDShortcutRowsTests.swift`:**
  - `rowsPresentWithExactValues`: a literal list of the 27 PRD §5.12 rows → `(prdAction, [entryID], [expected displayString])`, e.g. ("New / Open / Save / Save As", [file.new, file.open, file.save, file.saveAs], ["⌘N","⌘O","⌘S","⇧⌘S"]), ("Undo / Redo", …, ["⌘Z","⇧⌘Z"]), ("Erase Selection / Fill Selection", [edit.eraseSelection, edit.fillSelection], ["⌫ or ⌦","⌥⌫"]), ("Zoom In / Zoom Out", …, ["⌘=","⌘−"]), ("Show Tools / History / Layers / Colors panel", …, ["⌥⌘1","⌥⌘2","⌥⌘3","⌥⌘4"]), ("Layer Properties", [layers.properties], ["—"]), ("Hide app *(Mac reserved)*", [app.hide], ["⌘H"]), ("Minimize *(Mac reserved)*", [window.minimize], ["⌘M"]), ("Brush width down / up", [brush.widthDown, brush.widthUp], ["[","]"]), ("Switch active color slot", [colors.switchSlot], ["C"]), ("Tools", the 14 tools.* ids, ["S",…,"O"] primary bindings), ("Redo alias", [], []) plus the assertion that no binding anywhere is ⌘Y — every row of PRD §5.12 as of 2026-11-04. Each entry's primary display strings (joined with " or " for multiple bindings of the same entry, Shift variants excluded for tools) must equal the expected strings.
  - `prdTableHasNoUnmappedRows`: read `PRD.md` (repo root via `#filePath`), take the table under `### 5.12`, parse the first cell of each data row, and assert the set equals the literal list's `prdAction` set (a PRD row added later fails until mapped).
- **Unit — `PaintDotMacTests/Shortcuts/ShortcutMarkdownTests.swift`:** `headerAndGeneratedComment` (first two lines exact); `sectionsInOrder` (the 14 `##` titles then "Conflicts and deviations", "Pending decisions", "Reserved by macOS"); `copyMergedRow` (contains exactly `| Copy Merged | ⇧⌘C | Ctrl + Shift + C | Pending decision (Q3) |`); `eraseRow` (`⌫ or ⌦`, "Remapped"); `pointerRowUsesGesture` ("⌘-click"); `deviationsListed` (Merge Layer Down, Rotate 180°, Redo, Brightness / Contrast, Go to Layer Above appear under "Conflicts and deviations"); `pipesEscaped` (synthetic note "a|b" → `a\|b`); `deterministic` (two renders equal; no `\r`; ends with "\n").
- **Unit (hosted) — `PaintDotMacTests/Shortcuts/ShortcutDocsTests.swift`:** `docsFileMatchesTable`: read `<repo>/docs/shortcuts.md` and compare to `ShortcutMarkdown.render()` byte for byte; on mismatch report the first differing line number and "run with RECORD_SHORTCUT_DOCS=1". With `RECORD_SHORTCUT_DOCS=1` in the environment it writes the file and then records an issue ("recorded docs/shortcuts.md; rerun without RECORD_SHORTCUT_DOCS"), so a recording run can never pass silently (mirrors `RECORD_GOLDENS`).
- **Unit (hosted, `@MainActor`) — `PaintDotMacTests/App/MainMenuShortcutTests.swift`:**
  - `everyItemMatchesTable`: walk `MainMenu.make()` recursively (with the standard effect registry); for each item with an identifier: if the table has an entry for it, `keyEquivalent`/mask (∩ ⌘⇧⌥⌃) equal `menuChord(forMenuItem:)`; else `keyEquivalent == ""`. Items without identifier are only separators and submenu parents (assert that).
  - `everyMenuEntryHasAnItem`: every `.menu` entry with a `menuItemIdentifier` and bindings is found in the tree (Settings included).
  - `hiddenAlternatesMatch`: `menu.view.zoomIn.alternate` exists, hidden, `allowsKeyEquivalentWhenHidden`, key "+", ⌘, same action as Zoom In.
  - `goToLayerItems`: Layers menu "Go to Layer Above" key "\u{F72C}" with `.option`, "Go to Layer Below" "\u{F72D}" `.option`.
  - `goToLayerDisabledWhileTextInput`: with a two-layer document whose bottom layer is active, `validateMenuItem` for Go to Layer Above is true; with a `textInputHasFocus` override (inject a focused `NSTextField` as the key window's first responder) it is false; with the Text tool editing (`capturesKeyboard`) it is false.
  - `noLiteralKeyEquivalentsInSource`: read `PaintDotMac/App/MainMenu.swift` via `#filePath` and assert no match for the regex `keyEquivalent:\s*"[^"]+"` and no `keyEquivalentModifierMask\s*=` (all go through `applyShortcut`).
  - Existing `MainMenuTests.noDuplicateShortcuts` and `noRedoAliasCommandY` stay.
- **Integration (headless) — `PaintDotMacTests/Shortcuts/ShortcutRoutingIntegrationTests.swift`:** with 0006's `ToolDispatcher` and the standard registry, feed `handleShortcut` (the Core path) every `.singleKey` tool chord from the table: each selects the expected tool (first of group; ⇧ → last); then with `textInputHasFocus: true` each chord leaves the active tool unchanged; with `keyWindow: .other` unchanged. For the Shapes tool active and pending, feed `ToolKeyEvent` A / ⇧A → shape kind advances / goes back (`tool.shapes.shapeType` in an in-memory store).
- **UI tests — `PaintDotMacUITests/ShortcutAuditUITests.swift`** (launch with a 400×300 PNG fixture generated at test time, `-UITestResetDefaults YES`):
  1. `testKeysTypeIntoNewImageWidthField`: note `tool.paintbrush` is selected and read `colors.primary`'s value; ⌘N → `newImageDialog`; select all in `newImage.width`, type "123", press ⌫ once → the field reads "12" (⌫ edited the field, it didn't run Erase Selection); type `smzhfgbepklrtoxdc[]` → the field's value starts with "12" (the number formatter may keep or reject the letters; either is fine); Cancel the dialog → `tool.paintbrush` still selected, `colors.primary` value unchanged, the History list has only its base row.
  2. `testKeysTypeIntoTextTool`: press `t` → `tool.text` selected; click the canvas; type `sbe xdc[]`; assert `canvas.textEditing` value == "sbe xdc[]", `tool.text` still selected, `colors.primary` unchanged; press ⌥⇟ (`typeKey(.pageDown, modifierFlags: .option)`) → still one layer row active as before (no layer switch) — with a second layer added first via ⇧⌘N so a "below" exists; ⌘↩ → History row "Text".
  3. `testGoToLayerShortcuts`: ⇧⌘N → two layer rows, `layerRow.1` ("Layer 2") selected; ⌥⇟ → `layerRow.0` selected; ⌥⇞ → `layerRow.1` selected; ⌥⇞ again → unchanged (top; item disabled); no History rows added (0024: switching layers is not a step).
  4. `testBrightnessContrastShortcut`: ⇧⌘T → `effectDialog` appears titled "Brightness / Contrast"; `effectDialog.cancel` → gone, no History row.
  5. `testRepresentativeShortcutsEndToEnd`: ⌥⌘3 → `layersPanel` visible; ⌥⌘3 → hidden; `b` → `tool.paintbrush`; `s` `s` (within 1 s) → `tool.lassoSelect`; ⇧S after 1.2 s → `tool.magicWand`; `x` → primary/secondary swapped (`colors.primary` value now the old secondary); ⌘0 → `statusBar.zoom` "100%".
- **Performance:** none (static table; NF-1–NF-4 unaffected).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open every menu and compare the shown shortcuts with `docs/shortcuts.md`; nothing appears twice, and AppKit-added items (tabs, full-screen tiling, dictation, emoji) still show their own shortcuts without clashes.
  2. With the app frontmost, press ⌘H, ⌥⌘H, ⌘M, ⌘`, ⌘Space, ⌃⌘Q (cancel the lock), ⇧⌘4 (Esc) — each does the macOS action, never a PaintDotMac command.
  3. On a MacBook keyboard, fn-⌥-↑ / fn-⌥-↓ switch layers; ⌦ (fn-⌫) erases the selection.
  4. Switch to a German keyboard layout: ⌘0, ⌘B, ⇧⌘Z still work; note in the Verification status which of ⌘[ / ⌘] / ⌘= work (expected: AppKit maps them where the layout can type them).
  5. In an Open panel (⌘O), ⇧⌘G opens "Go to Folder", not Black and White.
  6. Typing in the Colors hex field and the brush width field doesn't switch tools; ⌫ deletes characters there.

## Open questions

The recommended answers are applied in this spec; the user hasn't confirmed them. The pending items from earlier specs (Q3) are included in the table with their recommended values but stay marked `pendingDecision` until the user confirms them; this spec does not settle them.

1. **Go to Layer Above / Below: ⌥⇞ / ⌥⇟** (Paint.NET Alt + PgUp / Alt + PgDn, by the Alt → ⌥ rule; fn-⌥-↑/↓ on laptops). 0024 left them without a shortcut "until 0045". Alternatives: ⌥] / ⌥[ (Photoshop's select-layer keys), or none. Recommended: ⌥⇞ / ⌥⇟, disabled while a text field or the Text tool has focus.
2. **Brightness / Contrast ⇧⌘T** (Paint.NET's current docs list Ctrl + Shift + T; 0031 assumed "Paint.NET has none"). ⇧⌘T is not reserved by macOS and unused in the app. Recommended: add ⇧⌘T.
3. **Pending from earlier specs (unchanged recommended values, not settled here):** Copy Merged ⇧⌘C (0030); Black and White ⇧⌘G, Sepia ⇧⌘E, Posterize ⇧⌘P (0032; ⇧⌘G is Go to Folder inside Open/Save panels, ⇧⌘P is Page Setup in printing apps); Auto-Level ⇧⌘L (0033); Shapes A / Shift+A cycle shape types as a tool-local key (0039). Recommended: keep all, then add the rows to PRD §5.12.
4. **Line/Curve , . / keys** (Paint.NET: start cap style, line style, end cap style) are not implemented by 0038. Recommended: leave them unmapped in v1.0 and list them as "Not mapped" in `docs/shortcuts.md`.
5. **Other Paint.NET shortcuts left unmapped in v1.0** (listed as "Not mapped" in `docs/shortcuts.md`): Save All (Ctrl + Alt + S), Print (Ctrl + P), Enter as Deselect (Return commits pending edits instead), the second Ctrl + B restoring the previous zoom, Ctrl + [ / ] brush width × 5 (⌘[ / ⌘] are Rotate), Ctrl + , Toggle Layer Visibility (⌘, is Settings), Go to Top/Bottom Layer, Ctrl/Alt + 1…9 switch image, PgUp/PgDn/Home/End scrolling and Space + arrow panning (no scroll bars, D-29), the Shift + Delete / Ctrl + Insert / Shift + Insert clipboard aliases, Shift + Backspace fill with secondary color, Ctrl + Shift + F5…F8 reset window. Recommended: leave all unmapped.
6. **Layer Rotate / Zoom (P1, 0060):** Paint.NET's Ctrl + Shift + Z collides with Redo ⇧⌘Z. Recommended: no shortcut when 0060 adds the item (0060 adds its row to the table).

## Out of scope

- User-customizable shortcuts or a shortcuts editor (not in the PRD).
- New commands for the unmapped Paint.NET shortcuts (Save All, Print, Toggle Layer Visibility menu item, Go to Top/Bottom Layer, scrolling keys) — Open question 5.
- The Settings window and its action (0046; it keeps ⌘, from this table).
- Per-keyboard-layout remapping.
- Editing `PRD.md` (the batch owner adds the confirmed §5.12 rows; see item 13).
- Shortcuts for P1 features (0052–0069 add their own rows to the table when they land).
