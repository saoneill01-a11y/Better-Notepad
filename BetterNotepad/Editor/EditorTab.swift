import AppKit
import Combine

/// What is kept about a closed tab so ⇧⌘T can bring it back.
struct ClosedTabRecord {
    var fileURL: URL?
    /// nil when the tab matched the file on disk (it is re-read from there).
    var text: String?
    var encoding: TextEncodingKind
    var lineEnding: LineEnding
    var selection: NSRange
    var topOffset: Int
    var knownModificationDate: Date?
}

private struct PendingViewState {
    var selections: [NSRange]
    var topOffset: Int
    var scrollX: CGFloat
}

/// One open document: its text view, undo history, file metadata and autosave state.
@MainActor
final class EditorTab: NSObject, ObservableObject, Identifiable, NSTextViewDelegate {
    let id: UUID

    @Published private(set) var fileURL: URL?
    @Published private(set) var title: String = "Untitled"
    @Published private(set) var isDirty = false

    var encoding: TextEncodingKind = .utf8
    var lineEnding: LineEnding = .lf
    var knownModificationDate: Date?
    private(set) var hasBackup = false

    let textView: NotepadTextView
    let scrollView: NSScrollView
    let lineIndex = LineIndex()
    private(set) var ruler: LineNumberRulerView!
    let tabUndoManager = UndoManager()

    var onTextChange: ((EditorTab) -> Void)?
    var onSelectionChange: ((EditorTab) -> Void)?
    var onViewStateChange: ((EditorTab) -> Void)?

    private var pendingViewState: PendingViewState?
    private var autosaveWork: DispatchWorkItem?
    private var editGeneration = 0
    private var persistedGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var appliedFont: NSFont?
    private var appliedWrap: Bool?

    init(id: UUID = UUID()) {
        self.id = id
        textView = NotepadTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        configureViews()
    }

    // MARK: - Setup

    private func configureViews() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isIncrementalSearchingEnabled = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.usesInspectorBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.displaysLinkToolTips = false
        tv.allowsDocumentBackgroundColorChange = false
        tv.drawsBackground = true
        tv.backgroundColor = Theme.editorBackground
        tv.textColor = .textColor
        tv.insertionPointColor = .textColor
        tv.textContainerInset = NSSize(width: 20, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        tv.textContainer?.widthTracksTextView = true
        tv.onEscape = { [weak self] in self?.onEscape?() }

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.documentView = tv

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: tv, lineIndex: lineIndex)
        self.ruler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false

