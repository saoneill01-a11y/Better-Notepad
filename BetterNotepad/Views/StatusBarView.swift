import SwiftUI

@MainActor
final class StatusModel: ObservableObject {
    @Published var position = "Ln 1, Col 1"
    @Published var selection = ""
    @Published var lines = "1 line"
    @Published var characters = "0 characters"
    @Published var zoom = "100%"
    @Published var lineEnding = LineEnding.lf
    @Published var encoding = TextEncodingKind.utf8
    @Published var isMarkdown = false
    var onChooseMarkdown: ((Bool) -> Void)?

    var onChooseLineEnding: ((LineEnding) -> Void)?
    var onChooseEncoding: ((TextEncodingKind) -> Void)?
}

struct StatusBarView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.borderColor).frame(height: 1)
            HStack(spacing: 0) {
                cell(model.position)
                if !model.selection.isEmpty {
                    separator
                    cell(model.selection)
                }
                Spacer(minLength: 8)
                cell(model.lines)
                separator
                cell(model.characters)
                separator
                cell(model.zoom)
                separator
                Menu {
                    Picker("Format", selection: Binding(
                        get: { model.isMarkdown },
                        set: { model.onChooseMarkdown?($0) })) {
                        Text("Plain Text").tag(false)
                        Text("Markdown").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.isMarkdown ? "Markdown" : "Plain Text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .help("Show this tab as plain text or with Markdown formatting (⇧⌘M)")
                separator
                Menu {
                    Picker("Line Endings", selection: Binding(
                        get: { model.lineEnding },
                        set: { model.onChooseLineEnding?($0) })) {
                        ForEach(LineEnding.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.lineEnding.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .help("Line endings used when saving")
                separator
                Menu {
                    Picker("Encoding", selection: Binding(
                        get: { model.encoding },
                        set: { model.onChooseEncoding?($0) })) {
                        ForEach(TextEncodingKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.encoding.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .help("Text encoding used when saving")
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .background(Theme.chromeColor)
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
    }

    private var separator: some View {
        Rectangle().fill(Theme.borderColor).frame(width: 1, height: 12)
    }
}
