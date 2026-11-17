import AppKit
import SwiftUI
import Combine

/// One editor window: tab bar, find bar, editor and status bar, plus all document actions.
/// The app can have several; AppDelegate owns them and the shared session.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let tabManager = TabManager()
    let status = StatusModel()
    let findState = FindState()

    private let prefs = Preferences.shared
    private let editorContainer = NSView()
    private var findBarHost: NSHostingView<FindBarView>!
    private var cancellables = Set<AnyCancellable>()
    private var fileMonitorTimer: Timer?
    private var isShowingFileChangeAlert = false
    private var isClosingWindow = false
    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private var app: AppDelegate { AppDelegate.shared }
    var currentTab: EditorTab? { tabManager.selectedTab }

    static func make() -> MainWindowController {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Better Notepad"
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .none
        // The title bar takes the tab bar's colour so they read as one strip, like Notepad.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.chrome
        return MainWindowController(window: window)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
        window?.delegate = self
        tabManager.controller = self
        buildInterface()
        bindModels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func buildInterface() {
        guard let window else { return }

        let tabBar = NSHostingView(rootView: TabBarView(manager: tabManager))
        tabBar.sizingOptions = []

        let findHost = NSHostingView(rootView: FindBarView(state: findState))
        findHost.sizingOptions = [.intrinsicContentSize]
        findHost.isHidden = true
        findHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        findHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        findBarHost = findHost

        let statusHost = NSHostingView(rootView: StatusBarView(model: status))
        statusHost.sizingOptions = []

        let views: [NSView] = [tabBar, findHost, editorContainer, statusHost]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),
            statusHost.heightAnchor.constraint(equalToConstant: 24),
        ])
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        editorContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        window.contentView = content
    }

    private func bindModels() {
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.preferencesChanged() }
            .store(in: &cancellables)

        tabManager.$tabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSessionSave() }
            .store(in: &cancellables)

        findState.onFindNext = { [weak self] in self?.find(forward: true) }
        findState.onFindPrevious = { [weak self] in self?.find(forward: false) }
        findState.onReplace = { [weak self] in self?.replaceCurrent() }
        findState.onReplaceAll = { [weak self] in self?.replaceAll() }
        findState.onClose = { [weak self] in self?.hideFindBar() }

        status.onChooseEncoding = { [weak self] in self?.chooseEncoding($0) }
        status.onChooseLineEnding = { [weak self] in self?.chooseLineEnding($0) }
    }

    private func preferencesChanged() {
        for tab in tabManager.tabs { tab.apply(preferences: prefs) }
        updateStatus()
    }

    // MARK: - Tabs

    private func makeTab(id: UUID = UUID()) -> EditorTab {
        let tab = EditorTab(id: id)
        adopt(tab)
        return tab
    }

    /// Points a tab's callbacks at this window (new tabs, and tabs moved in from another window).
    private func adopt(_ tab: EditorTab) {
        tab.onTextChange = { [weak self] tab in self?.tabDidChangeText(tab) }
        tab.onSelectionChange = { [weak self] tab in self?.tabDidChangeSelection(tab) }
        tab.onViewStateChange = { [weak self] tab in
            self?.scheduleSessionSave()
            if tab === self?.currentTab { self?.updateWindowTitle() }
        }
        tab.onEscape = { [weak self] in self?.hideFindBar() }
        tab.apply(preferences: prefs)
    }

    func selectTab(id: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return }
        if tab.scrollView.superview !== editorContainer {
            editorContainer.subviews.forEach { $0.removeFromSuperview() }
            let sv = tab.scrollView
            sv.removeFromSuperview()
            sv.translatesAutoresizingMaskIntoConstraints = false
            editorContainer.addSubview(sv)
            NSLayoutConstraint.activate([
                sv.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
                sv.topAnchor.constraint(equalTo: editorContainer.topAnchor),
                sv.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            ])
        }
        if tabManager.selectedID != id { tabManager.selectedID = id }
        editorContainer.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(tab.textView)
        window?.initialFirstResponder = tab.textView
        updateWindowTitle()
        updateStatus()
        if tab.hasPendingViewState {
            DispatchQueue.main.async { [weak tab] in tab?.applyPendingViewStateIfNeeded() }
        }
        scheduleSessionSave()
    }

    @objc func newTab(_ sender: Any?) {
        let tab = makeTab()
        tabManager.tabs.append(tab)
        selectTab(id: tab.id)
    }

    /// Adds a tab that already has content (moved from another window).
    /// Adds a tab moved in from another window. Existing tabs, even empty ones, are kept.
    func insert(_ tab: EditorTab, at index: Int? = nil) {
        adopt(tab)
        let position = min(max(0, index ?? tabManager.tabs.count), tabManager.tabs.count)
        tabManager.tabs.insert(tab, at: position)
        selectTab(id: tab.id)
    }

    /// Tab position under a screen point in this window's tab bar (tabs are 190 pt wide, 2 pt apart).
    func tabInsertionIndex(forScreenPoint point: NSPoint) -> Int {
        guard let window else { return tabManager.tabs.count }
        let x = window.convertPoint(fromScreen: point).x - 6
        return min(max(0, Int((x / 192).rounded())), tabManager.tabs.count)
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = currentTab { requestCloseTab(id: tab.id) }
    }

    func requestCloseTab(id: UUID, completion: ((Bool) -> Void)? = nil) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }), let window else {
            completion?(true)
            return
        }
        guard tab.needsSavePrompt else {
            closeTabNow(tab)
            completion?(true)
            return
        }
        selectTab(id: id)
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(tab.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async {
                    self.save(tab) { ok in
                        if ok { self.closeTabNow(tab) }
                        completion?(ok)
                    }
                }
            case .alertSecondButtonReturn:
                self.closeTabNow(tab)
                completion?(true)
            default:
                completion?(false)
            }
        }
    }

    private func closeTabNow(_ tab: EditorTab) {
        removeTab(tab, rememberClosed: true)
        if tabManager.tabs.isEmpty && !isClosingWindow {
            newTab(nil)
        }
    }

    /// Takes a tab out of this window. Closed tabs are remembered for ⇧⌘T and their autosave is removed.
    private func removeTab(_ tab: EditorTab, rememberClosed: Bool, keepAlive: Bool = false) {
        guard let index = tabManager.tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = tab.id == tabManager.selectedID
        if rememberClosed, let record = tab.closedRecord() {
            app.rememberClosedTab(record)
        }
        if !keepAlive { tab.discard() }
        tab.scrollView.removeFromSuperview()
        tabManager.tabs.remove(at: index)
        if wasSelected, !tabManager.tabs.isEmpty {
            selectTab(id: tabManager.tabs[min(index, tabManager.tabs.count - 1)].id)
        }
        scheduleSessionSave()
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        if let tab = currentTab { moveTabToNewWindow(id: tab.id) }
    }

    func moveTabToNewWindow(id: UUID) {
        guard tabManager.tabs.count > 1, let tab = tabManager.tabs.first(where: { $0.id == id }) else { return }
        tab.flushAutosave()
        removeTab(tab, rememberClosed: false, keepAlive: true)
        app.openWindow(with: tab, cascadingFrom: self)
    }

    /// Removes a tab without closing it, so another window can take it.
    func detachTab(id: UUID) -> EditorTab? {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return nil }
        tab.flushAutosave()
        removeTab(tab, rememberClosed: false, keepAlive: true)
        if tabManager.tabs.isEmpty {
            // Its last tab left: the window goes away (nothing in it to save).
            isClosingWindow = true
            finishClosingWindow()
        }
        return tab
    }

    /// The tab was dropped outside every window onto something that didn't accept it.
    func tearOffTab(id: UUID, at screenPoint: NSPoint) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return }
        if tabManager.tabs.count == 1 {
            // Already alone in its window: move the window there instead.
            window?.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 100, y: screenPoint.y + 40))
            return
        }
        tab.flushAutosave()
        removeTab(tab, rememberClosed: false, keepAlive: true)
        app.openWindow(with: tab, cascadingFrom: self, at: screenPoint)
    }

    // MARK: - Dragging a tab to Finder / the Desktop

    /// "<first line>.txt" for untitled tabs (cleaned up and shortened), or the file's own name.
    func suggestedFileName(forTabID id: UUID) -> String {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return "Untitled.txt" }
        if let url = tab.fileURL { return url.lastPathComponent }
        return Self.fileName(fromFirstLineOf: tab.nsText)
    }

    static func fileName(fromFirstLineOf text: NSString, maxLength: Int = 50) -> String {
        let firstLineEnd = text.range(of: "\n").location
        let head = text.substring(to: min(firstLineEnd == NSNotFound ? text.length : firstLineEnd, 400))
        // Characters Finder or other systems can't take in names, and anything invisible.
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters).union(.newlines)
        var name = head.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }   // no hidden files
        if name.count > maxLength {
            let cut = String(name.prefix(maxLength))
            // Prefer ending at a word boundary if one is reasonably close.
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxLength * 2 / 3 {
                name = String(cut[..<space])
            } else {
                name = cut
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Untitled" : name) + ".txt"
    }

    func handleTabDroppedAsFile(id: UUID, destination: URL, completion: @escaping (Error?) -> Void) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else {
            completion(CocoaError(.userCancelled))
            return
        }
        let folder = destination.deletingLastPathComponent()
        let saveFile = { [weak self] in
            do {
                _ = try self?.writeCopy(of: tab, into: folder, named: destination.lastPathComponent)
                completion(nil)
            } catch {
                completion(error)
                self?.showError(error, message: "“\(destination.lastPathComponent)” couldn’t be saved.")
            }
        }
        let openWindow = { [weak self] in
            // Tell Finder nothing was created, then tear the tab off next to where it was dropped.
            completion(CocoaError(.userCancelled))
            self?.tearOffTab(id: id, at: self?.tabManager.lastDropPoint ?? NSEvent.mouseLocation)
        }

        switch prefs.tabDropAction {
        case .saveFile:
            saveFile()
        case .newWindow:
            openWindow()
        case .ask:
            NSApp.activate()
            let alert = NSAlert()
            let place = folder.path == FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
                ? "the Desktop" : "“\(folder.lastPathComponent)”"
            alert.messageText = "Save “\(destination.lastPathComponent)” to \(place)?"
            alert.informativeText = "This saves a copy of the tab as a text file. You can open the tab in its own window instead."
            alert.addButton(withTitle: "Save File")
            alert.addButton(withTitle: "Open in New Window")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do this every time (change in Settings)"
            let response = alert.runModal()
            let remember = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn:
                if remember { prefs.tabDropAction = .saveFile }
                saveFile()
            case .alertSecondButtonReturn:
                if remember { prefs.tabDropAction = .newWindow }
                openWindow()
            default:
                completion(CocoaError(.userCancelled))
            }
        }
    }

    /// Writes the tab's text (in its encoding and line endings) to a new file in `folder`,
    /// adding " 2", " 3", … if the name is taken. The tab itself is not changed.
    private func writeCopy(of tab: EditorTab, into folder: URL, named name: String) throws -> URL {
        let data = TextFileCodec.encode(tab.text, encoding: tab.encoding, lineEnding: tab.lineEnding)
            ?? TextFileCodec.encode(tab.text, encoding: .utf8, lineEnding: tab.lineEnding)
            ?? Data()
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext.isEmpty ? "txt" : ext)
            n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Opens a closed tab again in this window.
    func reopen(_ record: ClosedTabRecord) {
        let tab = makeTab()
        do {
            try tab.restoreClosed(record)
        } catch {
            tab.discard()
            showError(error, message: "“\(record.fileURL?.lastPathComponent ?? "Untitled")” couldn’t be reopened.")
            return
        }
        if let current = currentTab, current.isPristine {
            removeTab(current, rememberClosed: false)
        }
        tabManager.tabs.append(tab)
        selectTab(id: tab.id)
    }

    func selectTab(withFileURL url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let tab = tabManager.tabs.first(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target })
        else { return false }
        window?.makeKeyAndOrderFront(nil)
        selectTab(id: tab.id)
        return true
    }

    @objc func showNextTab(_ sender: Any?) {
        cycleTabs(by: 1)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        cycleTabs(by: -1)
    }

    private func cycleTabs(by delta: Int) {
        let tabs = tabManager.tabs
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == tabManager.selectedID }) else { return }
        let next = (current + delta + tabs.count) % tabs.count
        selectTab(id: tabs[next].id)
    }

    private func tabDidChangeText(_ tab: EditorTab) {
        if tab === currentTab {
            updateStatus()
            updateWindowTitle()
        }
        scheduleSessionSave()
    }

    private func tabDidChangeSelection(_ tab: EditorTab) {
        if tab === currentTab { updateStatus() }
        scheduleSessionSave()
    }

    // MARK: - Window title & status bar

    private func updateWindowTitle() {
        guard let window, let tab = currentTab else { return }
        window.title = tab.title
        window.representedURL = tab.fileURL
        window.isDocumentEdited = tab.isDirty
    }

    private func format(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    func updateStatus() {
        guard let tab = currentTab else { return }
        let index = tab.lineIndex
        let length = tab.length
        let ranges = tab.textView.selectedRanges.map { $0.rangeValue }
        let primary = ranges.first ?? NSRange(location: 0, length: 0)
        let caret = min(primary.location, length)
        let line = index.lineNumber(at: caret)
        let column = caret - index.lineStart(line) + 1
        status.position = "Ln \(format(line + 1)), Col \(format(column))"

        let selected = ranges.reduce(0) { $0 + $1.length }
        if selected > 0 {
            let start = ranges.map { $0.location }.min() ?? 0
            let end = ranges.map { NSMaxRange($0) }.max() ?? 0
            let spanned = index.lineNumber(at: max(start, end - 1)) - index.lineNumber(at: start) + 1
            status.selection = "\(format(selected)) selected (\(format(spanned)) \(spanned == 1 ? "line" : "lines"))"
        } else {
            status.selection = ""
        }
        let lines = index.lineCount
        status.lines = "\(format(lines)) \(lines == 1 ? "line" : "lines")"
        status.characters = "\(format(length)) \(length == 1 ? "character" : "characters")"
        status.zoom = "\(prefs.zoomPercent)%"
        if status.lineEnding != tab.lineEnding { status.lineEnding = tab.lineEnding }
        if status.encoding != tab.encoding { status.encoding = tab.encoding }
    }

    // MARK: - Encoding and line endings

    private func chooseEncoding(_ encoding: TextEncodingKind) {
        guard let tab = currentTab else { return }
        guard encoding.canEncode(tab.nsText) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "This text can’t be saved as \(encoding.displayName)."
            alert.informativeText = "It contains characters that \(encoding.displayName) can’t represent. Remove them first, or keep a Unicode encoding such as UTF-8."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            updateStatus()
            return
        }
        tab.changeEncoding(encoding)
        updateStatus()
    }

    private func chooseLineEnding(_ ending: LineEnding) {
        currentTab?.changeLineEnding(ending)
        updateStatus()
    }

    // MARK: - Opening files

    @objc func openDocument(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let dir = currentTab?.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }
    }

    func open(urls: [URL]) {
        for rawURL in urls {
            let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
            // Already open somewhere (this or another window): just show it.
            if app.selectExistingTab(for: url) { continue }
            do {
                let file = try EditorTab.readFile(at: url)
                let tab: EditorTab
                if let current = currentTab, current.isPristine {
                    tab = current
                } else {
                    tab = makeTab()
                    tabManager.tabs.append(tab)
                }
                tab.load(file, from: url)
                RecentFiles.shared.add(url)
                selectTab(id: tab.id)
            } catch {
                showError(error, message: "“\(url.lastPathComponent)” couldn’t be opened.")
            }
        }
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) {
        guard let tab = currentTab else { return }
        save(tab, completion: nil)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let tab = currentTab else { return }
        saveAs(tab, completion: nil)
    }

    @objc func saveAllDocuments(_ sender: Any?) {
        for tab in tabManager.tabs where tab.isDirty && tab.fileURL != nil {
            save(tab, completion: nil)
        }
    }

    func save(_ tab: EditorTab, completion: ((Bool) -> Void)?) {
        guard let url = tab.fileURL else {
            saveAs(tab, completion: completion)
            return
        }
        do {
            try tab.write(to: url)
            RecentFiles.shared.add(url)
            didSave(tab)
            completion?(true)
        } catch {
            showError(error, message: "“\(url.lastPathComponent)” couldn’t be saved.")
            completion?(false)
        }
    }

    func saveAs(_ tab: EditorTab, completion: ((Bool) -> Void)?) {
        guard let window else { completion?(false); return }
        selectTab(id: tab.id)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let url = tab.fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        } else {
            let base = tab.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = base + ".txt"
        }
        let options = SaveOptionsView(encoding: tab.encoding, lineEnding: tab.lineEnding)
        panel.accessoryView = options.view

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            var encoding = options.encoding
            if !encoding.canEncode(tab.nsText) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "This text can’t be saved as \(encoding.displayName)."
                alert.informativeText = "It contains characters that \(encoding.displayName) can’t represent. Save it as UTF-8 instead?"
                alert.addButton(withTitle: "Save as UTF-8")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    completion?(false)
                    return
                }
                encoding = .utf8
            }
            let previous = (tab.encoding, tab.lineEnding)
            tab.encoding = encoding
            tab.lineEnding = options.lineEnding
            do {
                try tab.write(to: url)
                RecentFiles.shared.add(url)
                self.didSave(tab)
                completion?(true)
            } catch {
                (tab.encoding, tab.lineEnding) = previous
                self.showError(error, message: "“\(url.lastPathComponent)” couldn’t be saved.")
                completion?(false)
            }
        }
    }

    private func didSave(_ tab: EditorTab) {
        if tab === currentTab {
            updateWindowTitle()
            updateStatus()
        }
        scheduleSessionSave()
    }

    private func showError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Printing

    @objc func printTab(_ sender: Any?) {
        guard let tab = currentTab, let window else { return }
        let operation = PrintRenderer.operation(text: tab.text, title: tab.title, font: prefs.baseFont)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Find & Replace

    @objc func showFind(_ sender: Any?) {
        showFindBar(replace: false)
    }

    @objc func showFindAndReplace(_ sender: Any?) {
        showFindBar(replace: true)
    }

    private func showFindBar(replace: Bool) {
        if let tab = currentTab {
            let sel = tab.textView.selectedRange()
            if sel.length > 0, sel.length < 200 {
                let s = tab.nsText.substring(with: sel)
                if !s.contains("\n") { findState.findText = s }
            }
        }
        findState.showReplace = replace
        findState.message = ""
        findBarHost.isHidden = false
        DispatchQueue.main.async { [weak self] in self?.findState.focusToken += 1 }
    }

    @objc func hideFindBar(_ sender: Any? = nil) {
        guard !findBarHost.isHidden else { return }
        findBarHost.isHidden = true
        findState.message = ""
        if let tab = currentTab { window?.makeFirstResponder(tab.textView) }
    }

    @objc func findNextMatch(_ sender: Any?) {
        find(forward: true)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        find(forward: false)
    }

    private func find(forward: Bool) {
        guard let tab = currentTab else { return }
        guard !findState.findText.isEmpty else {
            showFindBar(replace: false)
            return
        }
        let tv = tab.textView
        let sel = tv.selectedRange()
        let from = forward ? NSMaxRange(sel) : sel.location
        if let match = TextSearch.find(findState.findText, in: tab.nsText, from: from, forward: forward,
                                       matchCase: findState.matchCase, wholeWord: findState.wholeWord) {
            tv.setSelectedRange(match)
            tv.scrollRangeToVisible(match)
            tv.showFindIndicator(for: match)
            findState.message = ""
        } else {
            findState.message = "Can’t find “\(findState.findText)”"
            NSSound.beep()
        }
    }

    private func replaceCurrent() {
        guard let tab = currentTab, !findState.findText.isEmpty else { return }
        let tv = tab.textView
        let sel = tv.selectedRange()
        if sel.length > 0,
           let match = TextSearch.find(findState.findText, in: tab.nsText, from: sel.location, forward: true,
                                       matchCase: findState.matchCase, wholeWord: findState.wholeWord, wrap: false),
           match == sel {
            let replacement = TextFileCodec.normalizeLineEndings(findState.replaceText)
            tv.insertText(replacement, replacementRange: sel)
        }
        find(forward: true)
    }

    private func replaceAll() {
        guard let tab = currentTab,
              let regex = TextSearch.regex(for: findState.findText, matchCase: findState.matchCase,
                                           wholeWord: findState.wholeWord),
              let storage = tab.textView.textStorage else { return }
        let tv = tab.textView
        let full = NSRange(location: 0, length: storage.length)
        let result = NSMutableString(string: storage.mutableString)
        let replacement = NSRegularExpression.escapedTemplate(for: TextFileCodec.normalizeLineEndings(findState.replaceText))
        let count = regex.replaceMatches(in: result, options: [], range: full, withTemplate: replacement)
        guard count > 0 else {
            findState.message = "Can’t find “\(findState.findText)”"
            NSSound.beep()
            return
        }
        let origin = tab.scrollView.contentView.bounds.origin
        let caret = tv.selectedRange().location
        let newText = result as String
        if tv.shouldChangeText(in: full, replacementString: newText) {
            storage.replaceCharacters(in: full, with: newText)
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        tv.scroll(origin)
        findState.message = "Replaced \(format(count)) \(count == 1 ? "occurrence" : "occurrences")"
    }

    // MARK: - Edit commands

    @objc func goToLine(_ sender: Any?) {
        guard let tab = currentTab, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go To Line"
        alert.informativeText = "Line number (1 – \(format(tab.lineIndex.lineCount))):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let currentLine = tab.lineIndex.lineNumber(at: tab.textView.selectedRange().location) + 1
        field.stringValue = String(currentLine)
        alert.accessoryView = field
        alert.addButton(withTitle: "Go To")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            guard let n = Int(text), n >= 1, n <= tab.lineIndex.lineCount else {
                NSSound.beep()
                return
            }
            let loc = tab.lineIndex.lineStart(n - 1)
            let tv = tab.textView
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
            self.window?.makeFirstResponder(tv)
        }
    }

    @objc func insertTimeDate(_ sender: Any?) {
        guard let tab = currentTab else { return }
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let date = DateFormatter()
        date.setLocalizedDateFormatFromTemplate("yMd")
        let now = Date()
        let stamp = "\(time.string(from: now)) \(date.string(from: now))"
        let tv = tab.textView
        tv.insertText(stamp, replacementRange: tv.selectedRange())
    }

    // MARK: - View commands

    @objc func zoomInText(_ sender: Any?) {
        prefs.zoomPercent = min(500, prefs.zoomPercent + 10)
    }

    @objc func zoomOutText(_ sender: Any?) {
        prefs.zoomPercent = max(10, prefs.zoomPercent - 10)
    }

    @objc func resetZoomText(_ sender: Any?) {
        prefs.zoomPercent = 100
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        prefs.showLineNumbers.toggle()
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        prefs.wordWrap.toggle()
    }

    @objc func showEditorFontPanel(_ sender: Any?) {
        if let tab = currentTab { window?.makeFirstResponder(tab.textView) }
        NSFontManager.shared.setSelectedFont(prefs.baseFont, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    /// Fallback if the font panel's message reaches us instead of the text view.
    @objc func changeFont(_ sender: Any?) {
        let manager = (sender as? NSFontManager) ?? NSFontManager.shared
        prefs.setBaseFont(manager.convert(prefs.baseFont))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLineNumbers(_:)):
            item.state = prefs.showLineNumbers ? .on : .off
        case #selector(toggleWordWrap(_:)):
            item.state = prefs.wordWrap ? .on : .off
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)), #selector(moveTabToNewWindow(_:)):
            return tabManager.tabs.count > 1
        case #selector(saveAllDocuments(_:)):
            return tabManager.tabs.contains { $0.isDirty && $0.fileURL != nil }
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(printTab(_:)):
            return currentTab != nil
        default:
            break
        }
        return true
    }

    // MARK: - Session

    func scheduleSessionSave() {
        app.scheduleSessionSave()
    }

    func windowSnapshot() -> WindowSnapshot {
        WindowSnapshot(tabs: tabManager.tabs.map { $0.snapshot() },
                       selectedID: tabManager.selectedID,
                       windowFrame: window?.frameDescriptor)
    }

    var tabIDs: [UUID] { tabManager.tabs.map { $0.id } }

    func flushAutosaves() {
        for tab in tabManager.tabs { tab.flushAutosave() }
    }

    /// Rebuilds this window from a saved session. Returns false if none of its tabs could be restored.
    @discardableResult
    func restore(from snapshot: WindowSnapshot?) -> Bool {
        if let frame = snapshot?.windowFrame, let window {
            window.setFrame(from: frame)
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
            if !visible { window.center() }
        } else {
            window?.center()
        }

        for saved in snapshot?.tabs ?? [] {
            let tab = makeTab(id: saved.id)
            if tab.restore(from: saved) {
                tab.apply(preferences: prefs)
                tabManager.tabs.append(tab)
            } else {
                tab.discard()
            }
        }
        let restoredAny = !tabManager.tabs.isEmpty
        if !restoredAny {
            tabManager.tabs.append(makeTab())
        }
        let selected = snapshot?.selectedID.flatMap { id in tabManager.tabs.first { $0.id == id } } ?? tabManager.tabs[0]
        selectTab(id: selected.id)
        return restoredAny
    }

    // MARK: - External file changes

    func startMonitoring() {
        fileMonitorTimer?.invalidate()
        fileMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForExternalChanges() }
        }
    }

    func stopMonitoring() {
        fileMonitorTimer?.invalidate()
        fileMonitorTimer = nil
    }

    func checkForExternalChanges() {
        guard !isShowingFileChangeAlert, NSApp.isActive, let window, window.isKeyWindow,
              window.attachedSheet == nil else { return }
        for tab in tabManager.tabs {
            guard let url = tab.fileURL,
                  let known = tab.knownModificationDate,
                  let current = EditorTab.modificationDate(of: url) else { continue }
            if abs(current.timeIntervalSince(known)) > 0.001 {
                promptReload(tab: tab, newDate: current)
                return
            }
        }
    }

    private func promptReload(tab: EditorTab, newDate: Date) {
        guard let window else { return }
        isShowingFileChangeAlert = true
        selectTab(id: tab.id)
        let alert = NSAlert()
        alert.messageText = "“\(tab.title)” was changed by another application."
        alert.informativeText = tab.isDirty
            ? "Do you want to reload it from disk? Your unsaved changes in this tab will be lost."
            : "Do you want to reload it from disk?"
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Keep My Version")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingFileChangeAlert = false
            tab.knownModificationDate = newDate
            if response == .alertFirstButtonReturn {
                do {
                    try tab.reloadFromDisk()
                } catch {
                    self.showError(error, message: "“\(tab.title)” couldn’t be reloaded.")
                }
            } else {
                // The editor's version now differs from disk; keep it as unsaved changes.
                tab.noteUserEdit()
            }
            if tab === self.currentTab {
                self.updateStatus()
                self.updateWindowTitle()
            }
            self.scheduleSessionSave()
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Last window: like Windows 11 Notepad, quit without prompting; everything comes back next launch.
        if app.windowControllers.count <= 1 {
            NSApp.terminate(nil)
            return false
        }
        // Another window stays open, so this window's tabs really close: ask about unsaved ones.
        closeRemainingTabs()
        return false
    }

    private func closeRemainingTabs() {
        isClosingWindow = true
        guard let next = tabManager.tabs.first(where: { $0.needsSavePrompt }) else {
            for tab in tabManager.tabs { removeTab(tab, rememberClosed: true) }
            finishClosingWindow()
            return
        }
        requestCloseTab(id: next.id) { [weak self] closed in
            guard let self else { return }
            if closed {
                self.closeRemainingTabs()
            } else {
                // Cancelled: keep the window. Make sure it isn't left without tabs.
                self.isClosingWindow = false
                if self.tabManager.tabs.isEmpty { self.newTab(nil) }
            }
        }
    }

    private func finishClosingWindow() {
        stopMonitoring()
        app.windowControllerDidClose(self)
        window?.orderOut(nil)
        window?.close()
    }

    func windowWillMove(_ notification: Notification) {
        app.windowDragDidBegin(self)
    }

    /// Title bar plus tab bar, in screen coordinates: dropping another window here merges it in.
    func tabStripContains(screenPoint: NSPoint) -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        let frame = window.frame
        let titleBarHeight = frame.height - window.contentLayoutRect.height
        let strip = NSRect(x: frame.minX, y: frame.maxY - titleBarHeight - 36, width: frame.width, height: titleBarHeight + 36)
        return strip.contains(screenPoint)
    }

    func windowDidResize(_ notification: Notification) { scheduleSessionSave() }
    func windowDidMove(_ notification: Notification) { scheduleSessionSave() }
    func windowDidBecomeKey(_ notification: Notification) {
        app.windowControllerDidBecomeKey(self)
        checkForExternalChanges()
    }
}

/// Encoding and line-ending pop-ups shown at the bottom of the Save As panel.
@MainActor
private final class SaveOptionsView {
    let view: NSView
    private let encodingPopUp = NSPopUpButton()
    private let lineEndingPopUp = NSPopUpButton()

    init(encoding: TextEncodingKind, lineEnding: LineEnding) {
        for kind in TextEncodingKind.allCases { encodingPopUp.addItem(withTitle: kind.displayName) }
        encodingPopUp.selectItem(at: TextEncodingKind.allCases.firstIndex(of: encoding) ?? 0)
        for ending in LineEnding.allCases { lineEndingPopUp.addItem(withTitle: ending.displayName) }
        lineEndingPopUp.selectItem(at: LineEnding.allCases.firstIndex(of: lineEnding) ?? 0)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Encoding:"), encodingPopUp],
            [NSTextField(labelWithString: "Line Endings:"), lineEndingPopUp],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        view = container
    }

    var encoding: TextEncodingKind { TextEncodingKind.allCases[max(0, encodingPopUp.indexOfSelectedItem)] }
    var lineEnding: LineEnding { LineEnding.allCases[max(0, lineEndingPopUp.indexOfSelectedItem)] }
}
