// MARK: exteraGram — .plugin file install sheet

import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import ComponentFlow
import ViewControllerComponent
import SheetComponent
import BalancedTextComponent
import BundleIconComponent
import GlassBarButtonComponent
import ButtonComponent
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import StickerResources
import EGSettingsUI

// MARK: - Metadata Model

struct EGPluginFileMetadata {
    var id: String?
    var name: String?
    var description: String?
    var author: String?
    var version: String?
    var icon: String?
    var requirements: [String] = []
    var appVersion: String?
    var sdkVersion: String?

    var isEmpty: Bool {
        return id == nil && name == nil && description == nil && author == nil && version == nil
    }

    static func parse(from text: String) -> EGPluginFileMetadata {
        var meta = EGPluginFileMetadata()
        for line in text.components(separatedBy: .newlines) {
            guard let (key, value) = parseLine(line) else { continue }
            switch key {
            case "id":          meta.id = value
            case "name":        meta.name = value
            case "description": meta.description = value
            case "author":      meta.author = value
            case "version":     meta.version = value
            case "icon":
                if let slash = value.lastIndex(of: "/"),
                   Int(value[value.index(after: slash)...]) != nil {
                    meta.icon = value
                }
            case "requirements":
                meta.requirements = value.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "app_version": meta.appVersion = value
            case "sdk_version": meta.sdkVersion = value
            default:            break
            }
        }
        return meta
    }

    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eqIdx = trimmed.firstIndex(of: "=") else { return nil }
        let rawKey = String(trimmed[trimmed.startIndex..<eqIdx])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let valuePart = String(trimmed[trimmed.index(after: eqIdx)...])
            .trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty, !valuePart.isEmpty else { return nil }
        for quote: Character in ["\"", "'"] {
            let q = String(quote)
            guard valuePart.hasPrefix(q) else { continue }
            let afterOpen = String(valuePart.dropFirst())
            guard let closeRange = afterOpen.range(of: q) else { continue }
            return (rawKey, String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound]))
        }
        return nil
    }
}

// MARK: - Plugin Icon Component (animated sticker with fallback)

private final class EGPluginIconComponent: Component {
    let iconUrl: String?
    let accountContext: AccountContext
    let size: CGFloat

    init(iconUrl: String?, accountContext: AccountContext, size: CGFloat) {
        self.iconUrl = iconUrl
        self.accountContext = accountContext
        self.size = size
    }

    static func ==(lhs: EGPluginIconComponent, rhs: EGPluginIconComponent) -> Bool {
        return lhs.iconUrl == rhs.iconUrl && lhs.size == rhs.size
    }

    final class View: UIView {
        private let fallbackBg = UIView()
        private let fallbackIcon = UIImageView()
        private var stickerNode: DefaultAnimatedStickerNodeImpl?
        private var packDisposable: Disposable?
        private var fetchDisposable: Disposable?
        private var loadedIconUrl: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            fallbackBg.backgroundColor = UIColor.secondarySystemFill
            fallbackBg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(fallbackBg)
            let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            fallbackIcon.image = UIImage(systemName: "puzzlepiece.extension", withConfiguration: cfg)
            fallbackIcon.tintColor = UIColor.secondaryLabel
            fallbackIcon.contentMode = .center
            fallbackIcon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(fallbackIcon)
        }
        required init?(coder: NSCoder) { fatalError() }

        deinit {
            let node = stickerNode; let d1 = packDisposable; let d2 = fetchDisposable
            if Thread.isMainThread {
                node?.view.removeFromSuperview(); d1?.dispose(); d2?.dispose()
            } else {
                DispatchQueue.main.async { node?.view.removeFromSuperview(); d1?.dispose(); d2?.dispose() }
            }
        }

        func update(component: EGPluginIconComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let size = component.size
            layer.cornerRadius = size * 0.22

            if loadedIconUrl != component.iconUrl {
                loadedIconUrl = component.iconUrl
                stickerNode?.view.removeFromSuperview(); stickerNode = nil
                packDisposable?.dispose(); fetchDisposable?.dispose()
                fallbackBg.isHidden = false; fallbackIcon.isHidden = false

                if let url = component.iconUrl, !url.isEmpty {
                    loadSticker(url, size: size, context: component.accountContext)
                }
            }
            return CGSize(width: size, height: size)
        }

