import AppKit

/// The whole main menu bar, built in code (no nib; PRD §4 UI, spec 0001 *Scope* table).
///
/// Later specs only add items: the Image, Layers, Adjustments, and Effects menus go between
/// View and Window, in that order (Paint.NET's order), and the placeholder items below get wired
/// up by their specs. Items with a `nil` action are deliberate placeholders — AppKit
/// auto-disables them until they are wired. AppKit adds the tab items (Show Previous Tab, Show
/// Next Tab, Move Tab to New Window, Merge All Windows) to the Window menu and (Show Tab Bar,
/// Show All Tabs) to the View menu by itself, plus the window-tiling items and the Edit menu's
/// dictation and emoji items; none of those are added by hand here.
@MainActor
enum MainMenu {
    // MARK: - Identifiers

    static let appMenuIdentifier = NSUserInterfaceItemIdentifier("menu.app")
    static let fileMenuIdentifier = NSUserInterfaceItemIdentifier("menu.file")
    static let editMenuIdentifier = NSUserInterfaceItemIdentifier("menu.edit")
    static let viewMenuIdentifier = NSUserInterfaceItemIdentifier("menu.view")
    static let imageMenuIdentifier = NSUserInterfaceItemIdentifier("menu.image")
    static let layersMenuIdentifier = NSUserInterfaceItemIdentifier("menu.layers")
    static let windowMenuIdentifier = NSUserInterfaceItemIdentifier("menu.window")
    static let helpMenuIdentifier = NSUserInterfaceItemIdentifier("menu.help")
    static let servicesItemIdentifier = NSUserInterfaceItemIdentifier("menu.app.services")
    static let openRecentItemIdentifier = NSUserInterfaceItemIdentifier("menu.file.openRecent")
    // File > New / Save / Save As (0005).
    static let fileNewItemIdentifier = NSUserInterfaceItemIdentifier("menu.file.new")
    static let fileSaveItemIdentifier = NSUserInterfaceItemIdentifier("menu.file.save")
    static let fileSaveAsItemIdentifier = NSUserInterfaceItemIdentifier("menu.file.saveAs")
    // Zoom items (0004); stable identifiers so 0045 can audit the shortcut table.
    static let zoomInItemIdentifier = NSUserInterfaceItemIdentifier("menu.view.zoomIn")
    static let zoomOutItemIdentifier = NSUserInterfaceItemIdentifier("menu.view.zoomOut")
    static let zoomToWindowItemIdentifier = NSUserInterfaceItemIdentifier("menu.view.zoomToWindow")
    // Zoom to Selection (0014, ⇧⌘B — Paint.NET's Ctrl+Shift+B).
    static let zoomToSelectionItemIdentifier = NSUserInterfaceItemIdentifier("menu.view.zoomToSelection")
    static let actualSizeItemIdentifier = NSUserInterfaceItemIdentifier("menu.view.actualSize")
    // Edit > selection items (0013; 0018's Erase Selection / Fill Selection sit between
    // Deselect and Invert Selection, as 0013 planned).
    static let editSelectAllItemIdentifier = NSUserInterfaceItemIdentifier("menu.edit.selectAll")
    static let editDeselectItemIdentifier = NSUserInterfaceItemIdentifier("menu.edit.deselect")
    static let editEraseSelectionItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.edit.eraseSelection")
    static let editFillSelectionItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.edit.fillSelection")
    static let editInvertSelectionItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.edit.invertSelection")
    // Image > Crop to Selection (0022, ⇧⌘X — Paint.NET's Ctrl+Shift+X, PRD §5.12).
    static let cropToSelectionItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.image.cropToSelection")
    // Image > Flatten (0024, ⇧⌘F — Paint.NET's Ctrl+Shift+F, PRD §5.12), last in the menu.
    static let imageFlattenItemIdentifier = NSUserInterfaceItemIdentifier("menu.image.flatten")
    // Layers menu items (0024, PRD §5.4 L-1 / §5.12).
    static let layersAddItemIdentifier = NSUserInterfaceItemIdentifier("menu.layers.addNewLayer")
    static let layersDeleteItemIdentifier = NSUserInterfaceItemIdentifier("menu.layers.deleteLayer")
    static let layersDuplicateItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.layers.duplicateLayer")
    static let layersMergeItemIdentifier = NSUserInterfaceItemIdentifier("menu.layers.mergeLayerDown")
    static let layersGoToAboveItemIdentifier = NSUserInterfaceItemIdentifier("menu.layers.goToLayerAbove")
    static let layersGoToBelowItemIdentifier = NSUserInterfaceItemIdentifier("menu.layers.goToLayerBelow")
    static let layersMoveUpItemIdentifier = NSUserInterfaceItemIdentifier("menu.layers.moveLayerUp")
    static let layersMoveDownItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.layers.moveLayerDown")
    static let layersPropertiesItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.layers.properties")
    // Edit > clipboard items (0021; the block 0001 placed, 0021 implements).
    static let editCutItemIdentifier = NSUserInterfaceItemIdentifier("menu.edit.cut")
    static let editCopyItemIdentifier = NSUserInterfaceItemIdentifier("menu.edit.copy")
    static let editPasteItemIdentifier = NSUserInterfaceItemIdentifier("menu.edit.paste")
    static let editPasteIntoNewImageItemIdentifier =
        NSUserInterfaceItemIdentifier("menu.edit.pasteIntoNewImage")
    /// Panel toggle action (0006); each item's `representedObject` carries the `PanelKind`
    /// raw value and its identifier is `menu.window.panel.<kind>`.
    static let togglePanelAction = NSSelectorFromString("togglePanel:")

