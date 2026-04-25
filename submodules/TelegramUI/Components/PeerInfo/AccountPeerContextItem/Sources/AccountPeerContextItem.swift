import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ContextUI
import AvatarNode
import EmojiStatusComponent
import AccountContext
import EGBadges

public final class AccountPeerContextItem: ContextMenuCustomItem {
    let context: AccountContext
    let account: Account
    let peer: EnginePeer
    let action: (ContextControllerProtocol, @escaping (ContextMenuActionResult) -> Void) -> Void
    
    public  init(context: AccountContext, account: Account, peer: EnginePeer, action: @escaping (ContextControllerProtocol, @escaping (ContextMenuActionResult) -> Void) -> Void) {
        self.context = context
        self.account = account
        self.peer = peer
        self.action = action
    }
    
    public func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return AccountPeerContextItemNode(presentationData: presentationData, item: self, getController: getController, actionSelected: actionSelected)
    }
}

private final class AccountPeerContextItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let item: AccountPeerContextItem
    private let presentationData: PresentationData
    private let getController: () -> ContextControllerProtocol?
    private let actionSelected: (ContextMenuActionResult) -> Void
    
    private let buttonNode: HighlightTrackingButtonNode
    private let textNode: ImmediateTextNode
    private let avatarNode: AvatarNode
    private let emojiStatusView: ComponentView<Empty>
    // Slot 2: exteraGram badge (shown alongside emoji/premium, matching Android DrawerAccountPickerView)
    private let egBadgeView: ComponentView<Empty>
    
    init(presentationData: PresentationData, item: AccountPeerContextItem, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.item = item
        self.presentationData = presentationData
        self.getController = getController
        self.actionSelected = actionSelected
        
        let textFont = Font.regular(presentationData.listsFontSize.baseDisplaySize * 17.0 / 17.0)
        
        self.textNode = ImmediateTextNode()
        self.textNode.isAccessibilityElement = false
        self.textNode.isUserInteractionEnabled = false
        self.textNode.displaysAsynchronously = false
        let peerTitle = item.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        self.textNode.attributedText = NSAttributedString(string: peerTitle, font: textFont, textColor: presentationData.theme.contextMenu.primaryColor)
        self.textNode.maximumNumberOfLines = 1
        
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 14.0))

        self.emojiStatusView = ComponentView<Empty>()
        self.egBadgeView = ComponentView<Empty>()
        
        self.buttonNode = HighlightTrackingButtonNode()
        self.buttonNode.isAccessibilityElement = true
        self.buttonNode.accessibilityLabel = peerTitle
        
        super.init()
        
        self.addSubnode(self.textNode)
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.buttonNode)
        
        self.buttonNode.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let sideInset: CGFloat = 18.0
        let iconSideInset: CGFloat = 20.0
        let verticalInset: CGFloat = 11.0
        
        let iconSize = CGSize(width: 28.0, height: 28.0)
        
        let standardIconWidth: CGFloat = 32.0
        var rightTextInset: CGFloat = sideInset
        if !iconSize.width.isZero {
            rightTextInset = max(iconSize.width, standardIconWidth) + iconSideInset + sideInset - 12.0
        }
        
        self.avatarNode.setPeer(context: self.item.context, account: self.item.account, theme: self.presentationData.theme, peer: self.item.peer)

        // Resolve slot 1 (emoji/premium) and slot 2 (badge) — mirrors Android DrawerAccountPickerView
        var slot1Content: EmojiStatusComponent.Content?
        if case let .user(user) = self.item.peer {
            if let emojiStatus = user.emojiStatus {
                slot1Content = .animation(content: .customEmoji(fileId: emojiStatus.fileId), size: CGSize(width: 28.0, height: 28.0), placeholderColor: self.presentationData.theme.list.mediaPlaceholderColor, themeColor: self.presentationData.theme.list.itemAccentColor, loopMode: .forever)
            } else if user.isPremium {
                slot1Content = .premium(color: self.presentationData.theme.list.itemAccentColor)
            }
        } else if case let .channel(channel) = self.item.peer {
            if let emojiStatus = channel.emojiStatus {
                slot1Content = .animation(content: .customEmoji(fileId: emojiStatus.fileId), size: CGSize(width: 28.0, height: 28.0), placeholderColor: self.presentationData.theme.list.mediaPlaceholderColor, themeColor: self.presentationData.theme.list.itemAccentColor, loopMode: .forever)
            }
        }

        let peerIdValue = self.item.peer.id.id._internalGetInt64Value()
        let egBadge = BadgesController.shared.getBadge(peerIdValue: peerIdValue)
        var slot2Content: EmojiStatusComponent.Content? = nil
        if let badge = egBadge {
            let badgeContent = EmojiStatusComponent.Content.animation(content: .customEmoji(fileId: badge.documentId), size: CGSize(width: 28.0, height: 28.0), placeholderColor: self.presentationData.theme.list.mediaPlaceholderColor, themeColor: self.presentationData.theme.list.itemAccentColor, loopMode: .forever)
            if slot1Content != nil {
                slot2Content = badgeContent   // emoji/premium in slot 1, badge in slot 2
            } else {
                slot1Content = badgeContent   // badge promoted to slot 1
            }
        }

        // Reserve text inset for occupied slots
        if slot1Content != nil { rightTextInset += 32.0 }
        if slot2Content != nil { rightTextInset += 32.0 }

        let textSize = self.textNode.updateLayout(CGSize(width: constrainedWidth - sideInset - rightTextInset, height: .greatestFiniteMagnitude))

        return (CGSize(width: textSize.width + sideInset + rightTextInset, height: verticalInset * 2.0 + textSize.height), { size, transition in
            let verticalOrigin = floor((size.height - textSize.height) / 2.0)
            let textFrame = CGRect(origin: CGPoint(x: iconSideInset + 40.0, y: verticalOrigin), size: textSize)
            transition.updateFrameAdditive(node: self.textNode, frame: textFrame)

            var nextIconX = textFrame.maxX + 2.0
            let iconH: CGFloat = 24.0

            if let content = slot1Content {
                let sz = self.emojiStatusView.update(
                    transition: .immediate,
                    component: AnyComponent(EmojiStatusComponent(
                        context: self.item.context,
                        animationCache: self.item.context.animationCache,
                        animationRenderer: self.item.context.animationRenderer,
                        content: content,
                        isVisibleForAnimations: true,
                        action: nil
                    )),
                    environment: {},
                    containerSize: CGSize(width: iconH, height: iconH)
                )
                if let view = self.emojiStatusView.view {
                    if view.superview == nil { self.view.addSubview(view) }
                    transition.updateFrame(view: view, frame: CGRect(origin: CGPoint(x: nextIconX, y: textFrame.minY + floor((textFrame.height - sz.height) / 2.0)), size: sz))
                    nextIconX += sz.width + 2.0
                }
            }

            if let content = slot2Content {
                let sz = self.egBadgeView.update(
                    transition: .immediate,
                    component: AnyComponent(EmojiStatusComponent(
                        context: self.item.context,
                        animationCache: self.item.context.animationCache,
                        animationRenderer: self.item.context.animationRenderer,
                        content: content,
                        isVisibleForAnimations: true,
                        action: nil
                    )),
                    environment: {},
                    containerSize: CGSize(width: iconH, height: iconH)
                )
                if let view = self.egBadgeView.view {
                    if view.superview == nil { self.view.addSubview(view) }
                    transition.updateFrame(view: view, frame: CGRect(origin: CGPoint(x: nextIconX, y: textFrame.minY + floor((textFrame.height - sz.height) / 2.0)), size: sz))
                }
            }

            transition.updateFrame(node: self.avatarNode, frame: CGRect(origin: CGPoint(x: iconSideInset + floor((standardIconWidth - iconSize.width) / 2.0), y: floor((size.height - iconSize.height) / 2.0)), size: iconSize))
            transition.updateFrame(node: self.buttonNode, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: size.width, height: size.height)))
        })
    }
    
    func updateTheme(presentationData: PresentationData) {
        if let attributedText = self.textNode.attributedText {
            let updatedAttributedText = NSMutableAttributedString(attributedString: attributedText)
            updatedAttributedText.addAttribute(.foregroundColor, value: presentationData.theme.contextMenu.primaryColor.cgColor, range: NSRange(location: 0, length: updatedAttributedText.length))
            self.textNode.attributedText = updatedAttributedText
        }
    }
    
    @objc private func buttonPressed() {
        self.performAction()
    }
    
    func canBeHighlighted() -> Bool {
        return true
    }
    
    func setIsHighlighted(_ value: Bool) {
    }
    
    func updateIsHighlighted(isHighlighted: Bool) {
        self.setIsHighlighted(isHighlighted)
    }
    
    func performAction() {
        guard let controller = self.getController() else {
            return
        }
        self.item.action(controller, { [weak self] result in
            self?.actionSelected(result)
        })
    }
}
