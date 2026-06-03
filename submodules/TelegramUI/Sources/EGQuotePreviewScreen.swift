// MARK: exteraGram — native glass-style quote preview sheet

import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ComponentFlow
import ViewControllerComponent
import SheetComponent
import BundleIconComponent
import GlassBarButtonComponent
import ButtonComponent
import TelegramCore
import EGPluginEngine

// MARK: - Image component

private final class EGQuoteImageComponent: Component {
    let imagePath: String

    init(imagePath: String) { self.imagePath = imagePath }

    static func ==(lhs: EGQuoteImageComponent, rhs: EGQuoteImageComponent) -> Bool {
        lhs.imagePath == rhs.imagePath
    }

    final class View: UIView {
        private let imageView = UIImageView()
        private var loadedPath: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError() }

        func update(component: EGQuoteImageComponent,
                    availableSize: CGSize,
                    state: EmptyComponentState,
                    environment: Environment<Empty>,
                    transition: ComponentTransition) -> CGSize {
            if loadedPath != component.imagePath {
                loadedPath = component.imagePath
                imageView.image = UIImage(contentsOfFile: component.imagePath)
            }
            let img = imageView.image
            let iw = img?.size.width  ?? availableSize.width
            let ih = img?.size.height ?? 200
            let scale  = availableSize.width / max(iw, 1)
            let height = min(ih * scale, availableSize.height * 0.55)
            let size   = CGSize(width: availableSize.width, height: height)
            imageView.frame = CGRect(origin: .zero, size: size)
            return size
        }
    }
}

// MARK: - Sheet content

