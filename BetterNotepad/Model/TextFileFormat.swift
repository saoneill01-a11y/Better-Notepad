import Foundation

/// Line ending style of a file. Inside the editor text is always normalized to "\n";
/// the original style is re-applied when saving.
enum LineEnding: String, Codable, CaseIterable {
    case lf, crlf, cr

    var displayName: String {
        switch self {
        case .lf: return "Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return "Macintosh (CR)"
        }
    }

    var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// Encodings Better Notepad can read and write back unchanged.
enum TextEncodingKind: String, Codable, CaseIterable {
    case utf8, utf8BOM, utf16LE, utf16BE, windows1252, latin1

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 with BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .windows1252: return "Windows-1252"
        case .latin1: return "ISO Latin 1"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        }
    }

    /// True if every character of `text` can be stored in this encoding.
    func canEncode(_ text: NSString) -> Bool {
        switch self {
        case .utf8, .utf8BOM, .utf16LE, .utf16BE: return true
        default: return text.canBeConverted(to: stringEncoding.rawValue)
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }
}

struct DecodedText {
    let text: String
    let encoding: TextEncodingKind
    let lineEnding: LineEnding
}

enum TextFileCodec {
    static func decode(_ data: Data) -> DecodedText {
        let head = [UInt8](data.prefix(3))
        var kind: TextEncodingKind
        var text: String?

        if head.count >= 3, head[0] == 0xEF, head[1] == 0xBB, head[2] == 0xBF {
            kind = .utf8BOM
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if head.count >= 2, head[0] == 0xFF, head[1] == 0xFE {
            kind = .utf16LE
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if head.count >= 2, head[0] == 0xFE, head[1] == 0xFF {
            kind = .utf16BE
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            kind = .utf8
            text = String(data: data, encoding: .utf8)
        }

        if text == nil {
            if let t = String(data: data, encoding: .windowsCP1252) {
                kind = .windows1252
                text = t
            } else {
                kind = .latin1
                text = String(data: data, encoding: .isoLatin1) ?? ""
            }
        }

        let raw = text ?? ""
        return DecodedText(text: normalizeLineEndings(raw), encoding: kind, lineEnding: detectLineEnding(raw))
    }

    static func encode(_ text: String, encoding: TextEncodingKind, lineEnding: LineEnding) -> Data? {
        let body = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.sequence)
        guard let data = body.data(using: encoding.stringEncoding, allowLossyConversion: false) else { return nil }
        if encoding.bom.isEmpty { return data }
        var out = Data(encoding.bom)
        out.append(data)
        return out
    }

    /// The first line break found decides the file's style.
    static func detectLineEnding(_ s: String) -> LineEnding {
        var it = s.utf8.makeIterator()
        while let b = it.next() {
            if b == 10 { return .lf }
            if b == 13 { return it.next() == 10 ? .crlf : .cr }
        }
        return .lf
    }

    static func normalizeLineEndings(_ s: String) -> String {
        guard s.utf8.contains(13) else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
