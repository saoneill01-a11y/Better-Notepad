import AppKit
import WebKit
import Markdown

/// Markdown → HTML for the preview pane. Built on swift-markdown's parser (CommonMark + GitHub
/// tables, strikethrough and task lists) with a renderer of our own, because swift-markdown's
/// HTMLFormatter does not escape text or code (a `<div>` in a code block would become real HTML).
enum MarkdownHTML {
    static func render(_ source: String) -> String {
        var renderer = PreviewRenderer()
        renderer.visit(Document(parsing: source))
        return renderer.result
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

private struct PreviewRenderer: MarkupWalker {
    var result = ""
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0

    private func esc(_ s: String) -> String { MarkdownHTML.escape(s) }

    mutating func visitBlockQuote(_ node: BlockQuote) {
        result += "<blockquote>\n"; descendInto(node); result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ node: CodeBlock) {
        let lang = node.language.map { " class=\"language-\(esc($0))\"" } ?? ""
        result += "<pre><code\(lang)>\(esc(node.code))</code></pre>\n"
    }

    mutating func visitHeading(_ node: Heading) {
        result += "<h\(node.level)>"; descendInto(node); result += "</h\(node.level)>\n"
    }

    mutating func visitThematicBreak(_ node: ThematicBreak) { result += "<hr />\n" }
    mutating func visitHTMLBlock(_ node: HTMLBlock) { result += node.rawHTML }

    mutating func visitListItem(_ node: ListItem) {
        if let box = node.checkbox {
            result += "<li class=\"task\"><input type=\"checkbox\" disabled\(box == .checked ? " checked" : "") /> "
        } else {
            result += "<li>"
        }
        // Single-paragraph items render without <p>, so checkboxes and text share a line and
        // tight lists stay tight.
        if node.childCount == 1, let paragraph = node.child(at: 0) as? Paragraph {
            descendInto(paragraph)
        } else {
            descendInto(node)
        }
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ node: OrderedList) {
        result += node.startIndex != 1 ? "<ol start=\"\(node.startIndex)\">\n" : "<ol>\n"
        descendInto(node); result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ node: UnorderedList) {
        result += "<ul>\n"; descendInto(node); result += "</ul>\n"
    }

    mutating func visitParagraph(_ node: Paragraph) {
        result += "<p>"; descendInto(node); result += "</p>\n"
    }

    mutating func visitTable(_ node: Table) {
        alignments = node.columnAlignments
        result += "<table>\n"; descendInto(node); result += "</table>\n"
        alignments = []
    }

    mutating func visitTableHead(_ node: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true; column = 0
        descendInto(node)
        inTableHead = false
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ node: Table.Body) {
        guard !node.isEmpty else { return }
        result += "<tbody>\n"; descendInto(node); result += "</tbody>\n"
    }

    mutating func visitTableRow(_ node: Table.Row) {
        result += "<tr>\n"; column = 0; descendInto(node); result += "</tr>\n"
    }

    mutating func visitTableCell(_ node: Table.Cell) {
        guard node.colspan > 0, node.rowspan > 0 else { return }
        let tag = inTableHead ? "th" : "td"
        var attrs = ""
        if column < alignments.count, let alignment = alignments[column] {
            attrs += " style=\"text-align: \(alignment)\""
        }
        if node.colspan > 1 { attrs += " colspan=\"\(node.colspan)\"" }
        if node.rowspan > 1 { attrs += " rowspan=\"\(node.rowspan)\"" }
        column += 1
        result += "<\(tag)\(attrs)>"; descendInto(node); result += "</\(tag)>\n"
    }

    mutating func visitInlineCode(_ node: InlineCode) { result += "<code>\(esc(node.code))</code>" }
    mutating func visitEmphasis(_ node: Emphasis) { result += "<em>"; descendInto(node); result += "</em>" }
    mutating func visitStrong(_ node: Strong) { result += "<strong>"; descendInto(node); result += "</strong>" }
    mutating func visitStrikethrough(_ node: Strikethrough) { result += "<del>"; descendInto(node); result += "</del>" }
    mutating func visitInlineHTML(_ node: InlineHTML) { result += node.rawHTML }
    mutating func visitLineBreak(_ node: LineBreak) { result += "<br />\n" }
    mutating func visitSoftBreak(_ node: SoftBreak) { result += "\n" }
    mutating func visitText(_ node: Text) { result += esc(node.string) }

    mutating func visitImage(_ node: Image) {
        result += "<img src=\"\(esc(node.source ?? ""))\" alt=\"\(esc(node.plainText))\""
        if let title = node.title, !title.isEmpty { result += " title=\"\(esc(title))\"" }
        result += " />"
    }

    mutating func visitLink(_ node: Link) {
        result += "<a href=\"\(esc(node.destination ?? ""))\""
        if let title = node.title, !title.isEmpty { result += " title=\"\(esc(title))\"" }
        result += ">"; descendInto(node); result += "</a>"
    }
}

/// Side-by-side rendered preview of a Markdown tab. Page scripts are disabled (the document is
/// untrusted); only the app's own update script runs. Links open in the default browser.
@MainActor
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var hasPage = false
    private var loaded = false
    private var pendingHTML: String?
    private var pendingFraction: CGFloat?
    private var baseURL: URL?

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: frame, configuration: config)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.editorBackground.cgColor
        }
    }

    /// Shows `markdown`. The first call loads the page; later calls swap the body in place so
    /// the scroll position is kept.
    func update(markdown: String, baseURL: URL?) {
        let body = MarkdownHTML.render(markdown)
        if !hasPage || baseURL != self.baseURL {
            hasPage = true
            self.baseURL = baseURL
            loaded = false
            pendingHTML = nil
            webView.loadHTMLString(Self.page(body: body), baseURL: baseURL ?? URL(fileURLWithPath: NSHomeDirectory()))
        } else if !loaded {
            pendingHTML = body   // page still loading: apply when it finishes
        } else {
            setBody(body)
        }
    }

    private func setBody(_ body: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: [body]),
              let literal = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.getElementById('content').innerHTML = \(literal)[0];", completionHandler: nil)
    }

    /// Scrolls the preview to the same relative position as the editor (0 = top, 1 = bottom).
    func scroll(toFraction fraction: CGFloat) {
        guard loaded else { pendingFraction = fraction; return }
        let f = min(max(fraction, 0), 1)
        webView.evaluateJavaScript(
            "window.scrollTo(0, \(f) * (document.documentElement.scrollHeight - window.innerHeight));",
            completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let html = pendingHTML { pendingHTML = nil; setBody(html) }
        if let f = pendingFraction { pendingFraction = nil; scroll(toFraction: f) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }

    private static func page(body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data: https:; style-src 'unsafe-inline';">
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.6 -apple-system, "Helvetica Neue", sans-serif; margin: 0; padding: 18px 26px 40px;
               color: #1f2328; background: transparent; word-wrap: break-word; }
        @media (prefers-color-scheme: dark) { body { color: #e6e6e6; } a { color: #6ea8ff; }
          code, pre { background: rgba(255,255,255,.07) !important; } th, td { border-color: #444 !important; }
          blockquote { color: #a0a0a0 !important; border-color: #555 !important; } hr { border-color: #444 !important; } }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 .5em; font-weight: 600; }
        h1 { font-size: 1.9em; padding-bottom: .25em; border-bottom: 1px solid rgba(128,128,128,.3); }
        h2 { font-size: 1.5em; padding-bottom: .2em; border-bottom: 1px solid rgba(128,128,128,.25); }
        h3 { font-size: 1.25em; } h4 { font-size: 1.05em; }
        body > :first-child, #content > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: #2f6fd6; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: .9em ui-monospace, "SF Mono", Menlo, monospace; background: rgba(0,0,0,.05); padding: .15em .35em; border-radius: 4px; }
        pre { background: rgba(0,0,0,.05); padding: 12px 14px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none !important; padding: 0; font-size: .88em; }
        blockquote { margin-left: 0; padding: 0 1em; color: #59636e; border-left: 4px solid #d0d7de; }
        ul, ol { padding-left: 1.8em; } li + li { margin-top: .2em; }
        li.task { list-style: none; margin-left: -1.4em; } li.task input { margin: 0 .45em 0 0; vertical-align: middle; }
        li > p { margin: .3em 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #d0d7de; padding: 5px 12px; } th { font-weight: 600; }
        hr { border: 0; border-top: 1px solid #d0d7de; margin: 1.5em 0; }
        img { max-width: 100%; }
        </style></head>
        <body><div id="content">\(body)</div></body></html>
        """
    }
}