        private func loadSticker(_ iconStr: String, size: CGFloat, context: AccountContext) {
            guard let slashIdx = iconStr.lastIndex(of: "/"),
                  let index = Int(iconStr[iconStr.index(after: slashIdx)...]) else { return }
            let packName = String(iconStr[iconStr.startIndex..<slashIdx])
            let iconSize = CGSize(width: size, height: size)
            let pixelSide = Int(size * UIScreen.main.scale)

            packDisposable = (context.engine.stickers.loadedStickerPack(reference: .name(packName), forceActualized: false)
                |> deliverOnMainQueue
            ).startStandalone(next: { [weak self] result in
                guard let self, self.stickerNode == nil else { return }
                guard case .result(_, let items, _) = result, index < items.count else { return }
                let file = items[index].file._parse()
                let node = DefaultAnimatedStickerNodeImpl()
                node.setup(
                    source: AnimatedStickerResourceSource(account: context.account, resource: file.resource, isVideo: file.isVideoSticker),
                    width: pixelSide, height: pixelSide,
                    playbackMode: .loop, mode: .direct(cachePathPrefix: nil)
                )
                node.updateLayout(size: iconSize)
                node.overrideVisibility = true; node.visibility = true
                node.frame = CGRect(origin: .zero, size: iconSize)
                node.view.frame = CGRect(origin: .zero, size: iconSize)
                self.fallbackBg.isHidden = true; self.fallbackIcon.isHidden = true
                self.addSubview(node.view)
                self.stickerNode = node

                self.fetchDisposable = freeMediaFileResourceInteractiveFetched(
                    account: context.account, userLocation: .other,
                    fileReference: stickerPackFileReference(file), resource: file.resource
                ).startStandalone()
            })
        }
    }

    func makeView() -> View { View(frame: .zero) }
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

// MARK: - Pill Component ("Unknown source" red capsule)

private final class EGSourcePillComponent: Component {
    static func ==(lhs: EGSourcePillComponent, rhs: EGSourcePillComponent) -> Bool { return true }

    final class View: UIView {
        private let iconView = UIImageView()
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            iconView.image = UIImage(systemName: "questionmark.circle.fill", withConfiguration: cfg)
            iconView.tintColor = .white
            iconView.contentMode = .scaleAspectFit
            label.text = "Unknown source"
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            backgroundColor = UIColor.systemRed.withAlphaComponent(0.82)
            addSubview(iconView)
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }

        func update(component: EGSourcePillComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let h: CGFloat = 24
            let iconSide: CGFloat = 13
            let gap: CGFloat = 4
            let hPad: CGFloat = 10
            let textW = label.sizeThatFits(CGSize(width: 200, height: h)).width
            let totalW = hPad + iconSide + gap + textW + hPad
            layer.cornerRadius = h / 2
            iconView.frame = CGRect(x: hPad, y: (h - iconSide) / 2, width: iconSide, height: iconSide)
            label.frame = CGRect(x: hPad + iconSide + gap, y: (h - 15) / 2, width: textW, height: 15)
            return CGSize(width: totalW, height: h)
        }
    }

    func makeView() -> View { View(frame: .zero) }
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

// MARK: - Sheet Content

