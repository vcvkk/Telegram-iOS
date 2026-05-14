// MARK: exteraGram
import EGSimpleSettings
import EGStatus
import EGIAP
import EGProUI
import EGPayWall
//
import Foundation
import UIKit
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
import TelegramPresentationData
import TelegramCallsUI
import TelegramUIPreferences
import AccountContext
import DeviceLocationManager
import ItemListUI
import LegacyUI
import ChatListUI
import PeersNearbyUI
import PeerInfoUI
import SettingsUI
import UrlHandling
import LegacyMediaPickerUI
import LocalMediaResources
import OverlayStatusController
import AlertUI
import PresentationDataUtils
import LocationUI
import AppLock
import WallpaperBackgroundNode
import InAppPurchaseManager
import PremiumUI
import StickerPackPreviewUI
import ChatControllerInteraction
import ChatPresentationInterfaceState
import StorageUsageScreen
import DebugSettingsUI
import MediaPickerUI
import Photos
import TextFormat
import ChatTextLinkEditUI
import AttachmentTextInputPanelNode
import ChatEntityKeyboardInputNode
import HashtagSearchUI
import PeerInfoStoryGridScreen
import TelegramAccountAuxiliaryMethods
import PeerSelectionController
import LegacyMessageInputPanel
import StatisticsUI
import ChatHistoryEntry
import ChatMessageItem
import ChatMessageItemImpl
import ChatRecentActionsController
import PeerInfoScreen
import ChatQrCodeScreen
import UndoUI
import ChatMessageNotificationItem
import ChatbotSetupScreen
import BusinessLocationSetupScreen
import BusinessHoursSetupScreen
import AutomaticBusinessMessageSetupScreen
import CollectibleItemInfoScreen
import StickerPickerScreen
import MediaEditor
import MediaEditorScreen
import BusinessIntroSetupScreen
import TelegramNotices
import BotSettingsScreen
import Camera
import CameraScreen
import BirthdayPickerScreen
import StarsTransactionsScreen
import StarsPurchaseScreen
import StarsTransferScreen
import StarsTransactionScreen
import StarsWithdrawalScreen
import MiniAppListScreen
import GiftOptionsScreen
import GiftViewScreen
import StarsIntroScreen
import ContentReportScreen
import AffiliateProgramSetupScreen
import GalleryUI
import ShareController
import AccountFreezeInfoScreen
import JoinSubjectScreen
import OldChannelsController
import InviteLinksUI
import GiftStoreScreen
import SendInviteLinkScreen
import PostSuggestionsSettingsScreen
import ForumSettingsScreen
import ForumCreateTopicScreen
import GlassBackgroundComponent
import AttachmentFileController
import NewContactScreen
import PasskeysScreen
import GiftDemoScreen
import ChatTextLinkEditUI
import CocoonInfoScreen
import GiftCraftScreen
import ChatParticipantRightsScreen
import PeerCopyProtectionInfoScreen
import ChatRankInfoScreen
import RankChatPreviewItem
import TextProcessingScreen
import CreateBotScreen

private func isAPNSSandboxEnvironment() -> Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    guard let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
          let profileData = try? Data(contentsOf: URL(fileURLWithPath: profilePath)),
          let profileString = String(data: profileData, encoding: .isoLatin1),
          let keyRange = profileString.range(of: "<key>aps-environment</key>") else {
        return false
    }
    let rest = profileString[keyRange.upperBound...]
    if let start = rest.range(of: "<string>"),
       let end = rest.range(of: "</string>", range: start.upperBound..<rest.endIndex) {
        return String(rest[start.upperBound..<end.lowerBound]) == "development"
    }
    return false
    #endif
}
