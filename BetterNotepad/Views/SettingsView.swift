import SwiftUI
import UniformTypeIdentifiers
import Sparkle

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    let updater: SPUUpdater
    @State private var defaultAppMessage = ""
    @State private var autoCheckUpdates = false

    private static let monospacedFonts: [(name: String, display: String)] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        var result: [(String, String)] = []
        for name in names {
            guard let font = NSFont(name: name, size: 12) else { continue }
            let traits = manager.traits(of: font)
            if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) { continue }
            result.append((name, font.displayName ?? name))
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }()

    var body: some View {
        Form {
            Section("Saving") {
                Toggle("Autosave directly to the file for tabs that are saved on disk", isOn: $prefs.autosaveToFile)
                Text("When off, unsaved edits are kept safely in ~/Library/Application Support/Better Notepad/ and the real file is only written when you press ⌘S. Untitled tabs are always autosaved there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Editor Font") {
                Picker("Font", selection: $prefs.fontName) {
                    Text("System Monospaced (SF Mono)").tag("")
                    if !prefs.fontName.isEmpty && !Self.monospacedFonts.contains(where: { $0.name == prefs.fontName }) {
                        Text(NSFont(name: prefs.fontName, size: 12)?.displayName ?? prefs.fontName).tag(prefs.fontName)
                    }
                    ForEach(Self.monospacedFonts, id: \.name) { font in
                        Text(font.display).tag(font.name)
                    }
                }
                Stepper(value: $prefs.fontSize, in: 6...72, step: 1) {
                    Text("Size: \(Int(prefs.fontSize)) pt")
                }
                HStack {
                    Text("The quick brown fox jumps over the lazy dog 0123456789")
                        .font(Font(prefs.baseFont))
                        .lineLimit(1)
                    Spacer()
                    Button("Font Panel…") {
                        NSFontManager.shared.setSelectedFont(prefs.baseFont, isMultiple: false)
                        NSFontManager.shared.orderFrontFontPanel(nil)
                    }
                }
            }

            Section("View") {
                Picker("Appearance", selection: $prefs.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show line numbers", isOn: $prefs.showLineNumbers)
                Toggle("Word wrap", isOn: $prefs.wordWrap)
                Toggle("Check spelling while typing", isOn: $prefs.spellCheck)
                Stepper(value: $prefs.zoomPercent, in: 10...500, step: 10) {
                    Text("Zoom: \(prefs.zoomPercent)%")
                }
            }

            Section("Markdown") {
                Toggle("Open .md files with Markdown formatting", isOn: $prefs.markdownForMarkdownFiles)
                Toggle("Show the preview beside Markdown files", isOn: $prefs.markdownPreviewByDefault)
                Toggle("Show the formatting toolbar", isOn: $prefs.showMarkdownToolbar)
                Text("Markdown files stay plain text: formatting only changes how they look here. Any tab can switch between Plain Text and Markdown from the status bar or with ⇧⌘M; ⌥⌘P shows the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Tabs") {
                Picker("Dragging a tab to Finder or the Desktop", selection: $prefs.tabDropAction) {
                    ForEach(TabDropAction.allCases) { Text($0.title).tag($0) }
                }
                Text("Dropping a tab anywhere else outside the window always opens it in a new window. Saved files are named after the tab’s first line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Typing") {
                Toggle("Holding a key repeats it", isOn: $prefs.keyRepeat)
                Text("When off, holding a letter shows accented characters (é, ñ, ü) instead. Applies after you quit and reopen Better Notepad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, value in updater.automaticallyChecksForUpdates = value }
                HStack {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Default App") {
                HStack {
                    Button("Make Better Notepad the Default App for .txt Files") {
                        setAsDefault()
                    }
                    Text(defaultAppMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 820)
        .onAppear { autoCheckUpdates = updater.automaticallyChecksForUpdates }
    }

    private func setAsDefault() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .plainText) { error in
            let text = error.map { "Failed: \($0.localizedDescription)" } ?? "Done."
            DispatchQueue.main.async { defaultAppMessage = text }
        }
    }
}
