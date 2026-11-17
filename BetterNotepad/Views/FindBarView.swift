import SwiftUI

@MainActor
final class FindState: ObservableObject {
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var matchCase = false
    @Published var wholeWord = false
    @Published var showReplace = false
    @Published var message = ""
    /// Incremented to move keyboard focus into the find field.
    @Published var focusToken = 0

    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?
}

struct FindBarView: View {
    @ObservedObject var state: FindState
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    state.showReplace.toggle()
                } label: {
                    Image(systemName: state.showReplace ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help("Toggle Replace (⌥⌘F)")

                TextField("Find", text: $state.findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, idealWidth: 260, maxWidth: 320)
                    .focused($findFocused)
                    .onSubmit { state.onFindNext?() }
                    .onExitCommand { state.onClose?() }

                Button { state.onFindPrevious?() } label: { Image(systemName: "chevron.up") }
                    .help("Find Previous (⇧⌘G)")
                Button { state.onFindNext?() } label: { Image(systemName: "chevron.down") }
                    .help("Find Next (⌘G)")

                Toggle("Match case", isOn: $state.matchCase)
                    .toggleStyle(.checkbox)
                Toggle("Whole word", isOn: $state.wholeWord)
                    .toggleStyle(.checkbox)

                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button { state.onClose?() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            if state.showReplace {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 14, height: 1)
                    TextField("Replace", text: $state.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, idealWidth: 260, maxWidth: 320)
                        .onSubmit { state.onReplace?() }
                        .onExitCommand { state.onClose?() }
                    Button("Replace") { state.onReplace?() }
                    Button("Replace All") { state.onReplaceAll?() }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.editorColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderColor).frame(height: 1) }
        .onChange(of: state.focusToken) { _, _ in findFocused = true }
        .onAppear { findFocused = true }
    }
}
