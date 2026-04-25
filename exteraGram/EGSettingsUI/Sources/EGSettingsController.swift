// MARK: exteraGram
import EGLogging
import EGSimpleSettings
import EGStrings
import EGAPIToken

import EGItemListUI
import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import MtProtoKit
import MessageUI
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import OverlayStatusController
import AccountContext
import AppBundle
import WebKit
import PeerNameColorScreen
import UndoUI


private enum EGControllerSection: Int32, EGItemListSection {
    case search
    case trending
    case content
    case tabs
    case folders
    case chatList
    case profiles
    case stories
    case translation
    case voiceMessages
    case calls
    case photo
    case stickers
    case videoNotes
    case contextMenu
    case accountColors
    case other
}

private enum EGBoolSetting: String {
    case hidePhoneInSettings
    case showTabNames
    case showContactsTab
    case showCallsTab
    case wideTabBar
    case foldersAtBottom
    case startTelescopeWithRearCam
    case hideStories
    case uploadSpeedBoost
    case showProfileId
    case warnOnStoriesOpen
    case sendWithReturnKey
    case rememberLastFolder
    case sendLargePhotos
    case storyStealthMode
    case disableSwipeToRecordStory
    case disableDeleteChatSwipeOption
    case quickTranslateButton
    case hideReactions
    case showRepostToStory
    case contextShowSelectFromUser
    case contextShowSaveToCloud
    case contextShowHideForwardName
    case contextShowRestrict
    case contextShowReport
    case contextShowReply
    case contextShowPin
    case contextShowSaveMedia
    case contextShowMessageReplies
    case contextShowJson
    case disableScrollToNextChannel
    case disableScrollToNextTopic
    case disableChatSwipeOptions
    case disableGalleryCamera
    case disableGalleryCameraPreview
    case disableSendAsButton
    case disableSnapDeletionEffect
    case stickerTimestamp
    case hideRecordingButton
    case hideTabBar
    case showDC
    case showCreationDate
    case showRegDate
    case compactChatList
    case compactMessagePreview
    case compactFolderNames
    case allChatsHidden
    case defaultEmojisFirst
    case messageDoubleTapActionOutgoingEdit
    case wideChannelPosts
    case forceEmojiTab
    case forceBuiltInMic
    case secondsInMessages
    case hideChannelBottomButton
    case confirmCalls
    case swipeForVideoPIP
    case enableVoipTcp
    case nyStyleSnow
    case nyStyleLightning
    case tabBarSearchEnabled
}

private enum EGOneFromManySetting: String {
    case nyStyle
    case bottomTabStyle
    case downloadSpeedBoost
    case allChatsTitleLengthOverride
//    case allChatsFolderPositionOverride
    case translationBackend
    case transcriptionBackend
}

private enum EGSliderSetting: String {
    case accountColorsSaturation
    case outgoingPhotoQuality
    case stickerSize
}

private enum EGDisclosureLink: String {
    case contentSettings
    case languageSettings
}

private struct PeerNameColorScreenState: Equatable {
    var updatedNameColor: PeerNameColor?
    var updatedBackgroundEmojiId: Int64?
}

private struct EGSettingsControllerState: Equatable {
    var searchQuery: String?
}

private typealias EGControllerEntry = EGItemListUIEntry<EGControllerSection, EGBoolSetting, EGSliderSetting, EGOneFromManySetting, EGDisclosureLink, AnyHashable>

