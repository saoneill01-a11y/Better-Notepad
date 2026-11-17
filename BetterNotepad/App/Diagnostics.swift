#if DEBUG
import AppKit

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
                case "showcase": self.diagShowcase(out: env["BN_DIAG_OUT"] ?? "/tmp/bn.png", file: env["BN_DIAG_FILE"])
                case "tabmove": self.diagTabMove()
                case "print": self.diagPrint(out: env["BN_DIAG_OUT"] ?? "/tmp/bn.pdf")
                default: print("DIAG unknown mode \(mode)")
                }
                fflush(stdout)
                if env["BN_DIAG_KEEP_OPEN"] == nil { NSApp.terminate(nil) }
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
