import AppKit
import Combine

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// What happens when a tab is dropped on Finder or the Desktop.
enum TabDropAction: String, CaseIterable, Identifiable {
    case ask, saveFile, newWindow
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .saveFile: return "Save a .txt file there"
        case .newWindow: return "Open the tab in a new window"
        }
    }
}

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
        static let keyRepeat = "KeyRepeat"
        static let appearance = "AppearanceMode"
        static let spellCheck = "SpellCheck"
        static let tabDropAction = "TabDropAction"
        static let markdownForMarkdownFiles = "MarkdownForMarkdownFiles"
        static let markdownPreviewByDefault = "MarkdownPreviewByDefault"
        static let showMarkdownToolbar = "ShowMarkdownToolbar"
        /// System key: when true, holding a key shows the accent picker instead of repeating.
        static let pressAndHold = "ApplePressAndHoldEnabled"
    }

    private let defaults = UserDefaults.standard

    /// PostScript font name; empty means the system monospaced font (SF Mono).
    @Published var fontName: String { didSet { defaults.set(fontName, forKey: Keys.fontName) } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    @Published var zoomPercent: Int { didSet { defaults.set(zoomPercent, forKey: Keys.zoom) } }
    @Published var wordWrap: Bool { didSet { defaults.set(wordWrap, forKey: Keys.wordWrap) } }
    @Published var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Keys.lineNumbers) } }
    @Published var autosaveToFile: Bool { didSet { defaults.set(autosaveToFile, forKey: Keys.autosaveToFile) } }
    @Published var spellCheck: Bool { didSet { defaults.set(spellCheck, forKey: Keys.spellCheck) } }
    /// Holding a letter repeats it (true) or shows the accent picker (false).
    @Published var keyRepeat: Bool {
        didSet {
            defaults.set(keyRepeat, forKey: Keys.keyRepeat)
            applyKeyRepeat()
        }
    }
    /// .md / .markdown files open with Markdown formatting.
    @Published var markdownForMarkdownFiles: Bool { didSet { defaults.set(markdownForMarkdownFiles, forKey: Keys.markdownForMarkdownFiles) } }
    /// Markdown files open with the preview pane showing.
    @Published var markdownPreviewByDefault: Bool { didSet { defaults.set(markdownPreviewByDefault, forKey: Keys.markdownPreviewByDefault) } }
    /// The formatting toolbar shows above Markdown tabs.
    @Published var showMarkdownToolbar: Bool { didSet { defaults.set(showMarkdownToolbar, forKey: Keys.showMarkdownToolbar) } }
    @Published var tabDropAction: TabDropAction {
        didSet { defaults.set(tabDropAction.rawValue, forKey: Keys.tabDropAction) }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    private init() {
        defaults.register(defaults: [
            Keys.fontName: "",
            Keys.fontSize: 13.0,
            Keys.zoom: 100,
            Keys.wordWrap: true,
            Keys.lineNumbers: false,
            Keys.autosaveToFile: false,
            Keys.keyRepeat: true,
            Keys.appearance: AppearanceMode.system.rawValue,
            Keys.spellCheck: false,
            Keys.tabDropAction: TabDropAction.ask.rawValue,
            Keys.markdownForMarkdownFiles: true,
            Keys.markdownPreviewByDefault: false,
            Keys.showMarkdownToolbar: true,
        ])
        fontName = defaults.string(forKey: Keys.fontName) ?? ""
        fontSize = defaults.double(forKey: Keys.fontSize)
        zoomPercent = defaults.integer(forKey: Keys.zoom)
        wordWrap = defaults.bool(forKey: Keys.wordWrap)
        showLineNumbers = defaults.bool(forKey: Keys.lineNumbers)
        autosaveToFile = defaults.bool(forKey: Keys.autosaveToFile)
        keyRepeat = defaults.bool(forKey: Keys.keyRepeat)
        spellCheck = defaults.bool(forKey: Keys.spellCheck)
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        markdownForMarkdownFiles = defaults.bool(forKey: Keys.markdownForMarkdownFiles)
        markdownPreviewByDefault = defaults.bool(forKey: Keys.markdownPreviewByDefault)
        showMarkdownToolbar = defaults.bool(forKey: Keys.showMarkdownToolbar)
        tabDropAction = TabDropAction(rawValue: defaults.string(forKey: Keys.tabDropAction) ?? "") ?? .ask
        if fontSize < 4 { fontSize = 13 }
        if zoomPercent < 10 || zoomPercent > 500 { zoomPercent = 100 }
        applyKeyRepeat()
    }

    /// Stored in the app's own defaults domain, so it only affects Better Notepad.
    /// AppKit reads it when the app starts, so a change applies after reopening the app.
    private func applyKeyRepeat() {
        defaults.set(!keyRepeat, forKey: Keys.pressAndHold)
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
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

    /// Version 1.0 used the bundle ID com.betternotepad.BetterNotepad. Copy its settings
    /// (font, zoom, recent files, …) into the new ID's defaults once, without overwriting anything.
    static func migrateLegacyDefaults() {
        let marker = "MigratedLegacyDefaults"
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: marker) else { return }
        if let old = standard.persistentDomain(forName: "com.betternotepad.BetterNotepad") {
            let current = Bundle.main.bundleIdentifier.flatMap { standard.persistentDomain(forName: $0) } ?? [:]
            for (key, value) in old where current[key] == nil {
                standard.set(value, forKey: key)
            }
        }
        standard.set(true, forKey: marker)
    }
}
