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
        #expect(menu.items.map(\.submenu?.title)
            == ["PaintDotMac", "File", "Edit", "View", "Window", "Help"])
        #expect(menu.items.map(\.identifier?.rawValue)
            == ["menu.app", "menu.file", "menu.edit", "menu.view", "menu.window", "menu.help"])
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
            Row(title: "New…", key: "n", modifiers: [.command], action: nil),
            Row(title: "Open…", key: "o", modifiers: [.command], action: "openDocument:"),
            Row(title: "Open Recent", key: "", modifiers: [], action: "submenuAction:"),
            .separator,
            Row(title: "Close", key: "w", modifiers: [.command], action: "performClose:"),
            Row(title: "Save", key: "s", modifiers: [.command], action: "saveDocument:"),
            Row(title: "Save As…", key: "s", modifiers: [.command, .shift], action: "saveDocumentAs:"),
        ])
    }

    @Test func editMenuItems() throws {
        try expectRows(MainMenu.editMenuIdentifier, [
            Row(title: "Undo", key: "z", modifiers: [.command], action: "undo:"),
            Row(title: "Redo", key: "z", modifiers: [.command, .shift], action: "redo:"),
            .separator,
            Row(title: "Cut", key: "x", modifiers: [.command], action: "cut:"),
            Row(title: "Copy", key: "c", modifiers: [.command], action: "copy:"),
            Row(title: "Paste", key: "v", modifiers: [.command], action: "paste:"),
            .separator,
            Row(title: "Select All", key: "a", modifiers: [.command], action: "selectAll:"),
        ])
    }

    @Test func viewMenuItems() throws {
        // Spec 0004: Paint.NET's order; the hidden ⌘+ twin of Zoom In keeps the row after it.
        try expectRows(MainMenu.viewMenuIdentifier, [
            Row(title: "Zoom In", key: "=", modifiers: [.command], action: "zoomIn:"),
            Row(title: "Zoom In", key: "+", modifiers: [.command], action: "zoomIn:"),
            Row(title: "Zoom Out", key: "-", modifiers: [.command], action: "zoomOut:"),
            Row(title: "Zoom to Window", key: "b", modifiers: [.command], action: "zoomToWindow:"),
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
            Row(title: "Bring All to Front", key: "", modifiers: [], action: "arrangeInFront:"),
        ])
    }

    @Test func helpMenuIsEmpty() throws {
        #expect(try submenu(MainMenu.helpMenuIdentifier).items.isEmpty)
    }

    @Test func placeholdersHaveNoAction() throws {
        // 0046 and 0005 update this test when they wire these items up.
        let settings = try submenu(MainMenu.appMenuIdentifier).items.first { $0.title == "Settings…" }
        #expect(settings?.action == nil)
        let newItem = try submenu(MainMenu.fileMenuIdentifier).items.first { $0.title == "New…" }
        #expect(newItem?.action == nil)
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
