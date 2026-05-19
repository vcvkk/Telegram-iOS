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

// MARK: - Plugin Icon Component (animated sticker, blue fallback, puzzle badge)

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
        // Icon content in a clipping subview so the badge can overflow
        private let clipView = UIView()
        private let fallbackBg = UIView()
        private let fallbackIcon = UIImageView()
        // Badge: white ring → blue dot → puzzle icon (bottom-right, +3 offset)
        private let badgeView = UIView()
        private let badgeOuterCircle = UIView()
        private let badgeInnerCircle = UIView()
        private let badgeIconView = UIImageView()

        private var stickerNode: DefaultAnimatedStickerNodeImpl?
        private var packDisposable: Disposable?
        private var fetchDisposable: Disposable?
        private var loadedIconUrl: String?

        override init(frame: CGRect) {
            super.init(frame: frame)

            // Clip view carries the rounded corners and clips sticker/fallback
            clipView.clipsToBounds = true
            addSubview(clipView)

            // Fallback: blue background + white filled puzzle piece (Fix 3)
            fallbackBg.backgroundColor = UIColor.systemBlue
            fallbackBg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            clipView.addSubview(fallbackBg)

            let cfg = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
            fallbackIcon.image = UIImage(systemName: "puzzlepiece.extension.fill", withConfiguration: cfg)
            fallbackIcon.tintColor = .white
            fallbackIcon.contentMode = .center
            fallbackIcon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            clipView.addSubview(fallbackIcon)

            // Badge (Fix 6): mirrors InstallerPreviewSheet — white ring, blue dot, puzzle icon
            addSubview(badgeView)

            badgeOuterCircle.backgroundColor = UIColor.systemBackground
            badgeOuterCircle.layer.cornerRadius = 13
            badgeOuterCircle.clipsToBounds = true
            badgeOuterCircle.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
            badgeView.addSubview(badgeOuterCircle)

            badgeInnerCircle.backgroundColor = UIColor.systemBlue
            badgeInnerCircle.layer.cornerRadius = 11
            badgeInnerCircle.clipsToBounds = true
            badgeInnerCircle.frame = CGRect(x: 2, y: 2, width: 22, height: 22)
            badgeView.addSubview(badgeInnerCircle)

            let badgeCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            badgeIconView.image = UIImage(systemName: "puzzlepiece.extension.fill", withConfiguration: badgeCfg)
            badgeIconView.tintColor = .white
            badgeIconView.contentMode = .center
            badgeIconView.frame = CGRect(x: 2, y: 2, width: 22, height: 22)
            badgeView.addSubview(badgeIconView)
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
            clipView.frame = CGRect(x: 0, y: 0, width: size, height: size)
            clipView.layer.cornerRadius = size * 0.22

            // Badge: offset (+3, +3) from bottom-right like SwiftUI .offset(x:3, y:3) at .bottomTrailing
            let badgeSize: CGFloat = 26
            badgeView.frame = CGRect(x: size - badgeSize + 3, y: size - badgeSize + 3, width: badgeSize, height: badgeSize)

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
                // Fix 5: set visibility flags and add to hierarchy BEFORE setup()
                // so didEnterHierarchy fires and isDisplaying=true when setup triggers rendering
                node.updateLayout(size: iconSize)
                node.overrideVisibility = true
                node.visibility = true
                node.frame = CGRect(origin: .zero, size: iconSize)
                node.view.frame = CGRect(origin: .zero, size: iconSize)
                self.fallbackBg.isHidden = true
                self.fallbackIcon.isHidden = true
                self.clipView.addSubview(node.view)
                self.stickerNode = node

                node.setup(
                    source: AnimatedStickerResourceSource(account: context.account, resource: file.resource, isVideo: file.isVideoSticker),
                    width: pixelSide, height: pixelSide,
                    playbackMode: .loop, mode: .direct(cachePathPrefix: nil)
                )

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
        private let bgView = UIView()
        private let iconView = UIImageView()
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            bgView.clipsToBounds = true
            bgView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.82)
            addSubview(bgView)
            let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            iconView.image = UIImage(systemName: "questionmark.circle.fill", withConfiguration: cfg)
            iconView.tintColor = .white
            iconView.contentMode = .scaleAspectFit
            label.text = "Unknown source"
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            bgView.addSubview(iconView)
            bgView.addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }

        func update(component: EGSourcePillComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let h: CGFloat = 24
            let iconSide: CGFloat = 13
            let gap: CGFloat = 4
            let hPad: CGFloat = 10
            let textW = label.sizeThatFits(CGSize(width: 200, height: h)).width
            let totalW = hPad + iconSide + gap + textW + hPad
            bgView.frame = CGRect(x: 0, y: 0, width: totalW, height: h)
            bgView.layer.cornerRadius = h / 2
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

// MARK: - Author Row Component (version · @tappable-usernames)

private final class EGAuthorRowComponent: Component {
    let version: String?
    let author: String?
    let textColor: UIColor
    let onUsernameTap: (String) -> Void

    init(version: String?, author: String?, textColor: UIColor, onUsernameTap: @escaping (String) -> Void) {
        self.version = version
        self.author = author
        self.textColor = textColor
        self.onUsernameTap = onUsernameTap
    }

    static func ==(lhs: EGAuthorRowComponent, rhs: EGAuthorRowComponent) -> Bool {
        return lhs.version == rhs.version && lhs.author == rhs.author
    }

    final class View: UIView {
        private let stack = UIStackView()
        private var usernameButtons: [(button: UIButton, username: String)] = []
        private var onUsernameTap: ((String) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            stack.axis = .horizontal
            stack.spacing = 0
            stack.alignment = .center
            addSubview(stack)
        }
        required init?(coder: NSCoder) { fatalError() }

        func update(component: EGAuthorRowComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            usernameButtons = []
            onUsernameTap = component.onUsernameTap

            func addLabel(_ text: String, color: UIColor) {
                let l = UILabel()
                l.text = text
                l.font = .systemFont(ofSize: 13)
                l.textColor = color
                stack.addArrangedSubview(l)
            }

            if let v = component.version {
                addLabel(v, color: component.textColor)
            }
            if component.version != nil && component.author != nil {
                addLabel(" · ", color: component.textColor)
            }
            if let author = component.author {
                for seg in Self.parseSegments(author) {
                    if seg.isUsername {
                        let btn = UIButton(type: .system)
                        btn.setTitle(seg.text, for: .normal)
                        btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
                        btn.setTitleColor(.systemBlue, for: .normal)
                        btn.contentEdgeInsets = .zero
                        btn.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
                        usernameButtons.append((btn, seg.rawUsername))
                        stack.addArrangedSubview(btn)
                    } else {
                        addLabel(seg.text, color: component.textColor)
                    }
                }
            }

            let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            stack.frame = CGRect(origin: .zero, size: size)
            return size
        }

        @objc private func buttonTapped(_ sender: UIButton) {
            if let pair = usernameButtons.first(where: { $0.button === sender }) {
                onUsernameTap?(pair.username)
            }
        }

        private struct Segment {
            let text: String
            let isUsername: Bool
            var rawUsername: String { isUsername ? String(text.dropFirst()) : text }
        }

        private static func parseSegments(_ author: String) -> [Segment] {
            guard let re = try? NSRegularExpression(pattern: "@[a-zA-Z][a-zA-Z0-9_]{1,31}") else {
                return [Segment(text: author, isUsername: false)]
            }
            var result: [Segment] = []
            var last = author.startIndex
            for match in re.matches(in: author, range: NSRange(author.startIndex..., in: author)) {
                guard let r = Range(match.range, in: author) else { continue }
                if r.lowerBound > last { result.append(Segment(text: String(author[last..<r.lowerBound]), isUsername: false)) }
                result.append(Segment(text: String(author[r]), isUsername: true))
                last = r.upperBound
            }
            if last < author.endIndex { result.append(Segment(text: String(author[last...]), isUsername: false)) }
            return result.isEmpty ? [Segment(text: author, isUsername: false)] : result
        }
    }

    func makeView() -> View { View(frame: .zero) }
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

// MARK: - Toggle Row Component ("Enable after installation")

private final class EGToggleRowComponent: Component {
    let isOn: Bool
    let valueChanged: (Bool) -> Void

    init(isOn: Bool, valueChanged: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.valueChanged = valueChanged
    }

    static func ==(lhs: EGToggleRowComponent, rhs: EGToggleRowComponent) -> Bool {
        return lhs.isOn == rhs.isOn
    }

    final class View: UIView {
        private let label = UILabel()
        private let toggle = UISwitch()
        var valueChanged: ((Bool) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.text = "Enable after installation"
            label.font = .systemFont(ofSize: 15)
            label.textColor = UIColor.label
            addSubview(label)
            toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)
            addSubview(toggle)
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func toggled() { valueChanged?(toggle.isOn) }

        func update(component: EGToggleRowComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let h: CGFloat = 44
            valueChanged = component.valueChanged
            toggle.isOn = component.isOn
            let sw = toggle.intrinsicContentSize.width
            let sh = toggle.intrinsicContentSize.height
            toggle.frame = CGRect(x: availableSize.width - sw, y: (h - sh) / 2, width: sw, height: sh)
            label.frame = CGRect(x: 0, y: 0, width: availableSize.width - sw - 8, height: h)
            return CGSize(width: availableSize.width, height: h)
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
    let openUsername: (String) -> Void

    init(metadata: EGPluginFileMetadata, filePath: String, accountContext: AccountContext, dismiss: @escaping () -> Void, share: @escaping () -> Void, openUsername: @escaping (String) -> Void) {
        self.metadata = metadata
        self.filePath = filePath
        self.accountContext = accountContext
        self.dismiss = dismiss
        self.share = share
        self.openUsername = openUsername
    }

    static func ==(lhs: EGPluginInstallSheetContent, rhs: EGPluginInstallSheetContent) -> Bool {
        return lhs.metadata.id == rhs.metadata.id && lhs.filePath == rhs.filePath
    }

    final class State: ComponentState {
        var isInstalling = false
        var isEnabled: Bool = true

        func install(metadata: EGPluginFileMetadata, filePath: String, isEnabled: Bool, dismiss: @escaping () -> Void) {
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
                    isEnabled: isEnabled,
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
        let authorRow    = Child(EGAuthorRowComponent.self)
        let iconView     = Child(EGPluginIconComponent.self)
        let titleText    = Child(BalancedTextComponent.self)
        let descText     = Child(BalancedTextComponent.self)
        let toggleRow    = Child(EGToggleRowComponent.self)
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

            // ── Top bar: close (left) · version/author (center) · share (right) ──
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
            context.add(closeBtn.position(CGPoint(x: hPad + 22, y: y + 22)))

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
            context.add(shareBtn.position(CGPoint(x: width - hPad - 22, y: y + 22)))

            // version · author centered in header bar (Fix 1)
            if component.metadata.version != nil || component.metadata.author != nil {
                let headerMaxW = max(0, width - 2 * (hPad + 44 + 4))
                let headerRow = authorRow.update(
                    component: EGAuthorRowComponent(
                        version: component.metadata.version,
                        author: component.metadata.author,
                        textColor: theme.actionSheet.secondaryTextColor,
                        onUsernameTap: component.openUsername
                    ),
                    availableSize: CGSize(width: headerMaxW, height: 44),
                    transition: .immediate
                )
                context.add(headerRow.position(CGPoint(x: width / 2, y: y + 22)))
            }

            y += 44.0 + 16.0

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

            // ── "Enable after installation" toggle (Fix 2) ──────────
            let tog = toggleRow.update(
                component: EGToggleRowComponent(
                    isOn: state.isEnabled,
                    valueChanged: { newVal in state.isEnabled = newVal; state.updated(transition: .immediate) }
                ),
                availableSize: CGSize(width: width - hPad * 2, height: 44),
                transition: .immediate
            )
            context.add(tog.position(CGPoint(x: width / 2, y: y + tog.size.height / 2)))
            y += tog.size.height + 12.0

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
                            isEnabled: state.isEnabled,
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
                // Fix 4: copy to a temp file with the original .plugin name before sharing
                let rawName = context.component.metadata.name ?? "Plugin"
                let safeName = rawName.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).plugin")
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.copyItem(atPath: context.component.filePath, toPath: tempURL.path)
                let avc = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                avc.popoverPresentationController?.sourceView = vc.view
                vc.present(avc, animated: true)
            }

            let ctx = context.component.accountContext
            let openUsername: (String) -> Void = { username in
                dismiss(true)
                let _ = (ctx.engine.peers.resolvePeerByName(name: username, referrer: nil)
                    |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                        guard case let .result(r) = result else { return .complete() }
                        return .single(r)
                    }
                    |> deliverOnMainQueue
                ).startStandalone(next: { peer in
                    guard let peer else { return }
                    guard let vc = controller() as? EGPluginInstallScreen,
                          let nc = vc.navigationController as? NavigationController else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        ctx.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                            navigationController: nc,
                            context: ctx,
                            chatLocation: .peer(peer)
                        ))
                    }
                })
            }

            let sheet = sheet.update(
                component: SheetComponent<EnvironmentType>(
                    content: AnyComponent<EnvironmentType>(EGPluginInstallSheetContent(
                        metadata: context.component.metadata,
                        filePath: context.component.filePath,
                        accountContext: context.component.accountContext,
                        dismiss: { dismiss(true) },
                        share: share,
                        openUsername: openUsername
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
