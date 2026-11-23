import SwiftUI

/// State shared between the window controller and the formatting toolbar.
@MainActor
final class MarkdownBarState: ObservableObject {
    @Published var previewVisible = false
    var onCommand: ((MarkdownCommand) -> Void)?
    var onTogglePreview: (() -> Void)?
    var onTurnOff: (() -> Void)?
}

/// Formatting toolbar shown above Markdown tabs, like the one in Windows 11 Notepad.
struct MarkdownToolbarView: View {
    @ObservedObject var state: MarkdownBarState

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Heading 1") { state.onCommand?(.heading(1)) }
                Button("Heading 2") { state.onCommand?(.heading(2)) }
                Button("Heading 3") { state.onCommand?(.heading(3)) }
                Divider()
                Button("Normal Text") { state.onCommand?(.heading(0)) }
            } label: {
                Label("Heading", systemImage: "textformat.size")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Heading (⌥⌘1–3, ⌥⌘0 for normal text)")
            .padding(.trailing, 4)

            divider
            button("bold", "Bold (⌘B)", .bold)
            button("italic", "Italic (⌘I)", .italic)
            button("strikethrough", "Strikethrough (⇧⌘X)", .strikethrough)
            button("chevron.left.forwardslash.chevron.right", "Code (⌘E)", .code)
            button("link", "Link (⌘K)", .link)
            divider
            button("list.bullet", "Bulleted List (⇧⌘8)", .bulletList)
            button("list.number", "Numbered List (⇧⌘7)", .numberedList)
            button("checklist", "Checklist (⇧⌘9)", .checklist)
            button("text.quote", "Quote (⇧⌘')", .quote)

            Spacer(minLength: 8)

            Button {
                state.onTogglePreview?()
            } label: {
                Label("Preview", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(state.previewVisible ? Color.accentColor.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.previewVisible ? Color.accentColor : Color.primary.opacity(0.8))
            .help("Show or hide the preview (⌥⌘P)")

            Button {
                state.onTurnOff?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Turn off Markdown formatting for this tab (⇧⌘M)")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.editorColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderColor).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.borderColor).frame(width: 1, height: 16).padding(.horizontal, 5)
    }

    private func button(_ symbol: String, _ help: String, _ command: MarkdownCommand) -> some View {
        Button {
            state.onCommand?(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle())
        .help(help)
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonBody(configuration: configuration)
    }
}

private struct ToolbarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(0.85))
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(configuration.isPressed ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.07) : .clear)))
            .onHover { hovering = $0 }
    }
}
