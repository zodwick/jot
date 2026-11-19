import AppKit
import UniformTypeIdentifiers

/// Owns the single page on disk: ~/Library/Application Support/Jot/page.md
/// plus an attachments/ folder for pasted files, and a small rolling backup.
final class Store {
    static let shared = Store()

    let directory: URL
    let pageURL: URL
    let attachmentsURL: URL
    private let backupsURL: URL

    private var pendingSave: DispatchWorkItem?
    private var lastSavedText: String?
    private let ioQueue = DispatchQueue(label: "jot.store", qos: .utility)

    private init() {
        if let override = ProcessInfo.processInfo.environment["JOT_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)   // for testing
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("Jot", isDirectory: true)
        }
        pageURL = directory.appendingPathComponent("page.md")
        attachmentsURL = directory.appendingPathComponent("attachments", isDirectory: true)
        backupsURL = directory.appendingPathComponent("backups", isDirectory: true)
        for dir in [directory, attachmentsURL, backupsURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Single writer

    private var lockFD: Int32 = -1

    /// Takes an exclusive lock on the data folder for this process's lifetime
    /// (released automatically when it exits, even on a crash). Returns false if
    /// another Jot already holds it: two copies editing one page.md would
    /// overwrite each other's changes.
    func acquireLock() -> Bool {
        if lockFD >= 0 { return true }
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }   // can't lock (odd filesystem): don't block launching
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    // MARK: Page

    func load() -> String {
        let text = (try? String(contentsOf: pageURL, encoding: .utf8)) ?? ""
        lastSavedText = text
        rollBackupIfNeeded()
        return text
    }

    /// Debounced save; call on every edit.
    func scheduleSave(_ text: @escaping () -> String) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow(text()) }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Synchronous save (used on quit / deactivate).
    func flush(_ text: String) {
        pendingSave?.cancel()
        pendingSave = nil
        guard text != lastSavedText else { return }
        lastSavedText = text
        try? text.write(to: pageURL, atomically: true, encoding: .utf8)
    }

    private func saveNow(_ text: String) {
        guard text != lastSavedText else { return }
        lastSavedText = text
        let url = pageURL
        ioQueue.async { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Keeps one copy of the page per day for the last 7 days, so an
    /// accidental select-all + delete + quit is recoverable.
    private func rollBackupIfNeeded() {
        guard FileManager.default.fileExists(atPath: pageURL.path) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let todays = backupsURL.appendingPathComponent("page-\(fmt.string(from: Date())).md")
        if !FileManager.default.fileExists(atPath: todays.path) {
            try? FileManager.default.copyItem(at: pageURL, to: todays)
        }
        let all = (try? FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
        for old in all.filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(7) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: Attachments

    /// Copies a file into attachments/ and returns its page-relative path.
    func importFile(_ source: URL) -> String? {
        let name = uniqueName(base: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
        let dest = attachmentsURL.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return "attachments/\(name)"
        } catch {
            NSLog("Jot: failed to import \(source.path): \(error)")
            return nil
        }
    }

    /// Writes raw data (e.g. a pasted screenshot) into attachments/.
    func importData(_ data: Data, ext: String, base: String = "image") -> String? {
        let name = uniqueName(base: base, ext: ext)
        do {
            try data.write(to: attachmentsURL.appendingPathComponent(name))
            return "attachments/\(name)"
        } catch {
            return nil
        }
    }

    func resolve(_ relativePath: String) -> URL {
        if relativePath.hasPrefix("/") { return URL(fileURLWithPath: relativePath) }
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        return directory.appendingPathComponent(decoded)
    }

    private func uniqueName(base: String, ext: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let safeBase = base.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let stamp = fmt.string(from: Date())
        var candidate = ext.isEmpty ? "\(safeBase)-\(stamp)" : "\(safeBase)-\(stamp).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: attachmentsURL.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(safeBase)-\(stamp)-\(n)" : "\(safeBase)-\(stamp)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
