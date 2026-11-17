import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Pasteboard type for a tab being dragged between tab bars (declared in Info.plist).
    static let betterNotepadTab = UTType(exportedAs: "com.csioly.betternotepad.tab")
}

extension NSPasteboard.PasteboardType {
    static let betterNotepadTab = NSPasteboard.PasteboardType(UTType.betterNotepadTab.identifier)
}

/// File promise for a dragged tab, plus the tab's ID in our private type so tab bars can reorder
/// or adopt it. Finder and the Desktop only see the promised .txt file.
final class TabFilePromiseProvider: NSFilePromiseProvider {
    var tabID: UUID?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.betterNotepadTab] + super.writableTypes(for: pasteboard)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .betterNotepadTab ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .betterNotepadTab { return tabID?.uuidString.data(using: .utf8) }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Transparent AppKit view laid over a tab (except its close button). It selects the tab on click,
/// starts an AppKit drag session when the mouse moves, and shows the tab's context menu.
/// An AppKit drag is used because it reports where and how the drag ended, which SwiftUI's
/// `onDrag` does not: dropped on nothing → the tab opens in a new window there;
/// dropped on Finder or the Desktop → a .txt file named after the first line (or Ask, per Settings).
struct TabDragHandle: NSViewRepresentable {
    let tabID: UUID
    let manager: TabManager
    let toolTip: String

    func makeNSView(context: Context) -> TabDragView {
        let view = TabDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TabDragView, context: Context) {
        view.tabID = tabID
        view.manager = manager
        view.toolTip = toolTip
    }
}

final class TabDragView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var tabID = UUID()
    weak var manager: TabManager?
    private var mouseDownEvent: NSEvent?
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.underlyingQueue = .main
        return queue
    }()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        manager?.select(tabID)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        mouseDownEvent = nil
        startDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let manager else { return nil }
        let menu = NSMenu()
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        let move = NSMenuItem(title: "Move Tab to New Window", action: #selector(moveToNewWindow(_:)), keyEquivalent: "")
        move.target = self
        move.isEnabled = manager.tabs.count > 1
        menu.autoenablesItems = false
        menu.addItem(move)
        return menu
    }

    @objc private func closeTab(_ sender: Any?) { manager?.close(tabID) }
    @objc private func moveToNewWindow(_ sender: Any?) { manager?.moveToNewWindow(tabID) }

    // MARK: Dragging

    private func startDrag(with event: NSEvent) {
        guard let manager, manager.tabs.contains(where: { $0.id == tabID }) else { return }
        let provider = TabFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: self)
        provider.tabID = tabID
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: snapshot())
        manager.draggingID = tabID
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// Picture of the whole tab (this view only covers it, so render the hosting view's area).
    private func snapshot() -> NSImage {
        guard let host = superview else { return NSImage(size: bounds.size) }
        var root: NSView = host
        while let parent = root.superview, !(root is NSHostingView<TabBarView>) { root = parent }
        let tabRect = convert(bounds, to: root).insetBy(dx: 0, dy: 0)
        let fullTab = NSRect(x: tabRect.minX, y: tabRect.minY, width: tabRect.width + 26, height: tabRect.height)
            .intersection(root.bounds)
        guard let rep = root.bitmapImageRepForCachingDisplay(in: fullTab) else { return NSImage(size: bounds.size) }
        root.cacheDisplay(in: fullTab, to: rep)
        let image = NSImage(size: fullTab.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let source = manager?.controller else { return }
        AppDelegate.shared.highlightTabDropTarget(at: screenPoint, source: source)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        TabDragView.finishDrag(tabID: tabID, manager: manager, at: screenPoint, operation: operation)
    }

    /// Where a tab drag ended decides what happens (separate from the session so it can be tested).
    static func finishDrag(tabID id: UUID, manager: TabManager?, at screenPoint: NSPoint, operation: NSDragOperation) {
        guard let manager, let source = manager.controller else { return }
        let app = AppDelegate.shared
        manager.lastDropPoint = screenPoint
        manager.dragEnded()
        app.highlightTabDropTarget(at: nil, source: source)
        if let target = app.tabDropTarget(at: screenPoint, source: source) {
            // Over another window's title or tab bar: move the tab there, at the drop position.
            app.moveTab(id: id, to: target, at: target.tabInsertionIndex(forScreenPoint: screenPoint))
        } else if operation == [], !app.isPointInsideAppWindow(screenPoint) {
            // Nothing accepted the drop and it landed outside every window: tear the tab off.
            source.tearOffTab(id: id, at: screenPoint)
        }
    }

    // MARK: File promise (Finder / Desktop)

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        manager?.controller?.suggestedFileName(forTabID: tabID) ?? "Untitled.txt"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let id = tabID
        MainActor.assumeIsolated {
            guard let controller = manager?.controller else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            controller.handleTabDroppedAsFile(id: id, destination: url, completion: completionHandler)
        }
    }
}
