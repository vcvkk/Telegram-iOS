import Foundationimport UniformTypeIdentifiersimport preferencesimport UndoUIimport AccountContextimport Displayimport TelegramCoreimport Postboximport ItemListUIimport SwiftSignalKitimport TelegramPresentationDataimport PresentationDataUtilsimport TelegramUIPreferencesimport SettingsUI
// Optional
import configcoreimport logging

private enum EGProControllerSection: Int32, EGItemListSection {
    case base
    case appearance
    case notifications
}

private enum EGProDisclosureLink: String {
    case sessionBackupManager
    case messageFilter
    case appIcons
    case appBages
}

private enum EGProToggles: String {
    case _placeholder
}

private enum EGProOneFromManySetting: String {
    case pinnedMessageNotifications
    case mentionsAndRepliesNotifications
}

private enum EGProAction: String {
    case _placeholder
}

private typealias EGProControllerEntry = EGItemListUIEntry<EGProControllerSection, EGProToggles, AnyHashable, EGProOneFromManySetting, EGProDisclosureLink, EGProAction>

private func EGProControllerEntries(presentationData: PresentationData) -> [EGProControllerEntry] {
    var entries: [EGProControllerEntry] = []
    let lang = presentationData.strings.baseLanguageCode

    let id = EGItemListCounter()

    entries.append(.disclosure(id: id.count, section: .base, link: .sessionBackupManager, text: "SessionBackup.Title".i18n(lang)))
    entries.append(.disclosure(id: id.count, section: .base, link: .messageFilter, text: "MessageFilter.Title".i18n(lang)))
    entries.append(.header(id: id.count, section: .notifications, text: presentationData.strings.Notifications_Title.uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .notifications, settingName: .pinnedMessageNotifications, text: "Notifications.PinnedMessages.Title".i18n(lang), value: "Notifications.PinnedMessages.value.\(EGSimpleSettings.shared.pinnedMessageNotifications)".i18n(lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .notifications, settingName: .mentionsAndRepliesNotifications, text: "Notifications.MentionsAndReplies.Title".i18n(lang), value: "Notifications.MentionsAndReplies.value.\(EGSimpleSettings.shared.mentionsAndRepliesNotifications)".i18n(lang), enabled: true))
    entries.append(.header(id: id.count, section: .appearance, text: presentationData.strings.Appearance_Title.uppercased(), badge: nil))
    entries.append(.disclosure(id: id.count, section: .appearance, link: .appIcons, text: presentationData.strings.Appearance_AppIcon))
    entries.append(.disclosure(id: id.count, section: .appearance, link: .appBages, text: "AppBadge.Title".i18n(lang)))
    entries.append(.notice(id: id.count, section: .appearance, text: "AppBadge.Notice".i18n(lang)))

    return entries
}

public func okUndoController(_ text: String, _ presentationData: PresentationData) -> UndoOverlayController {
    return UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false })
}

public func egProController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let simplePromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = EGItemListArguments<EGProToggles, AnyHashable, EGProOneFromManySetting, EGProDisclosureLink, EGProAction>(context: context, setBoolValue: { toggleName, value in
        switch toggleName {
            case ._placeholder:
                break
        }
    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []

        switch (setting) {
            case .pinnedMessageNotifications:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.pinnedMessageNotifications = value
                    EGSimpleSettings.shared.synchronizeShared()
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.PinnedMessageNotificationsSettings.allCases {
                    items.append(ActionSheetButtonItem(title: "Notifications.PinnedMessages.value.\(value.rawValue)".i18n(lang), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .mentionsAndRepliesNotifications:
                let setAction: (String) -> Void = { value in
                    EGSimpleSettings.shared.mentionsAndRepliesNotifications = value
                    EGSimpleSettings.shared.synchronizeShared()
                    simplePromise.set(true)
                }

                for value in EGSimpleSettings.MentionsAndRepliesNotificationsSettings.allCases {
                    items.append(ActionSheetButtonItem(title: "Notifications.MentionsAndReplies.value.\(value.rawValue)".i18n(lang), color: .accent, action: { [weak actionSheet] in
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
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch (link) {
            case .sessionBackupManager:
                pushControllerImpl?(egSessionBackupManagerController(context: context, presentationData: presentationData))
            case .messageFilter:
                pushControllerImpl?(egMessageFilterController(presentationData: presentationData))
            case .appIcons:
                pushControllerImpl?(themeSettingsController(context: context, focusOnItemTag: .icon))
            case .appBages:
                if #available(iOS 14.0, *) {
                    pushControllerImpl?(egAppBadgeSettingsController(context: context, presentationData: presentationData))
                }
        }
    }, action: { _ in
    })

    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ ->  (ItemListControllerState, (ItemListNodeState, Any)) in

        let entries = EGProControllerEntries(presentationData: presentationData)

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("exteraGram Pro"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))

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