    /// The View menu's zoom actions (0004), sent first-responder-style to
    /// `DocumentWindowController`.
    static let zoomInAction = NSSelectorFromString("zoomIn:")
    static let zoomOutAction = NSSelectorFromString("zoomOut:")
    static let zoomToWindowAction = NSSelectorFromString("zoomToWindow:")
    static let zoomToSelectionAction = NSSelectorFromString("zoomToSelection:")
    static let actualSizeAction = NSSelectorFromString("actualSize:")

    /// The Edit menu's selection actions (0013), sent first-responder-style to
    /// `DocumentWindowController` (target nil).
    static let selectAllAction = NSSelectorFromString("selectAll:")
    static let deselectAction = NSSelectorFromString("deselect:")
    static let invertSelectionAction = NSSelectorFromString("invertSelection:")

    /// The Edit menu's Erase / Fill Selection actions (0018), sent first-responder-style
    /// to `DocumentWindowController` (target nil). ⌦ also erases but a menu item carries
    /// one key equivalent, so the key monitor handles the ⌦ alias (and the ⌫ repeat).
    static let eraseSelectionAction = NSSelectorFromString("eraseSelection:")
    static let fillSelectionAction = NSSelectorFromString("fillSelection:")

    /// The Image menu's actions (0022), sent first-responder-style to
    /// `DocumentWindowController` (target nil).
    static let cropToSelectionAction = NSSelectorFromString("cropToSelection:")
    static let flattenImageAction = NSSelectorFromString("flattenImage:")

    /// The Layers menu's actions (0024), sent first-responder-style to
    /// `DocumentWindowController` (target nil).
    static let addNewLayerAction = NSSelectorFromString("addNewLayer:")
    static let showLayerPropertiesAction = NSSelectorFromString("showLayerProperties:")
    static let deleteLayerAction = NSSelectorFromString("deleteLayer:")
    static let duplicateLayerAction = NSSelectorFromString("duplicateLayer:")
    static let mergeLayerDownAction = NSSelectorFromString("mergeLayerDown:")
    static let goToLayerAboveAction = NSSelectorFromString("goToLayerAbove:")
    static let goToLayerBelowAction = NSSelectorFromString("goToLayerBelow:")
    static let moveLayerUpAction = NSSelectorFromString("moveLayerUp:")
    static let moveLayerDownAction = NSSelectorFromString("moveLayerDown:")

