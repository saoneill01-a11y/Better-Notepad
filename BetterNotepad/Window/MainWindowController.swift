import AppKit
import SwiftUI
import Combine

/// The single main window: tab bar, find bar, editor and status bar, plus all document actions.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let tabManager = TabManager()
    let status = StatusModel()
    let findState = FindState()

    private let prefs = Preferences.shared
    private let editorContainer = NSView()
    private var findBarHost: NSHostingView<FindBarView>!
    private var cancellables = Set<AnyCancellable>()
    private var sessionSaveWork: DispatchWorkItem?
    private var fileMonitorTimer: Timer?
    private var isShowingFileChangeAlert = false
    private var isRestoring = false
    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private var currentTab: EditorTab? { tabManager.selectedTab }

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

        let separator = NSBox()
        separator.boxType = .separator

        let views: [NSView] = [tabBar, separator, findHost, editorContainer, statusHost]
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
    }

    private func preferencesChanged() {
        for tab in tabManager.tabs { tab.apply(preferences: prefs) }
        updateStatus()
    }

    // MARK: - Tabs

    private func makeTab(id: UUID = UUID()) -> EditorTab {
        let tab = EditorTab(id: id)
        tab.onTextChange = { [weak self] tab in self?.tabDidChangeText(tab) }
        tab.onSelectionChange = { [weak self] tab in self?.tabDidChangeSelection(tab) }
        tab.onViewStateChange = { [weak self] tab in
            self?.scheduleSessionSave()
            if tab === self?.currentTab { self?.updateWindowTitle() }
        }
        tab.onEscape = { [weak self] in self?.hideFindBar() }
        tab.apply(preferences: prefs)
        return tab
    }

    func selectTab(id: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return }
        if tab.scrollView.superview !== editorContainer {
            editorContainer.subviews.forEach { $0.removeFromSuperview() }
            let sv = tab.scrollView
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

    @objc func closeTab(_ sender: Any?) {
        if let tab = currentTab { requestCloseTab(id: tab.id) }
    }

    func requestCloseTab(id: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }), let window else { return }
        guard tab.needsSavePrompt else {
            closeTabNow(tab)
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
                    self.save(tab) { ok in if ok { self.closeTabNow(tab) } }
                }
            case .alertSecondButtonReturn:
                self.closeTabNow(tab)
            default:
                break
            }
        }
    }

    private func closeTabNow(_ tab: EditorTab) {
        guard let index = tabManager.tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = tab.id == tabManager.selectedID
        tab.discard()
        tab.scrollView.removeFromSuperview()
        tabManager.tabs.remove(at: index)
        if tabManager.tabs.isEmpty {
            newTab(nil)
        } else if wasSelected {
            selectTab(id: tabManager.tabs[min(index, tabManager.tabs.count - 1)].id)
        }
        scheduleSessionSave()
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
        status.lineEnding = tab.lineEnding.displayName
        status.encoding = tab.encoding.displayName
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
            if let existing = tabManager.tabs.first(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == url }) {
                selectTab(id: existing.id)
                continue
            }
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
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            do {
                try tab.write(to: url)
                RecentFiles.shared.add(url)
                self.didSave(tab)
                completion?(true)
            } catch {
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
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return tabManager.tabs.count > 1
        case #selector(saveAllDocuments(_:)):
            return tabManager.tabs.contains { $0.isDirty && $0.fileURL != nil }
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return currentTab != nil
        default:
            break
        }
        return true
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
        let snapshot = SessionSnapshot(tabs: tabManager.tabs.map { $0.snapshot() },
                                       selectedID: tabManager.selectedID,
                                       windowFrame: window?.frameDescriptor)
        SessionStore.shared.save(snapshot)
    }

    /// Flush every pending autosave and write the session. Called on quit and when the app deactivates.
    func persistEverything() {
        for tab in tabManager.tabs { tab.flushAutosave() }
        saveSessionNow()
        SessionStore.shared.flush()
    }

    func restoreSession() {
        isRestoring = true
        defer { isRestoring = false }

        let session = SessionStore.shared.load()
        if let frame = session?.windowFrame, let window {
            window.setFrame(from: frame)
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
            if !visible { window.center() }
        } else {
            window?.center()
        }

        for snapshot in session?.tabs ?? [] {
            let tab = makeTab(id: snapshot.id)
            if tab.restore(from: snapshot) {
                tab.apply(preferences: prefs)
                tabManager.tabs.append(tab)
            } else {
                tab.discard()
            }
        }
        if tabManager.tabs.isEmpty {
            let tab = makeTab()
            tabManager.tabs.append(tab)
        }
        let selected = session?.selectedID.flatMap { id in tabManager.tabs.first { $0.id == id } } ?? tabManager.tabs[0]
        selectTab(id: selected.id)
        SessionStore.shared.removeOrphanedBackups(keeping: Set(tabManager.tabs.map { $0.id }))
    }

    // MARK: - External file changes

    func startMonitoring() {
        fileMonitorTimer?.invalidate()
        fileMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForExternalChanges() }
        }
    }

    func checkForExternalChanges() {
        guard !isShowingFileChangeAlert, NSApp.isActive, let window, window.attachedSheet == nil else { return }
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

    #if DEBUG
    /// Debug-only: types sample text, logs the editor geometry and renders the window to a PNG.
    func runDiagnostics(pngPath: String) {
        guard let tab = currentTab, let window, let content = window.contentView else { return }
        let tv = tab.textView
        tv.insertText("Hello diagnostics\nSecond line", replacementRange: tv.selectedRange())
        content.layoutSubtreeIfNeeded()
        func d(_ name: String, _ v: NSView) {
            print("DIAG \(name): frame=\(v.frame) hidden=\(v.isHidden) superview=\(v.superview.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        d("content", content)
        d("editorContainer", editorContainer)
        d("scrollView", tab.scrollView)
        d("clipView", tab.scrollView.contentView)
        d("textView", tv)
        print("DIAG firstResponder=\(String(describing: window.firstResponder))")
        print("DIAG container=\(String(describing: tv.textContainer?.size)) tracks=\(String(describing: tv.textContainer?.widthTracksTextView)) inset=\(tv.textContainerInset)")
        print("DIAG storageLength=\(tab.length) rulersVisible=\(tab.scrollView.rulersVisible) ruler=\(tab.ruler.frame)")
        print("DIAG textColor=\(String(describing: tv.textColor)) font=\(String(describing: tv.font)) typing=\(tv.typingAttributes)")
        if let tlm = tv.textLayoutManager {
            print("DIAG viewport=\(String(describing: tlm.textViewportLayoutController.viewportRange)) usage=\(tlm.usageBoundsForTextContainer)")
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
                print("DIAG fragment frame=\(f.layoutFragmentFrame) lines=\(f.textLineFragments.count)")
                return true
            }
        }
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: pngPath))
        }
        fflush(stdout)
    }
    #endif

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Like Windows 11 Notepad: closing the window never prompts; everything is restored next launch.
        NSApp.terminate(nil)
        return false
    }

    func windowDidResize(_ notification: Notification) { scheduleSessionSave() }
    func windowDidMove(_ notification: Notification) { scheduleSessionSave() }
    func windowDidBecomeKey(_ notification: Notification) { checkForExternalChanges() }
}
