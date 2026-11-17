import AppKit
import Testing
@testable import PaintDotMac

@MainActor
@Suite(.serialized)
struct MainMenuTests {
    /// One menu row as the *Scope* table states it: title, key equivalent, the four modifier
    /// flags, and the action selector string. `separator` is the literal "—" row.
    private struct Row: Equatable, CustomStringConvertible {
        var title: String
        var key: String
        var modifiers: NSEvent.ModifierFlags
        var action: String?

        static let separator = Row(title: "—", key: "", modifiers: [], action: nil)

        var description: String {
            "(\(title), \(key.debugDescription), \(modifierNames), \(action ?? "nil"))"
        }

        private var modifierNames: String {
            var names: [String] = []
            if modifiers.contains(.control) { names.append("⌃") }
            if modifiers.contains(.option) { names.append("⌥") }
            if modifiers.contains(.shift) { names.append("⇧") }
            if modifiers.contains(.command) { names.append("⌘") }
            return names.joined()
        }
    }

    /// Reads the live items; separators map to the `—` sentinel (AppKit leaves them a stray
    /// `.command` mask, which is meaningless for a separator), and only the four modifier flags
    /// participate in the comparison. Submenu parents carry AppKit's own `submenuAction:`.
    private func rows(of menu: NSMenu) -> [Row] {
        menu.items.map { item in
            if item.isSeparatorItem { return .separator }
            return Row(
                title: item.title,
                key: item.keyEquivalent,
                modifiers: item.keyEquivalentModifierMask
                    .intersection([.command, .shift, .option, .control]),
                action: item.action.map(NSStringFromSelector)
            )
        }
    }

    private func topLevelMenus() -> NSMenu {
        MainMenu.make()
    }

