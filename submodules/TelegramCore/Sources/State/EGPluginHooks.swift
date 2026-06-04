// MARK: exteraGram — Plugin TL hook registry

import Foundation

// MARK: - Plugin menu item registration

/// A UI entry point registered by a plugin via _ios_bridge.register_plugin_entry().
public struct EGPluginMenuItem {
    public let pluginId: String
    public let entryType: String   // "chatlist" | "context_menu" | "profile"
    public let itemId: String
    public let title: String
    public let iconName: String?   // optional bundle image name; nil = no icon

    public init(pluginId: String, entryType: String, itemId: String, title: String, iconName: String? = nil) {
        self.pluginId  = pluginId
        self.entryType = entryType
        self.itemId    = itemId
        self.title     = title
        self.iconName  = iconName
    }
}

/// Closure-based hook registry. TelegramCore calls these at dispatch points.
/// EGPluginEngine registers closures here at engine startup.
/// No dependency on EGPluginEngine — TelegramCore stays self-contained.
public enum EGPluginHooks {
    /// Called before messages.sendReaction is dispatched.
    /// Modify params["big"] = true to force large reaction animation.
    public static var sendReactionHook: ((inout [String: Any]) -> Void)?

    /// Called when enqueueMessages fires for a real outgoing user message.
    /// params["peer_id"]: Int64, params["count"]: Int
    public static var sendMessageHook: ((inout [String: Any]) -> Void)?

    /// Called when a message is being edited.
    /// params["peer_id"]: Int64, params["message_id"]: Int32, params["text"]: String
    public static var editMessageHook: ((inout [String: Any]) -> Void)?

    /// Called when messages are deleted interactively.
    /// params["message_ids"]: [Int32], params["delete_for_everyone"]: Bool
    public static var deleteMessagesHook: ((inout [String: Any]) -> Void)?

    /// Synchronous intercept hook for outgoing text messages.
    /// params["peer_id"]: Int64, params["text"]: String
    /// Handler sets params["cancel"] = true to cancel the send (enqueueMessages returns empty signal).
    public static var messageInterceptHook: ((inout [String: Any]) -> Bool)?

    /// Called from _ios_bridge.send_message(peer_id, text) — plugin-initiated sends.
    /// Wired by PluginsController.wireClientInfo to a real enqueueMessages call.
    public static var pluginSendMessageHandler: ((Int64, String) -> Void)?

    /// Called from _ios_bridge.send_reaction(peer_id, msg_id, emoticon) — plugin-initiated reactions.
    /// Wired by PluginsController.wireClientInfo to updateMessageReactionsInteractively.
    public static var pluginSendReactionHandler: ((Int64, Int32, String) -> Void)?

    /// Called from _ios_bridge.send_photo(peer_id, file_path, reply_msg_id) — plugin-initiated photo send.
    public static var pluginSendPhotoHandler: ((Int64, String, Int32?) -> Void)?

    /// Called from _ios_bridge.send_file(peer_id, file_path, file_name, reply_msg_id) — plugin-initiated file send.
    public static var pluginSendFileHandler: ((Int64, String, String, Int32?) -> Void)?

    /// Wired by ChatController: find a loaded ChatMessageItemView node for (peerId, msgId).
    /// Returns the raw UIView pointer as UInt, or 0 if not found. Must be called on main thread.
    public static var findMessageViewHandler: ((Int64, Int32) -> UInt)?

    /// Wired by ChatController: async pixel-perfect snapshot of a message bubble to a PNG file.
    /// outPath is the destination file path; completion(outPath) or completion(nil) called on main thread.
    public static var snapshotMessageHandler: ((Int64, Int32, CGFloat, String, @escaping (String?) -> Void) -> Void)?

    /// Wired by ChatController: called when the quote toolbar button is tapped in selection mode.
    /// (peerId, messageIds): peer and sorted selected message IDs. Handler fires plugin.selection_action_tapped.
    public static var quoteSelectionHandler: ((Int64, [Int32]) -> Void)?

    /// Wired by ChatController: snapshots the chat wallpaper background to outPath as PNG.
    /// Called synchronously on main thread by py_get_wallpaper_image. Returns true on success.
    public static var getWallpaperImageHandler: ((String) -> Bool)?

    /// MessageTextEntity type names to suppress when storing incoming messages.
    /// Plugins insert/remove entries; TelegramCore checks the set at parse time.
    /// Example: "Spoiler" suppresses messageEntitySpoiler entities.
    public nonisolated(unsafe) static var suppressedEntityTypes: Set<String> = []

    /// MessageAttribute class names to suppress when storing incoming messages.
    /// Plugins insert/remove entries; TelegramCore checks the set at parse time.
    /// Example: "MediaSpoilerMessageAttribute" drops the media-spoiler attribute.
    public nonisolated(unsafe) static var suppressedAttributeTypes: Set<String> = []

    // MARK: - Generic event bus

    /// Synchronous event dispatch — registered closure modifies params in-place and returns.
    /// Use when the caller needs the modified params back (e.g. reaction big flag).
    public static var eventBusHook: ((String, inout [String: Any]) -> Void)?

    /// Asynchronous event dispatch — fire-and-forget notification to plugins.
    /// Use for lifecycle events where no params need to be written back.
    public static var eventBusHookAsync: ((String, [String: Any]) -> Void)?

    /// Fire a synchronous lifecycle/data event. Plugins registered via add_event_hook() receive it.
    @inline(__always)
    public static func fire(_ event: String, _ params: inout [String: Any]) {
        eventBusHook?(event, &params)
    }

    /// Fire an async lifecycle event (notification-only, params are a snapshot).
    @inline(__always)
    public static func fireAsync(_ event: String, params: [String: Any] = [:]) {
        eventBusHookAsync?(event, params)
    }

    // MARK: - Plugin menu item registry

    /// All UI entry points registered by loaded plugins via register_plugin_entry().
    /// Written on main thread; read on main thread from UI code.
    public nonisolated(unsafe) static var registeredMenuItems: [EGPluginMenuItem] = []

    /// Called when a plugin's registered menu item is tapped in the iOS UI.
    /// Fires "plugin.menu_item_tapped" into Python via EGTLHookBridge.
    /// The optional context dict carries message data (peer_id, message_id, text, sender_name, date)
    /// for context_menu entries; nil for chatlist/profile entries.
    public static var pluginMenuItemTappedHandler: ((String, String, String, [String: Any]?) -> Void)?
}

// MARK: - Event bus event catalogue (for plugin documentation)
// Plugins subscribe via add_tl_hook(event_name, callback).
//
// "messages.receivedMessage"   — incoming message stored (after decrypt)
//   params: peer_id: Int64, text: String, message_id: Int (if available)
//   source: AccountStateManagementUtils.swift / .updateNewMessage
//
// "messages.readHistory"       — read pointer advanced
//   params: peer_id: Int64, max_id: Int
//
// "messages.pinMessage"        — message pinned/unpinned
//   params: peer_id: Int64, message_id: Int, pinned: Bool
//
// "messages.forwardMessages"   — messages forwarded
//   params: peer_id: Int64, count: Int
