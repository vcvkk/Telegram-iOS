// MARK: exteraGram — EGPluginEngine ObjC/Python bridge

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridge between Python and iOS Swift/ObjC layer.
/// Uses CPython C API internally; public interface is pure ObjC.
@interface EGPythonBridge : NSObject

/// Initialize CPython 3.13 runtime using the modern PyConfig API.
/// @param pythonHome  Path where lib/python3.13/ can be found (PyConfig.home).
/// @param sdkPath     Path to Python SDK .py files (added to module search paths).
/// @param pluginsPath Path to installed .plugin files.
/// @param sitePkgs    Path to site-packages directory.
/// @return YES if CPython started successfully.
+ (BOOL)initializeWithHome:(NSString *)pythonHome
                   sdkPath:(NSString *)sdkPath
               pluginsPath:(NSString *)pluginsPath
          sitePackagesPath:(NSString *)sitePkgs;

/// Whether CPython has been initialized.
@property (class, nonatomic, readonly) BOOL isInitialized;

/// Execute block with the Python GIL held. Safe to call from any thread.
/// No-op if not initialized.
+ (void)withPython:(NS_NOESCAPE void (^)(void))block;

/// Load a .plugin file as a Python module and call its on_load().
/// Returns nil on success, or an error description string on failure.
+ (nullable NSString *)loadPlugin:(NSString *)pluginId fromPath:(NSString *)path;

/// Unload a plugin: call on_unload() and remove from sys.modules.
+ (void)unloadPlugin:(NSString *)pluginId;

/// Fire all Python TL hook callbacks registered for tlType.
/// The params dict is converted to a Python dict, passed to each callback,
/// then the (possibly modified) values are written back into params.
+ (void)dispatchTLHook:(NSString *)tlType params:(NSMutableDictionary<NSString *, id> *)params;

/// Whether any loaded plugin has registered a hook for the given TL type.
+ (BOOL)hasHook:(NSString *)tlType;

/// Called by the Python _ios_bridge extension to log messages.
+ (void)logFromPlugin:(NSString *)tag message:(NSString *)message;

/// Returns YES if the loaded plugin module exposes a `__settings__` attribute.
+ (BOOL)pluginHasSettings:(NSString *)pluginId;

/// Returns the plugin's `__settings__.to_dict()` as an NSDictionary, or nil if none.
+ (nullable NSDictionary *)getPluginSettingsSchema:(NSString *)pluginId;

/// Call `on_setting_action(key)` on the loaded plugin module, if defined.
/// Used by 'button'-type settings to dispatch tap events into Python.
+ (void)invokePluginAction:(NSString *)pluginId key:(NSString *)key;

/// Install Python requirements for a plugin: calls pkg_manager.ensure_requirements() with GIL.
/// Blocks the calling thread (called on engineQueue, not main). Returns YES if all satisfied.
+ (BOOL)installRequirements:(NSArray<NSString *> *)requirements forPlugin:(NSString *)pluginId;

/// Extract python3.13.zip (bundled as a data resource) to destDir, preserving paths.
/// Returns YES on success. Idempotent — call before initializeWithHome:.
+ (BOOL)extractPythonStdlibZip:(NSString *)zipPath toDirectory:(NSString *)destDir;

/// Wired by EGPluginsEngineImpl: (typeName, suppress) → EGPluginHooks.suppressedEntityTypes insert/remove.
@property (class, nonatomic, copy, nullable) void (^suppressEntityTypeHandler)(NSString *, BOOL);

/// Wired by EGPluginsEngineImpl: (typeName, suppress) → EGPluginHooks.suppressedAttributeTypes insert/remove.
@property (class, nonatomic, copy, nullable) void (^suppressAttributeTypeHandler)(NSString *, BOOL);

/// Wired by PluginsController.wireClientInfo: (peerId, text) → real enqueueMessages call.
/// Called from _ios_bridge.send_message(peer_id, text) to let plugins send messages.
@property (class, nonatomic, copy, nullable) void (^sendMessageHandler)(long long peerId, NSString *text);

/// Wired by PluginsController.wireClientInfo: (peerId, msgId, emoticon) → updateMessageReactionsInteractively.
/// Called from _ios_bridge.send_reaction(peer_id, msg_id, emoticon) to let plugins add reactions.
@property (class, nonatomic, copy, nullable) void (^sendReactionHandler)(long long peerId, int32_t msgId, NSString *emoticon);

/// Wired by EGPluginsEngineImpl: called when a plugin registers a UI entry point via
/// _ios_bridge.register_plugin_entry(plugin_id, entry_type, item_id, title[, icon_name]).
/// entry_type: "chatlist" | "context_menu" | "profile"; icon_name is optional (nil = no icon)
@property (class, nonatomic, copy, nullable) void (^registerMenuItemHandler)(NSString *pluginId, NSString *entryType, NSString *itemId, NSString *title, NSString * _Nullable iconName);

/// Wired by EGPluginsEngineImpl: (peerId, filePath, replyMsgId) → enqueueMessages with photo media.
/// Called from _ios_bridge.send_photo(peer_id, file_path[, reply_msg_id]).
@property (class, nonatomic, copy, nullable) void (^sendPhotoHandler)(long long peerId, NSString *filePath, NSNumber * _Nullable replyMsgId);

/// Wired by EGPluginsEngineImpl: (peerId, filePath, fileName, replyMsgId) → enqueueMessages with file media.
/// Called from _ios_bridge.send_file(peer_id, file_path[, file_name[, reply_msg_id]]).
@property (class, nonatomic, copy, nullable) void (^sendFileHandler)(long long peerId, NSString *filePath, NSString *fileName, NSNumber * _Nullable replyMsgId);

/// Must be called on the main thread before any plugin uses get_system_info / get_device_info.
/// Enables UIDevice battery monitoring and caches immutable UIScreen dimensions so that
/// the Python bridge functions can call them safely from background threads without dispatch_sync.
+ (void)prepareUIKitCaches;

@end

NS_ASSUME_NONNULL_END

