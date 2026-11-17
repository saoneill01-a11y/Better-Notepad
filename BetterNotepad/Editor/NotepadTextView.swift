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