    private func submenu(_ identifier: NSUserInterfaceItemIdentifier) throws -> NSMenu {
        let item = try #require(topLevelMenus().items.first { $0.identifier == identifier },
                                "no top-level menu item \(identifier.rawValue)")
        return try #require(item.submenu, "menu item \(identifier.rawValue) has no submenu")
    }

    /// Compares menu rows outside `#expect` so a failed lookup reports itself, and a failed
    /// comparison prints the actual rows.
    private func expectRows(_ menuIdentifier: NSUserInterfaceItemIdentifier,
                            _ expected: [Row]) throws {
        let actual = try rows(of: submenu(menuIdentifier))
        #expect(actual == expected, "actual rows: \(actual.map(\.description))")
    }

    @Test func topLevelMenusInOrder() {
        let menu = topLevelMenus()
        // 0022 creates the Image menu between View and Window (Paint.NET's order); 0024's
        // Layers follows it there (File, Edit, View, Image, Layers, Window, Help; 0031
        // inserts Adjustments/Effects after Layers).
        #expect(menu.items.map(\.submenu?.title)
            == ["PaintDotMac", "File", "Edit", "View", "Image", "Layers", "Window", "Help"])
        #expect(menu.items.map(\.identifier?.rawValue)
            == ["menu.app", "menu.file", "menu.edit", "menu.view", "menu.image",
                "menu.layers", "menu.window", "menu.help"])
    }

    /// 0022: Crop to Selection ⇧⌘X; 0024 appends a separator and Flatten ⇧⌘F last
    /// (Paint.NET's Image menu ends with Flatten).
    @Test func imageMenuItems() throws {
        try expectRows(MainMenu.imageMenuIdentifier, [
            Row(title: "Crop to Selection", key: "x", modifiers: [.command, .shift],
                action: "cropToSelection:"),
            .separator,
            Row(title: "Flatten", key: "f", modifiers: [.command, .shift],
                action: "flattenImage:"),
        ])
        let cropItem = try #require(submenu(MainMenu.imageMenuIdentifier).items.first {
            $0.identifier?.rawValue == "menu.image.cropToSelection"
        })
        #expect(cropItem.title == "Crop to Selection")
    }

    /// 0024: the last Image item is Flatten (⇧⌘F), right after a separator.
    @Test func imageMenuFlattenLast() throws {
        let items = try submenu(MainMenu.imageMenuIdentifier).items
        let last = try #require(items.last)
        #expect(last.title == "Flatten")
        #expect(last.keyEquivalent == "f")
        #expect(last.keyEquivalentModifierMask == [.command, .shift])
        let flattenAction = try #require(last.action)
        #expect(NSStringFromSelector(flattenAction) == "flattenImage:")
        #expect(items.dropLast().last?.isSeparatorItem == true)
        #expect(last.identifier?.rawValue == "menu.image.flatten")
    }

    /// 0024 L-1: the Layers menu, Paint.NET order, exact shortcuts and actions.
    @Test func layersMenuItems() throws {
        try expectRows(MainMenu.layersMenuIdentifier, [
            Row(title: "Add New Layer", key: "n", modifiers: [.command, .shift],
                action: "addNewLayer:"),
            Row(title: "Delete Layer", key: "\u{8}", modifiers: [.command, .shift],
                action: "deleteLayer:"),
            Row(title: "Duplicate Layer", key: "d", modifiers: [.command, .shift],
                action: "duplicateLayer:"),
            Row(title: "Merge Layer Down", key: "e", modifiers: [.command],
                action: "mergeLayerDown:"),
            .separator,
            Row(title: "Go to Layer Above", key: "", modifiers: [],
                action: "goToLayerAbove:"),
            Row(title: "Go to Layer Below", key: "", modifiers: [],
                action: "goToLayerBelow:"),
            .separator,
            Row(title: "Move Layer Up", key: "", modifiers: [], action: "moveLayerUp:"),
            Row(title: "Move Layer Down", key: "", modifiers: [], action: "moveLayerDown:"),
            .separator,
            // 0025: Layer Properties… last, no key equivalent (§5.12 maps it to
            // double-clicking a layer row).
            Row(title: "Layer Properties…", key: "", modifiers: [],
                action: "showLayerProperties:"),
        ])
        // The menu sits directly after Image and before Window.
        let titles = topLevelMenus().items.compactMap(\.submenu?.title)
        guard let imageIndex = titles.firstIndex(of: "Image") else {
            Issue.record("no Image menu")
            return
        }
        #expect(titles[imageIndex + 1] == "Layers")
        #expect(titles[imageIndex + 2] == "Window")
        // Identifiers at the stated positions.
        let identifiers = try submenu(MainMenu.layersMenuIdentifier).items.map(\.identifier?.rawValue)
        #expect(identifiers == [
            "menu.layers.addNewLayer", "menu.layers.deleteLayer", "menu.layers.duplicateLayer",
            "menu.layers.mergeLayerDown", nil, "menu.layers.goToLayerAbove",
            "menu.layers.goToLayerBelow", nil, "menu.layers.moveLayerUp",
            "menu.layers.moveLayerDown", nil, "menu.layers.properties",
        ])
    }

    /// The 0024 key equivalents (⇧⌘N, ⇧⌘⌫, ⇧⌘D, ⌘E, ⇧⌘F) don't collide with any other
    /// main-menu item (same key + modifiers).
    @Test func noShortcutCollisions() throws {
        func collect(_ menu: NSMenu, into list: inout [(key: String,
                                                        modifiers: NSEvent.ModifierFlags)]) {
            for item in menu.items where !item.isSeparatorItem {
                if !item.keyEquivalent.isEmpty {
                    list.append((item.keyEquivalent, item.keyEquivalentModifierMask))
                }
                if let submenu = item.submenu { collect(submenu, into: &list) }
            }
        }
        var shortcuts: [(key: String, modifiers: NSEvent.ModifierFlags)] = []
        collect(topLevelMenus(), into: &shortcuts)
        let new: [(key: String, modifiers: NSEvent.ModifierFlags, label: String)] = [
            ("n", [.command, .shift], "Add New Layer"),
            ("\u{8}", [.command, .shift], "Delete Layer"),
            ("d", [.command, .shift], "Duplicate Layer"),
            ("e", [.command], "Merge Layer Down"),
            ("f", [.command, .shift], "Flatten"),
        ]
        for entry in new {
            let matches = shortcuts.filter {
                $0.key == entry.key && $0.modifiers == entry.modifiers
            }
            #expect(matches.count == 1, "\(entry.label) shortcut collides with another item")
        }
    }

    @Test func appMenuItems() throws {
        try expectRows(MainMenu.appMenuIdentifier, [
            Row(title: "About PaintDotMac", key: "", modifiers: [], action: "orderFrontStandardAboutPanel:"),
            .separator,
            Row(title: "Settings…", key: ",", modifiers: [.command], action: nil),
            .separator,
            Row(title: "Services", key: "", modifiers: [], action: "submenuAction:"),
            .separator,
            Row(title: "Hide PaintDotMac", key: "h", modifiers: [.command], action: "hide:"),
            Row(title: "Hide Others", key: "h", modifiers: [.command, .option], action: "hideOtherApplications:"),
            Row(title: "Show All", key: "", modifiers: [], action: "unhideAllApplications:"),
            .separator,
            Row(title: "Quit PaintDotMac", key: "q", modifiers: [.command], action: "terminate:"),
        ])
    }

    @Test func fileMenuItems() throws {
        try expectRows(MainMenu.fileMenuIdentifier, [
            Row(title: "New…", key: "n", modifiers: [.command], action: "newDocument:"),
            Row(title: "Open…", key: "o", modifiers: [.command], action: "openDocument:"),
            Row(title: "Open Recent", key: "", modifiers: [], action: "submenuAction:"),
            .separator,
            Row(title: "Close", key: "w", modifiers: [.command], action: "performClose:"),
            Row(title: "Save", key: "s", modifiers: [.command], action: "saveDocument:"),
            Row(title: "Save As…", key: "s", modifiers: [.command, .shift], action: "saveDocumentAs:"),
        ])
        // 0005 accessibility identifiers.
        let identifiers = try submenu(MainMenu.fileMenuIdentifier).items.compactMap(\.identifier?.rawValue)
        #expect(identifiers.contains("menu.file.new"))
        #expect(identifiers.contains("menu.file.save"))
        #expect(identifiers.contains("menu.file.saveAs"))
    }

    @Test func editMenuItems() throws {
        try expectRows(MainMenu.editMenuIdentifier, [
            Row(title: "Undo", key: "z", modifiers: [.command], action: "undo:"),
            Row(title: "Redo", key: "z", modifiers: [.command, .shift], action: "redo:"),
            .separator,
            Row(title: "Cut", key: "x", modifiers: [.command], action: "cut:"),
            Row(title: "Copy", key: "c", modifiers: [.command], action: "copy:"),
            Row(title: "Paste", key: "v", modifiers: [.command], action: "paste:"),
            // 0021: Paint.NET order — Paste into New Image directly after Paste.
            Row(title: "Paste into New Image", key: "v", modifiers: [.command, .option],
                action: "pasteIntoNewImage:"),
            .separator,
            // 0013's Paint.NET selection block with 0018's Erase/Fill Selection inserted
            // between Deselect and Invert Selection. ⌫ is `NSBackspaceCharacter`; ⌦ is a
            // key-monitor-only alias (one key equivalent per item).
            Row(title: "Select All", key: "a", modifiers: [.command], action: "selectAll:"),
            Row(title: "Deselect", key: "d", modifiers: [.command], action: "deselect:"),
            Row(title: "Erase Selection", key: "\u{8}", modifiers: [], action: "eraseSelection:"),
            Row(title: "Fill Selection", key: "\u{8}", modifiers: [.option],
                action: "fillSelection:"),
            Row(title: "Invert Selection", key: "i", modifiers: [.command],
                action: "invertSelection:"),
        ])
    }

    @Test func editMenuClipboardItems() throws {
        // 0021: titles, shortcuts, actions, and identifiers of the clipboard block,
        // in Paint.NET order (Cut, Copy, Paste, Paste into New Image).
        let edit = try submenu(MainMenu.editMenuIdentifier)
        let byIdentifier: [(NSUserInterfaceItemIdentifier, String, String,
                            NSEvent.ModifierFlags, String)] = [
            (MainMenu.editCutItemIdentifier, "Cut", "x", [.command], "cut:"),
            (MainMenu.editCopyItemIdentifier, "Copy", "c", [.command], "copy:"),
            (MainMenu.editPasteItemIdentifier, "Paste", "v", [.command], "paste:"),
            (MainMenu.editPasteIntoNewImageItemIdentifier, "Paste into New Image", "v",
             [.command, .option], "pasteIntoNewImage:"),
        ]
        var indices: [Int] = []
        for (identifier, title, key, modifiers, action) in byIdentifier {
            let item = try #require(edit.items.first { $0.identifier == identifier },
                                    "missing \(identifier.rawValue)")
            indices.append(edit.items.firstIndex(of: item) ?? -1)
            #expect(item.title == title)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
            #expect(item.action == NSSelectorFromString(action))
        }
        #expect(indices == indices.sorted(), "the clipboard items keep their order")
        // ⌥⌘V is distinct from ⌘V (noDuplicateShortcuts covers the whole menu).
        let pasteIndex = try #require(edit.items.firstIndex {
            $0.identifier == MainMenu.editPasteItemIdentifier
        })
        let pasteNewIndex = try #require(edit.items.firstIndex {
            $0.identifier == MainMenu.editPasteIntoNewImageItemIdentifier
        })
        #expect(pasteNewIndex == pasteIndex + 1, "Paste into New Image follows Paste")
    }

    @Test func editMenuSelectionItems() throws {
        // Titles, shortcuts, and identifiers exactly as 0013 + 0018 (Paint.NET E-4 / §5.12).
        let edit = try submenu(MainMenu.editMenuIdentifier)
        let byIdentifier: [NSUserInterfaceItemIdentifier] = [
            MainMenu.editSelectAllItemIdentifier,
            MainMenu.editDeselectItemIdentifier,
            MainMenu.editEraseSelectionItemIdentifier,
            MainMenu.editFillSelectionItemIdentifier,
            MainMenu.editInvertSelectionItemIdentifier,
        ]
        var indices: [Int] = []
        for identifier in byIdentifier {
            let item = try #require(edit.items.first { $0.identifier == identifier },
                                    "missing \(identifier.rawValue)")
            indices.append(edit.items.firstIndex(of: item) ?? -1)
            switch identifier {
            case MainMenu.editSelectAllItemIdentifier:
                #expect(item.title == "Select All")
                #expect(item.keyEquivalent == "a")
                #expect(item.keyEquivalentModifierMask == [.command])
                #expect(item.action == NSSelectorFromString("selectAll:"))
            case MainMenu.editDeselectItemIdentifier:
                #expect(item.title == "Deselect", "not \"Deselect All\" (EditMenu.html)")
                #expect(item.keyEquivalent == "d")
                #expect(item.keyEquivalentModifierMask == [.command])
                #expect(item.action == NSSelectorFromString("deselect:"))
            case MainMenu.editEraseSelectionItemIdentifier:
                #expect(item.title == "Erase Selection")
                #expect(item.keyEquivalent == "\u{8}", "⌫ (NSBackspaceCharacter)")
                #expect(item.keyEquivalentModifierMask.isEmpty, "unmodified ⌫ (E-4)")
                #expect(item.action == NSSelectorFromString("eraseSelection:"))
            case MainMenu.editFillSelectionItemIdentifier:
                #expect(item.title == "Fill Selection")
                #expect(item.keyEquivalent == "\u{8}")
                #expect(item.keyEquivalentModifierMask == [.option], "⌥⌫ (E-4)")
                #expect(item.action == NSSelectorFromString("fillSelection:"))
            default:
                #expect(item.title == "Invert Selection")
                #expect(item.keyEquivalent == "i")
                #expect(item.keyEquivalentModifierMask == [.command])
                #expect(item.action == NSSelectorFromString("invertSelection:"))
            }
        }
        #expect(indices == indices.sorted(),
                "Select All, Deselect, Erase, Fill, Invert Selection in order")
        #expect(indices.first! > edit.items.firstIndex(where: { $0.title == "Paste" }) ?? -1,
                "after the clipboard block")

        // No other menu item anywhere uses ⌘D or ⌘I.
        for menu in [topLevelMenus()] + topLevelMenus().items.compactMap(\.submenu) {
            for item in menu.items where !byIdentifier.contains(item.identifier ?? .init("")) {
                guard item.keyEquivalentModifierMask == [.command] else { continue }
                #expect(item.keyEquivalent != "d", "⌘D belongs to Deselect alone: \(item.title)")
                #expect(item.keyEquivalent != "i", "⌘I belongs to Invert Selection alone: \(item.title)")
            }
        }
    }

    @Test func viewMenuItems() throws {
        // Spec 0004: Paint.NET's order; the hidden ⌘+ twin of Zoom In keeps the row after it.
        try expectRows(MainMenu.viewMenuIdentifier, [
            Row(title: "Zoom In", key: "=", modifiers: [.command], action: "zoomIn:"),
            Row(title: "Zoom In", key: "+", modifiers: [.command], action: "zoomIn:"),
            Row(title: "Zoom Out", key: "-", modifiers: [.command], action: "zoomOut:"),
            Row(title: "Zoom to Window", key: "b", modifiers: [.command], action: "zoomToWindow:"),
            Row(title: "Zoom to Selection", key: "b", modifiers: [.command, .shift], action: "zoomToSelection:"),
            Row(title: "Actual Size", key: "0", modifiers: [.command], action: "actualSize:"),
            .separator,
            Row(title: "Enter Full Screen", key: "f", modifiers: [.command, .control], action: "toggleFullScreen:"),
        ])
        // The ⌘+ twin is hidden but still answers key equivalents (⌘+ == ⇧⌘=).
        let menu = try submenu(MainMenu.viewMenuIdentifier)
        let plus = try #require(menu.items.first { $0.keyEquivalent == "+" })
        #expect(plus.isHidden)
        #expect(plus.allowsKeyEquivalentWhenHidden)
    }

    @Test func windowMenuItems() throws {
        try expectRows(MainMenu.windowMenuIdentifier, [
            Row(title: "Minimize", key: "m", modifiers: [.command], action: "performMiniaturize:"),
            Row(title: "Zoom", key: "", modifiers: [], action: "performZoom:"),
            .separator,
            Row(title: "Tools", key: "1", modifiers: [.command, .option], action: "togglePanel:"),
            Row(title: "History", key: "2", modifiers: [.command, .option], action: "togglePanel:"),
            Row(title: "Layers", key: "3", modifiers: [.command, .option], action: "togglePanel:"),
            Row(title: "Colors", key: "4", modifiers: [.command, .option], action: "togglePanel:"),
            .separator,
            Row(title: "Bring All to Front", key: "", modifiers: [], action: "arrangeInFront:"),
        ])
    }

    /// The four panel toggles (0006): identifiers, `representedObject`, and ⌥⌘1–4.
    @Test func windowMenuHasPanelToggles() throws {
        let menu = try submenu(MainMenu.windowMenuIdentifier)
        for (kind, key) in zip(PanelKind.allCases, ["1", "2", "3", "4"]) {
            let item = try #require(
                menu.items.first { $0.identifier == kind.menuItemIdentifier },
                "Window menu has no item \(kind.menuItemIdentifier.rawValue)")
            #expect(item.title == kind.title)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                        == [.command, .option])
            #expect(item.action == MainMenu.togglePanelAction)
            #expect(item.representedObject as? String == kind.rawValue)
        }
    }

    @Test func helpMenuIsEmpty() throws {
        #expect(try submenu(MainMenu.helpMenuIdentifier).items.isEmpty)
    }

    @Test func placeholdersHaveNoAction() throws {
        // 0005 wired New… to newDocument(_:); only Settings… is still a placeholder (0046).
        let settings = try submenu(MainMenu.appMenuIdentifier).items.first { $0.title == "Settings…" }
        #expect(settings?.action == nil)
    }

    @Test func openRecentContainsClearMenu() throws {
        let openRecent = try #require(
            try submenu(MainMenu.fileMenuIdentifier)
                .items.first { $0.identifier == MainMenu.openRecentItemIdentifier }?
                .submenu
        )
        #expect(openRecent.items.count == 1)
        let clear = try #require(openRecent.items.first)
        #expect(clear.title == "Clear Menu")
        #expect(clear.action.map(NSStringFromSelector) == "clearRecentDocuments:")
    }

    @Test func noRedoAliasCommandY() {
        // Redo is ⇧⌘Z only (D-12): no item anywhere has key "y" with only ⌘.
        for item in allItems(in: topLevelMenus()) {
            #expect(!(item.keyEquivalent == "y"
                      && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command),
                    "item \(item.title) claims ⌘Y")
        }
    }

    @Test func noDuplicateShortcuts() throws {
        var seen: [(key: String, modifiers: NSEvent.ModifierFlags, title: String)] = []
        for item in allItems(in: topLevelMenus()) where item.action != nil && !item.keyEquivalent.isEmpty {
            let modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            if let clash = seen.first(where: { $0.key == item.keyEquivalent && $0.modifiers == modifiers }) {
                Issue.record("shortcut \(item.keyEquivalent)\(modifiers) used by both \(clash.title) and \(item.title)")
            }
            seen.append((item.keyEquivalent, modifiers, item.title))
        }
    }

    @Test func installSetsSpecialMenus() throws {
        let savedMainMenu = NSApp.mainMenu
        let savedServices = NSApp.servicesMenu
        let savedWindows = NSApp.windowsMenu
        let savedHelp = NSApp.helpMenu
        defer {
            NSApp.mainMenu = savedMainMenu
            NSApp.servicesMenu = savedServices
            NSApp.windowsMenu = savedWindows
            NSApp.helpMenu = savedHelp
        }

        // Uninstall first: AppKit may ignore reassignment of a special menu that is already
        // registered, so this also proves that `install` (not a leftover launch value) is what
        // wires the three menus.
        NSApp.mainMenu = nil
        NSApp.servicesMenu = nil
        NSApp.windowsMenu = nil
        NSApp.helpMenu = nil

        MainMenu.install(in: NSApp)

        let installed = try #require(NSApp.mainMenu, "install did not set the main menu")
        #expect(NSApp.windowsMenu?.title == "Window")
        #expect(NSApp.helpMenu?.title == "Help")
        // Once a main menu is set on a running app, AppKit manages the Services menu instance
        // itself, so the object `install` passed in is not observable; what is: that a Services
        // menu is registered and our installed menu bar carries the Services item.
        #expect(NSApp.servicesMenu?.title == "Services")
        let servicesItem = try #require(
            Self.findItem(in: installed, identifier: MainMenu.servicesItemIdentifier),
            "the installed menu lost its Services item"
        )
        #expect(servicesItem.submenu?.title == "Services")
    }

    /// Every item in the tree, depth first, including submenu items but not the separators'
    /// (nonexistent) submenus.
    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            var items = [item]
            if let submenu = item.submenu { items += allItems(in: submenu) }
            return items
        }
    }

    /// Depth-first item lookup, matching `MainMenu.install`'s search.
    private static func findItem(in menu: NSMenu, identifier: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier == identifier { return item }
            if let submenu = item.submenu, let found = findItem(in: submenu, identifier: identifier) {
                return found
            }
        }
        return nil
    }
}
