import AppKit

/// Plain-text NSTextView (TextKit 2) with Notepad behaviours:
/// clicking/dragging in the left margin selects whole lines, a Notepad-style context menu,
/// per-tab undo, and font changes routed to the app-wide editor font preference.
final class NotepadTextView: NSTextView {

    /// Called when Escape is pressed (used to close the find bar).
    var onEscape: (() -> Void)?

    /// Width of the clickable margin to the left of the text inside the view.
    var leftMarginHitWidth: CGFloat {
        textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
    }

    // MARK: - Pinch to zoom

    private var pinchAccumulator: CGFloat = 0

    /// Trackpad pinch changes the editor zoom in the same 10% steps as ⌘= / ⌘-.
    override func magnify(with event: NSEvent) {
        if event.phase == .began { pinchAccumulator = 0 }
        pinchAccumulator += event.magnification
        let step: CGFloat = 0.08
        let prefs = Preferences.shared
        while pinchAccumulator >= step {
            prefs.zoomPercent = min(500, prefs.zoomPercent + 10)
            pinchAccumulator -= step
        }
        while pinchAccumulator <= -step {
            prefs.zoomPercent = max(10, prefs.zoomPercent - 10)
            pinchAccumulator += step
        }
        if event.phase == .ended || event.phase == .cancelled { pinchAccumulator = 0 }
    }

    /// Two-finger double-tap resets zoom to 100%.
    override func smartMagnify(with event: NSEvent) {
        Preferences.shared.zoomPercent = 100
    }

    // MARK: - Margin pointer

    /// Right-pointing arrow (like Notepad) shown over the line-select margin.
    static let lineSelectCursor: NSCursor = {
        let arrow = NSCursor.arrow
        let source = arrow.image
        let size = source.size
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: size.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            source.draw(in: rect)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width - arrow.hotSpot.x, y: arrow.hotSpot.y))
    }()

    private var marginTrackingArea: NSTrackingArea?

    private func isInMargin(_ event: NSEvent) -> Bool {
        convert(event.locationInWindow, from: nil).x < leftMarginHitWidth
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = marginTrackingArea { removeTrackingArea(area) }
        let rect = NSRect(x: 0, y: 0, width: leftMarginHitWidth, height: bounds.height)
        let area = NSTrackingArea(rect: rect, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        marginTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if isInMargin(event) {
            Self.lineSelectCursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isInMargin(event) {
            Self.lineSelectCursor.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === marginTrackingArea, !isInMargin(event) {
            NSCursor.iBeam.set()
        }
    }

    // MARK: - Line selection

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags
        if p.x < leftMarginHitWidth, !mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
            trackLineSelection(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    /// Character offset of the first character of the visual paragraph at a y position (view coordinates).
    func characterOffset(atY y: CGFloat) -> Int {
        let length = textStorage?.length ?? 0
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return 0 }
        let containerY = y - textContainerOrigin.y
        if containerY < 0 { return 0 }
        if let fragment = tlm.textLayoutFragment(for: CGPoint(x: 1, y: containerY)) {
            return tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        }
        return length
    }

    /// Whole line (including its newline) at a y position in view coordinates.
    func lineRange(atY y: CGFloat) -> NSRange {
        guard let ns = textStorage?.mutableString, ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let offset = min(characterOffset(atY: y), ns.length)
        return ns.lineRange(for: NSRange(location: offset, length: 0))
    }

    /// Selects whole lines while the mouse is dragged (used by the margin and the line-number gutter).
    func trackLineSelection(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        let startY = convert(event.locationInWindow, from: nil).y
        var anchor = lineRange(atY: startY)
        if event.modifierFlags.contains(.shift) {
            anchor = NSUnionRange(selectedRange(), anchor)
        }
        setSelectedRange(anchor, affinity: .downstream, stillSelecting: false)

        while true {
            guard let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if ev.type == .leftMouseUp { break }
            autoscroll(with: ev)
            let y = convert(ev.locationInWindow, from: nil).y
            let range = NSUnionRange(anchor, lineRange(atY: y))
            setSelectedRange(range, affinity: .downstream, stillSelecting: false)
        }
    }

    // MARK: - Undo (per-tab undo manager comes from the delegate)

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            item.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo ?? false
        }
        if item.action == #selector(redo(_:)) {
            item.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo ?? false
        }
        return super.validateMenuItem(item)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if isContinuousSpellCheckingEnabled {
            addSpellingSuggestions(to: menu, for: event)
        }
        add("Undo", #selector(undo(_:)))
        menu.addItem(.separator())
        add("Cut", #selector(cut(_:)))
        add("Copy", #selector(copy(_:)))
        add("Paste", #selector(paste(_:)))
        add("Delete", #selector(delete(_:)))
        menu.addItem(.separator())
        add("Select All", #selector(selectAll(_:)))
        return menu
    }

    // MARK: - Spelling suggestions

    private struct Misspelling {
        let range: NSRange
        let word: String
    }

    private func misspelling(at event: NSEvent) -> Misspelling? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index < storage.length else { return nil }
        let wordRange = selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
        guard wordRange.length > 0, wordRange.length < 100 else { return nil }
        let word = storage.mutableString.substring(with: wordRange)
        let checker = NSSpellChecker.shared
        let bad = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                        inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil)
        guard bad.location != NSNotFound else { return nil }
        return Misspelling(range: wordRange, word: word)
    }

    private func addSpellingSuggestions(to menu: NSMenu, for event: NSEvent) {
        guard let miss = misspelling(at: event) else { return }
        let checker = NSSpellChecker.shared
        let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: (miss.word as NSString).length),
                                      in: miss.word, language: nil,
                                      inSpellDocumentWithTag: spellCheckerDocumentTag) ?? []
        if guesses.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for guess in guesses.prefix(6) {
            let item = NSMenuItem(title: guess, action: #selector(applySpellingGuess(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [NSValue(range: miss.range), guess] as [Any]
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let learn = NSMenuItem(title: "Learn Spelling", action: #selector(learnWord(_:)), keyEquivalent: "")
        learn.target = self
        learn.representedObject = miss.word
        menu.addItem(learn)
        let ignore = NSMenuItem(title: "Ignore Spelling", action: #selector(ignoreWord(_:)), keyEquivalent: "")
        ignore.target = self
        ignore.representedObject = miss.word
        menu.addItem(ignore)
        menu.addItem(.separator())
    }

    @objc private func applySpellingGuess(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any],
              let range = (info.first as? NSValue)?.rangeValue,
              let guess = info.last as? String,
              NSMaxRange(range) <= (textStorage?.length ?? 0) else { return }
        insertText(guess, replacementRange: range)
    }

    @objc private func learnWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.learnWord(word)
        recheckSpelling()
    }

    @objc private func ignoreWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: spellCheckerDocumentTag)
        recheckSpelling()
    }

    private func recheckSpelling() {
        // Toggling forces the visible text to be checked again.
        isContinuousSpellCheckingEnabled = false
        isContinuousSpellCheckingEnabled = true
    }

    // MARK: - Font

    override func changeFont(_ sender: Any?) {
        let manager = (sender as? NSFontManager) ?? NSFontManager.shared
        let newFont = manager.convert(Preferences.shared.baseFont)
        Preferences.shared.setBaseFont(newFont)
    }

    // MARK: - Escape

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
