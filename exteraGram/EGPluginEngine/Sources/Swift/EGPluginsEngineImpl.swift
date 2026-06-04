// MARK: exteraGram — Plugin engine: load/unload/enable/disable

import Foundation
import EGLogging
import EGPluginEngineBridge
import TelegramCore

/// Core engine. Owned by EGSettingsUI's PluginsController.
/// Does NOT import EGSettingsUI — dependency flows: EGSettingsUI → EGPluginEngine.
public final class EGPluginsEngineImpl {
    private var errorStates: [String: String] = [:]
    private var notResponding: [String: Bool] = [:]
    private var hasSettingsMap: [String: Bool] = [:]
    private let engineQueue = DispatchQueue(
        label: "app.exteragram.ios.pluginEngine",
        qos: .userInitiated
    )

    public init() {}

    // MARK: - Lifecycle

    /// Start engine and load the given plugins.
    /// `plugins` is a list of (id, filePath) pairs from PluginsController.
    public func start(plugins: [(id: String, filePath: String)], completion: @escaping () -> Void) {
        // Enable battery monitoring and cache UIScreen dims on main thread before the engine
        // background queue runs — prevents dispatch_sync deadlock in py_get_system_info.
        DispatchQueue.main.async {
            EGPythonBridge.prepareUIKitCaches()
        }
        engineQueue.async {
            EGPluginRuntime.shared.initialize()
            guard EGPythonBridge.isInitialized else {
                EGLogger.shared.log("PluginEngine", "Python unavailable — engine stub mode")
                completion()
                return
            }
            // Wire TL hook registry
            EGPluginHooks.sendReactionHook = { params in
                EGTLHookBridge.shared.dispatchTLHook("messages.sendReaction", params: &params)
            }
            // sendMessage / editMessage / deleteMessages are notification-only:
            // dispatch via the bridge's dedicated serial Python queue — never
            // blocks main thread, always same OS thread (avoids GCD thread-
            // recycling SIGSEGV in CPython PyGILState).
            EGPluginHooks.sendMessageHook = { params in
                EGTLHookBridge.shared.dispatchTLHookAsync(
                    "messages.sendMessage", snapshot: params)
            }
            EGPluginHooks.editMessageHook = { params in
                EGTLHookBridge.shared.dispatchTLHookAsync(
                    "messages.editMessage", snapshot: params)
            }
            EGPluginHooks.deleteMessagesHook = { params in
                EGTLHookBridge.shared.dispatchTLHookAsync(
                    "messages.deleteMessages", snapshot: params)
            }
            // Wire generic message-filter hooks so plugins can suppress entity/attribute types.
            EGPythonBridge.suppressEntityTypeHandler = { typeName, suppress in
                if suppress { EGPluginHooks.suppressedEntityTypes.insert(typeName) }
                else        { EGPluginHooks.suppressedEntityTypes.remove(typeName) }
            }
            EGPythonBridge.suppressAttributeTypeHandler = { typeName, suppress in
                if suppress { EGPluginHooks.suppressedAttributeTypes.insert(typeName) }
                else        { EGPluginHooks.suppressedAttributeTypes.remove(typeName) }
            }
            // Generic event bus — reuses the same g_tl_hooks dict; event name is the key.
            EGPluginHooks.eventBusHook = { [weak self] event, params in
                _ = self
                EGTLHookBridge.shared.dispatchTLHook(event, params: &params)
            }
            EGPluginHooks.eventBusHookAsync = { event, params in
                EGTLHookBridge.shared.dispatchTLHookAsync(event, snapshot: params)
            }
            // Synchronous intercept: lets plugins cancel outgoing messages and send replacements.
            // Zero overhead when no plugin registers "messages.interceptMessage".
            EGPluginHooks.messageInterceptHook = { params in
                guard EGPythonBridge.isInitialized,
                      EGPythonBridge.hasHook("messages.interceptMessage") else { return false }
                EGTLHookBridge.shared.dispatchTLHook("messages.interceptMessage", params: &params)
                return params["cancel"] as? Bool ?? false
            }
            // Forward _ios_bridge.send_message() to the real enqueueMessages wired by PluginsController.
            // EGPythonBridge is ObjC — only visible inside EGPluginEngine, not in EGSettingsUI.
            EGPythonBridge.sendMessageHandler = { peerId, text in
                EGPluginHooks.pluginSendMessageHandler?(peerId, text)
            }
            EGPythonBridge.sendReactionHandler = { peerId, msgId, emoticon in
                EGPluginHooks.pluginSendReactionHandler?(peerId, msgId, emoticon)
            }
            EGPythonBridge.sendPhotoHandler = { peerId, filePath, replyMsgId in
                EGPluginHooks.pluginSendPhotoHandler?(peerId, filePath, replyMsgId?.int32Value)
            }
            EGPythonBridge.sendFileHandler = { peerId, filePath, fileName, replyMsgId in
                EGPluginHooks.pluginSendFileHandler?(peerId, filePath, fileName, replyMsgId?.int32Value)
            }
            EGPythonBridge.findMessageViewHandler = { peerId, msgId in
                return UInt64(EGPluginHooks.findMessageViewHandler?(peerId, msgId) ?? 0)
            }
            EGPythonBridge.snapshotMessageHandler = { peerId, msgId, width, outPath, completion in
                EGPluginHooks.snapshotMessageHandler?(peerId, msgId, width, outPath) { path in
                    completion?(path)
                }
            }
            // Wire register_plugin_entry() → EGPluginHooks.registeredMenuItems
            EGPythonBridge.registerMenuItemHandler = { pluginId, entryType, itemId, title, iconName in
                let item = EGPluginMenuItem(pluginId: pluginId, entryType: entryType,
                                           itemId: itemId, title: title, iconName: iconName)
                if !EGPluginHooks.registeredMenuItems.contains(where: {
                    $0.pluginId == pluginId && $0.itemId == itemId && $0.entryType == entryType
                }) {
                    EGPluginHooks.registeredMenuItems.append(item)
                    EGPluginDebugLog.shared.append(tag: "PluginEngine",
                        "Registered \(pluginId)/\(entryType)/\(itemId) icon=\(iconName ?? "nil") total=\(EGPluginHooks.registeredMenuItems.count)")
                }
            }
            EGPluginDebugLog.shared.append(tag: "PluginEngine", "Starting \(plugins.count) plugin(s)…")
            for plugin in plugins {
                // loadPlugin also calls EGPluginRuntime.initialize() — dispatch_once makes it safe.
                self.loadPlugin(id: plugin.id, filePath: plugin.filePath)
            }
            EGPluginDebugLog.shared.append(tag: "PluginEngine",
                "Engine started — items=\(EGPluginHooks.registeredMenuItems.count) so far")
            // Notify UI that plugin menu items may have been registered.
            // Slight delay ensures py_register_plugin_entry's dispatch_async(main) has run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                EGPluginDebugLog.shared.append(tag: "PluginEngine",
                    "Posting EGPluginMenuItemsUpdated — \(EGPluginHooks.registeredMenuItems.count) item(s)")
                NotificationCenter.default.post(
                    name: Notification.Name("EGPluginMenuItemsUpdated"), object: nil)
            }
            completion()
        }
    }

    public func stop(pluginIds: [String], completion: @escaping () -> Void) {
        engineQueue.async {
            EGPluginHooks.sendReactionHook = nil
            EGPluginHooks.sendMessageHook = nil
            EGPluginHooks.editMessageHook = nil
            EGPluginHooks.deleteMessagesHook = nil
            EGPluginHooks.suppressedEntityTypes.removeAll()
            EGPluginHooks.suppressedAttributeTypes.removeAll()
            EGPythonBridge.suppressEntityTypeHandler = nil
            EGPythonBridge.suppressAttributeTypeHandler = nil
            EGPluginHooks.eventBusHook = nil
            EGPluginHooks.eventBusHookAsync = nil
            EGPluginHooks.messageInterceptHook = nil
            EGPythonBridge.sendMessageHandler = nil
            EGPythonBridge.sendReactionHandler = nil
            EGPythonBridge.sendPhotoHandler = nil
            EGPythonBridge.sendFileHandler = nil
            EGPythonBridge.findMessageViewHandler = nil
            EGPythonBridge.snapshotMessageHandler = nil
            EGPythonBridge.registerMenuItemHandler = nil
            EGPluginHooks.registeredMenuItems.removeAll()
            for id in pluginIds {
                if EGPythonBridge.isInitialized {
                    EGPythonBridge.unloadPlugin(id)
                }
            }
            self.errorStates.removeAll()
            self.notResponding.removeAll()
            self.hasSettingsMap.removeAll()
            EGLogger.shared.log("PluginEngine", "Engine stopped")
            completion()
        }
    }

    // MARK: - Install (validate + copy file to Documents/EGPlugins/)

    /// Validate metadata and copy the plugin file to its final location.
    /// Returns the parsed metadata on success; caller creates the EGPlugin.
    public func installPlugin(from filePath: String) throws -> EGFullPluginMetadata {
        let meta = try EGPluginLoader.shared.parseAndValidate(path: filePath)
        EGPluginsDirectory.plugins.create()
        let dest = EGPluginsDirectory.plugins.url.appendingPathComponent("\(meta.id).plugin")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(atPath: filePath, toPath: dest.path)
        EGLogger.shared.log("PluginEngine", "Installed \(meta.id) v\(meta.version)")
        return meta
    }

    // MARK: - Load / Unload

    public func loadPlugin(id: String, filePath: String) {
        guard !filePath.isEmpty else { errorStates[id] = "No file path"; return }
        // Ensure Python is initialized. dispatch_once in EGPythonBridge makes this safe to call
        // from any thread, even concurrently — the second caller waits for the first to finish.
        EGPluginRuntime.shared.initialize()
        guard EGPythonBridge.isInitialized else {
            let msg = "Python runtime unavailable"
            errorStates[id] = msg
            EGPluginDebugLog.shared.append(tag: "Engine", "[\(id)] \(msg)")
            return
        }
        if let parsed = try? EGPluginLoader.shared.parseAndValidate(path: filePath) {
            let reqs = parsed.requirements
            if !reqs.isEmpty {
                EGPluginDebugLog.shared.append(tag: "Engine", "[\(id)] installing requirements: \(reqs)")
                let ok = EGPythonBridge.installRequirements(reqs, forPlugin: id)
                if !ok {
                    let msg = "Failed to install requirements: \(reqs.joined(separator: ", "))"
                    errorStates[id] = msg
                    EGPluginDebugLog.shared.append(tag: "Engine", "ERROR [\(id)]: \(msg)")
                    return
                }
            }
        }
        let watchdog = EGPluginsWatchdog.shared
        watchdog.begin(pluginId: id) { [weak self] in self?.notResponding[id] = true }
        EGPluginDebugLog.shared.append(tag: "Engine", "Loading plugin: \(id)")
        let errMsg = EGPythonBridge.loadPlugin(id, fromPath: filePath)
        watchdog.end(pluginId: id)
        if let errMsg {
            errorStates[id] = errMsg
            EGLogger.shared.log("PluginEngine", "Error loading \(id): \(errMsg)")
            EGPluginDebugLog.shared.append(tag: "Engine", "ERROR [\(id)]: \(errMsg)")
        } else {
            errorStates.removeValue(forKey: id)
            hasSettingsMap[id] = EGPythonBridge.pluginHasSettings(id)
            EGPluginDebugLog.shared.append(tag: "Engine", "Loaded [\(id)] ✓")
        }
    }

    public func unloadPlugin(_ id: String) {
        EGPythonBridge.unloadPlugin(id)
        errorStates.removeValue(forKey: id)
        notResponding.removeValue(forKey: id)
        hasSettingsMap.removeValue(forKey: id)
    }

    // MARK: - State queries

    public func isPluginError(_ id: String) -> Bool { errorStates[id] != nil }
    public func pluginErrorMessage(_ id: String) -> String? { errorStates[id] }
    public func isPluginNotResponding(_ id: String) -> Bool { notResponding[id] == true }
    public func pluginHasSettings(_ id: String) -> Bool { hasSettingsMap[id] == true }

    // MARK: - Enable / Disable

    public func setPluginEnabled(id: String, enabled: Bool) {
        if enabled {
            // filePath must be looked up by the caller (PluginsController)
            // This is a no-op stub; PluginsController calls loadPlugin/unloadPlugin directly
        } else {
            unloadPlugin(id)
        }
    }

    // MARK: - Settings

    public func getPluginSetting(_ id: String, key: String, default def: Any?) -> Any? {
        UserDefaults.standard.object(forKey: "eg.plugin.\(id).\(key)") ?? def
    }

    public func setPluginSetting(_ id: String, key: String, value: Any) {
        UserDefaults.standard.set(value, forKey: "eg.plugin.\(id).\(key)")
    }

    /// Invoke a 'button'-type setting tap: calls module.on_setting_action(key) in Python.
    public func invokePluginAction(_ id: String, key: String) {
        guard EGPythonBridge.isInitialized else { return }
        EGPythonBridge.invokePluginAction(id, key: key)
    }

    /// Returns the plugin's `__settings__` items array, or nil if the plugin has no settings.
    public func getPluginSettingsSchema(_ id: String) -> [[String: Any]]? {
        guard EGPythonBridge.isInitialized else { return nil }
        guard let schema = EGPythonBridge.getPluginSettingsSchema(id),
              let items = schema["items"] as? [[String: Any]] else { return nil }
        return items
    }
}