private func EGControllerEntries(presentationData: PresentationData, callListSettings: CallListSettings, experimentalUISettings: ExperimentalUISettings, appConfiguration: AppConfiguration, nameColors: PeerNameColors, state: EGSettingsControllerState) -> [EGControllerEntry] {
    
    let lang = presentationData.strings.baseLanguageCode
    let strings = presentationData.strings
    let newStr = strings.Settings_New
    var entries: [EGControllerEntry] = []
    
    let id = EGItemListCounter()
    
    entries.append(.searchInput(id: id.count, section: .search, title: NSAttributedString(string: "🔍"), text: state.searchQuery ?? "", placeholder: strings.Common_Search))
    
    
    if EGSimpleSettings.shared.canUseNY {
        entries.append(.header(id: id.count, section: .trending, text: i18n("Settings.NY.Header", lang), badge: newStr))
        entries.append(.toggle(id: id.count, section: .trending, settingName: .nyStyleSnow, value: EGSimpleSettings.shared.nyStyle == EGSimpleSettings.NYStyle.snow.rawValue, text: i18n("Settings.NY.Style.snow", lang), enabled: true))
        entries.append(.toggle(id: id.count, section: .trending, settingName: .nyStyleLightning, value: EGSimpleSettings.shared.nyStyle == EGSimpleSettings.NYStyle.lightning.rawValue, text: i18n("Settings.NY.Style.lightning", lang), enabled: true))
        // entries.append(.oneFromManySelector(id: id.count, section: .trending, settingName: .nyStyle, text: i18n("Settings.NY.Style", lang), value: i18n("Settings.NY.Style.\(EGSimpleSettings.shared.nyStyle)", lang), enabled: true))
        entries.append(.notice(id: id.count, section: .trending, text: i18n("Settings.NY.Notice", lang)))
    } else {
        id.increment(3)
    }
    
    if appConfiguration.egWebSettings.global.canEditSettings {
        entries.append(.disclosure(id: id.count, section: .content, link: .contentSettings, text: i18n("Settings.ContentSettings", lang)))
    } else {
        id.increment(1)
    }
    
    entries.append(.header(id: id.count, section: .tabs, text: i18n("Settings.Tabs.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .hideTabBar, value: EGSimpleSettings.shared.hideTabBar, text: i18n("Settings.Tabs.HideTabBar", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showContactsTab, value: callListSettings.showContactsTab, text: i18n("Settings.Tabs.ShowContacts", lang), enabled: !EGSimpleSettings.shared.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showCallsTab, value: callListSettings.showTab, text: strings.CallSettings_TabIcon, enabled: !EGSimpleSettings.shared.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showTabNames, value: EGSimpleSettings.shared.showTabNames, text: i18n("Settings.Tabs.ShowNames", lang), enabled: !EGSimpleSettings.shared.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .tabBarSearchEnabled, value: EGSimpleSettings.shared.tabBarSearchEnabled, text: i18n("Settings.Tabs.SearchButton", lang), enabled: !EGSimpleSettings.shared.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .wideTabBar, value: EGSimpleSettings.shared.wideTabBar, text: i18n("Settings.Tabs.WideTabBar", lang), enabled: !EGSimpleSettings.shared.hideTabBar))
    entries.append(.notice(id: id.count, section: .tabs, text: i18n("Settings.Tabs.WideTabBar.Notice", lang)))
    
    entries.append(.header(id: id.count, section: .folders, text: strings.Settings_ChatFolders.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .foldersAtBottom, value: experimentalUISettings.foldersTabAtBottom, text: i18n("Settings.Folders.BottomTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .allChatsHidden, value: EGSimpleSettings.shared.allChatsHidden, text: i18n("Settings.Folders.AllChatsHidden", lang, strings.ChatList_Tabs_AllChats), enabled: true))
    #if DEBUG
//    entries.append(.oneFromManySelector(id: id.count, section: .folders, settingName: .allChatsFolderPositionOverride, text: i18n("Settings.Folders.AllChatsPlacement", lang), value: i18n("Settings.Folders.AllChatsPlacement.\(EGSimpleSettings.shared.allChatsFolderPositionOverride)", lang), enabled: true))
    #endif
    entries.append(.toggle(id: id.count, section: .folders, settingName: .compactFolderNames, value: EGSimpleSettings.shared.compactFolderNames, text: i18n("Settings.Folders.CompactNames", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .folders, settingName: .allChatsTitleLengthOverride, text: i18n("Settings.Folders.AllChatsTitle", lang), value: i18n("Settings.Folders.AllChatsTitle.\(EGSimpleSettings.shared.allChatsTitleLengthOverride)", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .rememberLastFolder, value: EGSimpleSettings.shared.rememberLastFolder, text: i18n("Settings.Folders.RememberLast", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .folders, text: i18n("Settings.Folders.RememberLast.Notice", lang)))
    
    entries.append(.header(id: id.count, section: .chatList, text: i18n("Settings.ChatList.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .compactChatList, value: EGSimpleSettings.shared.compactChatList, text: i18n("Settings.CompactChatList", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .compactMessagePreview, value: EGSimpleSettings.shared.chatListLines != EGSimpleSettings.ChatListLines.three.rawValue, text: i18n("Settings.CompactMessagePreview", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .disableChatSwipeOptions, value: !EGSimpleSettings.shared.disableChatSwipeOptions, text: i18n("Settings.ChatSwipeOptions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .disableDeleteChatSwipeOption, value: !EGSimpleSettings.shared.disableDeleteChatSwipeOption, text: i18n("Settings.DeleteChatSwipeOption", lang), enabled: !EGSimpleSettings.shared.disableChatSwipeOptions))
    
    entries.append(.header(id: id.count, section: .profiles, text: i18n("Settings.Profiles.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showProfileId, value: EGSimpleSettings.shared.showProfileId, text: i18n("Settings.ShowProfileID", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showDC, value: EGSimpleSettings.shared.showDC, text: i18n("Settings.ShowDC", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showRegDate, value: EGSimpleSettings.shared.showRegDate, text: i18n("Settings.ShowRegDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowRegDate.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showCreationDate, value: EGSimpleSettings.shared.showCreationDate, text: i18n("Settings.ShowCreationDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowCreationDate.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .confirmCalls, value: EGSimpleSettings.shared.confirmCalls, text: i18n("Settings.CallConfirmation", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.CallConfirmation.Notice", lang)))
    
    entries.append(.header(id: id.count, section: .stories, text: strings.AutoDownloadSettings_Stories.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .hideStories, value: EGSimpleSettings.shared.hideStories, text: i18n("Settings.Stories.Hide", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .disableSwipeToRecordStory, value: EGSimpleSettings.shared.disableSwipeToRecordStory, text: i18n("Settings.Stories.DisableSwipeToRecord", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .warnOnStoriesOpen, value: EGSimpleSettings.shared.warnOnStoriesOpen, text: i18n("Settings.Stories.WarnBeforeView", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .showRepostToStory, value: EGSimpleSettings.shared.showRepostToStoryV2, text: strings.Share_RepostToStory.replacingOccurrences(of: "\n", with: " "), enabled: true))
    if EGSimpleSettings.shared.canUseStealthMode {
        entries.append(.toggle(id: id.count, section: .stories, settingName: .storyStealthMode, value: EGSimpleSettings.shared.storyStealthMode, text: strings.Story_StealthMode_Title, enabled: true))
        entries.append(.notice(id: id.count, section: .stories, text: strings.Story_StealthMode_ControlText))
    } else {
        id.increment(2)
    }

    
    entries.append(.header(id: id.count, section: .translation, text: strings.Localization_TranslateMessages.uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationBackend, text: i18n("Settings.Translation.Backend", lang), value: i18n("Settings.Translation.Backend.\(EGSimpleSettings.shared.translationBackend)", lang), enabled: true))
    if EGSimpleSettings.shared.translationBackendEnum != .gtranslate {
        entries.append(.notice(id: id.count, section: .translation, text: i18n("Settings.Translation.Backend.Notice", lang, "Settings.Translation.Backend.\(EGSimpleSettings.TranslationBackend.gtranslate.rawValue)".i18n(lang))))
    } else {
        id.increment(1)
    }
    entries.append(.toggle(id: id.count, section: .translation, settingName: .quickTranslateButton, value: EGSimpleSettings.shared.quickTranslateButton, text: i18n("Settings.Translation.QuickTranslateButton", lang), enabled: true))
    entries.append(.disclosure(id: id.count, section: .translation, link: .languageSettings, text: strings.Localization_TranslateEntireChat))
    entries.append(.notice(id: id.count, section: .translation, text: i18n("Common.NoTelegramPremiumNeeded", lang, strings.Settings_Premium)))

    entries.append(.header(id: id.count, section: .voiceMessages, text: "Settings.Transcription.Header".i18n(lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .voiceMessages, settingName: .transcriptionBackend, text: i18n("Settings.Transcription.Backend", lang), value: i18n("Settings.Transcription.Backend.\(EGSimpleSettings.shared.transcriptionBackend)", lang), enabled: true))
    if EGSimpleSettings.shared.transcriptionBackendEnum != .apple {
        entries.append(.notice(id: id.count, section: .voiceMessages, text: i18n("Settings.Transcription.Backend.Notice", lang, "Settings.Transcription.Backend.\(EGSimpleSettings.TranscriptionBackend.apple.rawValue)".i18n(lang))))
    } else {
        id.increment(1)
    }
    entries.append(.header(id: id.count, section: .voiceMessages, text: strings.Privacy_VoiceMessages.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .voiceMessages, settingName: .forceBuiltInMic, value: EGSimpleSettings.shared.forceBuiltInMic, text: i18n("Settings.forceBuiltInMic", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .voiceMessages, text: i18n("Settings.forceBuiltInMic.Notice", lang)))

    entries.append(.header(id: id.count, section: .calls, text: strings.Calls_TabTitle.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .calls, settingName: .enableVoipTcp, value: experimentalUISettings.enableVoipTcp, text: "Force TCP", enabled: true))
    entries.append(.notice(id: id.count, section: .calls, text: "Common.KnowWhatYouDo".i18n(lang)))
    
    entries.append(.header(id: id.count, section: .photo, text: strings.NetworkUsageSettings_MediaImageDataSection, badge: nil))
    entries.append(.header(id: id.count, section: .photo, text: strings.PhotoEditor_QualityTool.uppercased(), badge: nil))
    entries.append(.percentageSlider(id: id.count, section: .photo, settingName: .outgoingPhotoQuality, value: EGSimpleSettings.shared.outgoingPhotoQuality))
    entries.append(.notice(id: id.count, section: .photo, text: i18n("Settings.Photo.Quality.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .photo, settingName: .sendLargePhotos, value: EGSimpleSettings.shared.sendLargePhotos, text: i18n("Settings.Photo.SendLarge", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .photo, text: i18n("Settings.Photo.SendLarge.Notice", lang)))
    
    entries.append(.header(id: id.count, section: .stickers, text: strings.StickerPacksSettings_Title.uppercased(), badge: nil))
    entries.append(.header(id: id.count, section: .stickers, text: i18n("Settings.Stickers.Size", lang), badge: nil))
    entries.append(.percentageSlider(id: id.count, section: .stickers, settingName: .stickerSize, value: EGSimpleSettings.shared.stickerSize))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .stickerTimestamp, value: EGSimpleSettings.shared.stickerTimestamp, text: i18n("Settings.Stickers.Timestamp", lang), enabled: true))
    
    
    entries.append(.header(id: id.count, section: .videoNotes, text: i18n("Settings.VideoNotes.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .videoNotes, settingName: .startTelescopeWithRearCam, value: EGSimpleSettings.shared.startTelescopeWithRearCam, text: i18n("Settings.VideoNotes.StartWithRearCam", lang), enabled: true))
    
    entries.append(.header(id: id.count, section: .contextMenu, text: i18n("Settings.ContextMenu", lang), badge: nil))
    entries.append(.notice(id: id.count, section: .contextMenu, text: i18n("Settings.ContextMenu.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowSaveToCloud, value: EGSimpleSettings.shared.contextShowSaveToCloud, text: i18n("ContextMenu.SaveToCloud", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowHideForwardName, value: EGSimpleSettings.shared.contextShowHideForwardName, text: strings.Conversation_ForwardOptions_HideSendersNames, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowSelectFromUser, value: EGSimpleSettings.shared.contextShowSelectFromUser, text: i18n("ContextMenu.SelectFromUser", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowRestrict, value: EGSimpleSettings.shared.contextShowRestrict, text: strings.Conversation_ContextMenuBan, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowReport, value: EGSimpleSettings.shared.contextShowReport, text: strings.Conversation_ContextMenuReport, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowReply, value: EGSimpleSettings.shared.contextShowReply, text: strings.Conversation_ContextMenuReply, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowPin, value: EGSimpleSettings.shared.contextShowPin, text: strings.Conversation_Pin, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowSaveMedia, value: EGSimpleSettings.shared.contextShowSaveMedia, text: strings.Conversation_SaveToFiles, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowMessageReplies, value: EGSimpleSettings.shared.contextShowMessageReplies, text: strings.Conversation_ContextViewThread, enabled: true))
    entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowJson, value: EGSimpleSettings.shared.contextShowJson, text: "JSON", enabled: true))
    /* entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowRestrict, value: EGSimpleSettings.shared.contextShowRestrict, text: strings.Conversation_ContextMenuBan)) */
    
    entries.append(.header(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Header", lang), badge: nil))
    entries.append(.header(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Saturation", lang), badge: nil))
    let accountColorSaturation = EGSimpleSettings.shared.accountColorsSaturation
    entries.append(.percentageSlider(id: id.count, section: .accountColors, settingName: .accountColorsSaturation, value: accountColorSaturation))
//    let nameColor: PeerNameColor
//    if let updatedNameColor = state.updatedNameColor {
//        nameColor = updatedNameColor
//    } else {
//        nameColor = .blue
//    }
//    let _ = nameColors.get(nameColor, dark: presentationData.theme.overallDarkAppearance)
//    entries.append(.peerColorPicker(id: entries.count, section: .other,
//        colors: nameColors,
//        currentColor: nameColor, // TODO: PeerNameColor(rawValue: <#T##Int32#>)
//        currentSaturation: accountColorSaturation
//    ))
    
    if accountColorSaturation == 0 {
        id.increment(100)
        entries.append(.peerColorDisclosurePreview(id: id.count, section: .accountColors, name: "\(strings.UserInfo_FirstNamePlaceholder) \(strings.UserInfo_LastNamePlaceholder)", color:         presentationData.theme.chat.message.incoming.accentTextColor))
    } else {
        id.increment(200)
        for index in nameColors.displayOrder.prefix(3) {
            let color: PeerNameColor = PeerNameColor(rawValue: index)
            let colors = nameColors.get(color, dark: presentationData.theme.overallDarkAppearance)
            entries.append(.peerColorDisclosurePreview(id: id.count, section: .accountColors, name: "\(strings.UserInfo_FirstNamePlaceholder) \(strings.UserInfo_LastNamePlaceholder)", color: colors.main))
        }
    }
    entries.append(.notice(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Saturation.Notice", lang)))
    
    id.increment(10000)
    entries.append(.header(id: id.count, section: .other, text: strings.Appearance_Other.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .other, settingName: .swipeForVideoPIP, value: EGSimpleSettings.shared.videoPIPSwipeDirection == EGSimpleSettings.VideoPIPSwipeDirection.up.rawValue, text: i18n("Settings.swipeForVideoPIP", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Settings.swipeForVideoPIP.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideChannelBottomButton, value: !EGSimpleSettings.shared.hideChannelBottomButton, text: i18n("Settings.showChannelBottomButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .wideChannelPosts, value: EGSimpleSettings.shared.wideChannelPosts, text: i18n("Settings.wideChannelPosts", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .secondsInMessages, value: EGSimpleSettings.shared.secondsInMessages, text: i18n("Settings.secondsInMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .messageDoubleTapActionOutgoingEdit, value: EGSimpleSettings.shared.messageDoubleTapActionOutgoing == EGSimpleSettings.MessageDoubleTapAction.edit.rawValue, text: i18n("Settings.messageDoubleTapActionOutgoingEdit", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideRecordingButton, value: !EGSimpleSettings.shared.hideRecordingButton, text: i18n("Settings.RecordingButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .disableSnapDeletionEffect, value: !EGSimpleSettings.shared.disableSnapDeletionEffect, text: i18n("Settings.SnapDeletionEffect", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .disableSendAsButton, value: !EGSimpleSettings.shared.disableSendAsButton, text: i18n("Settings.SendAsButton", lang, strings.Conversation_SendMesageAs), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .disableGalleryCamera, value: !EGSimpleSettings.shared.disableGalleryCamera, text: i18n("Settings.GalleryCamera", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .disableGalleryCameraPreview, value: !EGSimpleSettings.shared.disableGalleryCameraPreview, text: i18n("Settings.GalleryCameraPreview", lang), enabled: !EGSimpleSettings.shared.disableGalleryCamera))
    entries.append(.toggle(id: id.count, section: .other, settingName: .disableScrollToNextChannel, value: !EGSimpleSettings.shared.disableScrollToNextChannel, text: i18n("Settings.PullToNextChannel", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .disableScrollToNextTopic, value: !EGSimpleSettings.shared.disableScrollToNextTopic, text: i18n("Settings.PullToNextTopic", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideReactions, value: EGSimpleSettings.shared.hideReactions, text: i18n("Settings.HideReactions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .uploadSpeedBoost, value: EGSimpleSettings.shared.uploadSpeedBoost, text: i18n("Settings.UploadsBoost", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .other, settingName: .downloadSpeedBoost, text: i18n("Settings.DownloadsBoost", lang), value: i18n("Settings.DownloadsBoost.\(EGSimpleSettings.shared.downloadSpeedBoost)", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Settings.DownloadsBoost.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .other, settingName: .sendWithReturnKey, value: EGSimpleSettings.shared.sendWithReturnKey, text: i18n("Settings.SendWithReturnKey", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .forceEmojiTab, value: EGSimpleSettings.shared.forceEmojiTab, text: i18n("Settings.ForceEmojiTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .defaultEmojisFirst, value: EGSimpleSettings.shared.defaultEmojisFirst, text: i18n("Settings.DefaultEmojisFirst", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Settings.DefaultEmojisFirst.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hidePhoneInSettings, value: EGSimpleSettings.shared.hidePhoneInSettings, text: i18n("Settings.HidePhoneInSettingsUI", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Settings.HidePhoneInSettingsUI.Notice", lang)))
    
    return filterSGItemListUIEntrires(entries: entries, by: state.searchQuery)
}

public func egSettingsController(context: AccountContext/*, focusOnItemTag: Int? = nil*/) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
//    var getRootControllerImpl: (() -> UIViewController?)?
//    var getNavigationControllerImpl: (() -> NavigationController?)?
    var askForRestart: (() -> Void)?
    
    let initialState = EGSettingsControllerState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((EGSettingsControllerState) -> EGSettingsControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
//    let sliderPromise = ValuePromise(EGSimpleSettings.shared.accountColorsSaturation, ignoreRepeated: true)
//    let sliderStateValue = Atomic(value: EGSimpleSettings.shared.accountColorsSaturation)
//    let _: ((Int32) -> Int32) -> Void = { f in
//        sliderPromise.set(sliderStateValue.modify( {f($0)}))
//    }
    
    let simplePromise = ValuePromise(true, ignoreRepeated: false)
    
    let arguments = EGItemListArguments<EGBoolSetting, EGSliderSetting, EGOneFromManySetting, EGDisclosureLink, AnyHashable>(
        context: context,
        /*updatePeerColor: { color in
          updateState { state in
              var updatedState = state
              updatedState.updatedNameColor = color
              return updatedState
          }
        },*/ setBoolValue: { setting, value in
        switch setting {
        case .hidePhoneInSettings:
            EGSimpleSettings.shared.hidePhoneInSettings = value
            askForRestart?()
        case .showTabNames:
            EGSimpleSettings.shared.showTabNames = value
            askForRestart?()
        case .showContactsTab:
            let _ = (
                updateCallListSettingsInteractively(
                    accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowContactsTab(value) }
                )
            ).start()
        case .showCallsTab:
            let _ = (
                updateCallListSettingsInteractively(
                    accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowTab(value) }
                )
            ).start()
        case .tabBarSearchEnabled:
            EGSimpleSettings.shared.tabBarSearchEnabled = value
        case .wideTabBar:
            EGSimpleSettings.shared.wideTabBar = value
            askForRestart?()
        case .foldersAtBottom:
            let _ = (
                updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.foldersTabAtBottom = value
                        return settings
                    }
                )
            ).start()
        case .startTelescopeWithRearCam:
            EGSimpleSettings.shared.startTelescopeWithRearCam = value
        case .hideStories:
            EGSimpleSettings.shared.hideStories = value
        case .showProfileId:
            EGSimpleSettings.shared.showProfileId = value
        case .warnOnStoriesOpen:
            EGSimpleSettings.shared.warnOnStoriesOpen = value
        case .sendWithReturnKey:
            EGSimpleSettings.shared.sendWithReturnKey = value
        case .rememberLastFolder:
            EGSimpleSettings.shared.rememberLastFolder = value
        case .sendLargePhotos:
            EGSimpleSettings.shared.sendLargePhotos = value
        case .storyStealthMode:
            EGSimpleSettings.shared.storyStealthMode = value
        case .disableSwipeToRecordStory:
            EGSimpleSettings.shared.disableSwipeToRecordStory = value
        case .quickTranslateButton:
            EGSimpleSettings.shared.quickTranslateButton = value
        case .uploadSpeedBoost:
            EGSimpleSettings.shared.uploadSpeedBoost = value
        case .hideReactions:
            EGSimpleSettings.shared.hideReactions = value
        case .showRepostToStory:
            EGSimpleSettings.shared.showRepostToStoryV2 = value
        case .contextShowSelectFromUser:
            EGSimpleSettings.shared.contextShowSelectFromUser = value
        case .contextShowSaveToCloud:
            EGSimpleSettings.shared.contextShowSaveToCloud = value
        case .contextShowRestrict:
            EGSimpleSettings.shared.contextShowRestrict = value
        case .contextShowHideForwardName:
            EGSimpleSettings.shared.contextShowHideForwardName = value
        case .disableScrollToNextChannel:
            EGSimpleSettings.shared.disableScrollToNextChannel = !value
        case .disableScrollToNextTopic:
            EGSimpleSettings.shared.disableScrollToNextTopic = !value
        case .disableChatSwipeOptions:
            EGSimpleSettings.shared.disableChatSwipeOptions = !value
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
            askForRestart?()
        case .disableDeleteChatSwipeOption:
            EGSimpleSettings.shared.disableDeleteChatSwipeOption = !value
            askForRestart?()
        case .disableGalleryCamera:
            EGSimpleSettings.shared.disableGalleryCamera = !value
            simplePromise.set(true)
        case .disableGalleryCameraPreview:
            EGSimpleSettings.shared.disableGalleryCameraPreview = !value
        case .disableSendAsButton:
            EGSimpleSettings.shared.disableSendAsButton = !value
        case .disableSnapDeletionEffect:
            EGSimpleSettings.shared.disableSnapDeletionEffect = !value
        case .contextShowReport:
            EGSimpleSettings.shared.contextShowReport = value
        case .contextShowReply:
            EGSimpleSettings.shared.contextShowReply = value
        case .contextShowPin:
            EGSimpleSettings.shared.contextShowPin = value
        case .contextShowSaveMedia:
            EGSimpleSettings.shared.contextShowSaveMedia = value
        case .contextShowMessageReplies:
            EGSimpleSettings.shared.contextShowMessageReplies = value
        case .stickerTimestamp:
            EGSimpleSettings.shared.stickerTimestamp = value
        case .contextShowJson:
            EGSimpleSettings.shared.contextShowJson = value
        case .hideRecordingButton:
            EGSimpleSettings.shared.hideRecordingButton = !value
        case .hideTabBar:
            EGSimpleSettings.shared.hideTabBar = value
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
            askForRestart?()
        case .showDC:
            EGSimpleSettings.shared.showDC = value
        case .showCreationDate:
            EGSimpleSettings.shared.showCreationDate = value
        case .showRegDate:
            EGSimpleSettings.shared.showRegDate = value
        case .compactChatList:
            EGSimpleSettings.shared.compactChatList = value
            askForRestart?()
        case .compactMessagePreview:
            EGSimpleSettings.shared.chatListLines = value ? EGSimpleSettings.ChatListLines.one.rawValue : EGSimpleSettings.ChatListLines.three.rawValue
            askForRestart?()
        case .compactFolderNames:
            EGSimpleSettings.shared.compactFolderNames = value
            askForRestart?()
        case .allChatsHidden:
            EGSimpleSettings.shared.allChatsHidden = value
            askForRestart?()
        case .defaultEmojisFirst:
            EGSimpleSettings.shared.defaultEmojisFirst = value
        case .messageDoubleTapActionOutgoingEdit:
            EGSimpleSettings.shared.messageDoubleTapActionOutgoing = value ? EGSimpleSettings.MessageDoubleTapAction.edit.rawValue : EGSimpleSettings.MessageDoubleTapAction.default.rawValue
        case .wideChannelPosts:
            EGSimpleSettings.shared.wideChannelPosts = value
        case .forceEmojiTab:
            EGSimpleSettings.shared.forceEmojiTab = value
        case .forceBuiltInMic:
            EGSimpleSettings.shared.forceBuiltInMic = value
        case .hideChannelBottomButton:
            EGSimpleSettings.shared.hideChannelBottomButton = !value
        case .secondsInMessages:
            EGSimpleSettings.shared.secondsInMessages = value
        case .confirmCalls:
            EGSimpleSettings.shared.confirmCalls = value
        case .swipeForVideoPIP:
            EGSimpleSettings.shared.videoPIPSwipeDirection = value ? EGSimpleSettings.VideoPIPSwipeDirection.up.rawValue : EGSimpleSettings.VideoPIPSwipeDirection.none.rawValue
        case .enableVoipTcp:
            let _ = (
                updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.enableVoipTcp = value
                        return settings
                    }
                )
            ).start()
        case .nyStyleSnow:
            EGSimpleSettings.shared.nyStyle = value ? EGSimpleSettings.NYStyle.snow.rawValue : EGSimpleSettings.NYStyle.default.rawValue
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
        case .nyStyleLightning:
            EGSimpleSettings.shared.nyStyle = value ? EGSimpleSettings.NYStyle.lightning.rawValue : EGSimpleSettings.NYStyle.default.rawValue
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
        }
    }, updateSliderValue: { setting, value in
        switch (setting) {
            case .accountColorsSaturation:
                if EGSimpleSettings.shared.accountColorsSaturation != value {
                    EGSimpleSettings.shared.accountColorsSaturation = value
                    simplePromise.set(true)
                }
            case .outgoingPhotoQuality:
                if EGSimpleSettings.shared.outgoingPhotoQuality != value {
                    EGSimpleSettings.shared.outgoingPhotoQuality = value
                    simplePromise.set(true)
                }
            case .stickerSize:
                if EGSimpleSettings.shared.stickerSize != value {
                    EGSimpleSettings.shared.stickerSize = value
                    simplePromise.set(true)
                }
        }

    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        
        switch (setting) {
            case .downloadSpeedBoost:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.downloadSpeedBoost = value
                    
                    let enableDownloadX: Bool
                    switch (value) {
                        case EGSimpleSettings.DownloadSpeedBoostValues.none.rawValue:
                            enableDownloadX = false
                        default:
                            enableDownloadX = true
                    }
                    
                    // Updating controller
                    simplePromise.set(true)

                    let _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { settings in
                        var settings = settings
                        settings.useExperimentalDownload = enableDownloadX
                        return settings
                    }).start(completed: {
                        Queue.mainQueue().async {
                            askForRestart?()
                        }
                    })
                }

                for value in EGSimpleSettings.DownloadSpeedBoostValues.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("Settings.DownloadsBoost.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .bottomTabStyle:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.bottomTabStyle = value
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.BottomTabStyleValues.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("Settings.Folders.BottomTabStyle.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .allChatsTitleLengthOverride:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.allChatsTitleLengthOverride = value
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.AllChatsTitleLengthOverride.allCases {
                    let title: String
                    switch (value) {
                        case EGSimpleSettings.AllChatsTitleLengthOverride.short:
                            title = "\"\(presentationData.strings.ChatList_Tabs_All)\""
                        case EGSimpleSettings.AllChatsTitleLengthOverride.long:
                            title = "\"\(presentationData.strings.ChatList_Tabs_AllChats)\""
                        default:
                            title = i18n("Settings.Folders.AllChatsTitle.none", presentationData.strings.baseLanguageCode)
                    }
                    items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
//        case .allChatsFolderPositionOverride:
//            let setAction: (String) -> Void = { value in
//                EGSimpleSettings.shared.allChatsFolderPositionOverride = value
//                simplePromise.set(true)
//            }
//
//            for value in EGSimpleSettings.AllChatsFolderPositionOverride.allCases {
//                items.append(ActionSheetButtonItem(title: i18n("Settings.Folders.AllChatsTitle.\(value)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
//                    actionSheet?.dismissAnimated()
//                    setAction(value.rawValue)
//                }))
//            }
            case .translationBackend:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.translationBackend = value
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.TranslationBackend.allCases {
                    if value == .system {
                        if #available(iOS 18.0, *) {
                        } else {
                            continue // System translation is not available on iOS 17 and below
                        }
                    }
                    items.append(ActionSheetButtonItem(title: i18n("Settings.Translation.Backend.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .transcriptionBackend:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.transcriptionBackend = value
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.TranscriptionBackend.allCases {
                    if #available(iOS 13.0, *) {
                    } else {
                        if value == .apple {
                            continue // Apple recognition is not available on iOS 12
                        }
                    }
                    items.append(ActionSheetButtonItem(title: i18n("Settings.Transcription.Backend.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .nyStyle:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.nyStyle = value
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.NYStyle.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("Settings.NY.Style.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
        }
        
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }, openDisclosureLink: { link in
        switch (link) {
            case .languageSettings:
                pushControllerImpl?(context.sharedContext.makeLocalizationListController(context: context))
            case .contentSettings:
                let _ = (getEGSettingsURL(context: context) |> deliverOnMainQueue).start(next: { [weak context] url in
                    guard let strongContext = context else {
                        return
                    }
                    strongContext.sharedContext.applicationBindings.openUrl(url)
                })
        }
    }, searchInput: { searchQuery in
        updateState { state in
            var updatedState = state
            updatedState.searchQuery = searchQuery
            return updatedState
        }
    })
    
    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings])
    let preferences = context.account.postbox.preferencesView(keys: [PreferencesKeys.appConfiguration])
    let updatedContentSettingsConfiguration = contentSettingsConfiguration(network: context.account.network)
    |> map(Optional.init)
    let contentSettingsConfiguration = Promise<ContentSettingsConfiguration?>()
    contentSettingsConfiguration.set(.single(nil)
    |> then(updatedContentSettingsConfiguration))
    
    let signal = combineLatest(simplePromise.get(), /*sliderPromise.get(),*/ statePromise.get(), context.sharedContext.presentationData, sharedData, preferences, contentSettingsConfiguration.get(),
        context.engine.accountData.observeAvailableColorOptions(scope: .replies),
        context.engine.accountData.observeAvailableColorOptions(scope: .profile)
    )
    |> map { _, /*sliderValue,*/ state, presentationData, sharedData, view, contentSettingsConfiguration, availableReplyColors, availableProfileColors ->  (ItemListControllerState, (ItemListNodeState, Any)) in
        
        let appConfiguration: AppConfiguration = view.values[PreferencesKeys.appConfiguration]?.get(AppConfiguration.self) ?? AppConfiguration.defaultValue
        let callListSettings: CallListSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
        let experimentalUISettings: ExperimentalUISettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        
        let entries = EGControllerEntries(presentationData: presentationData, callListSettings: callListSettings, experimentalUISettings: experimentalUISettings, appConfiguration: appConfiguration, nameColors: PeerNameColors.with(availableReplyColors: availableReplyColors, availableProfileColors: availableProfileColors), state: state)
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("exteraGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        
        // TODO(exteragram): focusOnItemTag support
        /* var index = 0
        var scrollToItem: ListViewScrollToItem?
         if let focusOnItemTag = focusOnItemTag {
            for entry in entries {
                if entry.tag?.isEqual(to: focusOnItemTag) ?? false {
                    scrollToItem = ListViewScrollToItem(index: index, position: .top(0.0), animated: false, curve: .Default(duration: 0.0), directionHint: .Up)
                }
                index += 1
            }
        } */
        
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: /*focusOnItemTag*/ nil, initialScrollToItem: nil /* scrollToItem*/ )
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
//    getRootControllerImpl = { [weak controller] in
//        return controller?.view.window?.rootViewController
//    }
//    getNavigationControllerImpl = { [weak controller] in
//        return controller?.navigationController as? NavigationController
//    }
    askForRestart = { [weak context] in
        guard let context = context else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(
            UndoOverlayController(
                presentationData: presentationData, 
                content: .info(title: nil, // i18n("Common.RestartRequired", presentationData.strings.baseLanguageCode),
                    text: i18n("Common.RestartRequired", presentationData.strings.baseLanguageCode),
                    timeout: nil,
                    customUndoText: i18n("Common.RestartNow", presentationData.strings.baseLanguageCode) //presentationData.strings.Common_Yes
                ),
                elevatedLayout: false,
                action: { action in if action == .undo { exit(0) }; return true }
            ),
            nil
        )
    }
    return controller

}
