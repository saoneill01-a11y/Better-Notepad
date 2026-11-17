import AppKit

/// Builds the menu bar in code (no storyboard).
@MainActor
enum MainMenuBuilder {
    static func build(recentMenuDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        let appName = "Better Notepad"

        // App menu
        let appMenu = submenu(in: main, title: appName)
        appMenu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        // File
        let file = submenu(in: main, title: "File")
        file.addItem(item("New Tab", #selector(MainWindowController.newTab(_:)), "t"))
        file.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recentMenuDelegate
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(item("Save", #selector(MainWindowController.saveDocument(_:)), "s"))
        file.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Save All", #selector(MainWindowController.saveAllDocuments(_:)), "s", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))

        // Edit
        let edit = submenu(in: main, title: "Edit")
        edit.addItem(item("Undo", #selector(NotepadTextView.undo(_:)), "z"))
        edit.addItem(item("Redo", #selector(NotepadTextView.redo(_:)), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Find…", #selector(MainWindowController.showFind(_:)), "f"))
        edit.addItem(item("Find & Replace…", #selector(MainWindowController.showFindAndReplace(_:)), "f", [.command, .option]))
        edit.addItem(item("Find Next", #selector(MainWindowController.findNextMatch(_:)), "g"))
        edit.addItem(item("Find Previous", #selector(MainWindowController.findPreviousMatch(_:)), "g", [.command, .shift]))
        edit.addItem(item("Go to Line…", #selector(MainWindowController.goToLine(_:)), "l"))
        edit.addItem(.separator())
        let f5 = String(Character(UnicodeScalar(NSF5FunctionKey)!))
        edit.addItem(item("Insert Time/Date", #selector(MainWindowController.insertTimeDate(_:)), f5, []))

        // Format
        let format = submenu(in: main, title: "Format")
        format.addItem(item("Font…", #selector(MainWindowController.showEditorFontPanel(_:))))
        format.addItem(item("Word Wrap", #selector(MainWindowController.toggleWordWrap(_:))))

        // View
        let view = submenu(in: main, title: "View")
        view.addItem(item("Zoom In", #selector(MainWindowController.zoomInText(_:)), "="))
        view.addItem(item("Zoom Out", #selector(MainWindowController.zoomOutText(_:)), "-"))
        view.addItem(item("Restore Default Zoom", #selector(MainWindowController.resetZoomText(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Line Numbers", #selector(MainWindowController.toggleLineNumbers(_:))))
        view.addItem(item("Word Wrap", #selector(MainWindowController.toggleWordWrap(_:))))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Window
        let window = submenu(in: main, title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        // ⌘} / ⌘{ are what ⇧⌘] / ⇧⌘[ produce on a US keyboard.
        window.addItem(item("Show Next Tab", #selector(MainWindowController.showNextTab(_:)), "}"))
        window.addItem(item("Show Previous Tab", #selector(MainWindowController.showPreviousTab(_:)), "{"))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        let help = submenu(in: main, title: "Help")
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}
