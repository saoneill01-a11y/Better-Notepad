import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var defaultAppMessage = ""

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
                Toggle("Show line numbers", isOn: $prefs.showLineNumbers)
                Toggle("Word wrap", isOn: $prefs.wordWrap)
                Stepper(value: $prefs.zoomPercent, in: 10...500, step: 10) {
                    Text("Zoom: \(prefs.zoomPercent)%")
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
        .frame(width: 560, height: 520)
    }

    private func setAsDefault() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .plainText) { error in
            let text = error.map { "Failed: \($0.localizedDescription)" } ?? "Done."
            DispatchQueue.main.async { defaultAppMessage = text }
        }
    }
}
