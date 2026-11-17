import AppKit
import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var windowControllers: [MainWindowController] = []
    private weak var lastActiveController: MainWindowController?
    private var settingsWindow: NSWindow?
    private var sessionSaveWork: DispatchWorkItem?
    private var isRestoring = false
    /// Most recently closed last; ⇧⌘T pops from the end.
    private var closedTabs: [ClosedTabRecord] = []

    /// Sparkle updater. Not started in Debug builds so development runs never prompt or download.
    let updaterController: SPUStandardUpdaterController = {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    /// The window menu commands and opened files go to.
    var activeController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        if let last = lastActiveController, windowControllers.contains(where: { $0 === last }) { return last }
        return windowControllers.last
    }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.migrateLegacyDefaults()
        Preferences.shared.applyAppearance()
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenuBuilder.build(recentMenuDelegate: self, updater: updaterController)
        // Restore before any "open file" events arrive so double-clicked files open as new tabs.
        restoreSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = lastActiveController
        for controller in windowControllers where controller !== key {
            controller.showWindow(nil)
        }
        key?.showWindow(nil)
        key?.window?.makeKeyAndOrderFront(nil)
        windowControllers.forEach { $0.startMonitoring() }
        NSApp.activate()
        #if DEBUG
        runDebugDiagnosticsIfRequested()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let controller = activeController ?? openWindow()
        controller.open(urls: urls)
        controller.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never prompt: everything is autosaved and restored on the next launch.
        persistEverything()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistEverything()
    }

    func applicationDidResignActive(_ notification: Notification) {
        persistEverything()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { activeController?.showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Windows

    @discardableResult
    func openWindow(cascadingFrom source: MainWindowController? = nil) -> MainWindowController {
        let controller = MainWindowController.make()
        windowControllers.append(controller)
        if let sourceWindow = (source ?? activeController)?.window, let window = controller.window,
           sourceWindow !== window {
            window.setFrame(sourceWindow.frame, display: false)
            let topLeft = NSPoint(x: sourceWindow.frame.minX, y: sourceWindow.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else {
            controller.window?.center()
        }
        return controller
    }

    func openWindow(with tab: EditorTab, cascadingFrom source: MainWindowController, at screenPoint: NSPoint? = nil) {
        let controller = openWindow(cascadingFrom: source)
        if let screenPoint, let window = controller.window {
            // Put the new window's tab bar under the pointer, like tearing off a browser tab.
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 100, y: screenPoint.y + 40))
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? window.screen {
                window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
            }
        }
        controller.insert(tab)
        controller.showWindow(nil)
        controller.startMonitoring()
        scheduleSessionSave()
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = openWindow()
        controller.newTab(nil)
        controller.showWindow(nil)
        controller.startMonitoring()
        scheduleSessionSave()
    }

    func windowControllerDidBecomeKey(_ controller: MainWindowController) {
        lastActiveController = controller
        scheduleSessionSave()
    }

    func windowControllerDidClose(_ controller: MainWindowController) {
        windowControllers.removeAll { $0 === controller }
        if lastActiveController === controller { lastActiveController = windowControllers.last }
        scheduleSessionSave()
    }

    /// Moves a tab (dragged from another window's tab bar) into `target`.
    func moveTab(id: UUID, to target: MainWindowController, at index: Int? = nil) {
        guard let source = windowControllers.first(where: { $0 !== target && $0.tabIDs.contains(id) }),
              let tab = source.detachTab(id: id) else { return }
        target.insert(tab, at: index)
        target.window?.makeKeyAndOrderFront(nil)
        scheduleSessionSave()
    }

    // MARK: Dragging a window onto another window's tab bar

    private var windowDragTimer: Timer?
    private weak var draggedWindowController: MainWindowController?
    private weak var mergeTarget: MainWindowController?

    /// Called when the user starts dragging a window by its title bar. While the button is held,
    /// watch the pointer: over another window's title/tab bar that bar highlights, and letting go
    /// there moves every tab of the dragged window into it.
    func windowDragDidBegin(_ controller: MainWindowController) {
        guard windowControllers.count > 1, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        draggedWindowController = controller
        windowDragTimer?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackWindowDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowDragTimer = timer
    }

    private func trackWindowDrag() {
        guard let dragged = draggedWindowController else { endWindowDrag(); return }
        let target = mergeTarget(for: NSEvent.mouseLocation, excluding: dragged)
        if target !== mergeTarget {
            mergeTarget?.tabManager.isMergeTarget = false
            target?.tabManager.isMergeTarget = true
            mergeTarget = target
            dragged.window?.alphaValue = target == nil ? 1 : 0.6
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            let destination = mergeTarget
            endWindowDrag()
            if let destination { mergeWindow(dragged, into: destination) }
        }
    }

    private func endWindowDrag() {
        windowDragTimer?.invalidate()
        windowDragTimer = nil
        mergeTarget?.tabManager.isMergeTarget = false
        mergeTarget = nil
        draggedWindowController?.window?.alphaValue = 1
        draggedWindowController = nil
    }

    /// Frontmost other window whose title/tab bar is under the point. With `blockedByExcluded`,
    /// the excluded window counts as covering anything behind it (used for tab drags, where the
    /// source window stays put; a window being dragged is always under the pointer, so it doesn't).
    func mergeTarget(for screenPoint: NSPoint, excluding excluded: MainWindowController,
                     blockedByExcluded: Bool = false) -> MainWindowController? {
        for window in NSApp.orderedWindows where window.isVisible {
            guard let controller = window.windowController as? MainWindowController,
                  windowControllers.contains(where: { $0 === controller }) else {
                if blockedByExcluded, window.frame.contains(screenPoint), window.level == .normal { return nil }
                continue
            }
            if controller === excluded {
                if blockedByExcluded, window.frame.contains(screenPoint) { return nil }
                continue
            }
            if controller.tabStripContains(screenPoint: screenPoint) { return controller }
            if window.frame.contains(screenPoint) { return nil }   // over this window's text: covers ones behind
        }
        return nil
    }

    /// Another window's title/tab bar under a tab being dragged out of `source`.
    func tabDropTarget(at screenPoint: NSPoint, source: MainWindowController) -> MainWindowController? {
        mergeTarget(for: screenPoint, excluding: source, blockedByExcluded: true)
    }

    private weak var tabDropHighlight: MainWindowController?

    /// Outlines the tab bar a dragged tab would move into (nil point clears it).
    func highlightTabDropTarget(at screenPoint: NSPoint?, source: MainWindowController) {
        let target = screenPoint.flatMap { tabDropTarget(at: $0, source: source) }
        guard target !== tabDropHighlight else { return }
        tabDropHighlight?.tabManager.isMergeTarget = false
        target?.tabManager.isMergeTarget = true
        tabDropHighlight = target
    }

    /// Moves every tab of `source` into `target` (keeping order and the selected tab); `source` closes.
    func mergeWindow(_ source: MainWindowController, into target: MainWindowController) {
        let selected = source.tabManager.selectedID
        for id in source.tabIDs {
            moveTab(id: id, to: target)
        }
        if let selected { target.selectTab(id: selected) }
        target.window?.makeKeyAndOrderFront(nil)
    }

    func isPointInsideAppWindow(_ screenPoint: NSPoint) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
    }

    /// Shows a file that is already open in any window. Returns false if it isn't open.
    func selectExistingTab(for url: URL) -> Bool {
        if let active = activeController, active.selectTab(withFileURL: url) { return true }
        return windowControllers.contains { $0.selectTab(withFileURL: url) }
    }

    // MARK: - Reopen closed tab

    func rememberClosedTab(_ record: ClosedTabRecord) {
        closedTabs.append(record)
        if closedTabs.count > 25 { closedTabs.removeFirst(closedTabs.count - 25) }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let record = closedTabs.popLast() else { return }
        if let url = record.fileURL, record.text == nil, selectExistingTab(for: url) { return }
        let controller = activeController ?? openWindow()
        controller.reopen(record)
        controller.showWindow(nil)
    }

    // MARK: - Session

    func scheduleSessionSave() {
        guard !isRestoring else { return }
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSessionNow() }
        }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func saveSessionNow() {
        sessionSaveWork?.cancel()
        sessionSaveWork = nil
        guard !windowControllers.isEmpty else { return }
        let keyIndex = activeController.flatMap { active in windowControllers.firstIndex { $0 === active } }
        let snapshot = SessionSnapshot(windows: windowControllers.map { $0.windowSnapshot() }, keyWindowIndex: keyIndex)
        SessionStore.shared.save(snapshot)
    }

    /// Flush every pending autosave and write the session. Called on quit and when the app deactivates.
    func persistEverything() {
        windowControllers.forEach { $0.flushAutosaves() }
        saveSessionNow()
        SessionStore.shared.flush()
    }

    private func restoreSession() {
        isRestoring = true
        defer { isRestoring = false }

        let session = SessionStore.shared.load()
        let saved = session?.allWindows ?? []
        for (index, windowSnapshot) in saved.enumerated() {
            let controller = MainWindowController.make()
            let restoredAny = controller.restore(from: windowSnapshot)
            // A window whose tabs all failed to load (files deleted) is dropped, unless it would be the only one.
            if restoredAny || (index == saved.count - 1 && windowControllers.isEmpty) {
                windowControllers.append(controller)
                if index == session?.keyWindowIndex { lastActiveController = controller }
            }
        }
        if windowControllers.isEmpty {
            let controller = MainWindowController.make()
            controller.restore(from: nil)
            windowControllers.append(controller)
        }
        if lastActiveController == nil { lastActiveController = windowControllers.last }
        SessionStore.shared.removeOrphanedBackups(keeping: Set(windowControllers.flatMap { $0.tabIDs }))
    }

    // MARK: - Actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(updater: updaterController.updater))
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
        let controller = activeController ?? openWindow()
        controller.showWindow(nil)
        controller.openDocument(sender)
    }

    @objc func newTab(_ sender: Any?) {
        let controller = activeController ?? openWindow()
        controller.showWindow(nil)
        controller.newTab(sender)
    }

    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/saoneill01-a11y/Better-Notepad#readme")!)
    }

    @objc func reportProblem(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/saoneill01-a11y/Better-Notepad/issues/new")!)
    }

    @objc func setAppearanceMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let mode = AppearanceMode(rawValue: id) else { return }
        Preferences.shared.appearanceMode = mode
    }

    @objc func toggleSpellCheck(_ sender: Any?) {
        Preferences.shared.spellCheck.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reopenClosedTab(_:)):
            return !closedTabs.isEmpty
        case #selector(setAppearanceMode(_:)):
            item.state = (item.representedObject as? String) == Preferences.shared.appearanceMode.rawValue ? .on : .off
        case #selector(toggleSpellCheck(_:)):
            item.state = Preferences.shared.spellCheck ? .on : .off
        default:
            break
        }
        return true
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
            let controller = activeController ?? openWindow()
            controller.open(urls: [url])
            controller.showWindow(nil)
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
