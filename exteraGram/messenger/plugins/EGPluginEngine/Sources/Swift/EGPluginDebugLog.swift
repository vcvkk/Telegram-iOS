// MARK: exteraGram — in-memory + on-disk plugin debug log buffer

import Foundation

/// Thread-safe ring buffer of recent plugin system log entries.
/// Written by EGLoggerBridge, EGPluginRuntime, and EGPluginsEngineImpl.
/// Observed by EGPluginDebugController (via EGPluginDebugLog.changed notification).
///
/// Crash breadcrumbs: each `append` is also flushed to disk asynchronously.
/// Call `markCleanExit()` on graceful shutdown. On next launch, `loadCrashBreadcrumbs()`
/// checks if the previous log file ended cleanly — if not, the previous entries are
/// exposed as `crashBreadcrumbs` so the debug UI can display them.
public final class EGPluginDebugLog {
    public static let shared = EGPluginDebugLog()

    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let tag: String
        public let message: String

        public init(tag: String, message: String) {
            self.id = UUID()
            self.timestamp = Date()
            self.tag = tag
            self.message = message
        }

        public var formattedTimestamp: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: timestamp)
        }
    }

    public static let changed = Notification.Name("app.exteragram.ios.pluginDebugLogChanged")

    private let lock = NSLock()
    private var _entries: [Entry] = []
    private let maxEntries = 500

    // Crash breadcrumbs — entries from the previous session that crashed.
    private var _crashBreadcrumbs: [Entry]? = nil
    public var crashBreadcrumbs: [Entry]? {
        lock.lock(); defer { lock.unlock() }
        return _crashBreadcrumbs
    }

    // Background queue for all disk I/O — never blocks the caller.
    private let ioQueue = DispatchQueue(label: "app.exteragram.ios.pluginDebugLog.io", qos: .utility)
    private static let cleanExitSentinel = "[CLEAN_EXIT]"

    private init() {}

    // MARK: - Log file URLs

    private static var currentLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("eg_plugin_debug.log")
    }

    private static var previousLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("eg_plugin_debug_prev.log")
    }

    // MARK: - Public API

    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    public func append(tag: String, _ message: String) {
        let entry = Entry(tag: tag, message: message)
        lock.lock()
        _entries.append(entry)
        if _entries.count > maxEntries { _entries.removeFirst() }
        lock.unlock()

        let line = "[\(entry.formattedTimestamp)] [\(tag)] \(message)\n"
        ioQueue.async { Self.appendLine(line, to: Self.currentLogURL) }

        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.changed, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    public func clear() {
        lock.lock(); _entries = []; lock.unlock()
        ioQueue.async { try? FileManager.default.removeItem(at: Self.currentLogURL) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// Call on graceful shutdown (applicationWillTerminate). Writes a sentinel so
    /// the next launch knows the previous session ended cleanly (no crash breadcrumbs).
    public func markCleanExit() {
        ioQueue.sync { Self.appendLine(Self.cleanExitSentinel + "\n", to: Self.currentLogURL) }
    }

    /// Call early in app startup (didFinishLaunching). Rotates the log file and
    /// populates `crashBreadcrumbs` if the previous session crashed.
    public func loadCrashBreadcrumbs() {
        ioQueue.async {
            let current = Self.currentLogURL
            let previous = Self.previousLogURL
            defer {
                // Rotate: rename current → previous so this session starts fresh.
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: current, to: previous)
            }

            guard let data = try? Data(contentsOf: current),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else { return }

            // If the session ended cleanly, no breadcrumbs needed.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasSuffix(Self.cleanExitSentinel) else { return }

            // Parse entries from the plain-text log lines.
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix(Self.cleanExitSentinel) }
            let breadcrumbs = lines.map { line -> Entry in
                // Format: [HH:mm:ss.SSS] [TAG] message
                if line.hasPrefix("["), let closeBracket = line.firstIndex(of: "]"),
                   let tagStart = line.index(closeBracket, offsetBy: 3, limitedBy: line.endIndex),
                   let tagEnd = line[tagStart...].firstIndex(of: "]") {
                    let tag = String(line[tagStart..<tagEnd])
                    let msgStart = line.index(tagEnd, offsetBy: 2)
                    let message = msgStart < line.endIndex ? String(line[msgStart...]) : ""
                    return Entry(tag: tag, message: message)
                }
                return Entry(tag: "Log", message: line)
            }

            self.lock.lock()
            self._crashBreadcrumbs = breadcrumbs
            self.lock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    // MARK: - Disk helpers

    private static func appendLine(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// C-callable bridge so ObjC can write synchronously to the debug log without
// going through the async NSNotification chain (avoids lost messages during init).
@_cdecl("EGPluginDebugLog_appendCStr")
public func EGPluginDebugLog_appendCStr(_ tag: UnsafePointer<CChar>?, _ message: UnsafePointer<CChar>?) {
    let tagStr = tag.map { String(cString: $0) } ?? "Plugin"
    let msgStr = message.map { String(cString: $0) } ?? ""
    EGPluginDebugLog.shared.append(tag: tagStr, msgStr)
}
