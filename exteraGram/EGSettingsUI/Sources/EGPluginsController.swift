// MARK: exteraGram

import Foundation
import UIKit
import SwiftUI
import LegacyUI
import EGSwiftUI
import EGStrings
import EGLogging
import EGPluginEngine
import AccountContext
import Display
import TelegramPresentationData
import SwiftSignalKit
import TelegramCore
import Postbox
import AnimatedStickerNode
import TelegramAnimatedStickerNode

/// Reference-type holder for the latest connection-state string so the
/// signal subscriber and the EGPluginClientInfo provider closure share state.
private final class ConnectionStateBox {
    var value: String = "connected"
}

// MARK: - Data Model

public struct EGPlugin: Identifiable, Codable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var pluginDescription: String
    public var version: String
    public var iconUrl: String?
    public var isEnabled: Bool
    public var isPinned: Bool
    public var hasSettings: Bool
    public var requiresPermissions: [String]

    // New fields (default values preserve Codable backward-compatibility)
    public var os: [String] = ["ios"]
    public var dependencies: [String] = []
    public var filePath: String = ""
    public var installedAt: Date = Date()

    // Runtime-only (not persisted)
    public var isExpanded: Bool = false
    public var isError: Bool = false
    public var isNotResponding: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, subtitle, version, iconUrl
        case pluginDescription = "description"
        case isEnabled, isPinned, hasSettings, requiresPermissions
        case os, dependencies, filePath, installedAt
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        subtitle: String = "",
        pluginDescription: String = "",
        version: String = "1.0",
        iconUrl: String? = nil,
        isEnabled: Bool = true,
        isPinned: Bool = false,
        hasSettings: Bool = false,
        requiresPermissions: [String] = [],
        os: [String] = ["ios"],
        dependencies: [String] = [],
        filePath: String = "",
        installedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.pluginDescription = pluginDescription
        self.version = version
        self.iconUrl = iconUrl
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.hasSettings = hasSettings
        self.requiresPermissions = requiresPermissions
        self.os = os
        self.dependencies = dependencies
        self.filePath = filePath
        self.installedAt = installedAt
    }

    /// Convenience init from EGPluginEngine metadata
    public init(from meta: EGFullPluginMetadata, filePath: String, isEnabled: Bool) {
        self.id = meta.id
        self.name = meta.name
        self.subtitle = meta.author
        self.pluginDescription = meta.description
        self.version = meta.version
        self.iconUrl = meta.iconUrl
        self.isEnabled = isEnabled
        self.isPinned = false
        self.hasSettings = false
        self.requiresPermissions = meta.permissions
        self.os = meta.os
        self.dependencies = meta.dependencies
        self.filePath = filePath
        self.installedAt = Date()
    }
}

// MARK: - Engine Controller

public final class PluginsController {
    public static let shared = PluginsController()
    private init() {
        observePluginUINotifications()
    }

    private let engine = EGPluginsEngineImpl()

    // MARK: Persisted plugin list

