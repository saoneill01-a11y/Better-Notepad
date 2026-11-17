import AppKit
import Combine

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let fontName = "EditorFontName"
        static let fontSize = "EditorFontSize"
        static let zoom = "ZoomPercent"
        static let wordWrap = "WordWrap"
        static let lineNumbers = "ShowLineNumbers"
        static let autosaveToFile = "AutosaveToFile"
    }

    private let defaults = UserDefaults.standard

    /// PostScript font name; empty means the system monospaced font (SF Mono).
    @Published var fontName: String { didSet { defaults.set(fontName, forKey: Keys.fontName) } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    @Published var zoomPercent: Int { didSet { defaults.set(zoomPercent, forKey: Keys.zoom) } }
    @Published var wordWrap: Bool { didSet { defaults.set(wordWrap, forKey: Keys.wordWrap) } }
    @Published var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Keys.lineNumbers) } }
    @Published var autosaveToFile: Bool { didSet { defaults.set(autosaveToFile, forKey: Keys.autosaveToFile) } }

    private init() {
        defaults.register(defaults: [
            Keys.fontName: "",
            Keys.fontSize: 13.0,
            Keys.zoom: 100,
            Keys.wordWrap: true,
            Keys.lineNumbers: false,
            Keys.autosaveToFile: false,
        ])
        fontName = defaults.string(forKey: Keys.fontName) ?? ""
        fontSize = defaults.double(forKey: Keys.fontSize)
        zoomPercent = defaults.integer(forKey: Keys.zoom)
        wordWrap = defaults.bool(forKey: Keys.wordWrap)
        showLineNumbers = defaults.bool(forKey: Keys.lineNumbers)
        autosaveToFile = defaults.bool(forKey: Keys.autosaveToFile)
        if fontSize < 4 { fontSize = 13 }
        if zoomPercent < 10 || zoomPercent > 500 { zoomPercent = 100 }
    }

    /// Font at 100% zoom.
    var baseFont: NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Font actually used in the editor (base font scaled by zoom).
    var editorFont: NSFont {
        let base = baseFont
        let size = max(4, (CGFloat(fontSize) * CGFloat(zoomPercent) / 100).rounded())
        return NSFont(descriptor: base.fontDescriptor, size: size) ?? base
    }

    func setBaseFont(_ font: NSFont) {
        // System UI fonts have private names (".AppleSystemUIFontMonospaced…") that can't be looked up later.
        fontName = font.fontName.hasPrefix(".") ? "" : font.fontName
        fontSize = Double(font.pointSize)
    }
}
