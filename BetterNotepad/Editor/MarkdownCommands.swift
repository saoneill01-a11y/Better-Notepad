import AppKit

/// Formatting actions from the toolbar, the Format menu and their shortcuts. Each one edits the
/// Markdown text itself (one undoable step), so the file stays plain Markdown.
enum MarkdownCommand: Equatable {
    case bold, italic, strikethrough, code, link
    /// 1–3 for headings, 0 for normal text.
    case heading(Int)
    case bulletList, numberedList, checklist, quote

    var undoName: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        case .link: return "Link"
        case .heading(let n): return n == 0 ? "Normal Text" : "Heading \(n)"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        }
    }
}

enum MarkdownFiles {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]
    /// A heading or list line without its Markdown symbols, for tab titles and file names.
    static func plainTitle(_ line: String) -> String {
        var s = Substring(line)
        while let c = s.first, "#>-*+ \t".contains(c) { s = s.dropFirst() }
        if s.hasPrefix("[ ] ") || s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { s = s.dropFirst(4) }
        return s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func isMarkdown(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return extensions.contains(ext)
    }
}

@MainActor
extension EditorTab {
    private static let headingPrefix = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
    private static let listPrefix = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let quotePrefix = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)

    func perform(_ command: MarkdownCommand) {
        switch command {
        case .bold: toggleWrap("**", name: command.undoName)
        case .italic: toggleWrap("*", name: command.undoName)
        case .strikethrough: toggleWrap("~~", name: command.undoName)
        case .code: toggleWrap("`", name: command.undoName)
        case .link: insertLink()
        case .heading(let level): setHeading(level)
        case .bulletList, .numberedList, .checklist, .quote: toggleLinePrefix(command)
        }
    }

    // MARK: Editing helper

    /// Replaces `range` with `text` as one undoable step and selects `selection` afterwards.
    func replace(_ range: NSRange, with text: String, select selection: NSRange, undoName: String) {
        let tv = textView
        guard let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: text)
        tv.didChangeText()
        tv.undoManager?.setActionName(undoName)
        tv.setSelectedRange(NSRange(location: min(selection.location, storage.length),
                                    length: min(selection.length, storage.length - min(selection.location, storage.length))))
    }

    // MARK: Bold, italic, strikethrough, code

    private func toggleWrap(_ marker: String, name: String) {
        let ns = nsText
        let sel = textView.selectedRange()
        let m = (marker as NSString).length
        // Markers just outside the selection: remove them.
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker,
           !(marker == "*" && isPartOfBold(ns, before: sel.location - m, after: NSMaxRange(sel) + m)) {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: ns.substring(with: sel), select: NSRange(location: outer.location, length: sel.length), undoName: name)
            return
        }
        let selected = ns.substring(with: sel)
        // Markers inside the selection: remove them.
        if sel.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            replace(sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length), undoName: name)
            return
        }
        // No selection: wrap the word under the caret, or insert an empty pair.
        var target = sel
        if sel.length == 0 {
            let word = textView.selectionRange(forProposedRange: sel, granularity: .selectByWord)
            if word.length > 0, word.location <= sel.location, NSMaxRange(word) >= sel.location,
               ns.substring(with: word).rangeOfCharacter(from: .alphanumerics) != nil {
                target = word
            }
        }
        // Keep surrounding spaces outside the markers ("**word** " not "**word **").
        var text = ns.substring(with: target)
        while text.hasSuffix(" ") || text.hasSuffix("\t") { text.removeLast(); target.length -= 1 }
        while text.hasPrefix(" ") || text.hasPrefix("\t") { text.removeFirst(); target.location += 1; target.length -= 1 }
        let wrapped = marker + text + marker
        let innerLength = (text as NSString).length
        let selectAfter = sel.length == 0 && target.length == 0
            ? NSRange(location: target.location + m, length: 0)
            : NSRange(location: target.location + m, length: innerLength)
        replace(target, with: wrapped, select: selectAfter, undoName: name)
    }

    /// True if single `*` markers are really the inner half of `**` (so italic doesn't eat bold).
    private func isPartOfBold(_ ns: NSString, before: Int, after: Int) -> Bool {
        let starBefore = before > 0 && ns.character(at: before - 1) == 42
        let starAfter = after < ns.length && ns.character(at: after) == 42
        return starBefore && starAfter
    }

    // MARK: Link

    private func insertLink() {
        guard let window = textView.window else { return }
        let sel = textView.selectedRange()
        let selected = nsText.substring(with: sel)
        let alert = NSAlert()
        alert.messageText = "Insert Link"
        let textField = NSTextField(string: selected.contains("\n") ? "" : selected)
        textField.placeholderString = "Text to show"
        let urlField = NSTextField(string: "")
        urlField.placeholderString = "https://example.com"
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.hasPrefix("http://") || clip.hasPrefix("https://") || clip.hasPrefix("mailto:"), !clip.contains(" ") {
            urlField.stringValue = clip
        }
        for field in [textField, urlField] { field.frame.size.width = 300 }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Text:"), textField],
                                      [NSTextField(labelWithString: "Address:"), urlField]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: NSSize(width: 360, height: grid.fittingSize.height))
        alert.accessoryView = grid
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = urlField.stringValue.isEmpty ? urlField : textField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let url = urlField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "%20")
            var label = textField.stringValue.replacingOccurrences(of: "\n", with: " ")
            if label.isEmpty { label = url }
            guard !url.isEmpty else { return }
            let markdown = "[\(label)](\(url))"
            self.replace(sel, with: markdown, select: NSRange(location: sel.location + (markdown as NSString).length, length: 0),
                         undoName: "Link")
            window.makeFirstResponder(self.textView)
        }
    }

    // MARK: Line-based formats

    /// Whole lines touched by the selection, without the final line break.
    private func selectedLines() -> (range: NSRange, lines: [String]) {
        let ns = nsText
        var range = ns.lineRange(for: textView.selectedRange())
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return (range, ns.substring(with: range).components(separatedBy: "\n"))
    }

    private func setHeading(_ level: Int) {
        let (range, lines) = selectedLines()
        let caret = textView.selectedRange()
        let already = lines.allSatisfy { line in
            guard let m = Self.headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            else { return level == 0 }
            return (line as NSString).substring(with: m.range).trimmingCharacters(in: .whitespaces).count == level
        }
        let target = already ? 0 : level
        let newLines = lines.map { line -> String in
            let ns = line as NSString
            var body = line
            if let m = Self.headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                body = ns.substring(from: m.range.length)
            }
            return target == 0 ? body : String(repeating: "#", count: target) + " " + body
        }
        commitLines(range: range, old: lines, new: newLines, caret: caret, undoName: MarkdownCommand.heading(target).undoName)
    }

    private func toggleLinePrefix(_ command: MarkdownCommand) {
        let (range, lines) = selectedLines()
        let caret = textView.selectedRange()
        let regex = command == .quote ? Self.quotePrefix : Self.listPrefix
        let content = lines.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty || lines.count == 1 }
        func hasThisFormat(_ line: String) -> Bool {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
            switch command {
            case .quote: return true
            case .checklist: return m.range(at: 3).location != NSNotFound
            case .bulletList:
                return m.range(at: 3).location == NSNotFound && "-*+".contains(ns.substring(with: m.range(at: 2)))
            case .numberedList:
                return m.range(at: 3).location == NSNotFound && ns.substring(with: m.range(at: 2)).first?.isNumber == true
            default: return false
            }
        }
        let removing = !content.isEmpty && content.allSatisfy { hasThisFormat($0.element) }
        var number = 1
        let newLines = lines.map { line -> String in
            let ns = line as NSString
            if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
            // Strip any existing list or quote prefix of the same family, keeping indentation.
            var indent = ""
            var body = line
            if let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                if command != .quote { indent = ns.substring(with: m.range(at: 1)) }
                body = ns.substring(from: m.range.length)
            } else if command != .quote {
                body = line.drop(while: { $0 == " " || $0 == "\t" }).description
                indent = String(line.prefix(line.count - body.count))
            }
            if removing { return indent + body }
            let prefix: String
            switch command {
            case .bulletList: prefix = "- "
            case .numberedList: prefix = "\(number). "; number += 1
            case .checklist: prefix = "- [ ] "
            default: prefix = "> "
            }
            return indent + prefix + body
        }
        commitLines(range: range, old: lines, new: newLines, caret: caret, undoName: command.undoName)
    }

    /// Writes changed lines back; a lone caret moves with its line's prefix change, a selection
    /// covers the edited lines.
    private func commitLines(range: NSRange, old: [String], new: [String], caret: NSRange, undoName: String) {
        guard old != new else { return }
        let text = new.joined(separator: "\n")
        let selection: NSRange
        if caret.length == 0, old.count == 1 {
            let delta = (new[0] as NSString).length - (old[0] as NSString).length
            selection = NSRange(location: max(range.location, caret.location + delta), length: 0)
        } else {
            selection = NSRange(location: range.location, length: (text as NSString).length)
        }
        replace(range, with: text, select: selection, undoName: undoName)
    }

    // MARK: Return key in lists

    /// Continues a list on Return ("- ", "2. ", "- [ ] ", "> "), or ends it when the item is empty.
    /// Returns false to let the text view insert a normal line break.
    func continueListOnReturn() -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = nsText
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineStart = lineRange.location
        let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        let beforeNS = before as NSString
        var prefix: String?
        var matchedLength = 0
        if let m = Self.listPrefix.firstMatch(in: before, range: NSRange(location: 0, length: beforeNS.length)) {
            let indent = beforeNS.substring(with: m.range(at: 1))
            let bullet = beforeNS.substring(with: m.range(at: 2))
            let task = m.range(at: 3).location != NSNotFound ? "[ ] " : ""
            if let n = Int(bullet.dropLast()) {
                prefix = indent + "\(n + 1)\(bullet.last!) " + task
            } else {
                prefix = indent + bullet + " " + task
            }
            matchedLength = m.range.length
        } else if let m = Self.quotePrefix.firstMatch(in: before, range: NSRange(location: 0, length: beforeNS.length)) {
            prefix = "> "
            matchedLength = m.range.length
        }
        guard let prefix else { return false }
        let rest = beforeNS.substring(from: matchedLength)
        let lineEnd = NSMaxRange(lineRange) - (NSMaxRange(lineRange) > lineStart && ns.character(at: NSMaxRange(lineRange) - 1) == 10 ? 1 : 0)
        let after = ns.substring(with: NSRange(location: sel.location, length: lineEnd - sel.location))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: Return ends the list by removing the bullet.
            replace(NSRange(location: lineStart, length: sel.location - lineStart), with: "",
                    select: NSRange(location: lineStart, length: 0), undoName: "Typing")
            return true
        }
        let insert = "\n" + prefix
        replace(sel, with: insert, select: NSRange(location: sel.location + (insert as NSString).length, length: 0),
                undoName: "Typing")
        return true
    }

    // MARK: Clicks

    /// Click on a task box toggles it; ⌘-click on a link opens it. Returns true if handled.
    func handleMarkdownClick(at index: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let ns = nsText
        guard index >= 0, index < ns.length else { return false }
        if modifiers.contains(.command),
           let target = textView.textStorage?.attribute(MarkdownStyler.linkKey, at: index, effectiveRange: nil) as? String {
            openLink(target)
            return true
        }
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: lineRange)
        guard let m = Self.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              m.range(at: 3).location != NSNotFound else { return false }
        let box = NSRange(location: lineRange.location + m.range(at: 3).location, length: 3)   // "[ ]"
        guard NSLocationInRange(index, box) else { return false }
        let checked = ns.substring(with: NSRange(location: box.location + 1, length: 1)).lowercased() == "x"
        let caret = textView.selectedRange()
        replace(NSRange(location: box.location + 1, length: 1), with: checked ? " " : "x", select: caret,
                undoName: checked ? "Uncheck" : "Check")
        return true
    }

    private func openLink(_ target: String) {
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        } else if let base = fileURL?.deletingLastPathComponent() {
            // Relative link to another file next to this one.
            // Text and Markdown files open here as tabs; anything else is only shown in Finder,
            // so a link in a document can never launch an app or script.
            let path = target.removingPercentEncoding ?? target
            let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let textExtensions: Set<String> = ["txt", "text", "log", "csv", "json", "xml", "yaml", "yml"]
            if MarkdownFiles.isMarkdown(url) || textExtensions.contains(url.pathExtension.lowercased()) {
                AppDelegate.shared.activeController?.open(urls: [url])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