    // Actions AppKit routes through the responder chain that no class exposes to Swift;
    // every action is sent to the first responder (target = nil).
    private static let undoAction = NSSelectorFromString("undo:")
    private static let redoAction = NSSelectorFromString("redo:")
    private static let cutAction = NSSelectorFromString("cut:")
    private static let copyAction = NSSelectorFromString("copy:")
    private static let pasteAction = NSSelectorFromString("paste:")
    // Edit > Paste into New Image (0021) — `PaintDocumentController` implements it, so it
    // works with or without an open document (the document controller is the last responder).
    private static let pasteIntoNewImageAction = NSSelectorFromString("pasteIntoNewImage:")
    // `NSDocument.saveDocument(_:)` is imported as `save(_:)` and `saveDocumentAs(_:)` as
    // `saveAs(_:)`; pin the menu actions to the selector names AppKit dispatches.
    private static let saveDocumentAction = NSSelectorFromString("saveDocument:")
    private static let saveDocumentAsAction = NSSelectorFromString("saveDocumentAs:")

    // MARK: - Installation

    /// Builds the menu bar and installs it, plus the Services, Window, and Help menus AppKit
    /// manages, finding each by identifier.
    static func install(in app: NSApplication) {
        let menu = make()
        app.mainMenu = menu
        app.servicesMenu = submenu(in: menu, itemIdentifier: servicesItemIdentifier)
        app.windowsMenu = submenu(in: menu, itemIdentifier: windowMenuIdentifier)
        app.helpMenu = submenu(in: menu, itemIdentifier: helpMenuIdentifier)
    }

    /// Builds the whole menu bar. Has no side effects on `NSApp`.
    static func make() -> NSMenu {
        let menu = NSMenu(title: "MainMenu")
        menu.addItem(topLevelItem(title: "PaintDotMac", identifier: appMenuIdentifier, submenu: appMenu()))
        menu.addItem(topLevelItem(title: "File", identifier: fileMenuIdentifier, submenu: fileMenu()))
        menu.addItem(topLevelItem(title: "Edit", identifier: editMenuIdentifier, submenu: editMenu()))
        menu.addItem(topLevelItem(title: "View", identifier: viewMenuIdentifier, submenu: viewMenu()))
        menu.addItem(topLevelItem(title: "Image", identifier: imageMenuIdentifier, submenu: imageMenu()))
        menu.addItem(topLevelItem(title: "Layers", identifier: layersMenuIdentifier, submenu: layersMenu()))
        menu.addItem(topLevelItem(title: "Window", identifier: windowMenuIdentifier, submenu: windowMenu()))
        menu.addItem(topLevelItem(title: "Help", identifier: helpMenuIdentifier, submenu: helpMenu()))
        return menu
    }

