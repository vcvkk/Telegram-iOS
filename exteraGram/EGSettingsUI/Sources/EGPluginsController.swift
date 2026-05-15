// MARK: exteraGram

import Foundation
import SwiftUI
import LegacyUI
import EGSwiftUI
import EGStrings
import AccountContext
import Display
import TelegramPresentationData
import SwiftSignalKit
import TelegramCore
import AnimatedStickerNode
import TelegramAnimatedStickerNode

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

    public var isExpanded: Bool = false
    public var isError: Bool = false
    public var isNotResponding: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, subtitle, version, iconUrl
        case pluginDescription = "description"
        case isEnabled, isPinned, hasSettings, requiresPermissions
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
        requiresPermissions: [String] = []
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
    }
}

// MARK: - Engine Stub

public final class PluginsController {
    public static let shared = PluginsController()
    private init() {}

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
        private var isShowing = false

        init(iconUrl: String, size: CGFloat, context: AccountContext) {
            self.iconUrl = iconUrl; self.size = size; self.context = context
        }

        deinit { loadDisposable?.dispose(); fetchDisposable?.dispose() }

        func load(into container: UIView) {
            guard let slashIdx = iconUrl.lastIndex(of: "/"),
                  let index = Int(iconUrl[iconUrl.index(after: slashIdx)...]) else {
                showPlaceholder(in: container)
                return
            }
            let packName = String(iconUrl[iconUrl.startIndex..<slashIdx])
            let iconSize = CGSize(width: size, height: size)
            let pixelSide = Int(size * UIScreen.main.scale)

            loadDisposable = (context.engine.stickers.loadedStickerPack(
                    reference: .name(packName), forceActualized: false)
                |> deliverOnMainQueue
            ).startStandalone(next: { [weak container, weak self] result in
                guard let self, let container else { return }
                guard !self.isShowing else { return }
                switch result {
                case .fetching:
                    break
                case .none:
                    self.isShowing = true
                    self.showPlaceholder(in: container)
                case .result(_, let items, _):
                    guard index < items.count else {
                        self.isShowing = true
                        self.showPlaceholder(in: container)
                        return
                    }
                    self.isShowing = true
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
                }
            })
        }

        private func showPlaceholder(in container: UIView) {
            container.backgroundColor = UIColor.secondarySystemFill
            if let img = UIImage(systemName: "puzzlepiece.extension") {
                let iv = UIImageView(image: img)
                iv.tintColor = UIColor.secondaryLabel
                iv.contentMode = .scaleAspectFit
                let inset = size * 0.3
                iv.frame = CGRect(x: inset / 2, y: inset / 2, width: size - inset, height: size - inset)
                container.addSubview(iv)
            }
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
                cellButton(image: "msg_settings") {}
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
                                plugins.removeAll { $0.id == plugin.id }
                                PluginsController.shared.plugins = plugins
                            }
                        )
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            plugins = PluginsController.shared.plugins
            isEngineEnabled = PluginsController.shared.isEngineEnabled
            isCompact = PluginsController.shared.isCompactView
        }
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
        // Stub: real engine calls PluginsController.init(runnable) / shutdown(runnable);
        // the runnable clears isSwitchingEngineState after async work completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isSwitchingEngine = false
        }
    }
}

// MARK: - Public Entry Point

public func egPluginsController(context: AccountContext) -> ViewController {
    guard #available(iOS 14.0, *) else {
        return egSettingsController(context: context)
    }

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
