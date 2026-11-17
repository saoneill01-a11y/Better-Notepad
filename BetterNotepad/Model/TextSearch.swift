import Foundation

enum TextSearch {
    private static let wordCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_")
        return set
    }()

    static func isWordCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return wordCharacters.contains(scalar)
    }

    static func isWholeWord(_ r: NSRange, in s: NSString) -> Bool {
        if r.location > 0, isWordCharacter(s.character(at: r.location - 1)) { return false }
        let end = NSMaxRange(r)
        if end < s.length, isWordCharacter(s.character(at: end)) { return false }
        return true
    }

    /// Finds the next (or previous) match starting at `from`, wrapping around the document.
    static func find(_ term: String, in text: NSString, from: Int, forward: Bool,
                     matchCase: Bool, wholeWord: Bool, wrap: Bool = true) -> NSRange? {
        let length = text.length
        guard !term.isEmpty, length > 0 else { return nil }
        var options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        if !forward { options.insert(.backwards) }

        func search(_ range: NSRange) -> NSRange? {
            var r = range
            while r.length > 0 {
                let found = text.range(of: term, options: options, range: r)
                if found.location == NSNotFound { return nil }
                if !wholeWord || isWholeWord(found, in: text) { return found }
                if forward {
                    let next = found.location + 1
                    r = NSRange(location: next, length: NSMaxRange(range) - next)
                } else {
                    r = NSRange(location: range.location, length: NSMaxRange(found) - 1 - range.location)
                }
            }
            return nil
        }

        let start = max(0, min(from, length))
        if forward {
            if let r = search(NSRange(location: start, length: length - start)) { return r }
        } else {
            if let r = search(NSRange(location: 0, length: start)) { return r }
        }
        return wrap ? search(NSRange(location: 0, length: length)) : nil
    }

    static func regex(for term: String, matchCase: Bool, wholeWord: Bool) -> NSRegularExpression? {
        guard !term.isEmpty else { return nil }
        var pattern = NSRegularExpression.escapedPattern(for: term)
        if wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])" + pattern + "(?![\\p{L}\\p{N}_])"
        }
        return try? NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    }
}