    // MARK: - Menus (spec 0001 table)

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "PaintDotMac")
        menu.addItem(makeItem("About PaintDotMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", key: ",", modifiers: .command)) // placeholder → 0046
        menu.addItem(.separator())
        menu.addItem(submenuItem("Services", identifier: servicesItemIdentifier, submenu: NSMenu(title: "Services")))
        menu.addItem(.separator())
        menu.addItem(makeItem("Hide PaintDotMac", key: "h", modifiers: .command, action: #selector(NSApplication.hide(_:))))
        menu.addItem(makeItem("Hide Others", key: "h", modifiers: [.command, .option],
                              action: #selector(NSApplication.hideOtherApplications(_:))))
        menu.addItem(makeItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit PaintDotMac", key: "q", modifiers: .command, action: #selector(NSApplication.terminate(_:))))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        let newItem = makeItem("New…", key: "n", modifiers: .command,
                               action: #selector(NSDocumentController.newDocument(_:)))
        newItem.identifier = fileNewItemIdentifier
        menu.addItem(newItem)
        menu.addItem(makeItem("Open…", key: "o", modifiers: .command,
                              action: #selector(NSDocumentController.openDocument(_:))))
        // AppKit fills the Open Recent submenu automatically because it contains the
        // `clearRecentDocuments(_:)` item.
        let openRecent = NSMenu(title: "Open Recent")
        openRecent.addItem(makeItem("Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenuItem("Open Recent", identifier: openRecentItemIdentifier, submenu: openRecent))
        menu.addItem(.separator())
        menu.addItem(makeItem("Close", key: "w", modifiers: .command, action: #selector(NSWindow.performClose(_:))))
        let saveItem = makeItem("Save", key: "s", modifiers: .command, action: saveDocumentAction)
        saveItem.identifier = fileSaveItemIdentifier
        menu.addItem(saveItem)
        let saveAsItem = makeItem("Save As…", key: "s", modifiers: [.command, .shift], action: saveDocumentAsAction)
        saveAsItem.identifier = fileSaveAsItemIdentifier
        menu.addItem(saveAsItem)
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(makeItem("Undo", key: "z", modifiers: .command, action: undoAction))
        menu.addItem(makeItem("Redo", key: "z", modifiers: [.command, .shift], action: redoAction)) // no ⌘Y alias (D-12)
        menu.addItem(.separator())
        // The clipboard block (0021). 0030 inserts Copy Merged after Copy and Paste into
        // New Layer after Paste.
        let cutItem = makeItem("Cut", key: "x", modifiers: .command, action: cutAction)
        cutItem.identifier = editCutItemIdentifier
        menu.addItem(cutItem)
        let copyItem = makeItem("Copy", key: "c", modifiers: .command, action: copyAction)
        copyItem.identifier = editCopyItemIdentifier
        menu.addItem(copyItem)
        let pasteItem = makeItem("Paste", key: "v", modifiers: .command, action: pasteAction)
        pasteItem.identifier = editPasteItemIdentifier
        menu.addItem(pasteItem)
        // Paste into New Image ⌥⌘V (Paint.NET's Ctrl+Alt+V; the PRD §5.12 Alt→⌥ rule).
        let pasteIntoNewImageItem = makeItem("Paste into New Image", key: "v",
                                             modifiers: [.command, .option],
                                             action: pasteIntoNewImageAction)
        pasteIntoNewImageItem.identifier = editPasteIntoNewImageItemIdentifier
        menu.addItem(pasteIntoNewImageItem)
        menu.addItem(.separator())
        // Paint.NET's Edit menu order (E-3) with 0018's items between Deselect and
        // Invert Selection. `NSBackspaceCharacter` shows as ⌫ and matches the Delete
        // key; ⌦ erases too (key monitor only) and ⌥⌫ fills (E-4, §5.12).
        let selectAllItem = makeItem("Select All", key: "a", modifiers: .command,
                                     action: selectAllAction)
        selectAllItem.identifier = editSelectAllItemIdentifier
        menu.addItem(selectAllItem)
        let deselectItem = makeItem("Deselect", key: "d", modifiers: .command,
                                    action: deselectAction)
        deselectItem.identifier = editDeselectItemIdentifier
        menu.addItem(deselectItem)
        // `NSBackspaceCharacter` — the ⌫ key equivalent with no modifiers.
        let eraseSelectionItem = makeItem("Erase Selection", key: "\u{8}",
                                          action: eraseSelectionAction)
        eraseSelectionItem.identifier = editEraseSelectionItemIdentifier
        menu.addItem(eraseSelectionItem)
        let fillSelectionItem = makeItem("Fill Selection", key: "\u{8}", modifiers: .option,
                                         action: fillSelectionAction)
        fillSelectionItem.identifier = editFillSelectionItemIdentifier
        menu.addItem(fillSelectionItem)
        let invertSelectionItem = makeItem("Invert Selection", key: "i", modifiers: .command,
                                           action: invertSelectionAction)
        invertSelectionItem.identifier = editInvertSelectionItemIdentifier
        menu.addItem(invertSelectionItem)
        return menu
    }

    /// Paint.NET's order (ViewMenu.html): Zoom In, Zoom Out, Zoom to Window,
    /// Zoom to Selection (0014), Actual Size, separator, Enter Full Screen.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let zoomIn = makeItem("Zoom In", key: "=", modifiers: .command, action: zoomInAction)
        zoomIn.identifier = zoomInItemIdentifier
        menu.addItem(zoomIn)
        // ⌘+ also zooms in (Paint.NET's Ctrl++): a hidden twin with the "+" equivalent.
        // AppKit's key-equivalent matching ignores ⇧, so ⌘+ (⇧⌘= on US layouts) hits it.
        let zoomInPlus = makeItem("Zoom In", key: "+", modifiers: .command, action: zoomInAction)
        zoomInPlus.identifier = NSUserInterfaceItemIdentifier(zoomInItemIdentifier.rawValue + ".plus")
        zoomInPlus.isHidden = true
        zoomInPlus.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInPlus)
        let zoomOut = makeItem("Zoom Out", key: "-", modifiers: .command, action: zoomOutAction)
        zoomOut.identifier = zoomOutItemIdentifier
        menu.addItem(zoomOut)
        let zoomToWindow = makeItem("Zoom to Window", key: "b", modifiers: .command,
                                    action: zoomToWindowAction)
        zoomToWindow.identifier = zoomToWindowItemIdentifier
        menu.addItem(zoomToWindow)
        // Zoom to Selection (0014, CAN-1): Paint.NET's Ctrl+Shift+B → ⇧⌘B (PRD §5.12).
        let zoomToSelection = makeItem("Zoom to Selection", key: "b",
                                       modifiers: [.command, .shift], action: zoomToSelectionAction)
        zoomToSelection.identifier = zoomToSelectionItemIdentifier
        menu.addItem(zoomToSelection)
        let actualSize = makeItem("Actual Size", key: "0", modifiers: .command,
                                  action: actualSizeAction)
        actualSize.identifier = actualSizeItemIdentifier
        menu.addItem(actualSize)
        menu.addItem(.separator())
        menu.addItem(makeItem("Enter Full Screen", key: "f", modifiers: [.command, .control],
                              action: #selector(NSWindow.toggleFullScreen(_:))))
        return menu
    }

    /// Paint.NET's Image menu (ImageMenu.html): commands that affect all layers. Flatten
    /// is last (Paint.NET's Image menu ends with it). 0035 (Resize Image), 0036 (Canvas
    /// Size / Resize Canvas), and 0037 (Flip/Rotate) insert their items between Crop to
    /// Selection and Flatten, in Paint.NET's order (Crop to Selection, Resize, Canvas
    /// Size, Flip/Rotate, Flatten).
    private static func imageMenu() -> NSMenu {
        let menu = NSMenu(title: "Image")
        // Crop to Selection ⇧⌘X (Paint.NET's Ctrl+Shift+X → ⇧⌘X, PRD §5.12). Disabled
        // without a selection (`validateMenuItem`), as Paint.NET's "only available if a
        // selection is active" states.
        let cropItem = makeItem(CropToSelection.name, key: "x", modifiers: [.command, .shift],
                                action: cropToSelectionAction)
        cropItem.identifier = cropToSelectionItemIdentifier
        menu.addItem(cropItem)
        menu.addItem(.separator())
        // Flatten ⇧⌘F (0024, IMG-5 — Paint.NET's Ctrl+Shift+F, PRD §5.12).
        let flattenItem = makeItem(LayerCommand.flatten.name, key: "f",
                                   modifiers: [.command, .shift], action: flattenImageAction)
        flattenItem.identifier = imageFlattenItemIdentifier
        menu.addItem(flattenItem)
        return menu
    }

    /// Paint.NET's Layers menu (LayersMenu.html), the L-1 subset (0024): Add New Layer,
    /// Delete Layer, Duplicate Layer, Merge Layer Down, —, Go to Layer Above, Go to Layer
    /// Below, —, Move Layer Up, Move Layer Down. Later specs slot in: 0030 "Import From
    /// File…" after Merge Layer Down; 0060 flips/rotate before Go to Layer Above; 0025
    /// "Layer Properties…" at the end after a separator. Go to/Move Layer get no shortcut
    /// (PRD §5.12 lists none; 0045 audits).
    private static func layersMenu() -> NSMenu {
        let menu = NSMenu(title: "Layers")
        // ⇧⌘N (Paint.NET's Ctrl+Shift+N). "n"/⌘ is File > New, so the ⇧ distinguishes it.
        let addItem = makeItem(LayerCommand.addNewLayer.name, key: "n", modifiers: [.command, .shift],
                               action: addNewLayerAction)
        addItem.identifier = layersAddItemIdentifier
        menu.addItem(addItem)
        // ⇧⌘⌫ — `NSBackspaceCharacter` (⌫) with ⇧⌘ (Paint.NET's Ctrl+Shift+Backspace).
        let deleteItem = makeItem(LayerCommand.deleteLayer.name, key: "\u{8}",
                                  modifiers: [.command, .shift], action: deleteLayerAction)
        deleteItem.identifier = layersDeleteItemIdentifier
        menu.addItem(deleteItem)
        // ⇧⌘D (Paint.NET's Ctrl+Shift+D).
        let duplicateItem = makeItem(LayerCommand.duplicateLayer.name, key: "d",
                                     modifiers: [.command, .shift], action: duplicateLayerAction)
        duplicateItem.identifier = layersDuplicateItemIdentifier
        menu.addItem(duplicateItem)
        // ⌘E (Paint.NET's Ctrl+E).
        let mergeItem = makeItem(LayerCommand.mergeLayerDown.name, key: "e", modifiers: .command,
                                 action: mergeLayerDownAction)
        mergeItem.identifier = layersMergeItemIdentifier
        menu.addItem(mergeItem)
        menu.addItem(.separator())
        let goToAboveItem = makeItem("Go to Layer Above", action: goToLayerAboveAction)
        goToAboveItem.identifier = layersGoToAboveItemIdentifier
        menu.addItem(goToAboveItem)
        let goToBelowItem = makeItem("Go to Layer Below", action: goToLayerBelowAction)
        goToBelowItem.identifier = layersGoToBelowItemIdentifier
        menu.addItem(goToBelowItem)
        menu.addItem(.separator())
        let moveUpItem = makeItem(LayerCommand.moveLayerUp.name, action: moveLayerUpAction)
        moveUpItem.identifier = layersMoveUpItemIdentifier
        menu.addItem(moveUpItem)
        let moveDownItem = makeItem(LayerCommand.moveLayerDown.name, action: moveLayerDownAction)
        moveDownItem.identifier = layersMoveDownItemIdentifier
        menu.addItem(moveDownItem)
        // 0025: "Layer Properties…" at the end after a separator (LayersMenu.html);
        // PRD §5.12 maps it to double-clicking a layer row, so it gets no key equivalent.
        menu.addItem(.separator())
        let propertiesItem = makeItem("Layer Properties…", action: showLayerPropertiesAction)
        propertiesItem.identifier = layersPropertiesItemIdentifier
        menu.addItem(propertiesItem)
        return menu
    }

    /// Minimize, Zoom, —, the four panel toggles ⌥⌘1–4 (APP-2, PRD §5.12), —, Bring All to
    /// Front. AppKit appends its tab items to this menu by itself.
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(makeItem("Minimize", key: "m", modifiers: .command, action: #selector(NSWindow.performMiniaturize(_:))))
        menu.addItem(makeItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        for kind in PanelKind.allCases {
            let item = makeItem(kind.title, key: kind.menuKeyEquivalent,
                                modifiers: PanelKind.menuKeyEquivalentModifiers,
                                action: togglePanelAction)
            item.identifier = kind.menuItemIdentifier
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        // No items; AppKit adds the search field because this menu becomes `helpMenu`.
        NSMenu(title: "Help")
    }

    // MARK: - Item builders

    private static func topLevelItem(title: String, identifier: NSUserInterfaceItemIdentifier,
                                     submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = identifier
        item.submenu = submenu
        return item
    }

    private static func submenuItem(_ title: String, identifier: NSUserInterfaceItemIdentifier,
                                    submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.keyEquivalentModifierMask = []
        item.identifier = identifier
        item.submenu = submenu // AppKit gives the item its own `submenuAction:` from here on
        return item
    }

    /// A leaf item. The modifier mask is set explicitly so items without a key equivalent do not
    /// keep `NSMenuItem`'s default `.command` mask.
    private static func makeItem(_ title: String, key: String = "",
                                 modifiers: NSEvent.ModifierFlags = [], action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(in menu: NSMenu, itemIdentifier: NSUserInterfaceItemIdentifier) -> NSMenu? {
        menuItem(in: menu, identifier: itemIdentifier)?.submenu
    }

    /// Finds an item anywhere in the tree; the Services item lives inside the app submenu, not
    /// at the top level.
    private static func menuItem(in menu: NSMenu, identifier: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier == identifier { return item }
            if let submenu = item.submenu, let found = menuItem(in: submenu, identifier: identifier) {
                return found
            }
        }
        return nil
    }
}
