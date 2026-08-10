// MARK: exteraGram — Plugin client-info registry
//
// Closure-based registry that exposes the current account/user/connection
// state to Python plugins via _ios_bridge. Wired from the app side (see
// PluginsController.wireClientInfo) so EGPluginEngine stays decoupled from
// AccountContext lifetime.

import Foundation

public enum EGPluginClientInfo {
    public static var accountIdProvider: (() -> Int64)?
    public static var userIdProvider: (() -> Int64)?
    public static var connectionStateProvider: (() -> String)?

    public static func reset() {
        accountIdProvider = nil
        userIdProvider = nil
        connectionStateProvider = nil
    }
}

// MARK: - C bridges (called from EGIOSBridge.m, no module import needed)

@_cdecl("EGPluginClientInfo_getAccountId")
public func EGPluginClientInfo_getAccountId() -> Int64 {
    return EGPluginClientInfo.accountIdProvider?() ?? 0
}

@_cdecl("EGPluginClientInfo_getUserId")
public func EGPluginClientInfo_getUserId() -> Int64 {
    return EGPluginClientInfo.userIdProvider?() ?? 0
}

/// Returns a strdup'd C string; caller must free().
@_cdecl("EGPluginClientInfo_getConnectionStateCStr")
public func EGPluginClientInfo_getConnectionStateCStr() -> UnsafePointer<CChar>? {
    let state = EGPluginClientInfo.connectionStateProvider?() ?? "connected"
    return UnsafePointer(strdup(state))
}

/// Returns a strdup'd C string for the plugin's per-id data directory; caller must free().
/// Creates the directory if it does not exist.
@_cdecl("EGPluginClientInfo_getPluginDataDirCStr")
public func EGPluginClientInfo_getPluginDataDirCStr(_ pluginId: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let pluginId else { return UnsafePointer(strdup("")) }
    let id = String(cString: pluginId)
    let dir = EGPluginsDirectory.data(id)
    dir.create()
    return UnsafePointer(strdup(dir.path))
}
