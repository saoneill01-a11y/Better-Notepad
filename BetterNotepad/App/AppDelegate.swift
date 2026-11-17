import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var windowController: MainWindowController?
    private var settingsWindow: NSWindow?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Holding a key repeats it (like Notepad) instead of showing the accent picker.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        NSApp.mainMenu = MainMenuBuilder.build(recentMenuDelegate: self)
        let controller = MainWindowController.make()
        windowController = controller
        // Restore before any "open file" events arrive so double-clicked files open as new tabs.
        controller.restoreSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController?.showWindow(nil)
        windowController?.startMonitoring()
        NSApp.activate()
        #if DEBUG
        if let out = ProcessInfo.processInfo.environment["BN_DIAG_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.windowController?.runDiagnostics(pngPath: out)
            }
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        windowController?.open(urls: urls)
        windowController?.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never prompt: everything is autosaved and restored on the next launch.
        windowController?.persistEverything()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.persistEverything()
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.persistEverything()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Better Notepad Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        windowController?.showWindow(nil)
        windowController?.openDocument(sender)
    }

    @objc func newTab(_ sender: Any?) {
        windowController?.showWindow(nil)
        windowController?.newTab(sender)
    }

    // MARK: - Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentFiles.shared.urls
        if urls.isEmpty {
            menu.addItem(NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: ""))
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            windowController?.open(urls: [url])
        } else {
            RecentFiles.shared.remove(url)
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” can’t be found."
            alert.informativeText = "It may have been moved or deleted."
            alert.runModal()
        }
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        RecentFiles.shared.clear()
    }
}