private final class EGPluginInstallSheetContent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let metadata: EGPluginFileMetadata
    let filePath: String
    let accountContext: AccountContext
    let dismiss: () -> Void
    let share: () -> Void

    init(metadata: EGPluginFileMetadata, filePath: String, accountContext: AccountContext, dismiss: @escaping () -> Void, share: @escaping () -> Void) {
        self.metadata = metadata
        self.filePath = filePath
        self.accountContext = accountContext
        self.dismiss = dismiss
        self.share = share
    }

    static func ==(lhs: EGPluginInstallSheetContent, rhs: EGPluginInstallSheetContent) -> Bool {
        return lhs.metadata.id == rhs.metadata.id && lhs.filePath == rhs.filePath
    }

    final class State: ComponentState {
        var isInstalling = false

        func install(metadata: EGPluginFileMetadata, filePath: String, dismiss: @escaping () -> Void) {
            guard !isInstalling else { return }
            isInstalling = true
            updated(transition: .immediate)
            let meta = metadata
            let fp = filePath
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let pluginId = meta.id ?? UUID().uuidString
                if let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    let dir = supportDir.appendingPathComponent("EGPlugins", isDirectory: true)
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent("\(pluginId).plugin")
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(atPath: fp, toPath: dest.path)
                }
                let plugin = EGPlugin(
                    id: pluginId,
                    name: meta.name ?? "Unknown Plugin",
                    subtitle: meta.author ?? "",
                    pluginDescription: meta.description ?? "",
                    version: meta.version ?? "1.0",
                    iconUrl: meta.icon,
                    isEnabled: true,
                    requiresPermissions: meta.requirements
                )
                DispatchQueue.main.async {
                    var plugins = PluginsController.shared.plugins
                    if let idx = plugins.firstIndex(where: { $0.id == pluginId }) {
                        plugins[idx] = plugin
                    } else {
                        plugins.append(plugin)
                    }
                    PluginsController.shared.plugins = plugins
                    dismiss()
                }
            }
        }
    }

    func makeState() -> State { State() }

    static var body: Body {
        let closeButton  = Child(GlassBarButtonComponent.self)
        let shareButton  = Child(GlassBarButtonComponent.self)
        let iconView     = Child(EGPluginIconComponent.self)
        let titleText    = Child(BalancedTextComponent.self)
        let descText     = Child(BalancedTextComponent.self)
        let metaText     = Child(BalancedTextComponent.self)
        let sourcePill   = Child(EGSourcePillComponent.self)
        let installBtn   = Child(ButtonComponent.self)

        return { context in
            let env = context.environment[ViewControllerComponentContainer.Environment.self].value
            let theme = env.theme
            let state = context.state
            let component = context.component
            let isDark = theme.overallDarkAppearance

            let hPad: CGFloat = 16.0
            let width = context.availableSize.width
            var y: CGFloat = 16.0

            // ── Top bar: close (top-left) + share (right of close) ──
            let closeBtn = closeButton.update(
                component: GlassBarButtonComponent(
                    size: CGSize(width: 44, height: 44),
                    backgroundColor: nil,
                    isDark: isDark,
                    state: .glass,
                    component: AnyComponentWithIdentity(id: "close", component: AnyComponent(
                        BundleIconComponent(name: "Navigation/Close", tintColor: theme.chat.inputPanel.panelControlColor)
                    )),
                    action: { _ in component.dismiss() }
                ),
                availableSize: CGSize(width: 44, height: 44),
                transition: .immediate
            )
            context.add(closeBtn.position(CGPoint(x: hPad + closeBtn.size.width / 2, y: y + closeBtn.size.height / 2)))

            let shareBtn = shareButton.update(
                component: GlassBarButtonComponent(
                    size: CGSize(width: 44, height: 44),
                    backgroundColor: nil,
                    isDark: isDark,
                    state: .glass,
                    component: AnyComponentWithIdentity(id: "share", component: AnyComponent(
                        BundleIconComponent(name: "Chat/Context Menu/Share", tintColor: theme.chat.inputPanel.panelControlColor)
                    )),
                    action: { _ in component.share() }
                ),
                availableSize: CGSize(width: 44, height: 44),
                transition: .immediate
            )
            context.add(shareBtn.position(CGPoint(x: width - hPad - shareBtn.size.width / 2, y: y + shareBtn.size.height / 2)))

            y += max(closeBtn.size.height, shareBtn.size.height) + 16.0

            // ── Plugin icon ───────────────────────────────────────
            let iconSide: CGFloat = 80.0
            let icon = iconView.update(
                component: EGPluginIconComponent(
                    iconUrl: component.metadata.icon,
                    accountContext: component.accountContext,
                    size: iconSide
                ),
                availableSize: CGSize(width: iconSide, height: iconSide),
                transition: .immediate
            )
            context.add(icon.position(CGPoint(x: width / 2, y: y + iconSide / 2)))
            y += iconSide + 18.0

            // ── Plugin name (bold 24pt, centered) ─────────────────────
            let nameStr = component.metadata.name ?? "Plugin"
            let title = titleText.update(
                component: BalancedTextComponent(
                    text: .plain(NSAttributedString(string: nameStr, font: Font.bold(24.0), textColor: theme.actionSheet.primaryTextColor)),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 0,
                    lineSpacing: 0.1
                ),
                availableSize: CGSize(width: width - hPad * 2, height: 300),
                transition: .immediate
            )
            context.add(title.position(CGPoint(x: width / 2, y: y + title.size.height / 2)))
            y += title.size.height + 10.0

            // ── Description (regular 15pt, centered, if present) ────
            if let desc = component.metadata.description, !desc.isEmpty {
                let desc = descText.update(
                    component: BalancedTextComponent(
                        text: .plain(NSAttributedString(string: desc, font: Font.regular(15.0), textColor: theme.actionSheet.secondaryTextColor)),
                        horizontalAlignment: .center,
                        maximumNumberOfLines: 0,
                        lineSpacing: 0.2,
                        insets: UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
                    ),
                    availableSize: CGSize(width: width - hPad * 2, height: 400),
                    transition: .immediate
                )
                context.add(desc.position(CGPoint(x: width / 2, y: y + desc.size.height / 2)))
                y += desc.size.height + 10.0
            }

            // ── version · author (secondary 13pt, centered) ─────────
            let metaParts = [component.metadata.version, component.metadata.author]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !metaParts.isEmpty {
                let metaStr = metaParts.joined(separator: " · ")
                let meta = metaText.update(
                    component: BalancedTextComponent(
                        text: .plain(NSAttributedString(string: metaStr, font: Font.regular(13.0), textColor: theme.actionSheet.secondaryTextColor)),
                        horizontalAlignment: .center,
                        maximumNumberOfLines: 1,
                        lineSpacing: 0.1
                    ),
                    availableSize: CGSize(width: width - hPad * 2, height: 40),
                    transition: .immediate
                )
                context.add(meta.position(CGPoint(x: width / 2, y: y + meta.size.height / 2)))
                y += meta.size.height + 10.0
            }

            // ── "Unknown source" red pill (centered) ────────────────
            let pill = sourcePill.update(
                component: EGSourcePillComponent(),
                availableSize: CGSize(width: width - hPad * 2, height: 30),
                transition: .immediate
            )
            context.add(pill.position(CGPoint(x: width / 2, y: y + pill.size.height / 2)))
            y += pill.size.height + 24.0

            // ── Install Plugin button (glass, full width) ────────────
            let buttonInsets = ContainerViewLayout.concentricInsets(
                bottomInset: env.safeInsets.bottom,
                innerDiameter: 52.0,
                sideInset: 16.0
            )

            let btnLabel = state.isInstalling ? "Installing…" : "Install Plugin"
            let installContent: [AnyComponentWithIdentity<Empty>] = [
                AnyComponentWithIdentity(id: 0, component: AnyComponent(ButtonTextContentComponent(
                    text: btnLabel,
                    badge: 0,
                    textColor: theme.list.itemCheckColors.foregroundColor,
                    badgeBackground: theme.list.itemCheckColors.foregroundColor,
                    badgeForeground: theme.list.itemCheckColors.fillColor
                )))
            ]

            let btn = installBtn.update(
                component: ButtonComponent(
                    background: ButtonComponent.Background(
                        style: .glass,
                        color: theme.list.itemCheckColors.fillColor,
                        foreground: theme.list.itemCheckColors.foregroundColor,
                        pressedColor: theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.9)
                    ),
                    content: AnyComponentWithIdentity(
                        id: AnyHashable(0),
                        component: AnyComponent(HStack(installContent, spacing: 4.0))
                    ),
                    isEnabled: !state.isInstalling,
                    displaysProgress: state.isInstalling,
                    action: {
                        state.install(
                            metadata: component.metadata,
                            filePath: component.filePath,
                            dismiss: component.dismiss
                        )
                    }
                ),
                availableSize: CGSize(width: width - buttonInsets.left - buttonInsets.right, height: 52.0),
                transition: .immediate
            )
            context.add(btn.position(CGPoint(x: width / 2, y: y + btn.size.height / 2)))
            y += btn.size.height + buttonInsets.bottom

            return CGSize(width: width, height: y)
        }
    }
}

