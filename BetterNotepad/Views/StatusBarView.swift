import SwiftUI

@MainActor
final class StatusModel: ObservableObject {
    @Published var position = "Ln 1, Col 1"
    @Published var selection = ""
    @Published var lines = "1 line"
    @Published var characters = "0 characters"
    @Published var zoom = "100%"
    @Published var lineEnding = LineEnding.lf.displayName
    @Published var encoding = TextEncodingKind.utf8.displayName
}

struct StatusBarView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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
                cell(model.lineEnding)
                separator
                cell(model.encoding)
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
    }

    private var separator: some View {
        Divider().frame(height: 12)
    }
}
