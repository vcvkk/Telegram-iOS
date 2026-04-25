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


// MARK: - e621 Screensaver

private final class E621ViewController: UIViewController {
    private let logoLabel = UILabel()
    private var position = CGPoint(x: 120, y: 160)
    private var velocity = CGPoint(x: 250, y: 195)
    private var lastTimestamp: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var hue: CGFloat = 0.55
    private var frameCount = 0

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.03, alpha: 1)

        logoLabel.text = "e621"
        logoLabel.font = .systemFont(ofSize: 80, weight: .black)
        logoLabel.textColor = UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
        logoLabel.sizeToFit()
        logoLabel.layer.shadowColor = logoLabel.textColor.cgColor
        logoLabel.layer.shadowRadius = 18
        logoLabel.layer.shadowOpacity = 0.9
        logoLabel.layer.shadowOffset = .zero
        view.addSubview(logoLabel)

        let hint = UILabel()
        hint.text = "tap to open"
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = UIColor.white.withAlphaComponent(0.25)
        hint.sizeToFit()
        hint.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(hint)
        DispatchQueue.main.async {
            hint.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.height - 52)
        }

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logoLabel.frame.origin = position
        // Spring entrance
        logoLabel.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        UIView.animate(withDuration: 0.5, delay: 0,
                       usingSpringWithDamping: 0.55, initialSpringVelocity: 0.3,
                       options: [], animations: { self.logoLabel.transform = .identity })
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard lastTimestamp != 0 else { lastTimestamp = link.timestamp; return }
        let dt = min(CGFloat(link.timestamp - lastTimestamp), 1.0 / 30.0)
        lastTimestamp = link.timestamp
        frameCount += 1

        position.x += velocity.x * dt
        position.y += velocity.y * dt

        let bounds = view.bounds
        let lw = logoLabel.bounds.width
        let lh = logoLabel.bounds.height
        var hitWall = false
        var corner = false

        if position.x < 0 {
            position.x = 0; velocity.x = abs(velocity.x); hitWall = true
            corner = position.y < lh || position.y > bounds.height - lh * 2
        } else if position.x + lw > bounds.width {
            position.x = bounds.width - lw; velocity.x = -abs(velocity.x); hitWall = true
            corner = position.y < lh || position.y > bounds.height - lh * 2
        }
        if position.y < 0 {
            position.y = 0; velocity.y = abs(velocity.y); hitWall = true
        } else if position.y + lh > bounds.height {
            position.y = bounds.height - lh; velocity.y = -abs(velocity.y); hitWall = true
        }

        if hitWall { cycleColor(); spawnTrail(); flashScreen(corner: corner) }
        if frameCount % 4 == 0 { spawnTrail() }

        logoLabel.frame.origin = position
    }

    private func cycleColor() {
        hue = (hue + 0.14).truncatingRemainder(dividingBy: 1)
        let color = UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
        logoLabel.textColor = color
        logoLabel.layer.shadowColor = color.cgColor
    }

    private func spawnTrail() {
        guard let snap = logoLabel.snapshotView(afterScreenUpdates: false) else { return }
        snap.frame = logoLabel.frame
        snap.alpha = 0.4
        view.insertSubview(snap, belowSubview: logoLabel)
        UIView.animate(withDuration: 0.55, delay: 0, options: .curveEaseOut, animations: {
            snap.alpha = 0
            snap.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        }, completion: { _ in snap.removeFromSuperview() })
    }

    private func flashScreen(corner: Bool) {
        let flash = UIView(frame: view.bounds)
        flash.backgroundColor = logoLabel.textColor.withAlphaComponent(corner ? 0.45 : 0.15)
        flash.isUserInteractionEnabled = false
        view.insertSubview(flash, belowSubview: logoLabel)
        UIView.animate(withDuration: corner ? 0.55 : 0.28, options: .curveEaseOut, animations: {
            flash.alpha = 0
        }, completion: { _ in flash.removeFromSuperview() })
    }

    @objc private func handleTap() {
        displayLink?.invalidate()
        displayLink = nil
        UIView.animate(withDuration: 0.22, animations: {
            self.logoLabel.transform = CGAffineTransform(scaleX: 25, y: 25)
            self.logoLabel.alpha = 0
            self.view.alpha = 0
        }, completion: { _ in
            UIApplication.shared.open(URL(string: "https://e621.net")!)
            self.dismiss(animated: false)
        })
    }
}

// MARK: -

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
            let vc = E621ViewController()
            vc.modalPresentationStyle = .overFullScreen
            vc.modalTransitionStyle = .crossDissolve
            if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
                window.rootViewController?.present(vc, animated: true)
            }
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


