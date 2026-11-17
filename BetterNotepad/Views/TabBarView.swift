import SwiftUI
import UniformTypeIdentifiers

/// Ordered list of tabs shown in the window. The window controller owns the behaviour.
@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [EditorTab] = []
    @Published var selectedID: UUID?
    var draggingID: UUID?
    weak var controller: MainWindowController?

    var selectedTab: EditorTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    func select(_ id: UUID) { controller?.selectTab(id: id) }
    func close(_ id: UUID) { controller?.requestCloseTab(id: id) }
    func newTab() { controller?.newTab(nil) }

    func move(_ dragged: UUID, onto target: UUID) {
        guard dragged != target,
              let from = tabs.firstIndex(where: { $0.id == dragged }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func dragEnded() {
        draggingID = nil
        controller?.scheduleSessionSave()
    }
}

struct TabBarView: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(manager.tabs) { tab in
                        TabItemView(tab: tab, isSelected: tab.id == manager.selectedID, manager: manager)
                            .id(tab.id)
                            .onDrag {
                                manager.draggingID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: TabDropDelegate(target: tab.id, manager: manager))
                    }
                    Button {
                        manager.newTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Tab (⌘T)")
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
            }
            .onChange(of: manager.selectedID) { _, newValue in
                if let newValue {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let manager: TabManager

    func dropEntered(info: DropInfo) {
        guard let dragged = manager.draggingID else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            manager.move(dragged, onto: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        manager.dragEnded()
        return true
    }
}

private struct TabItemView: View {
    @ObservedObject var tab: EditorTab
    let isSelected: Bool
    let manager: TabManager
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            ZStack {
                if tab.isDirty && !hovering {
                    Circle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes")
                } else if hovering || isSelected {
                    Button {
                        manager.close(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(hoveringClose ? Color.primary.opacity(0.12) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringClose = $0 }
                    .help("Close Tab (⌘W)")
                }
            }
            .frame(width: 18, height: 18)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 190, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color(nsColor: .textBackgroundColor)
                      : (hovering ? Color.primary.opacity(0.06) : Color.clear))
                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { manager.select(tab.id) }
        .help(tab.fileURL?.path ?? tab.title)
    }
}
