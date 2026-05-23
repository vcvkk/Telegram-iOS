// MARK: exteraGram — Plugin TL hook registry

import Foundation

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
