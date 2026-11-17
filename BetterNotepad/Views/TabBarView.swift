import SwiftUI
import UniformTypeIdentifiers

/// Ordered list of tabs shown in the window. The window controller owns the behaviour.
@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [EditorTab] = []
    @Published var selectedID: UUID?
    var draggingID: UUID?
    /// True while another window is being dragged over this window's tab bar (drop merges it here).
    @Published var isMergeTarget = false
    /// Screen point where the last tab drag ended (used to place a torn-off window).
    var lastDropPoint: NSPoint?
    weak var controller: MainWindowController?

    var selectedTab: EditorTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    func select(_ id: UUID) { controller?.selectTab(id: id) }
    func close(_ id: UUID) { controller?.requestCloseTab(id: id) }
    func newTab() { controller?.newTab(nil) }
    func moveToNewWindow(_ id: UUID) { controller?.moveTabToNewWindow(id: id) }


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
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(manager.tabs) { tab in
                        TabItemView(tab: tab, isSelected: tab.id == manager.selectedID, manager: manager)
                            .id(tab.id)
                            .onDrop(of: [.betterNotepadTab], delegate: TabDropDelegate(target: tab.id, manager: manager))
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
                    .padding(.bottom, 3)
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            // Empty part of the bar: accepts tabs dragged in from another window.
            .onDrop(of: [.betterNotepadTab], delegate: TabDropDelegate(target: nil, manager: manager))
            .onChange(of: manager.selectedID) { _, newValue in
                if let newValue {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue) }
                }
            }
        }
        .overlay {
            if manager.isMergeTarget {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .background(alignment: .bottom) {
            // Page border; the selected tab is drawn over it so it joins the page below.
            ZStack(alignment: .bottom) {
                Theme.chromeColor
                Rectangle().fill(Theme.borderColor).frame(height: 1)
            }
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    /// The tab this delegate sits on, or nil for the empty part of the bar.
    let target: UUID?
    let manager: TabManager

    func dropEntered(info: DropInfo) {
        guard let dragged = manager.draggingID, let target else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            manager.move(dragged, onto: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Tabs from another window are moved when the drag ends (TabDragView.finishDrag).
        if manager.draggingID != nil { manager.dragEnded() }
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
        .frame(width: 190, height: 30)
        .padding(.bottom, 3)
        .background(alignment: .bottom) {
            if isSelected {
                // Fills down to the bar's bottom edge, covering the page border there.
                let shape = UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
                shape.fill(Theme.editorColor)
                    .overlay(shape.strokeBorder(Theme.borderColor, lineWidth: 1).padding(.bottom, -1))
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Theme.tabHoverColor : Color.clear)
                    .padding(.bottom, 3)
            }
        }
        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.8))
        // Click, drag and right-click are handled in AppKit (see TabDragHandle); the close button
        // on the right stays uncovered so SwiftUI keeps handling it.
        .overlay(alignment: .leading) {
            TabDragHandle(tabID: tab.id, manager: manager, toolTip: tab.fileURL?.path ?? tab.title)
                .padding(.trailing, 28)
                .padding(.bottom, 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
