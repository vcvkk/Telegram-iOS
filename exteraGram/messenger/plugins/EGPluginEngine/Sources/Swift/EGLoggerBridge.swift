// MARK: exteraGram — bridges Python log notifications → EGLogger

import Foundation
import EGLogging

/// Receives log messages from the Python _ios_bridge C extension and forwards to EGLogger.
public final class EGLoggerBridge {
    public static let shared = EGLoggerBridge()
    private var observer: NSObjectProtocol?

    private init() {}

    public func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EGPluginLogNotification"),
            object: nil,
            queue: .main
        ) { note in
            let tag = note.userInfo?["tag"] as? String ?? "Plugin"
            let msg = note.userInfo?["msg"] as? String ?? ""
            EGLogger.shared.log("Plugin[\(tag)]", msg)
            EGPluginDebugLog.shared.append(tag: tag, msg)
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
