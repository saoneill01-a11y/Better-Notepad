import AppKit

/// Formats Markdown in place, the way Windows 11 Notepad does: the text stays plain Markdown
/// (that is what gets saved), but headings, bold, italic, code, links, lists and quotes are drawn
/// formatted, with the Markdown symbols faded rather than hidden so editing stays predictable.
///
/// Styling is line based and only touches display attributes, so it is cheap to redo for the
/// paragraph being edited. Fenced code blocks are the one multi-line construct; their state is
/// worked out by counting fence lines above.
@MainActor
enum MarkdownStyler {
    /// Documents larger than this are shown unformatted to keep typing fast.
    static let maxStyledLength = 2_000_000
    /// Stores the URL of a link on its text so ⌘-click can open it.
    static let linkKey = NSAttributedString.Key("BNMarkdownLink")

    // MARK: Fonts

    struct Fonts {
        let base: NSFont
        let code: NSFont
        let headings: [NSFont]   // index 0 = H1
    }

    private static var fontCache: (key: NSFont, fonts: Fonts)?

    static func fonts(for base: NSFont) -> Fonts {
        if let cached = fontCache, cached.key.isEqual(base) { return cached.fonts }
        let scales: [CGFloat] = [1.7, 1.45, 1.25, 1.12, 1.0, 1.0]
        let headings = scales.map { scale -> NSFont in
            let sized = NSFont(descriptor: base.fontDescriptor, size: (base.pointSize * scale).rounded()) ?? base
            return NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
        }
        let code = NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
        let fonts = Fonts(base: base, code: code, headings: headings)
        fontCache = (base, fonts)
        return fonts
    }

    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let fenceLine = regex(#"^ {0,3}(```|~~~)"#, [.anchorsMatchLines])
    private static let heading = regex(#"^(#{1,6})([ \t]+|$)"#)
    private static let rule = regex(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let quote = regex(#"^ {0,3}(>[ \t]?)+"#)
    private static let listItem = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\][ \t]+)?"#)
    private static let codeSpan = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let boldItalic = regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let bold = regex(#"(\*\*|(?<![\w_])__)(?=\S)(.+?)(?<=\S)(\*\*|__(?![\w_]))"#)
    private static let italicStar = regex(#"(?<![*\\])\*(?![\s*])(.+?)(?<![\s*\\])\*(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![\w_])_(?![\s_])(.+?)(?<![\s_])_(?![\w_])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let link = regex(#"(!?)\[([^\]\n]*)\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\)"#)
    private static let autolink = regex(#"<(https?://[^>\s]+)>"#)

    // MARK: Styling

    /// Number of fence lines (``` or ~~~) in the whole text; a change means fence state below moved.
    static func fenceCount(in text: NSString) -> Int {
        // Fast literal search (fences are rare); only count ones at the start of a line.
        var count = 0
        for marker in ["```", "~~~"] {
            var searchStart = 0
            while searchStart < text.length {
                let r = text.range(of: marker, options: .literal,
                                   range: NSRange(location: searchStart, length: text.length - searchStart))
                guard r.location != NSNotFound else { break }
                let lineStart = text.lineRange(for: NSRange(location: r.location, length: 0)).location
                let lead = r.location - lineStart
                if lead <= 3, lead == 0 || text.substring(with: NSRange(location: lineStart, length: lead)).allSatisfy({ $0 == " " }) {
                    count += 1
                }
                // Skip the rest of this line so "``````" counts once.
                searchStart = NSMaxRange(text.lineRange(for: r))
            }
        }
        return count
    }

    /// Removes all Markdown styling: base font, colour and paragraph style everywhere.
    static func clear(_ storage: NSTextStorage, base: NSFont, paragraph: NSParagraphStyle?) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes(base, paragraph), range: all)
    }

    /// Restyles every line that intersects `range` (pass the full range for the whole document).
    static func style(_ storage: NSTextStorage, range: NSRange, base: NSFont, paragraph: NSParagraphStyle?) {
        let text = storage.mutableString
        guard text.length > 0 else { return }
        let fonts = fonts(for: base)
        // One immutable copy per pass: bridging the mutable storage string per line would copy the
        // whole document each time.
        let string = String(text)
        let start = min(range.location, text.length)
        let lines = text.paragraphRange(for: NSRange(location: start, length: min(range.length, text.length - start)))
        var inFence = fenceLine.numberOfMatches(in: string,
                                                range: NSRange(location: 0, length: lines.location)) % 2 == 1
        var location = lines.location
        let end = NSMaxRange(lines)
        while location < end {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location, [10, 13].contains(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
            let content = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            storage.setAttributes(baseAttributes(base, paragraph), range: lineRange)
            styleLine(storage, string: string, line: content, fonts: fonts, inFence: &inFence)
            location = NSMaxRange(lineRange)
        }
    }

    static func baseAttributes(_ font: NSFont, _ paragraph: NSParagraphStyle?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        if let paragraph { attrs[.paragraphStyle] = paragraph }
        return attrs
    }

    private static func styleLine(_ s: NSTextStorage, string: String, line: NSRange, fonts: Fonts, inFence: inout Bool) {
        let text = string as NSString
        let marker = Theme.markdownMarker

        // Fenced code blocks.
        if fenceLine.firstMatch(in: string, range: line) != nil {
            s.addAttributes([.font: fonts.code, .foregroundColor: marker, .backgroundColor: Theme.codeBackground], range: line)
            inFence.toggle()
            return
        }
        if inFence {
            s.addAttributes([.font: fonts.code, .backgroundColor: Theme.codeBackground], range: line)
            return
        }
        guard line.length > 0 else { return }

        // Horizontal rule.
        if rule.firstMatch(in: string, range: line) != nil {
            s.addAttribute(.foregroundColor, value: marker, range: line)
            return
        }

        var inlineRange = line

        // Heading.
        if let m = heading.firstMatch(in: string, range: line) {
            let level = m.range(at: 1).length
            s.addAttribute(.font, value: fonts.headings[level - 1], range: line)
            s.addAttribute(.foregroundColor, value: marker, range: m.range)
            inlineRange = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        } else {
            // Block quote (may contain a list item).
            if let m = quote.firstMatch(in: string, range: line) {
                s.addAttribute(.foregroundColor, value: marker, range: m.range)
                let rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
                s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: rest)
                inlineRange = rest
            }
            // List item, with an optional task checkbox.
            if let m = listItem.firstMatch(in: string, range: inlineRange) {
                s.addAttribute(.foregroundColor, value: Theme.markdownAccent, range: m.range(at: 2))
                let box = m.range(at: 4)
                var restStart = NSMaxRange(m.range)
                if box.location != NSNotFound {
                    let checked = text.substring(with: box).lowercased().contains("x")
                    s.addAttribute(.foregroundColor, value: Theme.markdownAccent, range: box)
                    restStart = NSMaxRange(box)
                    if checked {
                        let rest = NSRange(location: restStart, length: NSMaxRange(line) - restStart)
                        s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                         .foregroundColor: NSColor.secondaryLabelColor], range: rest)
                    }
                }
                inlineRange = NSRange(location: restStart, length: NSMaxRange(line) - restStart)
            }
        }
        styleInline(s, string: string, range: inlineRange, fonts: fonts)
    }

    private static func styleInline(_ s: NSTextStorage, string: String, range: NSRange, fonts: Fonts) {
        guard range.length > 0 else { return }
        let marker = Theme.markdownMarker
        var protected: [NSRange] = []   // code spans and link URLs: no emphasis inside
        func isProtected(_ r: NSRange) -> Bool { protected.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in codeSpan.matches(in: string, range: range) {
            let ticks = m.range(at: 1).length
            s.addAttributes([.font: fonts.code, .backgroundColor: Theme.codeBackground], range: m.range)
            s.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: ticks))
            s.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(m.range) - ticks, length: ticks))
            protected.append(m.range)
        }
        for m in link.matches(in: string, range: range) where !isProtected(m.range) {
            let isImage = m.range(at: 1).length > 0
            let textRange = m.range(at: 2)
            let url = (string as NSString).substring(with: m.range(at: 3))
            s.addAttribute(.foregroundColor, value: marker, range: m.range)
            if textRange.length > 0 {
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.linkColor, linkKey: url]
                if !isImage { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                s.addAttributes(attrs, range: textRange)
            }
            protected.append(NSRange(location: NSMaxRange(textRange), length: NSMaxRange(m.range) - NSMaxRange(textRange)))
        }
        for m in autolink.matches(in: string, range: range) where !isProtected(m.range) {
            s.addAttribute(.foregroundColor, value: marker, range: m.range)
            s.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                             linkKey: (string as NSString).substring(with: m.range(at: 1))], range: m.range(at: 1))
            protected.append(m.range)
        }

        func emphasize(_ regex: NSRegularExpression, markerLength: (NSTextCheckingResult) -> Int,
                       traits: NSFontTraitMask, extra: [NSAttributedString.Key: Any] = [:]) {
            for m in regex.matches(in: string, range: range) where !isProtected(m.range) {
                let len = markerLength(m)
                let inner = NSRange(location: m.range.location + len, length: m.range.length - 2 * len)
                guard inner.length > 0 else { continue }
                if !traits.isEmpty { addTraits(traits, to: s, range: inner) }
                if !extra.isEmpty { s.addAttributes(extra, range: inner) }
                s.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: len))
                s.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(m.range) - len, length: len))
            }
        }
        emphasize(boldItalic, markerLength: { _ in 3 }, traits: [.boldFontMask, .italicFontMask])
        emphasize(bold, markerLength: { _ in 2 }, traits: .boldFontMask)
        emphasize(italicStar, markerLength: { _ in 1 }, traits: .italicFontMask)
        emphasize(italicUnderscore, markerLength: { _ in 1 }, traits: .italicFontMask)
        emphasize(strike, markerLength: { _ in 2 }, traits: [],
                  extra: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
    }

    /// Adds bold/italic to whatever fonts are already in `range` (so bold inside a heading stays heading-sized).
    private static func addTraits(_ traits: NSFontTraitMask, to s: NSTextStorage, range: NSRange) {
        var runs: [(NSRange, NSFont)] = []
        s.enumerateAttribute(.font, in: range) { value, r, _ in
            if let font = value as? NSFont { runs.append((r, font)) }
        }
        let manager = NSFontManager.shared
        for (r, font) in runs {
            var styled = font
            if traits.contains(.boldFontMask) { styled = manager.convert(styled, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) {
                let italic = manager.convert(styled, toHaveTrait: .italicFontMask)
                // Fonts without an italic face: slant the glyphs instead.
                if manager.traits(of: italic).contains(.italicFontMask) {
                    styled = italic
                } else {
                    s.addAttribute(.obliqueness, value: 0.18, range: r)
                }
            }
            s.addAttribute(.font, value: styled, range: r)
        }
    }
}
