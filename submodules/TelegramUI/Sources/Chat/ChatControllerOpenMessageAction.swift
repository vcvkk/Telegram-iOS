import EGSimpleSettings
import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import SafariServices
import MobileCoreServices
import Intents
import LegacyComponents
import TelegramPresentationData
import TelegramUIPreferences
import DeviceAccess
import TextFormat
import TelegramBaseController
import AccountContext
import TelegramStringFormatting
import OverlayStatusController
import DeviceLocationManager
import UrlEscaping
import ContextUI
import AlertUI
import PresentationDataUtils
import UndoUI
import TelegramCallsUI
import TelegramNotices
import GameUI
import ScreenCaptureDetection
import GalleryUI
import OpenInExternalAppUI
import LegacyUI
import InstantPageUI
import LocationUI
import BotPaymentsUI
import DeleteChatPeerActionSheetItem
import HashtagSearchUI
import LegacyMediaPickerUI
import Emoji
import PeerAvatarGalleryUI
import PeerInfoUI
import RaiseToListen
import UrlHandling
import AvatarNode
import AppBundle
import ComponentFlow
import ViewControllerComponent
import SheetComponent
import GlassBarButtonComponent
import BundleIconComponent
import LocalizedPeerData
import PhoneNumberFormat
import SettingsUI
import UrlWhitelist
import TelegramIntents
import TooltipUI
import StatisticsUI
import MediaResources
import GalleryData
import ChatInterfaceState
import InviteLinksUI
import Markdown
import TelegramPermissionsUI
import Speak
import TranslateUI
import UniversalMediaPlayer
import WallpaperBackgroundNode
import ChatListUI
import CalendarMessageScreen
import ReactionSelectionNode
import ReactionListContextMenuContent
import AttachmentUI
import AttachmentTextInputPanelNode
import MediaPickerUI
import ChatPresentationInterfaceState
import Pasteboard
import ChatSendMessageActionUI
import ChatTextLinkEditUI
import ChatRichTextEditorComposer
import WebUI
import PremiumUI
import ImageTransparency
import StickerPackPreviewUI
import TextNodeWithEntities
import EntityKeyboard
import ChatTitleView
import EmojiStatusComponent
import ChatTimerScreen
import MediaPasteboardUI
import ChatListHeaderComponent
import ChatControllerInteraction
import FeaturedStickersScreen
import ChatEntityKeyboardInputNode
import StorageUsageScreen
import AvatarEditorScreen
import ChatScheduleTimeController
import ICloudResources
import StoryContainerScreen
import MoreHeaderButton
import VolumeButtons
import ChatAvatarNavigationNode
import ChatContextQuery
import PeerReportScreen
import PeerSelectionController
import SaveToCameraRoll
import ChatMessageDateAndStatusNode
import ReplyAccessoryPanelNode
import TextSelectionNode
import ChatMessagePollBubbleContentNode
import ChatMessageItem
import ChatMessageItemImpl
import ChatMessageItemView
import ChatMessageItemCommon
import ChatHistoryEntry
import ChatMessageAnimatedStickerItemNode
import ChatMessageBubbleItemNode
import ChatNavigationButton
import WebsiteType
import PeerInfoScreen
import MediaEditor
import MediaEditorScreen
import WallpaperGalleryScreen
import WallpaperGridScreen
import VideoMessageCameraScreen
import TopMessageReactions
import AudioWaveform
import PeerNameColorScreen
import ChatEmptyNode
import ChatMediaInputStickerGridItem
import AdsInfoScreen
import MessageUI
import PhoneNumberFormat
import OwnershipTransferController
import OldChannelsController
import BrowserUI
import NotificationPeerExceptionController
import AdsReportScreen
import AdUI
import ChatMessagePaymentAlertController
import TelegramCallsUI
import QuickShareScreen
import PostSuggestionsSettingsScreen
import PromptUI
import SuggestedPostApproveAlert
import AVFoundation
import BalanceNeededScreen
import FaceScanScreen
import ChatThemeScreen
import ChatTextInputPanelNode
import ChatInputAccessoryPanel
import GlobalControlPanelsContext
import ChatSearchNavigationContentNode
import ChatAgeRestrictionAlertController
import TextProcessingScreen