private final class EGQuotePreviewContent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let imagePath:   String
    let peerId:      Int64
    let replyMsgId:  Int32
    let dismiss:     () -> Void
    let getVC:       () -> UIViewController?

    init(imagePath: String, peerId: Int64, replyMsgId: Int32,
         dismiss: @escaping () -> Void, getVC: @escaping () -> UIViewController?) {
        self.imagePath  = imagePath
        self.peerId     = peerId
        self.replyMsgId = replyMsgId
        self.dismiss    = dismiss
        self.getVC      = getVC
    }

    static func ==(lhs: EGQuotePreviewContent, rhs: EGQuotePreviewContent) -> Bool {
        lhs.imagePath == rhs.imagePath && lhs.peerId == rhs.peerId
    }

    static var body: Body {
        let closeBtn   = Child(GlassBarButtonComponent.self)
        let titleLabel = Child(BalancedTextComponent.self)
        let imageView  = Child(EGQuoteImageComponent.self)
        let photoBtn   = Child(ButtonComponent.self)
        let fileBtn    = Child(ButtonComponent.self)
        let copyBtn    = Child(ButtonComponent.self)
        let galleryBtn = Child(ButtonComponent.self)
        let shareBtn   = Child(ButtonComponent.self)

        return { context in
            let env       = context.environment[EnvironmentType.self].value
            let theme     = env.theme
            let isDark    = theme.overallDarkAppearance
            let component = context.component
            let width     = context.availableSize.width
            let hPad: CGFloat = 16
            var y: CGFloat = 16

            // ── Close button ─────────────────────────────────────────────
            let close = closeBtn.update(
                component: GlassBarButtonComponent(
                    size: CGSize(width: 44, height: 44),
                    backgroundColor: nil,
                    isDark: isDark,
                    state: .glass,
                    component: AnyComponentWithIdentity(
                        id: "close",
                        component: AnyComponent(BundleIconComponent(
                            name: "Navigation/Close",
                            tintColor: theme.chat.inputPanel.panelControlColor))
                    ),
                    action: { _ in component.dismiss() }
                ),
                availableSize: CGSize(width: 44, height: 44),
                transition: .immediate
            )
            context.add(close.position(CGPoint(x: hPad + 22, y: y + 22)))

            // Title centered in the header row
            let title = titleLabel.update(
                component: BalancedTextComponent(
                    text: .plain(NSAttributedString(
                        string: "✏️ Цитата",
                        font: Font.semibold(17),
                        textColor: theme.list.itemPrimaryTextColor
                    )),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 1,
                    lineSpacing: 0.0
                ),
                availableSize: CGSize(width: width - 100, height: 44),
                transition: .immediate
            )
            context.add(title.position(CGPoint(x: width / 2, y: y + 22)))

            y += 44 + 12

            // ── Image preview ─────────────────────────────────────────────
            let imgComp = imageView.update(
                component: EGQuoteImageComponent(imagePath: component.imagePath),
                availableSize: CGSize(width: width - hPad * 2, height: context.availableSize.height),
                transition: .immediate
            )
            context.add(imgComp.position(CGPoint(
                x: width / 2,
                y: y + imgComp.size.height / 2
            )))
            y += imgComp.size.height + 16

            // ── Shared button style helpers ───────────────────────────────
            let accentFill   = theme.list.itemCheckColors.fillColor
            let accentText   = theme.list.itemCheckColors.foregroundColor
            let neutralFill  = isDark
                ? UIColor(white: 1, alpha: 0.08)
                : UIColor(white: 0, alpha: 0.06)
            let neutralText  = theme.list.itemPrimaryTextColor
            let buttonInsets = ContainerViewLayout.concentricInsets(
                bottomInset: env.safeInsets.bottom,
                innerDiameter: 50,
                sideInset: hPad
            )
            let btnW = width - buttonInsets.left - buttonInsets.right

            func makeLabel(_ s: String, _ c: UIColor) -> AnyComponentWithIdentity<Empty> {
                AnyComponentWithIdentity(id: AnyHashable(s), component: AnyComponent(
                    ButtonTextContentComponent(
                        text: s, badge: 0,
                        textColor: c,
                        badgeBackground: c,
                        badgeForeground: accentFill)))
            }

            func primaryBg() -> ButtonComponent.Background {
                ButtonComponent.Background(
                    style: .glass, color: accentFill, foreground: accentText,
                    pressedColor: accentFill.withAlphaComponent(0.85), cornerRadius: 14)
            }
            func neutralBg() -> ButtonComponent.Background {
                ButtonComponent.Background(
                    style: .legacy, color: neutralFill, foreground: neutralText,
                    pressedColor: neutralFill.withAlphaComponent(0.5), cornerRadius: 12)
            }

            // ── "Как фото" (primary) ──────────────────────────────────────
            let pid = component.peerId; let rid = component.replyMsgId
            let iPath = component.imagePath
            let photo = photoBtn.update(
                component: ButtonComponent(
                    background: primaryBg(),
                    content: makeLabel("Как фото", accentText),
                    isEnabled: true,
                    action: { [dismiss = component.dismiss] in
                        dismiss()
                        EGPluginHooks.pluginSendPhotoHandler?(pid, iPath, rid == 0 ? nil : rid)
                    }
                ),
                availableSize: CGSize(width: btnW, height: 50),
                transition: .immediate
            )
            context.add(photo.position(CGPoint(x: width / 2, y: y + photo.size.height / 2)))
            y += photo.size.height + 8

            // ── "Как файл" + "Копировать" row ─────────────────────────────
            let halfW = (btnW - 8) / 2
            let file = fileBtn.update(
                component: ButtonComponent(
                    background: neutralBg(),
                    content: makeLabel("Как файл", neutralText),
                    isEnabled: true,
                    action: { [dismiss = component.dismiss] in
                        dismiss()
                        EGPluginHooks.pluginSendFileHandler?(pid, iPath, "quote.png", rid == 0 ? nil : rid)
                    }
                ),
                availableSize: CGSize(width: halfW, height: 46),
                transition: .immediate
            )
            context.add(file.position(CGPoint(x: hPad + halfW / 2, y: y + file.size.height / 2)))

            let copy = copyBtn.update(
                component: ButtonComponent(
                    background: neutralBg(),
                    content: makeLabel("Копировать", neutralText),
                    isEnabled: true,
                    action: { [dismiss = component.dismiss] in
                        dismiss()
                        if let img = UIImage(contentsOfFile: iPath) {
                            UIPasteboard.general.image = img
                        }
                    }
                ),
                availableSize: CGSize(width: halfW, height: 46),
                transition: .immediate
            )
            context.add(copy.position(CGPoint(x: width - hPad - halfW / 2, y: y + copy.size.height / 2)))
            y += copy.size.height + 8

            // ── "В галерею" + "Поделиться" row ────────────────────────────
            let gallery = galleryBtn.update(
                component: ButtonComponent(
                    background: neutralBg(),
                    content: makeLabel("В галерею", neutralText),
                    isEnabled: true,
                    action: { [dismiss = component.dismiss] in
                        dismiss()
                        if let img = UIImage(contentsOfFile: iPath) {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                        }
                    }
                ),
                availableSize: CGSize(width: halfW, height: 46),
                transition: .immediate
            )
            context.add(gallery.position(CGPoint(x: hPad + halfW / 2, y: y + gallery.size.height / 2)))

            let share = shareBtn.update(
                component: ButtonComponent(
                    background: neutralBg(),
                    content: makeLabel("Поделиться", neutralText),
                    isEnabled: true,
                    action: {
                        if let vc = component.getVC() {
                            let url = URL(fileURLWithPath: iPath)
                            let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                            avc.popoverPresentationController?.sourceView = vc.view
                            vc.present(avc, animated: true)
                        }
                    }
                ),
                availableSize: CGSize(width: halfW, height: 46),
                transition: .immediate
            )
            context.add(share.position(CGPoint(x: width - hPad - halfW / 2, y: y + share.size.height / 2)))
            y += share.size.height + buttonInsets.bottom

            return CGSize(width: width, height: y)
        }
    }
}

