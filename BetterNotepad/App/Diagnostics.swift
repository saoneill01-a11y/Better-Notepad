#if DEBUG
import AppKit
import WebKit

/// Debug-build-only self tests, driven by environment variables. Not compiled into Release.
///   BN_DIAG=render  BN_DIAG_OUT=/path.png   – two tabs with text, renders the window to a PNG
///   BN_DIAG=large   BN_DIAG_FILE=/path.txt  – opens a big file and times typing, scrolling, saving
///   BN_DIAG=windows                         – exercises new window / move tab / close / reopen
/// Use BN_STORE_DIR to keep test sessions away from the real autosave folder.
extension AppDelegate {
    func runDebugDiagnosticsIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["BN_DIAG"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                switch mode {
                case "render": self.diagRender(out: env["BN_DIAG_OUT"] ?? "/tmp/bn.png")
                case "large": self.diagLarge(path: env["BN_DIAG_FILE"] ?? "")
                case "windows": self.diagWindows()
                case "tabs": self.diagTabs(dir: env["BN_DIAG_OUT"] ?? "/tmp")
                case "merge": self.diagMerge()
                case "markdown": self.diagMarkdown(dir: env["BN_DIAG_OUT"] ?? "/tmp")
                case "showcase": self.diagShowcase(out: env["BN_DIAG_OUT"] ?? "/tmp/bn.png", file: env["BN_DIAG_FILE"])
                case "tabmove": self.diagTabMove()
                case "print": self.diagPrint(out: env["BN_DIAG_OUT"] ?? "/tmp/bn.pdf")
                default: print("DIAG unknown mode \(mode)")
                }
                fflush(stdout)
                // "markdown" quits by itself once its asynchronous preview check is done.
                if env["BN_DIAG_KEEP_OPEN"] == nil, mode != "markdown" { NSApp.terminate(nil) }
            }
        }
    }

    private func pump(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func diagRender(out: String) {
        guard let controller = activeController, let window = controller.window else { return }
        controller.currentTab?.textView.insertText("Notes for Monday\nBuy milk\nCall the office about the printer",
                                                    replacementRange: NSRange(location: 0, length: 0))
        controller.newTab(nil)
        controller.currentTab?.textView.insertText("Second tab text", replacementRange: NSRange(location: 0, length: 0))
        controller.showWindow(nil)
        pump(0.5)
        controller.tabManager.select(controller.tabManager.tabs[0].id)
        pump(0.5)
        guard let frameView = window.contentView?.superview else { return }
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("DIAG wrote \(out) appearance=\(NSApp.effectiveAppearance.name.rawValue)")
        }
    }

    private func diagLarge(path: String) {
        guard let controller = activeController, let window = controller.window else { return }
        func time(_ label: String, _ block: () -> Void) {
            let start = CFAbsoluteTimeGetCurrent()
            block()
            print(String(format: "PERF %-28@ %8.1f ms", label as NSString, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        time("open file") { controller.open(urls: [URL(fileURLWithPath: path)]) }
        time("first display") { draw() }
        guard let tab = controller.currentTab else { return }
        let tv = tab.textView
        print("PERF size: \(tab.length) UTF-16 units, \(tab.lineIndex.lineCount) lines")

        let mid = tab.lineIndex.lineStart(tab.lineIndex.lineCount / 2)
        time("jump to middle + display") {
            tv.setSelectedRange(NSRange(location: mid, length: 0))
            tv.scrollRangeToVisible(NSRange(location: mid, length: 0))
            draw()
        }
        var keyTimes: [Double] = []
        for ch in "The quick brown fox jumps" {
            let start = CFAbsoluteTimeGetCurrent()
            tv.insertText(String(ch), replacementRange: tv.selectedRange())
            draw()
            keyTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        print(String(format: "PERF typing in middle: avg %.2f ms, max %.2f ms per key (%d keys)",
                     keyTimes.reduce(0, +) / Double(keyTimes.count), keyTimes.max() ?? 0, keyTimes.count))
        time("return key") { tv.insertText("\n", replacementRange: tv.selectedRange()); draw() }
        time("backspace") { tv.deleteBackward(nil); draw() }
        time("scroll 40 pages down") {
            for _ in 0..<40 { tv.scrollPageDown(nil); draw() }
        }
        time("jump to end + display") {
            tv.setSelectedRange(NSRange(location: tab.length, length: 0))
            tv.scrollRangeToVisible(NSRange(location: tab.length, length: 0))
            draw()
        }
        time("type at end (10 keys)") {
            for _ in 0..<10 { tv.insertText("x", replacementRange: tv.selectedRange()); draw() }
        }
        time("select all + status") { tv.selectAll(nil); controller.updateStatus(); draw() }
        time("click to deselect") { tv.setSelectedRange(NSRange(location: 0, length: 0)); draw() }
        time("find (no match)") {
            _ = TextSearch.find("zzqqxxnotthere", in: tab.nsText, from: 0, forward: true, matchCase: false, wholeWord: false)
        }
        time("autosave (text copy+queue)") { tab.flushAutosave() }
        time("autosave write finished") { SessionStore.shared.flush() }
        time("session snapshot") { _ = tab.snapshot() }
        time("undo") { tab.tabUndoManager.undo(); draw() }
        time("encode for save") { _ = TextFileCodec.encode(tab.text, encoding: tab.encoding, lineEnding: tab.lineEnding) }
        time("toggle word wrap off") { Preferences.shared.wordWrap = false; pump(0.01); draw() }
        time("toggle word wrap on") { Preferences.shared.wordWrap = true; pump(0.01); draw() }
        time("zoom in") { Preferences.shared.zoomPercent += 10; pump(0.01); draw() }
        Preferences.shared.zoomPercent -= 10
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("PERF peak memory: \(usage.ru_maxrss / 1_048_576) MB")
    }

    private func diagTabs(dir: String) {
        for sample in ["Notes for Monday\nsecond line", "   ", "", "Report: Q3/Q4 *final* <draft>?", ".hidden start",
                       String(repeating: "word ", count: 40), String(repeating: "x", count: 120)] {
            print("DIAG name \(sample.debugDescription.prefix(40)) -> \(MainWindowController.fileName(fromFirstLineOf: sample as NSString))")
        }
        guard let c = activeController, let window = c.window, let content = window.contentView else { return }
        c.currentTab?.textView.insertText("Notes for Monday\nBuy milk", replacementRange: NSRange(location: 0, length: 0))
        c.newTab(nil)
        c.currentTab?.textView.insertText("Second", replacementRange: NSRange(location: 0, length: 0))
        pump(0.4)
        func click(_ x: CGFloat, _ yFromTop: CGFloat) {
            let p = NSPoint(x: x, y: content.bounds.height - yFromTop)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
                pump(0.1)
            }
        }
        let titles = { c.tabManager.tabs.map { $0.title } }
        print("DIAG before clicks: tabs \(titles()) selected \(c.currentTab?.title ?? "-")")
        print("DIAG hit at tab 0 close-button area: \(String(describing: content.hitTest(NSPoint(x: 181, y: content.bounds.height - 18)).map { type(of: $0) }))")
        print("DIAG hit at tab 0 title: \(String(describing: content.hitTest(NSPoint(x: 80, y: content.bounds.height - 18)).map { type(of: $0) }))")
        click(80, 18)
        print("DIAG after clicking tab 0 title: selected \(c.currentTab?.title ?? "-")")
        click(278, 18)
        print("DIAG after clicking tab 1 title: selected \(c.currentTab?.title ?? "-")")

        let pb = NSPasteboard(name: NSPasteboard.Name("bn-diag"))
        pb.clearContents()
        let dragView = TabDragView()
        dragView.manager = c.tabManager
        if let id = c.currentTab?.id { dragView.tabID = id }
        let provider = TabFilePromiseProvider(fileType: "public.plain-text", delegate: dragView)
        provider.tabID = c.currentTab?.id
        pb.writeObjects([provider])
        print("DIAG drag pasteboard types: \(pb.types?.map { $0.rawValue } ?? [])")
        print("DIAG promised file name: \(dragView.filePromiseProvider(provider, fileNameForType: "public.plain-text"))")
        print("DIAG drag tab id readable: \(String(data: pb.data(forType: .betterNotepadTab) ?? Data(), encoding: .utf8) == c.currentTab?.id.uuidString)")

        let folder = URL(fileURLWithPath: dir)
        let prefs = Preferences.shared
        let saved = prefs.tabDropAction
        prefs.tabDropAction = .saveFile
        let first = c.tabManager.tabs[0].id
        for _ in 0..<2 {
            let name = c.suggestedFileName(forTabID: first)
            c.handleTabDroppedAsFile(id: first, destination: folder.appendingPathComponent(name)) { err in
                print("DIAG save drop -> error \(String(describing: err))")
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".txt") }.sorted()) ?? []
        print("DIAG files: \(files)")
        if let f = files.first { print("DIAG content: \((try? String(contentsOfFile: dir + "/" + f, encoding: .utf8))?.debugDescription ?? "nil")") }

        prefs.tabDropAction = .newWindow
        c.tabManager.lastDropPoint = NSPoint(x: 400, y: 600)
        c.handleTabDroppedAsFile(id: first, destination: folder.appendingPathComponent("x.txt")) { err in
            print("DIAG window drop -> error \((err as? CocoaError)?.code == .userCancelled ? "userCancelled" : String(describing: err))")
        }
        pump(0.4)
        print("DIAG after new-window drop: \(windowControllers.count) windows, \(windowControllers.map { $0.tabManager.tabs.map { $0.title } })")
        prefs.tabDropAction = saved

        // Move the torn-off tab back into the first window (cross-window drop path).
        if let other = windowControllers.first(where: { $0 !== c }) {
            moveTab(id: first, to: c)
            pump(0.4)
            print("DIAG after moving it back: \(windowControllers.count) windows, \(windowControllers.map { $0.tabManager.tabs.map { $0.title } }) otherClosed=\(other.window?.isVisible == false)")
        }
        // Close button of the selected tab (SwiftUI button, not covered by the drag overlay).
        c.selectTab(id: c.tabManager.tabs[0].id)
        pump(0.3)
        let before = c.tabManager.tabs.count
        click(6 + 190 - 6 - 9, 18)
        pump(0.3)
        if let sheet = window.attachedSheet { print("DIAG close button asked to save (expected for unsaved text)"); window.endSheet(sheet, returnCode: .alertThirdButtonReturn) }
        print("DIAG close button: tabs \(before) -> \(c.tabManager.tabs.count)")
    }

    private func diagMarkdown(dir: String) {
        guard let c = activeController, let window = c.window else { return }
        window.setFrame(NSRect(x: 80, y: 120, width: 1100, height: 680), display: true)
        let sample = """
        # Project notes
        Some **bold**, *italic*, ~~gone~~ and `code` text, plus a [link](https://example.com).

        ## Tasks
        - [ ] Write the release notes
        - [x] Ship version 1.1
        1. First step
        2. Second step

        > A quote with **bold** inside.

        ```swift
        let a = b < c && **not bold**
        ```

        snake_case_name stays plain, and so does 2*3*4.

        | Name | Value |
        |------|------:|
        | <b>x</b> | 1 |
        """
        let tab = c.currentTab!
        tab.setMarkdownEnabled(true)
        tab.textView.insertText(sample, replacementRange: NSRange(location: 0, length: 0))
        pump(0.3)
        let ns = tab.nsText
        let storage = tab.textView.textStorage!
        let base = Preferences.shared.editorFont
        func font(at needle: String, offset: Int = 0) -> NSFont? {
            let r = ns.range(of: needle); guard r.location != NSNotFound else { return nil }
            return storage.attribute(.font, at: r.location + offset, effectiveRange: nil) as? NSFont
        }
        func traits(_ f: NSFont?) -> String {
            guard let f else { return "nil" }
            let t = NSFontManager.shared.traits(of: f)
            return "\(Int(f.pointSize))pt\(t.contains(.boldFontMask) ? " bold" : "")\(t.contains(.italicFontMask) ? " italic" : "")"
        }
        func color(at needle: String, offset: Int = 0) -> String {
            let r = ns.range(of: needle)
            let c = storage.attribute(.foregroundColor, at: r.location + offset, effectiveRange: nil) as? NSColor
            return c == Theme.markdownMarker ? "marker" : c == NSColor.linkColor ? "link" : c == Theme.markdownAccent ? "accent" : c == NSColor.textColor ? "text" : String(describing: c)
        }
        print("DIAG base font \(traits(base))")
        print("DIAG H1 '# Project': \(traits(font(at: "# Project", offset: 2))) marker '#': \(color(at: "# Project"))")
        print("DIAG H2 '## Tasks': \(traits(font(at: "## Tasks", offset: 3)))")
        print("DIAG bold: \(traits(font(at: "**bold**", offset: 2))) markers: \(color(at: "**bold**"))")
        print("DIAG italic: \(traits(font(at: "*italic*", offset: 1)))")
        print("DIAG strike: \(storage.attribute(.strikethroughStyle, at: ns.range(of: "~~gone~~").location + 2, effectiveRange: nil) != nil)")
        print("DIAG code font: \(font(at: "`code`", offset: 1)?.fontName ?? "nil")")
        print("DIAG link text: \(color(at: "[link]", offset: 1)) url: \(color(at: "(https://example.com)", offset: 2)) key: \(storage.attribute(MarkdownStyler.linkKey, at: ns.range(of: "[link]").location + 1, effectiveRange: nil) as? String ?? "nil")")
        print("DIAG task box: \(color(at: "- [ ] Write", offset: 2)) checked done strike: \(storage.attribute(.strikethroughStyle, at: ns.range(of: "Ship version").location, effectiveRange: nil) != nil)")
        print("DIAG list number: \(color(at: "1. First"))")
        print("DIAG fenced line not bold: \(traits(font(at: "**not bold**", offset: 2)))")
        print("DIAG snake_case plain: \(traits(font(at: "case_name", offset: 0))) 2*3*4 plain: \(traits(font(at: "3*4", offset: 0)))")

        // Typing inside the code fence keeps code styling; closing fence count changes restyle below.
        let fenceEnd = ns.range(of: "```\n\nsnake").location
        tab.textView.setSelectedRange(NSRange(location: fenceEnd, length: 0))
        tab.textView.insertText("x", replacementRange: tab.textView.selectedRange())
        print("DIAG typed in fence: \(font(at: "x```")?.fontName ?? "nil")")
        tab.textView.insertText("", replacementRange: NSRange(location: fenceEnd, length: 1))
        tab.tabUndoManager.removeAllActions()

        // Commands.
        func select(_ needle: String) { tab.textView.setSelectedRange(tab.nsText.range(of: needle)) }
        func line(containing needle: String) -> String {
            let t = tab.nsText; return t.substring(with: t.lineRange(for: t.range(of: needle))).trimmingCharacters(in: .newlines)
        }
        select("Some")
        tab.perform(.bold)
        print("DIAG bold cmd: \(line(containing: "Some"))")
        tab.perform(.bold)
        print("DIAG bold again (unwrap): \(line(containing: "Some"))")
        select("Some"); tab.perform(.italic)
        print("DIAG italic cmd: \(line(containing: "Some"))")
        tab.tabUndoManager.undo()
        print("DIAG undo: \(line(containing: "Some"))")
        select("Some"); tab.perform(.heading(2))
        print("DIAG heading 2: \(line(containing: "Some"))")
        tab.perform(.heading(2))
        print("DIAG heading 2 again: \(line(containing: "Some"))")
        select("snake"); tab.perform(.bulletList)
        print("DIAG bullet: \(line(containing: "snake"))")
        tab.perform(.numberedList)
        print("DIAG numbered: \(line(containing: "snake"))")
        tab.perform(.checklist)
        print("DIAG checklist: \(line(containing: "snake"))")
        tab.perform(.quote)
        print("DIAG quote: \(line(containing: "snake"))")
        tab.perform(.quote)

        // Return continues lists and ends empty items.
        let end = tab.nsText.range(of: "Second step").location + ("Second step" as NSString).length
        tab.textView.setSelectedRange(NSRange(location: end, length: 0))
        _ = tab.continueListOnReturn()
        print("DIAG return after '2. Second step' -> next line '\(line(containing: "3. "))'")
        _ = tab.continueListOnReturn()
        let caretLine = tab.nsText.substring(with: tab.nsText.lineRange(for: tab.textView.selectedRange())).trimmingCharacters(in: .newlines)
        print("DIAG return on empty item -> line '\(caretLine)' (list ended)")
        let taskEnd = tab.nsText.range(of: "release notes").location + 13
        tab.textView.setSelectedRange(NSRange(location: taskEnd, length: 0))
        _ = tab.continueListOnReturn()
        print("DIAG return in checklist -> '\(tab.nsText.substring(with: tab.nsText.lineRange(for: tab.textView.selectedRange())).trimmingCharacters(in: .newlines))'")

        // Clicking a task box toggles it.
        let box = tab.nsText.range(of: "- [ ] Write").location + 3
        _ = tab.handleMarkdownClick(at: box, modifiers: [])
        print("DIAG click box: \(line(containing: "Write the release"))")

        // Preview HTML escaping and structure.
        let html = MarkdownHTML.render(tab.text)
        print("DIAG html escapes code '<': \(html.contains("b &lt; c")), table: \(html.contains("<table>")), task checkbox: \(html.contains("type=\"checkbox\"")), right align: \(html.contains("text-align: right"))")

        // Show preview and render the editor side.
        tab.setPreviewVisible(true)
        pump(1.5)
        print("DIAG preview visible: \(tab.previewVisible), toolbar shown: \(c.markdownBar.previewVisible), split views: \(tab.rootView.arrangedSubviews.count)")
        if let frameView = window.contentView?.superview, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/md-window.png"))
        }
        // Session keeps the flags.
        let snap = tab.snapshot()
        print("DIAG snapshot markdown=\(snap.markdown ?? false) preview=\(snap.preview ?? false)")
        print("DIAG suggested drag name: \(c.suggestedFileName(forTabID: tab.id))")

        // Typing speed in a larger Markdown document.
        let big = String(repeating: sample + "\n\n", count: 600)
        c.newTab(nil)
        let t2 = c.currentTab!
        t2.setMarkdownEnabled(true)
        let start = CFAbsoluteTimeGetCurrent()
        t2.textView.insertText(big, replacementRange: NSRange(location: 0, length: 0))
        print(String(format: "PERF style %d chars on paste: %.0f ms", (big as NSString).length, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        let mid = (big as NSString).length / 2
        t2.textView.setSelectedRange(NSRange(location: mid, length: 0))
        var times: [Double] = []
        for ch in "typing **fast**" {
            let s = CFAbsoluteTimeGetCurrent()
            t2.textView.insertText(String(ch), replacementRange: t2.textView.selectedRange())
            window.displayIfNeeded()
            times.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
        }
        print(String(format: "PERF markdown typing: avg %.2f ms, max %.2f ms", times.reduce(0, +) / Double(times.count), times.max() ?? 0))

        // The preview loads asynchronously: check it from a later main-queue turn (waiting inside this
        // block would stall WebKit's callbacks), then quit.
        c.selectTab(id: tab.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let web = tab.rootView.arrangedSubviews.last?.subviews.first as? WKWebView else {
                print("DIAG no web view"); NSApp.terminate(nil); return
            }
            web.evaluateJavaScript("document.getElementById('content').innerHTML.length") { v, e in
                print("DIAG preview content length: \(v ?? "nil") error: \(e.map { "\($0)" } ?? "none") loading=\(web.isLoading)")
                web.takeSnapshot(with: nil) { image, _ in
                    if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/md-preview.png"))
                        print("DIAG preview snapshot written")
                    }
                    if let frameView = window.contentView?.superview,
                       let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/md-window.png"))
                    }
                    fflush(stdout)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Window with realistic content for the website screenshot.
    private func diagShowcase(out: String, file: String?) {
        guard let c = activeController, let window = c.window else { return }
        window.setFrame(NSRect(x: 100, y: 200, width: 1080, height: 520), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let notes = """
        Office IT checklist – November

        This week
        - Renew the firewall subscription (quote due Friday)
        - Set up 3 new laptops for the front desk
        - Test restoring last week's backup of the shared drive
        - Replace the toner in the upstairs printer

        Next week
        1. Update all Macs to the latest macOS
        2. Review who still has access to the old file server
        3. Move the guest Wi-Fi to its own network

        Notes
        Backups ran every night this month with no errors.
        The upstairs access point drops out around 3 PM; check the channel.
        """
        c.currentTab?.textView.insertText(notes, replacementRange: NSRange(location: 0, length: 0))
        let notesID = c.currentTab!.id
        if let file { c.open(urls: [URL(fileURLWithPath: file)]) }
        c.newTab(nil)
        c.currentTab?.textView.insertText("Grocery list\nCoffee\nOat milk\nApples", replacementRange: NSRange(location: 0, length: 0))
        c.selectTab(id: notesID)
        let tv = c.currentTab!.textView
        let caret = (tv.string as NSString).range(of: "quote due Friday").location
        tv.setSelectedRange(NSRange(location: caret + 16, length: 0))
        c.updateStatus()
        pump(0.6)
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print("DIAG showcase \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(out)")
    }

    private func diagTabMove() {
        guard let a = activeController else { return }
        a.currentTab?.textView.insertText("A1", replacementRange: NSRange(location: 0, length: 0))
        a.newTab(nil); a.currentTab?.textView.insertText("A2", replacementRange: NSRange(location: 0, length: 0))
        newWindow(nil)
        let b = windowControllers.last!
        b.currentTab?.textView.insertText("B1", replacementRange: NSRange(location: 0, length: 0))
        b.newTab(nil); b.currentTab?.textView.insertText("B2", replacementRange: NSRange(location: 0, length: 0))
        a.window?.setFrame(NSRect(x: 80, y: 300, width: 700, height: 400), display: true)
        b.window?.setFrame(NSRect(x: 820, y: 300, width: 700, height: 400), display: true)
        pump(0.3)
        func stripPoint(_ c: MainWindowController, tabX: CGFloat) -> NSPoint {
            let f = c.window!.frame
            let title = f.height - c.window!.contentLayoutRect.height
            return NSPoint(x: f.minX + tabX, y: f.maxY - title - 18)
        }
        let titles = { self.windowControllers.map { $0.tabManager.tabs.map { $0.title } } }
        print("DIAG start: \(titles())")
        // Drag A2 onto B's tab bar between B1 and B2 (x ≈ 6 + 192).
        let pointB = stripPoint(b, tabX: 6 + 192)
        highlightTabDropTarget(at: pointB, source: a)
        print("DIAG highlight on B while hovering: \(b.tabManager.isMergeTarget)")
        TabDragView.finishDrag(tabID: a.tabManager.tabs[1].id, manager: a.tabManager, at: pointB, operation: .move)
        pump(0.3)
        print("DIAG A2 dropped between B1 and B2: \(titles()) highlightCleared=\(!b.tabManager.isMergeTarget) selectedB=\(b.currentTab?.title ?? "-")")
        // Drag A's last tab onto B's bar at the end: window A should close.
        let pointEnd = stripPoint(b, tabX: 6 + 192 * 3 + 20)
        TabDragView.finishDrag(tabID: a.tabManager.tabs[0].id, manager: a.tabManager, at: pointEnd, operation: .move)
        pump(0.3)
        print("DIAG A1 dropped at end of B: \(titles()) windows=\(windowControllers.count)")
        // Dropping on B's own text area does nothing.
        let f = b.window!.frame
        TabDragView.finishDrag(tabID: b.tabManager.tabs[0].id, manager: b.tabManager, at: NSPoint(x: f.midX, y: f.midY), operation: [])
        pump(0.3)
        print("DIAG drop on own text area: \(titles())")
        // An empty tab torn off into its own window must survive another tab being dragged in.
        b.newTab(nil)
        let empty = b.currentTab!.id
        b.tearOffTab(id: empty, at: NSPoint(x: 300, y: 700))
        pump(0.3)
        let c = windowControllers.first { $0.tabIDs.contains(empty) }!
        c.window?.setFrame(NSRect(x: 80, y: 300, width: 700, height: 400), display: true)
        pump(0.2)
        TabDragView.finishDrag(tabID: b.tabManager.tabs[0].id, manager: b.tabManager,
                               at: stripPoint(c, tabX: 6 + 192 + 20), operation: .move)
        pump(0.3)
        print("DIAG tab dragged onto empty-tab window: \(titles()) emptyKept=\(c.tabIDs.contains(empty))")
    }

    private func diagMerge() {
        guard let a = activeController else { return }
        a.currentTab?.textView.insertText("one", replacementRange: NSRange(location: 0, length: 0))
        newWindow(nil)
        pump(0.3)
        let b = windowControllers.last!
        b.currentTab?.textView.insertText("two", replacementRange: NSRange(location: 0, length: 0))
        b.newTab(nil)
        b.currentTab?.textView.insertText("three", replacementRange: NSRange(location: 0, length: 0))
        b.selectTab(id: b.tabManager.tabs[0].id)
        pump(0.3)
        // Geometry: a point in A's tab bar, one in A's text area.
        if let fa = a.window?.frame, let wa = a.window {
            let title = fa.height - wa.contentLayoutRect.height
            let inStrip = NSPoint(x: fa.midX, y: fa.maxY - title - 18)
            let inText = NSPoint(x: fa.midX, y: fa.midY)
            b.window?.orderBack(nil)
            print("DIAG target in tab bar: \(mergeTarget(for: inStrip, excluding: b) === a), in text area: \(mergeTarget(for: inText, excluding: b) === a)")
        }
        print("DIAG before merge: \(windowControllers.map { $0.tabManager.tabs.map { $0.title } })")
        mergeWindow(b, into: a)
        pump(0.3)
        print("DIAG after merge: \(windowControllers.map { $0.tabManager.tabs.map { $0.title } }) selected=\(a.currentTab?.title ?? "-") bVisible=\(b.window?.isVisible ?? false)")
    }

    private func diagPrint(out: String) {
        let sample = (1...140).map { "Line \($0): The quick brown fox jumps over the lazy dog, again and again, until the line is long enough to wrap on the page." }
            .joined(separator: "\n")
        let op = PrintRenderer.operation(text: sample, title: "Print Test.txt", font: Preferences.shared.baseFont)
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: out)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        print("DIAG print ok=\(op.run()) -> \(out)")
    }

    private func diagWindows() {
        guard let first = activeController else { return }
        func state(_ label: String) {
            let desc = windowControllers.map { c in "[\(c.tabManager.tabs.map { $0.title }.joined(separator: ", "))]" }
            print("DIAG \(label): \(windowControllers.count) windows \(desc.joined(separator: " "))")
        }
        first.currentTab?.textView.insertText("alpha", replacementRange: NSRange(location: 0, length: 0))
        first.newTab(nil)
        first.currentTab?.textView.insertText("beta", replacementRange: NSRange(location: 0, length: 0))
        pump(0.3)
        state("start")
        first.moveTabToNewWindow(nil)
        pump(0.3)
        state("after move tab")
        newWindow(nil)
        pump(0.3)
        let gamma = windowControllers.last!
        gamma.currentTab?.textView.insertText("gamma", replacementRange: NSRange(location: 0, length: 0))
        state("after new window")
        // Closing a window that has an untitled tab with text prompts; answer "Don't Save".
        gamma.window?.performClose(nil)
        pump(0.3)
        if let sheet = gamma.window?.attachedSheet {
            gamma.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            pump(0.3)
        }
        state("after closing gamma window (Don't Save)")
        reopenClosedTab(nil)
        pump(0.3)
        state("after reopen closed tab")
        first.closeTab(nil)
        pump(0.3)
        if let sheet = first.window?.attachedSheet {
            first.window?.endSheet(sheet, returnCode: .alertThirdButtonReturn)   // Cancel
            pump(0.3)
        }
        state("after cancelling close of alpha")
        persistEverything()
        if let data = try? Data(contentsOf: SessionStore.shared.directory.appendingPathComponent("session.json")),
           let session = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            print("DIAG session: \(session.allWindows.count) windows, tabs per window \(session.allWindows.map { $0.tabs.count }), key \(String(describing: session.keyWindowIndex))")
        }
    }
}
#endif
