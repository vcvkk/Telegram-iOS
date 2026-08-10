// MARK: exteraGram — Plugin execution watchdog (5-second timeout)

import Foundation
import EGLogging

/// Monitors plugin execution time. If a plugin callback takes longer than the timeout,
/// the plugin is marked as "not responding" and its hooks are cleared.
final class EGPluginsWatchdog {
    static let shared = EGPluginsWatchdog()
    private let timeout: TimeInterval = 5.0
    // DispatchWorkItem is safe from any thread; Timer requires a running RunLoop.
    private var items: [String: DispatchWorkItem] = [:]
    private let lock = NSLock()
    private init() {}

    func begin(pluginId: String, onTimeout: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        items[pluginId]?.cancel()
        let item = DispatchWorkItem {
            EGLogger.shared.log("Watchdog", "Plugin '\(pluginId)' timed out")
            onTimeout()
        }
        items[pluginId] = item
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + timeout,
            execute: item
        )
    }

    func end(pluginId: String) {
        lock.lock()
        defer { lock.unlock() }
        items[pluginId]?.cancel()
        items.removeValue(forKey: pluginId)
    }
}