// MARK: - Sheet wrapper

private final class EGQuotePreviewSheetComponent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let imagePath:  String
    let peerId:     Int64
    let replyMsgId: Int32

    init(imagePath: String, peerId: Int64, replyMsgId: Int32) {
        self.imagePath  = imagePath
        self.peerId     = peerId
        self.replyMsgId = replyMsgId
    }

    static func ==(lhs: EGQuotePreviewSheetComponent, rhs: EGQuotePreviewSheetComponent) -> Bool {
        lhs.imagePath == rhs.imagePath && lhs.peerId == rhs.peerId
    }

    static var body: Body {
        let sheet      = Child(SheetComponent<EnvironmentType>.self)
        let animateOut = StoredActionSlot(Action<Void>.self)
        let exState    = SheetComponent<EnvironmentType>.ExternalState()

        return { context in
            let env        = context.environment[EnvironmentType.self]
            let controller = env.controller
            let component  = context.component

            let dismiss: (Bool) -> Void = { animated in
                if animated {
                    animateOut.invoke(Action { _ in
                        (controller() as? EGQuotePreviewScreen)?.dismiss(completion: nil)
                    })
                } else {
                    (controller() as? EGQuotePreviewScreen)?.dismiss(completion: nil)
                }
            }

            let s = sheet.update(
                component: SheetComponent<EnvironmentType>(
                    content: AnyComponent<EnvironmentType>(EGQuotePreviewContent(
                        imagePath:  component.imagePath,
                        peerId:     component.peerId,
                        replyMsgId: component.replyMsgId,
                        dismiss:    { dismiss(true) },
                        getVC:      { controller() }
                    )),
                    style: .glass,
                    backgroundColor: .color(env.value.theme.actionSheet.opaqueItemBackgroundColor),
                    followContentSizeChanges: true,
                    clipsContent: true,
                    autoAnimateOut: false,
                    externalState: exState,
                    animateOut: animateOut,
                    onPan: {},
                    willDismiss: {}
                ),
                environment: {
                    env
                    SheetComponentEnvironment(
                        metrics: env.value.metrics,
                        deviceMetrics: env.value.deviceMetrics,
                        isDisplaying: env.value.isVisible,
                        isCentered: env.value.metrics.widthClass == .regular,
                        hasInputHeight: !env.value.inputHeight.isZero,
                        regularMetricsSize: CGSize(width: 430, height: 900),
                        dismiss: { animated in dismiss(animated) }
                    )
                },
                availableSize: context.availableSize,
                transition: context.transition
            )
            context.add(s.position(CGPoint(
                x: context.availableSize.width / 2,
                y: context.availableSize.height / 2
            )))

            if let vc = controller(), !vc.automaticallyControlPresentationContextLayout {
                var sideInset: CGFloat = 0
                var bottomInset = max(env.value.safeInsets.bottom, exState.contentHeight)
                if case .regular = env.value.metrics.widthClass {
                    sideInset = floor((context.availableSize.width - 430) / 2) - 12
                    bottomInset = (context.availableSize.height - exState.contentHeight) / 2 + exState.contentHeight
                }
                let layout = ContainerViewLayout(
                    size: context.availableSize,
                    metrics: env.value.metrics,
                    deviceMetrics: env.value.deviceMetrics,
                    intrinsicInsets: UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0),
                    safeInsets: UIEdgeInsets(top: 0,
                                             left: max(sideInset, env.value.safeInsets.left),
                                             bottom: 0,
                                             right: max(sideInset, env.value.safeInsets.right)),
                    additionalInsets: .zero,
                    statusBarHeight: env.value.statusBarHeight,
                    inputHeight: nil,
                    inputHeightIsInteractivellyChanging: false,
                    inVoiceOver: false
                )
                vc.presentationContext.containerLayoutUpdated(
                    layout, transition: context.transition.containedViewLayoutTransition)
            }

            return context.availableSize
        }
    }
}

// MARK: - Screen

public final class EGQuotePreviewScreen: ViewControllerComponentContainer {
    public init(imagePath: String, peerId: Int64, replyMsgId: Int32, context: AccountContext) {
        super.init(
            context: context,
            component: EGQuotePreviewSheetComponent(
                imagePath:  imagePath,
                peerId:     peerId,
                replyMsgId: replyMsgId
            ),
            navigationBarAppearance: .none,
            statusBarStyle: .ignore,
            theme: .default
        )
        self.navigationPresentation = .flatModal
        self.automaticallyControlPresentationContextLayout = false
    }

    required init(coder aDecoder: NSCoder) { fatalError() }

    override public func viewDidLoad() {
        super.viewDidLoad()
        self.view.disablesInteractiveModalDismiss = false
    }
}
