import Foundation
import UIKit
import UniformTypeIdentifiers
import EGItemListUI
import UndoUI
import AccountContext
import Display
import TelegramCore
import Postbox
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import TelegramUIPreferences

// Optional
import EGBadges
import EGSimpleSettings
import EGLogging
import EGPayWall
import OverlayStatusController
#if DEBUG
import FLEX
#endif


private enum EGDebugControllerSection: Int32, EGItemListSection {
    case base
    case notifications
}

private enum EGDebugDisclosureLink: String {
    case sessionBackupManager
    case messageFilter
    case debugIAP
}

private enum EGDebugActions: String {
    case flexing
    case fileManager
    case clearRegDateCache
    case clearOutgoingTranslationLanguageCache
    case toggleDevBadgeSelf
    case clearBadgeCache
    case showBadgeCache
    case e621
}

private enum EGDebugToggles: String {
    case forceImmediateShareSheet
    case legacyNotificationsFix
}


private enum EGDebugOneFromManySetting: String {
    case pinnedMessageNotifications
    case mentionsAndRepliesNotifications
}

private typealias EGDebugControllerEntry = EGItemListUIEntry<EGDebugControllerSection, EGDebugToggles, AnyHashable, EGDebugOneFromManySetting, EGDebugDisclosureLink, EGDebugActions>

private func EGDebugControllerEntries(presentationData: PresentationData) -> [EGDebugControllerEntry] {
    var entries: [EGDebugControllerEntry] = []
    
    let id = EGItemListCounter()
    #if DEBUG
    entries.append(.action(id: id.count, section: .base, actionType: .flexing, text: "FLEX", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .fileManager, text: "FileManager", kind: .generic))
    #endif

    entries.append(.action(id: id.count, section: .base, actionType: .clearRegDateCache, text: "Clear Regdate cache", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .clearOutgoingTranslationLanguageCache, text: "Clear Outgoing Translation cache", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .toggleDevBadgeSelf, text: "Toggle DEV badge (self)", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .showBadgeCache, text: "Show badge cache", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .clearBadgeCache, text: "Clear Badge cache", kind: .destructive))
    entries.append(.toggle(id: id.count, section: .base, settingName: .forceImmediateShareSheet, value: EGSimpleSettings.shared.forceSystemSharing, text: "Force System Share Sheet", enabled: true))
    
    entries.append(.toggle(id: id.count, section: .notifications, settingName: .legacyNotificationsFix, value: EGSimpleSettings.shared.legacyNotificationsFix, text: "[OLD] Fix empty notifications", enabled: true))
    entries.append(.action(id: id.count, section: .base, actionType: .e621, text: "e621", kind: .generic))
    return entries
}
private func okUndoController(_ text: String, _ presentationData: PresentationData) -> UndoOverlayController {
    return UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false })
}


public func egDebugController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let simplePromise = ValuePromise(true, ignoreRepeated: false)
    
    let arguments = EGItemListArguments<EGDebugToggles, AnyHashable, EGDebugOneFromManySetting, EGDebugDisclosureLink, EGDebugActions>(context: context, setBoolValue: { toggleName, value in
        switch toggleName {
            case .forceImmediateShareSheet:
                EGSimpleSettings.shared.forceSystemSharing = value
            case .legacyNotificationsFix:
                EGSimpleSettings.shared.legacyNotificationsFix = value
                EGSimpleSettings.shared.synchronizeShared()
        }
    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let items: [ActionSheetItem] = []
//        var items: [ActionSheetItem] = []
        
//        switch (setting) {
//        }
        
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }, openDisclosureLink: { _ in
    }, action: { actionType in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch actionType {
            case .clearRegDateCache:
                EGLogger.shared.log("EGDebug", "Regdate cache cleanup init")
                
                /*
                let spinner = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))

                presentControllerImpl?(spinner, nil)
                */
                EGSimpleSettings.shared.regDateCache.drop()
                EGLogger.shared.log("EGDebug", "Regdate cache cleanup succesfull")
                presentControllerImpl?(okUndoController("OK: Regdate cache cleaned", presentationData), nil)
                /*
                Queue.mainQueue().async() { [weak spinner] in
                    spinner?.dismiss()
                }
                */
            case .clearOutgoingTranslationLanguageCache:
                EGLogger.shared.log("EGDebug", "Outgoing translation language cache cleanup init")
                EGSimpleSettings.shared.outgoingLanguageTranslation.drop()
                EGLogger.shared.log("EGDebug", "Outgoing translation language cache cleanup succesfull")
                presentControllerImpl?(okUndoController("OK: Outgoing translation language cache cleaned", presentationData), nil)
            case .toggleDevBadgeSelf:
                let selfId = context.account.peerId.id._internalGetInt64Value()
                if BadgesController.shared.hasBadge(peerIdValue: selfId) {
                    BadgesController.shared.injectBadge(nil, forPeerIdValue: selfId)
                    presentControllerImpl?(okUndoController("DEV badge removed for \(selfId)", presentationData), nil)
                } else {
                    BadgesController.shared.injectBadge(BadgesController.DEV_BADGE, forPeerIdValue: selfId)
                    presentControllerImpl?(okUndoController("DEV badge injected for \(selfId)", presentationData), nil)
                }
            case .showBadgeCache:
                let ids = BadgesController.shared.allCachedPeerIds
                let cacheInfo = ids.isEmpty ? "Cache: empty" : "Cache: \(ids.count) peer(s): " + ids.joined(separator: ", ")
                let text = "\(cacheInfo)\nLast sync: \(BadgesController.shared.lastSyncStatus)"
                presentControllerImpl?(okUndoController(text, presentationData), nil)
            case .clearBadgeCache:
                UserDefaults.standard.removeObject(forKey: "eg_badges_v1")
                presentControllerImpl?(okUndoController("OK: Badge cache cleared", presentationData), nil)
        case .flexing:
            #if DEBUG
            FLEXManager.shared.toggleExplorer()
            #endif
        case .e621:
            UIApplication.shared.open(URL(string: "https://e621.net")!)
        case .fileManager:
            #if DEBUG
            let baseAppBundleId = Bundle.main.bundleIdentifier!
            let appGroupName = "group.\(baseAppBundleId)"
            let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
            if let maybeAppGroupUrl = maybeAppGroupUrl {
                if let fileManager = FLEXFileBrowserController(path: maybeAppGroupUrl.path) {
                    FLEXManager.shared.showExplorer()
                    let flexNavigation = FLEXNavigationController(rootViewController: fileManager)
                    FLEXManager.shared.presentTool({ return flexNavigation })
                }
            } else {
                presentControllerImpl?(UndoOverlayController(
                    presentationData: presentationData,
                    content: .info(title: nil, text: "Empty path", timeout: nil, customUndoText: nil),
                    elevatedLayout: false,
                    action: { _ in return false }
                ),
                nil)
            }
            #endif
        }
    })
    
    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ ->  (ItemListControllerState, (ItemListNodeState, Any)) in
        
        let entries = EGDebugControllerEntries(presentationData: presentationData)
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("exteraGram Debug"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        
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
    // Workaround
    let _ = pushControllerImpl
    
    return controller
}