        let nc = NotificationCenter.default
        if let storage = tv.textStorage {
            observers.append(nc.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                            object: storage, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.textStorageDidProcessEditing() }
            })
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification,
                                        object: scrollView.contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDidChange() }
        })
        tv.postsFrameChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification,
                                        object: tv, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.ruler.needsDisplay = true }
        })
    }

    var onEscape: (() -> Void)?

    // MARK: - Text access

    /// Live, non-copying view of the text. Do not hold on to it across edits.
    var nsText: NSString { textView.textStorage?.mutableString ?? NSMutableString() }
    var length: Int { textView.textStorage?.length ?? 0 }
    /// A snapshot copy of the text.
    var text: String { textView.string }

    var isPristine: Bool { fileURL == nil && length == 0 && !isDirty && !hasBackup }
    var needsSavePrompt: Bool { isDirty && !(fileURL == nil && length == 0) }
    var hasPendingViewState: Bool { pendingViewState != nil }

    // MARK: - Preferences

    func apply(preferences p: Preferences) {
        let font = p.editorFont
        if appliedFont?.isEqual(font) != true {
            appliedFont = font
            let paragraph = NSMutableParagraphStyle()
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            paragraph.tabStops = []
            paragraph.defaultTabInterval = spaceWidth * 4
            textView.defaultParagraphStyle = paragraph
            textView.font = font
            textView.typingAttributes = typingAttributes(font: font, paragraph: paragraph)
            if let storage = textView.textStorage, storage.length > 0 {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
            }
            ruler.font = NSFont.monospacedDigitSystemFont(ofSize: max(8, (font.pointSize * 0.9).rounded()), weight: .regular)
        }
        if appliedWrap != p.wordWrap {
            appliedWrap = p.wordWrap
            applyWordWrap(p.wordWrap)
        }
        if scrollView.rulersVisible != p.showLineNumbers {
            scrollView.rulersVisible = p.showLineNumbers
        }
        if textView.isContinuousSpellCheckingEnabled != p.spellCheck {
            textView.isContinuousSpellCheckingEnabled = p.spellCheck
        }
    }

    private func typingAttributes(font: NSFont, paragraph: NSParagraphStyle?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        if let paragraph { attrs[.paragraphStyle] = paragraph }
        return attrs
    }

    private func applyWordWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        let contentSize = scrollView.contentSize
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.setFrameSize(NSSize(width: contentSize.width, height: textView.frame.height))
            container.widthTracksTextView = true
            container.size = NSSize(width: max(0, contentSize.width - 2 * textView.textContainerInset.width),
                                    height: CGFloat.greatestFiniteMagnitude)
            textView.scroll(NSPoint(x: 0, y: scrollView.contentView.bounds.minY))
        } else {
            scrollView.hasHorizontalScroller = true
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width]
        }
        ruler.needsDisplay = true
    }

    // MARK: - NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        tabUndoManager
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        // Keep the buffer "\n"-only: convert pasted/dropped CRLF or CR text.
        guard let s = replacementString, s.utf16.contains(13) else { return true }
        textView.insertText(TextFileCodec.normalizeLineEndings(s), replacementRange: range)
        return false
    }

    func textDidChange(_ notification: Notification) {
        noteUserEdit()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        ruler.needsDisplay = true
        onSelectionChange?(self)
    }

    private func textStorageDidProcessEditing() {
        guard let storage = textView.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        lineIndex.applyEdit(editedRange: storage.editedRange, changeInLength: storage.changeInLength,
                            text: storage.mutableString)
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    private func scrollDidChange() {
        ruler.needsDisplay = true
        if pendingViewState == nil { onViewStateChange?(self) }
    }

    /// Marks the tab modified and schedules an autosave (also used for programmatic edits).
    func noteUserEdit() {
        editGeneration += 1
        if !isDirty { isDirty = true }
        if fileURL == nil { refreshTitle() }
        scheduleAutosave()
        onTextChange?(self)
    }

    // MARK: - Encoding and line endings

    /// Changes how the tab will be written on the next save (marks it modified, like Notepad).
    func changeEncoding(_ newEncoding: TextEncodingKind) {
        guard newEncoding != encoding else { return }
        encoding = newEncoding
        noteUserEdit()
    }

    func changeLineEnding(_ newEnding: LineEnding) {
        guard newEnding != lineEnding else { return }
        lineEnding = newEnding
        noteUserEdit()
    }

    // MARK: - Reopen closed tab

    /// State to remember when this tab is closed, or nil if there is nothing worth reopening.
    func closedRecord() -> ClosedTabRecord? {
        if isPristine || (fileURL == nil && length == 0) { return nil }
        let keepText = isDirty || fileURL == nil
        return ClosedTabRecord(fileURL: fileURL,
                               text: keepText ? text : nil,
                               encoding: encoding,
                               lineEnding: lineEnding,
                               selection: textView.selectedRange(),
                               topOffset: pendingViewState?.topOffset ?? topVisibleOffset(),
                               knownModificationDate: knownModificationDate)
    }

    /// Fills a new tab from a closed-tab record. Unsaved text comes back as unsaved changes.
    func restoreClosed(_ record: ClosedTabRecord) throws {
        if let saved = record.text {
            encoding = record.encoding
            lineEnding = record.lineEnding
            fileURL = record.fileURL
            knownModificationDate = record.knownModificationDate
            replaceAllText(saved)
            noteUserEdit()
        } else if let url = record.fileURL {
            load(try EditorTab.readFile(at: url), from: url)
        }
        pendingViewState = PendingViewState(selections: [record.selection], topOffset: record.topOffset, scrollX: 0)
        refreshTitle()
    }

    // MARK: - Title

    func refreshTitle() {
        let newTitle: String
        if let url = fileURL {
            newTitle = url.lastPathComponent
        } else {
            // Like Windows 11 Notepad, untitled tabs are named after their first line.
            let ns = nsText
            let lineEnd = lineIndex.lineCount > 1 ? lineIndex.lineStart(1) - 1 : ns.length
            let take = min(lineEnd, 60)
            var first = ""
            if take > 0 {
                let r = ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: take))
                first = ns.substring(with: NSRange(location: 0, length: min(r.length, lineEnd)))
                    .trimmingCharacters(in: .whitespaces)
            }
            newTitle = first.isEmpty ? "Untitled" : first
        }
        if newTitle != title { title = newTitle }
    }

    // MARK: - Loading and saving

    struct LoadedFile {
        let decoded: DecodedText
        let modificationDate: Date?
    }

    static func readFile(at url: URL) throws -> LoadedFile {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return LoadedFile(decoded: TextFileCodec.decode(data), modificationDate: modificationDate(of: url))
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func replaceAllText(_ s: String) {
        let font = appliedFont ?? Preferences.shared.editorFont
        let attrs = typingAttributes(font: font, paragraph: textView.defaultParagraphStyle)
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: attrs))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        tabUndoManager.removeAllActions()
        ruler.needsDisplay = true
    }

    func load(_ file: LoadedFile, from url: URL) {
        encoding = file.decoded.encoding
        lineEnding = file.decoded.lineEnding
        fileURL = url
        knownModificationDate = file.modificationDate
        replaceAllText(file.decoded.text)
        isDirty = false
        autosaveWork?.cancel()
        autosaveWork = nil
        editGeneration += 1
        persistedGeneration = editGeneration
        if hasBackup {
            SessionStore.shared.removeBackup(id: id)
            hasBackup = false
        }
        refreshTitle()
    }

    func reloadFromDisk() throws {
        guard let url = fileURL else { return }
        let file = try EditorTab.readFile(at: url)
        let selection = textView.selectedRange()
        let scroll = scrollView.contentView.bounds.origin
        load(file, from: url)
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        textView.scroll(scroll)
        onViewStateChange?(self)
    }

    /// Writes the text to `url` using the tab's original encoding and line endings.
    func write(to url: URL) throws {
        let current = text
        var data = TextFileCodec.encode(current, encoding: encoding, lineEnding: lineEnding)
        if data == nil {
            // Characters not representable in the legacy encoding: fall back to UTF-8.
            encoding = .utf8
            data = TextFileCodec.encode(current, encoding: .utf8, lineEnding: lineEnding)
        }
        guard let data else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try data.write(to: url, options: .atomic)

        fileURL = url
        knownModificationDate = EditorTab.modificationDate(of: url)
        isDirty = false
        persistedGeneration = editGeneration
        autosaveWork?.cancel()
        autosaveWork = nil
        if hasBackup {
            SessionStore.shared.removeBackup(id: id)
            hasBackup = false
        }
        refreshTitle()
        onViewStateChange?(self)
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.performAutosave() }
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Runs any pending autosave immediately (used on quit / deactivate).
    func flushAutosave() {
        guard autosaveWork != nil || editGeneration != persistedGeneration else { return }
        autosaveWork?.cancel()
        performAutosave()
    }

    private func performAutosave() {
        autosaveWork = nil
        guard editGeneration != persistedGeneration else { return }

        if isDirty, let url = fileURL, Preferences.shared.autosaveToFile {
            do {
                try write(to: url)
                return
            } catch {
                NSLog("Better Notepad: autosave to file failed, keeping changes in the autosave store: \(error)")
            }
        }

        if isDirty {
            SessionStore.shared.writeBackup(id: id, text: text)
            hasBackup = true
        } else if hasBackup {
            SessionStore.shared.removeBackup(id: id)
            hasBackup = false
        }
        persistedGeneration = editGeneration
        onViewStateChange?(self)
    }

    /// Called when the tab is closed for good.
    func discard() {
        autosaveWork?.cancel()
        autosaveWork = nil
        SessionStore.shared.removeBackup(id: id)
        hasBackup = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: - Session state

    func snapshot() -> TabSnapshot {
        let selections: [NSRange]
        let top: Int
        let scrollX: CGFloat
        if let pending = pendingViewState {
            selections = pending.selections
            top = pending.topOffset
            scrollX = pending.scrollX
        } else {
            selections = textView.selectedRanges.map { $0.rangeValue }
            top = topVisibleOffset()
            scrollX = scrollView.contentView.bounds.minX
        }
        return TabSnapshot(id: id,
                           filePath: fileURL?.path,
                           isDirty: isDirty,
                           hasBackup: hasBackup,
                           encoding: encoding,
                           lineEnding: lineEnding,
                           selections: selections.map { [$0.location, $0.length] },
                           topOffset: top,
                           scrollX: Double(scrollX),
                           knownModificationDate: knownModificationDate)
    }

    /// Restores content from the autosave store or from disk. Returns false if nothing could be restored.
    func restore(from s: TabSnapshot) -> Bool {
        let url = s.filePath.map { URL(fileURLWithPath: $0) }
        if s.hasBackup, let backup = SessionStore.shared.readBackup(id: id) {
            encoding = s.encoding
            lineEnding = s.lineEnding
            fileURL = url
            replaceAllText(backup)
            hasBackup = true
            isDirty = s.isDirty || url == nil
            knownModificationDate = s.knownModificationDate ?? url.flatMap { EditorTab.modificationDate(of: $0) }
        } else if let url {
            guard let file = try? EditorTab.readFile(at: url) else { return false }
            load(file, from: url)
        } else {
            encoding = s.encoding
            lineEnding = s.lineEnding
        }
        editGeneration = 0
        persistedGeneration = 0
        pendingViewState = PendingViewState(
            selections: s.selections.compactMap { $0.count == 2 ? NSRange(location: $0[0], length: $0[1]) : nil },
            topOffset: s.topOffset,
            scrollX: CGFloat(s.scrollX))
        refreshTitle()
        return true
    }

    /// Applies restored selection and scroll position once the text view is on screen.
    func applyPendingViewStateIfNeeded() {
        guard let state = pendingViewState, textView.window != nil else { return }
        pendingViewState = nil
        let len = length
        let ranges: [NSValue] = state.selections.map { r in
            let loc = min(max(0, r.location), len)
            return NSValue(range: NSRange(location: loc, length: min(max(0, r.length), len - loc)))
        }
        textView.setSelectedRanges(ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges,
                                   affinity: .downstream, stillSelecting: false)
        scrollToOffset(state.topOffset, x: state.scrollX)
        // TextKit 2 refines estimated positions after the first layout pass; correct once more.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.scrollToOffset(state.topOffset, x: state.scrollX) }
        }
    }

    private func topVisibleOffset() -> Int {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return 0 }
        let y = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
        guard y > 0, let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 0 }
        return tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
    }

    private func scrollToOffset(_ offset: Int, x: CGFloat) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let target = min(max(0, offset), length)
        var y: CGFloat = 0
        if target > 0, let location = tcm.location(tcm.documentRange.location, offsetBy: target) {
            tlm.ensureLayout(for: NSTextRange(location: location))
            if let fragment = tlm.textLayoutFragment(for: location) {
                y = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            }
        }
        textView.scroll(NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        ruler.needsDisplay = true
    }
}
