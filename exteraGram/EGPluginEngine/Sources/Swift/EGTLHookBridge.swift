// MARK: exteraGram — Swift-side TL hook dispatcher

import Foundation
import EGLogging
import EGPluginEngineBridge

/// Called from TelegramCore at TL dispatch points.
/// Bridges Swift interception points → Python plugin callbacks via EGPythonBridge.
public final class EGTLHookBridge {
    public static let shared = EGTLHookBridge()
    private init() {}

    // Dedicated serial queue for all async Python TL-hook calls.
    // Serial = always same OS thread → CPython PyGILState/PyThreadState is
    // never created on a recycled GCD thread, preventing the SIGSEGV that
    // occurs when GCD reuses a thread that previously had Python state attached.
    private let hookQueue = DispatchQueue(
        label: "app.exteragram.ios.pythonTLHook",
        qos: .userInitiated
    )

    // Separate serial queue for synchronous TL-hook calls (messages.sendReaction etc.).
    // Kept distinct from hookQueue so a hanging sync hook doesn't starve pending async hooks.
    private let syncHookQueue = DispatchQueue(
        label: "app.exteragram.ios.pythonTLHookSync",
        qos: .userInitiated
    )

    /// Fire all Python hooks registered for `tlType` **synchronously**.
    /// Runs Python on `syncHookQueue` and waits up to 2 s; on timeout, the
    /// original params are returned unchanged (hook result is discarded).
    /// Use only when you need the modified params back (e.g. messages.sendReaction → big=true).
    public func dispatchTLHook(_ tlType: String, params: inout [String: Any]) {
        guard EGPythonBridge.isInitialized else { return }
        let mutable = NSMutableDictionary(dictionary: params)
        let sema = DispatchSemaphore(value: 0)
        syncHookQueue.async {
            EGPythonBridge.dispatchTLHook(tlType, params: mutable)
            sema.signal()
        }
        if sema.wait(timeout: .now() + 2.0) == .timedOut {
            EGLogger.shared.log("TLHook", "\(tlType) hook timed out after 2s — result discarded")
            return
        }
        for (key, value) in mutable {
            if let k = key as? String { params[k] = value }
        }
    }

    /// Fire hooks **asynchronously** on the dedicated serial Python queue.
    /// Use for notification-only hooks (messages.sendMessage) where the caller
    /// does not need modified params back and must not block the main thread.
    public func dispatchTLHookAsync(_ tlType: String, snapshot: [String: Any]) {
        hookQueue.async { [weak self] in
            guard let self else { return }
            var localParams = snapshot
            EGPluginDebugLog.shared.append(tag: "TLHook", "\(tlType) → Python (async)")
            self.dispatchTLHook(tlType, params: &localParams)
        }
    }

    /// Convenience for BigReactions: returns true if any plugin forces large reactions.
    public func shouldForceLargeReaction() -> Bool {
        guard EGPythonBridge.isInitialized,
              EGPythonBridge.hasHook("messages.sendReaction") else { return false }
        var params: [String: Any] = ["big": false]
        dispatchTLHook("messages.sendReaction", params: &params)
        return params["big"] as? Bool ?? false
    }
}