    public var plugins: [EGPlugin] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "eg_plugins_v1"),
                  let list = try? JSONDecoder().decode([EGPlugin].self, from: data)
            else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "eg_plugins_v1")
        }
    }

    // MARK: Persisted flags

    public var isEngineEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "eg_engine_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "eg_engine_enabled") }
    }

    public var isDevMode: Bool {
        get { UserDefaults.standard.bool(forKey: "eg_plugins_dev_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "eg_plugins_dev_mode") }
    }

    public var isCompactView: Bool {
        get { UserDefaults.standard.bool(forKey: "eg_plugins_compact") }
        set { UserDefaults.standard.set(newValue, forKey: "eg_plugins_compact") }
    }

    public var isSafeModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "eg_plugins_safe_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "eg_plugins_safe_mode") }
    }

    // MARK: - Lifecycle

    // UserDefaults key for the unclean-shutdown marker.
    // Set immediately before engine.start(); cleared after all plugins load
    // and on every explicit stopEngine(). If the app is killed or crashes
    // while plugins are running, the marker survives and is detected on the
    // next launch, triggering auto safe mode.
    private let launchMarkerKey = "eg_plugins_launching"

    public func startEngine(completion: (() -> Void)? = nil) {
        guard isEngineEnabled, !isSafeModeEnabled else {
            completion?(); return
        }

        // Unclean-shutdown detection -----------------------------------------------
        // If the marker is still set from a previous session, either the app was
        // force-killed while plugins were loading/running, or Python crashed.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: launchMarkerKey) {
            EGLogger.shared.log("PluginsController",
                "Unclean shutdown detected — auto-entering safe mode")
            isSafeModeEnabled = true
            // Give the run loop a moment so the caller's view hierarchy is stable
            // before the notification fires and triggers an alert.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(
                    name: .egPluginsSafeModeAutoEnabled, object: nil)
            }
            completion?()
            return
        }
        defaults.set(true, forKey: launchMarkerKey)
        // --------------------------------------------------------------------------

        // Re-sync bundled plugins when the app binary has been updated.
        syncBundledPlugins()
        // Repair any filePaths that are empty (plugins installed before filePath field was added)
        repairMissingFilePaths()
        let refs = plugins.filter { $0.isEnabled }.map { (id: $0.id, filePath: $0.filePath) }
        engine.start(plugins: refs) {
            // All plugins loaded cleanly — erase the crash marker.
            UserDefaults.standard.removeObject(forKey: self.launchMarkerKey)
            DispatchQueue.main.async {
                self.refreshPluginStates()
                NotificationCenter.default.post(name: .egPluginsChanged, object: nil)
                completion?()
            }
        }
    }

    /// Ensure every plugin's filePath resolves to an existing file.
    /// Handles both empty paths (pre-filePath field era) and stale absolute paths
    /// (container UUID changes on app reinstall/update).
    private func repairMissingFilePaths() {
        let dir = EGPluginsDirectory.plugins.url
        var updated = false
        var list = plugins
        for i in list.indices {
            let existing = list[i].filePath
            guard existing.isEmpty || !FileManager.default.fileExists(atPath: existing) else { continue }
            let candidate = dir.appendingPathComponent("\(list[i].id).plugin").path
            if FileManager.default.fileExists(atPath: candidate) {
                list[i].filePath = candidate
                updated = true
            }
        }
        if updated { plugins = list }
    }

    /// Overwrite installed bundled plugins with the current bundle copy when
    /// the file content differs.  Compares SHA-256 digests so we only write
    /// when necessary, and never skip a source change regardless of build
    /// version (safe for development builds where CFBundleVersion is static).
    /// Only updates plugins already in the installed list — new bundled plugins
    /// are not auto-installed (user opt-in is preserved).
    private func syncBundledPlugins() {
        let installedIds = Set(plugins.map { $0.id })
        let fm = FileManager.default
        let destDir = EGPluginsDirectory.plugins.url
        let bundleURLs = Bundle.main.urls(forResourcesWithExtension: "plugin",
                                          subdirectory: "Python/Plugins") ?? []
        for src in bundleURLs {
            let id = src.deletingPathExtension().lastPathComponent
            guard installedIds.contains(id) else { continue }
            let dest = destDir.appendingPathComponent("\(id).plugin")
            // Only overwrite when content differs (mtime or size change is the fast path)
            if let srcAttrs  = try? fm.attributesOfItem(atPath: src.path),
               let destAttrs = try? fm.attributesOfItem(atPath: dest.path),
               srcAttrs[.size] as? Int == destAttrs[.size] as? Int,
               srcAttrs[.modificationDate] as? Date == destAttrs[.modificationDate] as? Date {
                continue
            }
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: src, to: dest)) != nil {
                EGLogger.shared.log("PluginsController", "Updated bundled plugin: \(id)")
            }
        }
    }

    public func stopEngine(completion: (() -> Void)? = nil) {
        // Clean shutdown — erase the crash marker so the next startEngine
        // doesn't misdetect this as an unclean shutdown.
        UserDefaults.standard.removeObject(forKey: launchMarkerKey)
        let ids = plugins.map { $0.id }
        engine.stop(pluginIds: ids) {
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - Client info wiring (exposes account/user info to Python plugins)

    private var clientInfoDisposable: Disposable?

    /// Wire the AccountContext into EGPluginClientInfo so Python plugins can read
    /// account id, user id, and live connection state via _ios_bridge.
    /// Safe to call multiple times — the previous subscription is cancelled.
    public func wireClientInfo(context: AccountContext) {
        EGPluginClientInfo.accountIdProvider = { [weak context] in
            context?.account.id.int64 ?? 0
        }
        EGPluginClientInfo.userIdProvider = { [weak context] in
            context?.account.peerId.id._internalGetInt64Value() ?? 0
        }

        // Subscribe to connection status so get_connection_state() reflects live state.
        clientInfoDisposable?.dispose()
        let stateBox = ConnectionStateBox()
        clientInfoDisposable = context.account.network.connectionStatus.start(next: { status in
            stateBox.value = Self.stateString(status)
        })
        EGPluginClientInfo.connectionStateProvider = { stateBox.value }

        // Wire send_message() for plugins.
        EGPluginHooks.pluginSendMessageHandler = { [weak context] peerId, text in
            guard let ctx = context else { return }
            let pid = PeerId(peerId)
            let _ = enqueueMessages(
                account: ctx.account,
                peerId: pid,
                messages: [.message(
                    text: text,
                    attributes: [],
                    inlineStickers: [:],
                    mediaReference: nil,
                    threadId: nil,
                    replyToMessageId: nil,
                    replyToStoryId: nil,
                    localGroupingKey: nil,
                    correlationId: nil,
                    bubbleUpEmojiOrStickersets: []
                )]
            ).startStandalone()
        }

        // Wire send_reaction() for plugins — appends a builtin emoji reaction to a message.
        EGPluginHooks.pluginSendReactionHandler = { [weak context] peerId, messageId, emoticon in
            guard let ctx = context else { return }
            let pid   = PeerId(peerId)
            let msgId = MessageId(peerId: pid, namespace: Namespaces.Message.Cloud, id: messageId)
            let _ = updateMessageReactionsInteractively(
                account: ctx.account,
                messageIds: [msgId],
                reactions: [.builtin(emoticon)],
                isLarge: false,
                storeAsRecentlyUsed: true,
                add: true
            ).startStandalone()
        }
    }

    private static func stateString(_ status: ConnectionStatus) -> String {
        switch status {
        case .waitingForNetwork: return "waiting_for_network"
        case .connecting:        return "connecting"
        case .updating:          return "updating"
        case .online:            return "connected"
        }
    }

    // MARK: - Install

    /// Install from a file path. Returns the new EGPlugin on success.
    public func install(filePath: String, isEnabled: Bool = true) throws -> EGPlugin {
        let meta = try engine.installPlugin(from: filePath)
        let dest = EGPluginsDirectory.plugins.url.appendingPathComponent("\(meta.id).plugin")
        let plugin = EGPlugin(from: meta, filePath: dest.path, isEnabled: isEnabled)
        var all = plugins
        all.removeAll { $0.id == meta.id }
        all.append(plugin)
        plugins = all
        if isEnabled {
            engine.loadPlugin(id: meta.id, filePath: dest.path)
            refreshPluginStates()
        }
        NotificationCenter.default.post(name: .egPluginsChanged, object: nil)
        return plugin
    }

    // MARK: - Uninstall

    public func uninstall(_ pluginId: String) {
        engine.unloadPlugin(pluginId)
        var all = plugins
        all.removeAll { $0.id == pluginId }
        plugins = all
        let file = EGPluginsDirectory.plugins.url.appendingPathComponent("\(pluginId).plugin")
        try? FileManager.default.removeItem(at: file)
        // Remove plugin data directory
        try? FileManager.default.removeItem(at: EGPluginsDirectory.data(pluginId).url)
        // Remove all UserDefaults keys written by this plugin (eg.plugin.<id>.*)
        let prefix = "eg.plugin.\(pluginId)."
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { defaults.removeObject(forKey: $0) }
        NotificationCenter.default.post(name: .egPluginsChanged, object: nil)
    }

    // MARK: - Enable / Disable

    public func setEnabled(_ pluginId: String, enabled: Bool) {
        if let plugin = plugins.first(where: { $0.id == pluginId }) {
            if enabled {
                engine.loadPlugin(id: pluginId, filePath: plugin.filePath)
            } else {
                engine.unloadPlugin(pluginId)
            }
            var all = plugins
            if let idx = all.firstIndex(where: { $0.id == pluginId }) {
                all[idx].isEnabled = enabled
            }
            plugins = all
            refreshPluginStates()
        }
    }

    // MARK: - Live state (from engine)

    /// Sync engine error/not-responding states into the in-memory plugin structs so the UI reflects them.
    public func refreshPluginStates() {
        var all = plugins
        var changed = false
        for i in all.indices {
            let id = all[i].id
            let err = engine.isPluginError(id)
            let nr  = engine.isPluginNotResponding(id)
            let hs  = engine.pluginHasSettings(id)
            if all[i].isError != err || all[i].isNotResponding != nr || all[i].hasSettings != hs {
                all[i].isError = err
                all[i].isNotResponding = nr
                all[i].hasSettings = hs
                changed = true
            }
        }
        if changed {
            plugins = all
            NotificationCenter.default.post(name: .egPluginsChanged, object: nil)
        }
    }

    public func isPluginError(_ id: String) -> Bool { engine.isPluginError(id) }
    public func isPluginNotResponding(_ id: String) -> Bool { engine.isPluginNotResponding(id) }
    public func pluginHasSettings(_ id: String) -> Bool { engine.pluginHasSettings(id) }
    public func pluginErrorMessage(_ id: String) -> String? { engine.pluginErrorMessage(id) }

    // MARK: - Settings

    public func getSetting(_ pluginId: String, key: String, default def: Any?) -> Any? {
        engine.getPluginSetting(pluginId, key: key, default: def)
    }
    public func setSetting(_ pluginId: String, key: String, value: Any) {
        engine.setPluginSetting(pluginId, key: key, value: value)
    }
    public func getSettingsSchema(_ pluginId: String) -> [[String: Any]] {
        engine.getPluginSettingsSchema(pluginId) ?? []
    }
    public func invokeAction(_ pluginId: String, key: String) {
        engine.invokePluginAction(pluginId, key: key)
    }

    // MARK: - Plugin navigation callback (set by the settings VC hierarchy)

    /// Called when a plugin posts show_plugin_settings. Set from the presenting VC.
    public var onShowPluginSettings: ((String) -> Void)?

    // MARK: - UI notification observers

    private func observePluginUINotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EGPluginShowBulletinNotification"),
            object: nil, queue: .main
        ) { note in
            let title = note.userInfo?["title"] as? String ?? ""
            let text  = note.userInfo?["text"]  as? String ?? ""
            let icon  = note.userInfo?["icon"]  as? String ?? ""
            EGPluginDebugLog.shared.append(tag: "Bulletin", "observer fired: '\(title)'")
            Self.showBulletin(title: title, text: text, icon: icon)
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EGPluginShowToastNotification"),
            object: nil, queue: .main
        ) { note in
            let message  = note.userInfo?["message"]  as? String ?? ""
            let duration = note.userInfo?["duration"]  as? Double ?? 2.0
            Self.showToast(message: message, duration: duration)
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EGPluginShowSettingsNotification"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let pluginId = note.userInfo?["pluginId"] as? String else { return }
            self?.onShowPluginSettings?(pluginId)
        }

        NotificationCenter.default.addObserver(
            forName: .egPluginsSafeModeAutoEnabled,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.showSafeModeAlert()
        }
    }

    private func showSafeModeAlert() {
        guard let vc = Self.topViewController() else { return }
        let alert = UIAlertController(
            title: "Plugin Engine — Safe Mode",
            message: "The app was closed unexpectedly while plugins were running. "
                   + "Safe mode has been automatically enabled to prevent further instability.\n\n"
                   + "Disable a plugin you suspect caused the crash, then re-enable the engine "
                   + "from Settings → Plugins.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.addAction(UIAlertAction(title: "Disable Safe Mode", style: .destructive) { [weak self] _ in
            self?.isSafeModeEnabled = false
            NotificationCenter.default.post(name: .egPluginsChanged, object: nil)
        })
        vc.present(alert, animated: true)
    }

    // MARK: - Bulletin / toast presentation

    private static func topViewController() -> UIViewController? {
        // Collect all windows across all scenes (active or not).
        let allWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }

        // Prefer the key window; fall back to any window with a rootViewController.
        let win = allWindows.first(where: { $0.isKeyWindow })
                ?? allWindows.first(where: { $0.rootViewController != nil })

        if win == nil {
            EGPluginDebugLog.shared.append(tag: "Bulletin", "topViewController: no window found")
        }

        var vc = win?.rootViewController
        while let presented = vc?.presentedViewController,
              !presented.isBeingDismissed {
            vc = presented
        }
        while vc?.isBeingDismissed == true, let parent = vc?.presentingViewController {
            vc = parent
        }
        if let vc { EGPluginDebugLog.shared.append(tag: "Bulletin", "topViewController: \(type(of: vc))") }
        return vc
    }

    private static func showBulletin(title: String, text: String, icon: String) {
        guard let vc = topViewController() else {
            EGPluginDebugLog.shared.append(tag: "Bulletin", "showBulletin: no VC — giving up")
            return
        }
        let alert = UIAlertController(
            title: title,
            message: text.isEmpty ? nil : text,
            preferredStyle: .alert
        )
        if !icon.isEmpty {
            let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            if let img = UIImage(systemName: icon, withConfiguration: config) {
                alert.setValue(img, forKey: "image")
            }
        }
        vc.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            alert.dismiss(animated: true)
        }
    }

    private static func showToast(message: String, duration: Double) {
        guard let vc = topViewController(), let view = vc.view else { return }
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        label.alpha = 0
        UIView.animate(withDuration: 0.3) { label.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            UIView.animate(withDuration: 0.3, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    public static let egPluginsChanged = Notification.Name("app.exteragram.ios.pluginsChanged")
    /// Posted on main queue ~0.8s after launch when an unclean shutdown is detected.
    /// Observer should show the user an alert explaining safe mode was auto-enabled.
    public static let egPluginsSafeModeAutoEnabled = Notification.Name("app.exteragram.ios.pluginsSafeModeAutoEnabled")
}

// MARK: - Search/Nav State Bridge
// Bridges UIKit nav bar buttons with the SwiftUI list state.

@available(iOS 14.0, *)
private final class PluginsNavState: ObservableObject {
    @Published var isSearchActive: Bool = false
    @Published var searchText: String = ""
    var onSearchDeactivated: (() -> Void)?
    // Retains the bar button handler so UIBarButtonItem (weak target) doesn't dangle.
    var barHandler: AnyObject?

    func deactivate() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isSearchActive = false
            searchText = ""
        }
        onSearchDeactivated?()
    }
}

