import Foundation

struct TabSnapshot: Codable {
    var id: UUID
    var filePath: String?
    var isDirty: Bool
    var hasBackup: Bool
    var encoding: TextEncodingKind
    var lineEnding: LineEnding
    /// Selected ranges as [location, length] pairs (UTF-16 offsets).
    var selections: [[Int]]
    /// Character offset of the first visible line (robust against layout estimates).
    var topOffset: Int
    var scrollX: Double
    var knownModificationDate: Date?
}

struct WindowSnapshot: Codable {
    var tabs: [TabSnapshot]
    var selectedID: UUID?
    var windowFrame: String?
}

struct SessionSnapshot: Codable {
    var version = 2
    /// Windows front to back is not tracked; `keyWindowIndex` says which one was active.
    var windows: [WindowSnapshot]?
    var keyWindowIndex: Int?
    // Version 1 (single window) fields, still read for upgrades.
    var tabs: [TabSnapshot]?
    var selectedID: UUID?
    var windowFrame: String?

    init(windows: [WindowSnapshot], keyWindowIndex: Int?) {
        self.windows = windows
        self.keyWindowIndex = keyWindowIndex
    }

    var allWindows: [WindowSnapshot] {
        if let windows { return windows }
        if let tabs { return [WindowSnapshot(tabs: tabs, selectedID: selectedID, windowFrame: windowFrame)] }
        return []
    }
}

/// Everything persisted between launches lives in ~/Library/Application Support/Better Notepad/:
///   session.json         – windows, tab order, selected tab, cursor/scroll state, window frames
///   Unsaved/<uuid>.txt   – autosaved contents of tabs with unsaved changes (UTF-8)
final class SessionStore: @unchecked Sendable {
    static let shared = SessionStore()

    let directory: URL
    let backupsDirectory: URL
    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private let queue = DispatchQueue(label: "BetterNotepad.autosave", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Better Notepad", isDirectory: true)
        // Earlier builds stored everything in "Mac Note"; carry it over once.
        let legacy = base.appendingPathComponent("Mac Note", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: dir.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BN_STORE_DIR"] {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        directory = dir
        backupsDirectory = directory.appendingPathComponent("Unsaved", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }

    func backupURL(for id: UUID) -> URL {
        backupsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("txt")
    }

    /// Writes a tab's text in the background (atomic write, so a crash never leaves a half file).
    func writeBackup(id: UUID, text: String) {
        let url = backupURL(for: id)
        queue.async {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Better Notepad: autosave failed for \(id): \(error)")
            }
        }
    }

    func removeBackup(id: UUID) {
        let url = backupURL(for: id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func readBackup(id: UUID) -> String? {
        try? String(contentsOf: backupURL(for: id), encoding: .utf8)
    }

    func save(_ session: SessionSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: sessionURL, options: .atomic)
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Blocks until all queued autosave writes are on disk.
    func flush() {
        queue.sync {}
    }

    func removeOrphanedBackups(keeping ids: Set<UUID>) {
        let dir = backupsDirectory
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                if let id = UUID(uuidString: name), ids.contains(id) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
