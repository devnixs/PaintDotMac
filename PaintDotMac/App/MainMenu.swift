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
    static let actualSizeItemIdentifier = NSUserInterfaceItemIdentifier("menu.view.actualSize")

    /// The View menu's zoom actions (0004), sent first-responder-style to
    /// `DocumentWindowController`.
    static let zoomInAction = NSSelectorFromString("zoomIn:")
    static let zoomOutAction = NSSelectorFromString("zoomOut:")
    static let zoomToWindowAction = NSSelectorFromString("zoomToWindow:")
    static let actualSizeAction = NSSelectorFromString("actualSize:")

    // Actions AppKit routes through the responder chain that no class exposes to Swift;
    // every action is sent to the first responder (target = nil).
    private static let undoAction = NSSelectorFromString("undo:")
    private static let redoAction = NSSelectorFromString("redo:")
    private static let cutAction = NSSelectorFromString("cut:")
    private static let copyAction = NSSelectorFromString("copy:")
    private static let pasteAction = NSSelectorFromString("paste:")
    private static let selectAllAction = NSSelectorFromString("selectAll:")
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
        menu.addItem(makeItem("Cut", key: "x", modifiers: .command, action: cutAction))
        menu.addItem(makeItem("Copy", key: "c", modifiers: .command, action: copyAction))
        menu.addItem(makeItem("Paste", key: "v", modifiers: .command, action: pasteAction))
        menu.addItem(.separator())
        menu.addItem(makeItem("Select All", key: "a", modifiers: .command, action: selectAllAction))
        return menu
    }

    /// Paint.NET's order (ViewMenu.html): Zoom In, Zoom Out, Zoom to Window,
    /// (Zoom to Selection → 0014 inserts here), Actual Size, separator, Enter Full Screen.
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
        let actualSize = makeItem("Actual Size", key: "0", modifiers: .command,
                                  action: actualSizeAction)
        actualSize.identifier = actualSizeItemIdentifier
        menu.addItem(actualSize)
        menu.addItem(.separator())
        menu.addItem(makeItem("Enter Full Screen", key: "f", modifiers: [.command, .control],
                              action: #selector(NSWindow.toggleFullScreen(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(makeItem("Minimize", key: "m", modifiers: .command, action: #selector(NSWindow.performMiniaturize(_:))))
        menu.addItem(makeItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
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