extension ChatControllerImpl {
    // MARK: exteraGram
    // Hoisted out of `openMessageImpl` in ChatController.swift. That closure
    // was around 770 lines, of which this switch was 350, and the Swift type
    // checker gave up on the whole thing — "failed to produce diagnostic for
    // expression", which reports no line worth acting on and hides every
    // other error in the module behind it.
    //
    // Returns the value `openMessage` should return, or nil to carry on with
    // the generic open-message path below the switch.
    func openMessageAction(_ action: TelegramMediaAction, message: Message, params: OpenMessageParams, displayVoiceMessageDiscardAlert: () -> Bool) -> Bool? {
        var openMessageByAction = false

                    if !displayVoiceMessageDiscardAlert() {
                        return false
                    }
                    switch action.action {
                        case .pinnedMessageUpdated, .gameScore, .setSameChatWallpaper, .giveawayResults, .customText, .todoCompletions, .todoAppendTasks, .suggestedPostRefund, .suggestedPostSuccess, .suggestedPostApprovalStatus, .pollOptionAppended:
                            for attribute in message.attributes {
                                if let attribute = attribute as? ReplyMessageAttribute {
                                    var subject: EngineMessageReplyInnerSubject?
                                    if case let .todoCompletions(completed, incompleted) = action.action {
                                        if let completedTaskId = completed.first {
                                            subject = .todoItem(completedTaskId)
                                        } else if let incompletedTaskId = incompleted.first {
                                            subject = .todoItem(incompletedTaskId)
                                        }
                                    } else if case let .todoAppendTasks(tasks) = action.action {
                                        if let task = tasks.first {
                                            subject = .todoItem(task.id)
                                        }
                                    } else if case let .pollOptionAppended(option) = action.action {
                                        subject = .pollOption(option.opaqueIdentifier)
                                    }
                                    self.navigateToMessage(from: message.id, to: .id(attribute.messageId, NavigateToMessageParams(timestamp: nil, quote: attribute.isQuote ? attribute.quote.flatMap { quote in NavigateToMessageParams.Quote(string: quote.text, offset: quote.offset) } : nil, subject: subject)))
                                    break
                                }
                            }
                        case let .photoUpdated(image):
                            openMessageByAction = image != nil
                        case .groupPhoneCall, .inviteToGroupPhoneCall:
                            if let activeCall = self.presentationInterfaceState.activeGroupCallInfo?.activeCall {
                                self.joinGroupCall(peerId: message.id.peerId, invite: nil, activeCall: EngineGroupCallDescription(id: activeCall.id, accessHash: activeCall.accessHash, title: activeCall.title, scheduleTimestamp: activeCall.scheduleTimestamp, subscribedToScheduled: activeCall.subscribedToScheduled, isStream: activeCall.isStream))
                            } else {
                                var canManageGroupCalls = false
                                if let channel = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel {
                                    if channel.flags.contains(.isCreator) || channel.hasPermission(.manageCalls) {
                                        canManageGroupCalls = true
                                    }
                                } else if let group = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramGroup {
                                    if case .creator = group.role {
                                        canManageGroupCalls = true
                                    } else if case let .admin(rights, _) = group.role {
                                        if rights.rights.contains(.canManageCalls) {
                                            canManageGroupCalls = true
                                        }
                                    }
                                }
                                
                                if canManageGroupCalls {
                                    let text: String
                                    if let channel = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, case .broadcast = channel.info {
                                        text = self.presentationData.strings.LiveStream_CreateNewVoiceChatText
                                    } else {
                                        text = self.presentationData.strings.VoiceChat_CreateNewVoiceChatText
                                    }
                                    self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.VoiceChat_CreateNewVoiceChatStartNow, action: { [weak self] in
                                        if let self {
                                            var dismissStatus: (() -> Void)?
                                            let statusController = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: {
                                                dismissStatus?()
                                            }))
                                            dismissStatus = { [weak self, weak statusController] in
                                                self?.createVoiceChatDisposable.set(nil)
                                                statusController?.dismiss()
                                            }
                                            self.present(statusController, in: .window(.root))
                                            self.createVoiceChatDisposable.set((self.context.engine.calls.createGroupCall(peerId: message.id.peerId, title: nil, scheduleDate: nil, isExternalStream: false)
                                            |> deliverOnMainQueue).startStrict(next: { [weak self] info in
                                                guard let self else {
                                                    return
                                                }
                                                self.joinGroupCall(peerId: message.id.peerId, invite: nil, activeCall: EngineGroupCallDescription(id: info.id, accessHash: info.accessHash, title: info.title, scheduleTimestamp: info.scheduleTimestamp, subscribedToScheduled: info.subscribedToScheduled, isStream: info.isStream))
                                            }, error: { [weak self] error in
                                                dismissStatus?()
                                                
                                                guard let self else {
                                                    return
                                                }
                                            
                                                let text: String
                                                switch error {
                                                case .generic, .scheduledTooLate:
                                                    text = self.presentationData.strings.Login_UnknownError
                                                case .anonymousNotAllowed:
                                                    if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
                                                        text = self.presentationData.strings.LiveStream_AnonymousDisabledAlertText
                                                    } else {
                                                        text = self.presentationData.strings.VoiceChat_AnonymousDisabledAlertText
                                                    }
                                                }
                                                self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                                            }, completed: {
                                                dismissStatus?()
                                            }))
                                        }
                                    }), TextAlertAction(type: .genericAction, title: self.presentationData.strings.VoiceChat_CreateNewVoiceChatSchedule, action: { [weak self] in
                                        if let self {
                                            self.context.scheduleGroupCall(peerId: message.id.peerId, parentController: self)
                                        }
                                    }), TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {})], actionLayout: .vertical), in: .window(.root))
                                }
                            }
                            return true
                        case .messageAutoremoveTimeoutUpdated:
                            var canSetupAutoremoveTimeout = false
                            
                            if let _ = self.presentationInterfaceState.renderedPeer?.peer as? TelegramSecretChat {
                                canSetupAutoremoveTimeout = false
                            } else if let group = self.presentationInterfaceState.renderedPeer?.peer as? TelegramGroup {
                                if !group.hasBannedPermission(.banChangeInfo) {
                                    canSetupAutoremoveTimeout = true
                                }
                            } else if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser {
                                if user.id != self.context.account.peerId && user.botInfo == nil {
                                    canSetupAutoremoveTimeout = true
                                }
                            } else if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel {
                                if channel.hasPermission(.changeInfo) {
                                    canSetupAutoremoveTimeout = true
                                }
                            }
                            
                            if canSetupAutoremoveTimeout {
                                self.presentAutoremoveSetup()
                            }
                        case let .paymentSent(currency, _, _, _, _):
                            if currency == "XTR" {
                                let _ = (context.engine.payments.requestBotPaymentReceipt(messageId: message.id)
                                |> deliverOnMainQueue).start(next: { [weak self] receipt in
                                    guard let self else {
                                        return
                                    }
                                    self.push(self.context.sharedContext.makeStarsReceiptScreen(context: self.context, receipt: receipt))
                                })
                            } else {
                                self.present(BotReceiptController(context: self.context, messageId: message.id), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                            }
                            return true
                        case let .setChatTheme(chatTheme):
                            switch chatTheme {
                            case .emoticon:
                                self.presentThemeSelection()
                            case let .gift(gift, _):
                                if case let .unique(uniqueGift) = gift {
                                    let controller = self.context.sharedContext.makeGiftViewScreen(context: self.context, gift: uniqueGift, shareStory: { [weak self] uniqueGift in
                                        Queue.mainQueue().after(0.15) {
                                            if let self {
                                                let controller = self.context.sharedContext.makeStorySharingScreen(context: self.context, subject: .gift(uniqueGift), parentController: self)
                                                self.push(controller)
                                            }
                                        }
                                    }, openChatTheme: { [weak self] in
                                        if let self {
                                            Queue.mainQueue().after(0.15) {
                                                self.presentThemeSelection()
                                            }
                                        }
                                    }, dismissed: nil)
                                    self.push(controller)
                                }
                            }
                            return true
                        case let .setChatWallpaper(wallpaper, _):
                            guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
                                return true
                            }
                            if let peer = peer as? TelegramChannel {
                                if peer.flags.contains(.isCreator) || peer.adminRights?.rights.contains(.canChangeInfo) == true {
                                    let _ = (context.engine.peers.getChannelBoostStatus(peerId: peer.id)
                                    |> deliverOnMainQueue).start(next: { [weak self] boostStatus in
                                        guard let self else {
                                            return
                                        }
                                        self.push(ChannelAppearanceScreen(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: peer.id, boostStatus: boostStatus))
                                    })
                                }
                                return true
                            }
                            guard message.effectivelyIncoming(self.context.account.peerId), let peer = self.presentationInterfaceState.renderedPeer?.peer else {
                                self.presentThemeSelection()
                                return true
                            }
                            self.chatDisplayNode.dismissInput()
                            var options = WallpaperPresentationOptions()
                            var intensity: Int32?
                            if let settings = wallpaper.settings {
                                if settings.blur {
                                    options.insert(.blur)
                                }
                                if settings.motion {
                                    options.insert(.motion)
                                }
                                if case let .file(file) = wallpaper, !file.isPattern {
                                    intensity = settings.intensity
                                }
                            }
                            let wallpaperPreviewController = WallpaperGalleryController(context: self.context, source: .wallpaper(wallpaper, options, [], intensity, nil, nil), mode: .peer(EnginePeer(peer), true))
                            wallpaperPreviewController.apply = { [weak wallpaperPreviewController] entry, options, _, _, brightness, forBoth in
                                var settings: WallpaperSettings?
                                if case let .wallpaper(wallpaper, _) = entry {
                                    let baseSettings = wallpaper.settings
                                    var intensity: Int32? = baseSettings?.intensity
                                    if case let .file(file) = wallpaper, !file.isPattern {
                                        if let brightness {
                                            intensity = max(0, min(100, Int32(brightness * 100.0)))
                                        }
                                    }
                                    settings = WallpaperSettings(blur: options.contains(.blur), motion: options.contains(.motion), colors: baseSettings?.colors ?? [], intensity: intensity, rotation: baseSettings?.rotation)
                                }
                                let _ = (self.context.engine.themes.setExistingChatWallpaper(messageId: message.id, settings: settings, forBoth: forBoth)
                                |> deliverOnMainQueue).startStandalone()
                                Queue.mainQueue().after(0.1) {
                                    wallpaperPreviewController?.dismiss()
                                }
                            }
                            self.push(wallpaperPreviewController)
                            return true
                        case let .giftPremium(_, _, duration, _, _, _, _):
                            self.chatDisplayNode.dismissInput()
                            let fromPeerId: PeerId = message.author?.id == self.context.account.peerId ? self.context.account.peerId : message.id.peerId
                            let toPeerId: PeerId = message.author?.id == self.context.account.peerId ? message.id.peerId : self.context.account.peerId
                            let controller = PremiumIntroScreen(context: self.context, source: .gift(from: fromPeerId, to: toPeerId, duration: duration, giftCode: nil))
                            self.push(controller)
                            return true
                        case .starGift, .starGiftUnique:
                            if case let .starGiftUnique(gift, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action.action, case let .unique(uniqueGift) = gift, uniqueGift.flags.contains(.isBurned) {
                                self.present(textAlertController(context: context, updatedPresentationData: updatedPresentationData, title: nil, text: self.presentationData.strings.Resolve_GiftErrorBurned, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                            } else {
                                let controller = self.context.sharedContext.makeGiftViewScreen(context: self.context, message: EngineMessage(message), shareStory: { [weak self] uniqueGift in
                                    Queue.mainQueue().after(0.15) {
                                        if let self {
                                            let controller = self.context.sharedContext.makeStorySharingScreen(context: self.context, subject: .gift(uniqueGift), parentController: self)
                                            self.push(controller)
                                        }
                                    }
                                })
                                self.push(controller)
                            }
                            return true
                        case .giftStars:
                            let controller = self.context.sharedContext.makeStarsGiftScreen(context: self.context, message: EngineMessage(message))
                            self.push(controller)
                            return true
                        case let .giftTon(_, _, _, _, transactionId):
                            Task { @MainActor [weak self] in
                                guard let self, let transactionId, let peerId = self.chatLocation.peerId else {
                                    return
                                }
                                let transactionData = await self.context.engine.payments.getStarsTransaction(reference: StarsTransactionReference(peerId: self.context.account.peerId, ton: true, id: transactionId, isRefund: false)).get()
                                let peer = await self.context.engine.data.get(
                                    TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)
                                ).get()
                                if let transactionData, let peer {
                                    self.push(self.context.sharedContext.makeStarsTransactionScreen(context: self.context, transaction: transactionData, peer: peer))
                                }
                            }
                        case let .giftCode(slug, _, _, _, _, _, _, _, _, _, _):
                            self.openResolved(result: .premiumGiftCode(slug: slug), sourceMessageId: message.id, progress: params.progress)
                            return true
                        case .prizeStars:
                            let controller = self.context.sharedContext.makeStarsGiftScreen(context: self.context, message: EngineMessage(message))
                            self.push(controller)
                            return true
                        case let .suggestedBirthday(birthday):
                            self.chatDisplayNode.dismissInput()
                            guard message.author?.id != self.context.account.peerId else {
                                return true
                            }
                            self.openSuggestedBirthday(birthday)
                            return true
                        case let .suggestedProfilePhoto(image):
                            self.chatDisplayNode.dismissInput()
                            if let image = image {
                                if message.effectivelyIncoming(self.context.account.peerId) {
                                    if let emojiMarkup = image.emojiMarkup {
                                        let controller = AvatarEditorScreen(context: self.context, inputData: AvatarEditorScreen.inputData(context: self.context, isGroup: false), peerType: .user, markup: emojiMarkup)
                                        controller.imageCompletion = { [weak self] image, commit in
                                            if let self {
                                                if let rootController = self.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfilePhoto(image, mode: .accept, uploadStatus: nil)
                                                    commit()
                                                }
                                            }
                                        }
                                        controller.videoCompletion = { [weak self] image, url, values, markup, commit in
                                            if let self {
                                                if let rootController = self.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfileVideo(image, video: nil, values: nil, markup: markup, mode: .accept, uploadStatus: nil)
                                                    commit()
                                                }
                                            }
                                        }
                                        self.push(controller)
                                    } else {
                                        var selectedNode: (ASDisplayNode, CGRect, () -> (UIView?, UIView?))?
                                        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                            if let itemNode = itemNode as? ChatMessageItemView {
                                                if let result = itemNode.transitionNode(id: message.id, media: image, adjustRect: false) {
                                                    selectedNode = result
                                                }
                                            }
                                        }
                                        let transitionView = selectedNode?.0.view
                                        
                                        let senderName: String?
                                        if let peer = message.peers[message.id.peerId] {
                                            senderName = EnginePeer(peer).compactDisplayTitle
                                        } else {
                                            senderName = nil
                                        }
                                        
                                        legacyAvatarEditor(context: self.context, media: .message(message: MessageReference(message), media: image), transitionView: transitionView, senderName: senderName, present: { [weak self] c, a in
                                            self?.present(c, in: .window(.root), with: a)
                                        }, imageCompletion: { [weak self] image in
                                            if let self {
                                                if let rootController = self.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfilePhoto(image, mode: .accept, uploadStatus: nil)
                                                }
                                            }
                                        }, videoCompletion: { [weak self] image, url, adjustments in
                                            if let self {
                                                if let rootController = self.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.oldUpdateProfileVideo(image, asset: AVURLAsset(url: url), adjustments: adjustments, mode: .accept)
                                                }
                                            }
                                        })
                                    }
                                } else {
                                    openMessageByAction = true
                                }
                            }
                        case .boostsApplied:
                            self.controllerInteraction?.openGroupBoostInfo(nil, 0)
                            return true
                        case .paidMessagesPriceEdited:
                            self.interfaceInteraction?.openMonoforum()
                            return true
                        case .starGiftPurchaseOffer:
                            let controller = self.context.sharedContext.makeGiftViewScreen(context: self.context, message: EngineMessage(message), shareStory: { [weak self] uniqueGift in
                                Queue.mainQueue().after(0.15) {
                                    if let self {
                                        let controller = self.context.sharedContext.makeStorySharingScreen(context: self.context, subject: .gift(uniqueGift), parentController: self)
                                        self.push(controller)
                                    }
                                }
                            })
                            self.push(controller)
                            return true
                        default:
                            break
                    }
                    if !openMessageByAction {
                        return true
                    }
        return nil
    }
}