// MARK: - Nav Button Trampoline + Search Bar Delegate

private final class PluginsBarHandler: NSObject, UISearchBarDelegate {
    var searchTapped: (() -> Void)?
    var infoTapped: (() -> Void)?
    var cancelTapped: (() -> Void)?
    var onSearchTextChange: ((String) -> Void)?

    @objc func searchTappedObjc()  { searchTapped?()  }
    @objc func infoTappedObjc()   { infoTapped?()   }
    @objc func cancelTappedObjc() { cancelTapped?() }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        onSearchTextChange?(searchText)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - Share Sheet

@available(iOS 14.0, *)
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Animated Emoji Sticker View
// Mirrors Android's MediaDataController.setPlaceholderImage(..., "AnimatedEmojies", emoji, ...)
// Loads the Telegram AnimatedEmojies pack, finds the matching sticker, plays it once.

@available(iOS 14.0, *)
private struct AnimatedEmojiStickerView: UIViewRepresentable {
    let emoji: String
    let size: CGFloat
    let context: AccountContext

    func makeCoordinator() -> Coordinator {
        Coordinator(emoji: emoji, size: size, context: context)
    }

    func makeUIView(context uiCtx: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        uiCtx.coordinator.load(into: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator {
        private let emoji: String
        private let size: CGFloat
        private let context: AccountContext
        private var disposable: Disposable?
        private var fetchDisposable: Disposable?
        private var retainedNode: AnyObject?

        init(emoji: String, size: CGFloat, context: AccountContext) {
            self.emoji = emoji
            self.size = size
            self.context = context
        }

        deinit { disposable?.dispose(); fetchDisposable?.dispose() }

        func load(into container: UIView) {
            let iconSize = CGSize(width: size, height: size)
            let pixelSide = Int(size * UIScreen.main.scale)
            let emoji = self.emoji

            disposable = (context.engine.stickers.loadedStickerPack(
                    reference: .name("AnimatedEmojies"),
                    forceActualized: false)
                |> filter { if case .result = $0 { return true }; return false }
                |> take(1)
                |> deliverOnMainQueue
            ).startStandalone(next: { [weak container, weak self] result in
                guard let self,
                      let container,
                      case .result(_, let items, _) = result,
                      let item = items.first(where: {
                          $0.getStringRepresentationsOfIndexKeys().contains(emoji)
                      })
                else { return }

                let file = item.file._parse()
                let node = DefaultAnimatedStickerNodeImpl()
                node.setup(
                    source: AnimatedStickerResourceSource(
                        account: self.context.account,
                        resource: file.resource,
                        isVideo: file.isVideoSticker
                    ),
                    width: pixelSide,
                    height: pixelSide,
                    playbackMode: .once,
                    mode: .direct(cachePathPrefix: nil)
                )
                node.updateLayout(size: iconSize)
                node.overrideVisibility = true
                node.visibility = true
                node.frame = CGRect(origin: .zero, size: iconSize)
                node.view.frame = CGRect(origin: .zero, size: iconSize)
                container.addSubview(node.view)
                self.retainedNode = node

                self.fetchDisposable = freeMediaFileResourceInteractiveFetched(
                    account: self.context.account,
                    userLocation: .other,
                    fileReference: stickerPackFileReference(file),
                    resource: file.resource
                ).startStandalone()
            })
        }
    }
}

// MARK: - Empty State View
// Mirrors Android EmptyPluginsView: emoji sticker + descriptive text.
// isSearching=true  → 🔎 + PluginsNotFound
// isSearching=false → 📂 animated sticker + PluginsInfo

@available(iOS 14.0, *)
private struct PluginsEmptyView: View {
    let isSearching: Bool
    let lang: String
    let context: AccountContext
    let getNavigationController: () -> NavigationController?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if isSearching {
                Text("🔎")
                    .font(.system(size: 52))
                Text(i18n("Plugins.NoResults", lang))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                // Animated 📂 sticker — mirrors Android setPlaceholderImage("AnimatedEmojies","📂")
                AnimatedEmojiStickerView(emoji: "📂", size: 100, context: context)
                    .frame(width: 100, height: 100)

                // "Вы можете найти плагины в @exteraiPlugins."  (period is non-clickable)
                HStack(spacing: 0) {
                    Text("Вы можете найти плагины в ")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("@exteraiPlugins") {
                        let pd = context.sharedContext.currentPresentationData.with { $0 }
                        context.sharedContext.openExternalUrl(
                            context: context,
                            urlContext: .generic,
                            url: "https://t.me/exteraiPlugins",
                            forceExternal: false,
                            presentationData: pd,
                            navigationController: getNavigationController(),
                            dismissInput: {}
                        )
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.accentColor)
                    Text(".")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Plugin Icon View
// Loads a sticker from "packName/index" and displays it as an animated icon.

@available(iOS 14.0, *)
private struct EGPluginIconView: UIViewRepresentable {
    let iconUrl: String
    let size: CGFloat
    let context: AccountContext

    func makeCoordinator() -> Coordinator { Coordinator(iconUrl: iconUrl, size: size, context: context) }

    func makeUIView(context uiCtx: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        uiCtx.coordinator.load(into: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator {
        private let iconUrl: String
        private let size: CGFloat
        private let context: AccountContext
        private var loadDisposable: Disposable?
        private var fetchDisposable: Disposable?
        private var node: DefaultAnimatedStickerNodeImpl?

        init(iconUrl: String, size: CGFloat, context: AccountContext) {
            self.iconUrl = iconUrl; self.size = size; self.context = context
        }

        deinit { loadDisposable?.dispose(); fetchDisposable?.dispose() }

        func load(into container: UIView) {
            guard let slashIdx = iconUrl.lastIndex(of: "/"),
                  let index = Int(iconUrl[iconUrl.index(after: slashIdx)...]) else { return }
            let packName = String(iconUrl[iconUrl.startIndex..<slashIdx])
            let iconSize = CGSize(width: size, height: size)
            let pixelSide = Int(size * UIScreen.main.scale)

            loadDisposable = (context.engine.stickers.loadedStickerPack(
                    reference: .name(packName), forceActualized: false)
                |> deliverOnMainQueue
            ).startStandalone(next: { [weak container, weak self] result in
                guard let self, let container else { return }
                guard self.node == nil else { return }
                guard case .result(_, let items, _) = result, index < items.count else { return }

                let file = items[index].file._parse()
                let node = DefaultAnimatedStickerNodeImpl()
                node.setup(
                    source: AnimatedStickerResourceSource(
                        account: self.context.account,
                        resource: file.resource,
                        isVideo: file.isVideoSticker
                    ),
                    width: pixelSide, height: pixelSide,
                    playbackMode: .loop, mode: .direct(cachePathPrefix: nil)
                )
                node.updateLayout(size: iconSize)
                node.overrideVisibility = true
                node.visibility = true
                node.frame = CGRect(origin: .zero, size: iconSize)
                node.view.frame = CGRect(origin: .zero, size: iconSize)
                container.addSubview(node.view)
                self.node = node

                self.fetchDisposable = freeMediaFileResourceInteractiveFetched(
                    account: self.context.account,
                    userLocation: .other,
                    fileReference: stickerPackFileReference(file),
                    resource: file.resource
                ).startStandalone()
            })
        }
    }
}

// MARK: - Plugin Row
// Layout mirrors Android PluginCell (FrameLayout overlay pattern):
// - Content LinearLayout: margin l=16, t=16, r=16, b=8 (non-compact=VERTICAL header; compact=HORIZONTAL)
// - Toggle (checkBox): FrameLayout overlay gravity=TOP|RIGHT, margin t=16, r=24
// - Delete button: FrameLayout overlay gravity=BOTTOM|RIGHT, margin r=16, b=8
// - actionsLinear contains only share/openIn/pin/settings — NO delete

@available(iOS 14.0, *)
private struct PluginRowView: View {
    let plugin: EGPlugin
    let lang: String
    let isCompact: Bool
    let context: AccountContext
    let onUpdate: (EGPlugin) -> Void
    let onShare: () -> Void
    let onDelete: () -> Void
    let onSettings: () -> Void

    private var subtitleString: String {
        "v\(plugin.version)" + (plugin.subtitle.isEmpty ? "" : " · \(plugin.subtitle)")
    }

    var body: some View {
        ZStack {
            // Content area: LinearLayout(VERTICAL) margin l=16,t=16,r=16,b=8
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                descriptionSection
                permissionsSection
                // Divider: margin r=12, b=8
                Divider()
                    .padding(.trailing, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                // actionsLinear: share, openIn, pin, settings (no delete)
                actionsRow
                    .frame(height: 40)
            }
            .padding(.leading, 16)
            .padding(.top, 16)
            .padding(.trailing, 16)
            .padding(.bottom, 8)

            // Toggle overlay: gravity=TOP|RIGHT, margin t=16, r=24
            VStack {
                HStack {
                    Spacer()
                    if !plugin.isError && !plugin.isNotResponding {
                        Toggle("", isOn: Binding(
                            get: { plugin.isEnabled },
                            set: { newVal in
                                var updated = plugin
                                updated.isEnabled = newVal
                                onUpdate(updated)
                            }
                        ))
                        .labelsHidden()
                        .fixedSize()
                        .padding(.top, 16)
                        .padding(.trailing, 24)
                    }
                }
                Spacer()
            }

            // Delete overlay: gravity=BOTTOM|RIGHT, margin r=16, b=8
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    cellButton(
                        image: plugin.isNotResponding ? "ic_ab_other" : "msg_delete",
                        isDestructive: !plugin.isNotResponding
                    ) {
                        if !plugin.isNotResponding { onDelete() }
                    }
                    .frame(width: 40, height: 40)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                }
            }
        }
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var headerSection: some View {
        if isCompact {
            // compact=true → HORIZONTAL: icon(49×49, r=16) + name/subtitle
            HStack(alignment: .top, spacing: 0) {
                iconView(size: 49)
                    .padding(.trailing, 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.headline).foregroundColor(.primary).lineLimit(1)
                    Text(subtitleString).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }
            }
        } else {
            // compact=false → VERTICAL: icon(56×56, b=12) then name/subtitle below
            VStack(alignment: .leading, spacing: 0) {
                iconView(size: 56)
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.headline).foregroundColor(.primary).lineLimit(1)
                    Text(subtitleString).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var descriptionSection: some View {
        if plugin.isNotResponding {
            Text(i18n("Plugins.State.NotResponding", lang))
                .font(.subheadline).foregroundColor(.red)
                .padding(.trailing, 12).padding(.top, 6)
        } else if plugin.isError {
            Text(i18n("Plugins.State.Error", lang))
                .font(.subheadline).foregroundColor(.red)
                .padding(.trailing, 12).padding(.top, 6)
        } else if !plugin.pluginDescription.isEmpty {
            Text(plugin.pluginDescription)
                .font(.subheadline).foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 12).padding(.top, 6)
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        if !plugin.requiresPermissions.isEmpty {
            Text(plugin.requiresPermissions.joined(separator: " · "))
                .font(.footnote).foregroundColor(.orange)
                .padding(.top, 4)
        }
    }

    @ViewBuilder private var actionsRow: some View {
        HStack(spacing: 0) {
            cellButton(image: "msg_share") { onShare() }
            cellButton(image: "msg_openin") {}
            cellButton(image: plugin.isPinned ? "msg_unpin" : "msg_pin") {
                var updated = plugin
                updated.isPinned.toggle()
                onUpdate(updated)
            }
            if plugin.hasSettings && plugin.isEnabled && !plugin.isError && !plugin.isNotResponding {
                cellButton(image: "msg_settings") { onSettings() }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func iconView(size: CGFloat) -> some View {
        if let iconUrl = plugin.iconUrl, !iconUrl.isEmpty {
            EGPluginIconView(iconUrl: iconUrl, size: size, context: context)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color(UIColor.secondarySystemFill))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundColor(Color(UIColor.secondaryLabel))
                        .font(.system(size: size * 0.4))
                )
        }
    }

    @ViewBuilder
    private func cellButton(image: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(image)
                .renderingMode(.template)
                .foregroundColor(isDestructive ? .red : Color(UIColor.secondaryLabel))
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main Plugins View

@available(iOS 14.0, *)
private struct EGPluginsView: View {
    @Environment(\.lang) var lang: String
    weak var wrapperController: LegacyController?
    let context: AccountContext
    @ObservedObject var navState: PluginsNavState

    @State private var isEngineEnabled: Bool = PluginsController.shared.isEngineEnabled
    @State private var plugins: [EGPlugin] = PluginsController.shared.plugins
    @State private var isCompact: Bool = PluginsController.shared.isCompactView
    @State private var isSwitchingEngine: Bool = false
    @State private var pluginToShare: EGPlugin? = nil

    // Mirrors fillItems ordering: pinned (alphabetical) first, then non-pinned (alphabetical).
    // When searching, filters by name only (mirrors lambda$fillItems$1).
    private var displayPlugins: [EGPlugin] {
        var pool = plugins
        if !navState.searchText.isEmpty {
            pool = pool.filter { $0.name.lowercased().contains(navState.searchText.lowercased()) }
        }
        let pinned   = pool.filter {  $0.isPinned }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let unpinned = pool.filter { !$0.isPinned }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return pinned + unpinned
    }

    private var showEmptyState: Bool {
        guard isEngineEnabled else { return false }
        if !navState.searchText.isEmpty { return displayPlugins.isEmpty }
        return plugins.isEmpty
    }

    var body: some View {
        List {
            // Engine toggle — hidden while search is active
            if !navState.isSearchActive {
                Section {
                    Toggle(i18n("Plugins.Enable", lang), isOn: Binding(
                        get: { isEngineEnabled },
                        set: { _ in toggleEngine() }
                    ))
                    .disabled(isSwitchingEngine)
                }
            }

            // Each plugin = its own Section = its own rounded card
            if isEngineEnabled && !showEmptyState {
                ForEach(displayPlugins) { plugin in
                    Section {
                        PluginRowView(
                            plugin: plugin,
                            lang: lang,
                            isCompact: isCompact,
                            context: context,
                            onUpdate: { updated in
                                if let i = plugins.firstIndex(where: { $0.id == updated.id }) {
                                    plugins[i] = updated
                                    PluginsController.shared.plugins = plugins
                                }
                            },
                            onShare: { pluginToShare = plugin },
                            onDelete: {
                                PluginsController.shared.uninstall(plugin.id)
                                plugins = PluginsController.shared.plugins
                            },
                            onSettings: {
                                guard let nav = wrapperController?.navigationController as? NavigationController else { return }
                                let settingsVC = makePluginSettingsController(
                                    pluginId: plugin.id,
                                    pluginName: plugin.name,
                                    context: context
                                )
                                nav.pushViewController(settingsVC, animated: true)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        // Empty state floats over the list so Spacers can center it on the full screen
        .overlay(
            Group {
                if isEngineEnabled && showEmptyState {
                    PluginsEmptyView(
                        isSearching: !navState.searchText.isEmpty,
                        lang: lang,
                        context: context,
                        getNavigationController: { [weak wrapperController] in
                            wrapperController?.navigationController as? NavigationController
                        }
                    )
                }
            }
        )
        .sheet(item: $pluginToShare) { plugin in
            ActivityView(items: [plugin.name])
        }
    }

    // Mirrors togglePluginsEngine: guarded by isSwitchingEngineState,
    // collapses search when engine is disabled.
    private func toggleEngine() {
        guard !isSwitchingEngine else { return }
        isSwitchingEngine = true
        let enabling = !isEngineEnabled
        withAnimation(.easeInOut(duration: 0.15)) {
            isEngineEnabled = enabling
        }
        PluginsController.shared.isEngineEnabled = enabling
        if !enabling, navState.isSearchActive {
            navState.deactivate()
        }
        if enabling {
            PluginsController.shared.startEngine {
                self.isSwitchingEngine = false
                self.plugins = PluginsController.shared.plugins
            }
        } else {
            PluginsController.shared.stopEngine {
                self.isSwitchingEngine = false
            }
        }
    }
}

// MARK: - Public Entry Point

public func egPluginsController(context: AccountContext) -> ViewController {
    guard #available(iOS 14.0, *) else {
        return egSettingsController(context: context)
    }

    // Make account/user/connection info available to Python plugins.
    PluginsController.shared.wireClientInfo(context: context)

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let theme   = presentationData.theme
    let strings = presentationData.strings

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.title = i18n("Settings.Menu.Plugins", strings.baseLanguageCode)
    legacyController.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style

    let navState = PluginsNavState()
    let iconColor = theme.rootController.navigationBar.primaryTextColor

    let handler = PluginsBarHandler()
    navState.barHandler = handler   // navState outlives the buttons; keeps handler alive

    var infoButton: UIBarButtonItem? = nil
    var searchButton: UIBarButtonItem? = nil
    var cancelButton: UIBarButtonItem? = nil

    cancelButton = UIBarButtonItem(
        title: i18n("Plugins.Cancel", strings.baseLanguageCode),
        style: .plain,
        target: handler,
        action: #selector(PluginsBarHandler.cancelTappedObjc)
    )
    cancelButton?.tintColor = iconColor

    searchButton = UIBarButtonItem(
        image: PresentationResourcesRootController.navigationSearchIcon(theme)?
            .withTintColor(iconColor, renderingMode: .alwaysOriginal),
        style: .plain,
        target: handler,
        action: #selector(PluginsBarHandler.searchTappedObjc)
    )

    infoButton = UIBarButtonItem(
        image: PresentationResourcesRootController.navigationInfoIcon(theme)?
            .withTintColor(iconColor, renderingMode: .alwaysOriginal),
        style: .plain,
        target: handler,
        action: #selector(PluginsBarHandler.infoTappedObjc)
    )

    // Nav bar search bar — replaces title+back+info when search is active
    let navSearchBar = UISearchBar()
    navSearchBar.placeholder = i18n("Plugins.Search", strings.baseLanguageCode)
    navSearchBar.searchBarStyle = .minimal
    navSearchBar.tintColor = iconColor
    navSearchBar.sizeToFit()
    navSearchBar.delegate = handler

    handler.onSearchTextChange = { text in
        navState.searchText = text
    }

    handler.searchTapped = { [weak legacyController, weak navSearchBar] in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            navState.isSearchActive = true
        }
        legacyController?.navigationItem.titleView = navSearchBar
        legacyController?.navigationItem.setHidesBackButton(true, animated: false)
        legacyController?.navigationItem.rightBarButtonItems = [cancelButton].compactMap { $0 }
        navSearchBar?.becomeFirstResponder()
    }

    handler.infoTapped = { [weak legacyController] in
        legacyController?.navigationController?.pushViewController(
            egPluginsInfoController(context: context), animated: true)
    }

    let restoreNavBar = { [weak legacyController, weak navSearchBar] in
        navSearchBar?.text = ""
        navSearchBar?.resignFirstResponder()
        legacyController?.navigationItem.titleView = nil
        legacyController?.navigationItem.setHidesBackButton(false, animated: false)
        legacyController?.navigationItem.rightBarButtonItems = [infoButton, searchButton].compactMap { $0 }
    }

    handler.cancelTapped = {
        navState.deactivate()
        restoreNavBar()
    }

    navState.onSearchDeactivated = {
        restoreNavBar()
    }

    legacyController.navigationItem.rightBarButtonItems =
        [infoButton, searchButton].compactMap { $0 }

    let swiftUIView = EGSwiftUIView<EGPluginsView>(legacyController: legacyController, manageSafeArea: true) {
        EGPluginsView(wrapperController: legacyController, context: context, navState: navState)
    }
    let hostingController = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: hostingController)

    return legacyController
}