// MARK: - Sheet Wrapper Component

private final class EGPluginInstallSheetComponent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let metadata: EGPluginFileMetadata
    let filePath: String
    let accountContext: AccountContext

    init(metadata: EGPluginFileMetadata, filePath: String, accountContext: AccountContext) {
        self.metadata = metadata
        self.filePath = filePath
        self.accountContext = accountContext
    }

    static func ==(lhs: EGPluginInstallSheetComponent, rhs: EGPluginInstallSheetComponent) -> Bool {
        return lhs.metadata.id == rhs.metadata.id && lhs.filePath == rhs.filePath
    }

    static var body: Body {
        let sheet = Child(SheetComponent<EnvironmentType>.self)
        let animateOut = StoredActionSlot(Action<Void>.self)
        let sheetExternalState = SheetComponent<EnvironmentType>.ExternalState()

        return { context in
            let env = context.environment[EnvironmentType.self]
            let controller = env.controller

            let dismiss: (Bool) -> Void = { animated in
                if animated {
                    animateOut.invoke(Action { _ in
                        (controller() as? EGPluginInstallScreen)?.dismiss(completion: nil)
                    })
                } else {
                    (controller() as? EGPluginInstallScreen)?.dismiss(completion: nil)
                }
            }

            let share: () -> Void = {
                guard let vc = controller() as? EGPluginInstallScreen else { return }
                let avc = UIActivityViewController(
                    activityItems: [URL(fileURLWithPath: context.component.filePath)],
                    applicationActivities: nil
                )
                avc.popoverPresentationController?.sourceView = vc.view
                vc.present(avc, animated: true)
            }

            let sheet = sheet.update(
                component: SheetComponent<EnvironmentType>(
                    content: AnyComponent<EnvironmentType>(EGPluginInstallSheetContent(
                        metadata: context.component.metadata,
                        filePath: context.component.filePath,
                        accountContext: context.component.accountContext,
                        dismiss: { dismiss(true) },
                        share: share
                    )),
                    style: .glass,
                    backgroundColor: .color(env.theme.actionSheet.opaqueItemBackgroundColor),
                    followContentSizeChanges: true,
                    clipsContent: true,
                    autoAnimateOut: false,
                    externalState: sheetExternalState,
                    animateOut: animateOut,
                    onPan: {},
                    willDismiss: {}
                ),
                environment: {
                    env
                    SheetComponentEnvironment(
                        metrics: env.metrics,
                        deviceMetrics: env.deviceMetrics,
                        isDisplaying: env.value.isVisible,
                        isCentered: env.metrics.widthClass == .regular,
                        hasInputHeight: !env.inputHeight.isZero,
                        regularMetricsSize: CGSize(width: 430, height: 900),
                        dismiss: { animated in dismiss(animated) }
                    )
                },
                availableSize: context.availableSize,
                transition: context.transition
            )
            context.add(sheet
                .position(CGPoint(x: context.availableSize.width / 2, y: context.availableSize.height / 2))
            )

            if let vc = controller(), !vc.automaticallyControlPresentationContextLayout {
                var sideInset: CGFloat = 0
                var bottomInset = max(env.safeInsets.bottom, sheetExternalState.contentHeight)
                if case .regular = env.metrics.widthClass {
                    sideInset = floor((context.availableSize.width - 430) / 2) - 12
                    bottomInset = (context.availableSize.height - sheetExternalState.contentHeight) / 2 + sheetExternalState.contentHeight
                }
                let layout = ContainerViewLayout(
                    size: context.availableSize,
                    metrics: env.metrics,
                    deviceMetrics: env.deviceMetrics,
                    intrinsicInsets: UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0),
                    safeInsets: UIEdgeInsets(top: 0, left: max(sideInset, env.safeInsets.left), bottom: 0, right: max(sideInset, env.safeInsets.right)),
                    additionalInsets: .zero,
                    statusBarHeight: env.statusBarHeight,
                    inputHeight: nil,
                    inputHeightIsInteractivellyChanging: false,
                    inVoiceOver: false
                )
                vc.presentationContext.containerLayoutUpdated(layout, transition: context.transition.containedViewLayoutTransition)
            }

            return context.availableSize
        }
    }
}

