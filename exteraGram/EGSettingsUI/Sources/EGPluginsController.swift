// MARK: exteraGram

import Foundation
import SwiftUI
import LegacyUI
import EGSwiftUI
import EGStrings
import AccountContext
import Display
import TelegramPresentationData

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

// MARK: - Nav Button Trampoline
// UIBarButtonItem requires @objc target; using a trampoline avoids primaryAction: quirks.

private final class PluginsBarHandler: NSObject {
    var searchTapped: (() -> Void)?
    var infoTapped: (() -> Void)?
    var cancelTapped: (() -> Void)?
    @objc func searchTappedObjc()  { searchTapped?()  }
    @objc func infoTappedObjc()   { infoTapped?()   }
    @objc func cancelTappedObjc() { cancelTapped?() }
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

// MARK: - Empty State View
// Mirrors Android EmptyPluginsView: emoji sticker + descriptive text.
// isSearching=true  → 🔎 + PluginsNotFound
// isSearching=false → 📂 + PluginsInfo (no plugins installed)

@available(iOS 14.0, *)
private struct PluginsEmptyView: View {
    let isSearching: Bool
    let lang: String

    var body: some View {
        VStack(spacing: 16) {
            Text(isSearching ? "🔎" : "📂")
                .font(.system(size: 52))
            Text(i18n(isSearching ? "Plugins.NoResults" : "Plugins.Empty", lang))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
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
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color(UIColor.secondarySystemFill))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "puzzlepiece.extension")
                    .foregroundColor(Color(UIColor.secondaryLabel))
                    .font(.system(size: size * 0.4))
            )
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
            // Engine toggle — hidden while search is active (mirrors fillItems: only added when !searching)
            if !navState.isSearchActive {
                Section {
                    Toggle(i18n("Plugins.Enable", lang), isOn: Binding(
                        get: { isEngineEnabled },
                        set: { _ in toggleEngine() }
                    ))
                    .disabled(isSwitchingEngine)
                }
            }

            // Inline search field — own section when active
            if isEngineEnabled && navState.isSearchActive {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(i18n("Plugins.Search", lang), text: $navState.searchText)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        if !navState.searchText.isEmpty {
                            Button(action: { navState.searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Color(UIColor.tertiaryLabel))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Empty state — own section
            if isEngineEnabled && showEmptyState {
                Section {
                    PluginsEmptyView(
                        isSearching: !navState.searchText.isEmpty,
                        lang: lang
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            // Each plugin = its own Section = its own rounded card (matches screenshot)
            if isEngineEnabled && !showEmptyState {
                ForEach(displayPlugins) { plugin in
                    Section {
                        PluginRowView(
                            plugin: plugin,
                            lang: lang,
                            isCompact: isCompact,
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

    handler.searchTapped = { [weak legacyController] in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            navState.isSearchActive = true
        }
        legacyController?.navigationItem.rightBarButtonItems =
            [cancelButton].compactMap { $0 }
    }

    handler.infoTapped = { [weak legacyController] in
        legacyController?.navigationController?.pushViewController(
            egPluginsInfoController(context: context), animated: true)
    }

    handler.cancelTapped = { [weak legacyController] in
        navState.deactivate()
        legacyController?.navigationItem.rightBarButtonItems =
            [infoButton, searchButton].compactMap { $0 }
    }

    navState.onSearchDeactivated = { [weak legacyController] in
        legacyController?.navigationItem.rightBarButtonItems =
            [infoButton, searchButton].compactMap { $0 }
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