// MARK: - View Controller

final class EGPluginInstallScreen: ViewControllerComponentContainer {
    init(metadata: EGPluginFileMetadata, filePath: String, context: AccountContext) {
        super.init(
            context: context,
            component: EGPluginInstallSheetComponent(
                metadata: metadata,
                filePath: filePath,
                accountContext: context
            ),
            navigationBarAppearance: .none,
            statusBarStyle: .ignore,
            theme: .default
        )
        self.navigationPresentation = .flatModal
        self.automaticallyControlPresentationContextLayout = false
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.disablesInteractiveModalDismiss = true
    }

    func dismissAnimated() {
        if let view = self.node.hostView.findTaggedView(tag: SheetComponent<ViewControllerComponentContainer.Environment>.View.Tag()) as? SheetComponent<ViewControllerComponentContainer.Environment>.View {
            view.dismissAnimated()
        }
    }
}

// MARK: - Presentation Helper

func presentEGPluginMetadataIfAvailable(
    file: TelegramMediaFile,
    context: AccountContext,
    navigationController: NavigationController?
) {
    let _ = (context.account.postbox.mediaBox.resourceData(file.resource, option: .complete(waitUntilFetchStatus: true))
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { data in
        guard data.complete,
              let text = try? String(contentsOfFile: data.path, encoding: .utf8) else { return }
        let metadata = EGPluginFileMetadata.parse(from: text)
        guard !metadata.isEmpty else { return }
        let vc = EGPluginInstallScreen(metadata: metadata, filePath: data.path, context: context)
        navigationController?.pushViewController(vc)
    })
}
