import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import ContextUI
import TelegramPresentationData

extension PeerInfoScreenNode {
    func displayPluginContextMenu(source: ContextReferenceContentNode, gesture: ContextGesture?) {
        let entries = EGPluginHooks.registeredMenuItems.filter { $0.entryType == "profile" }
        guard !entries.isEmpty, let controller = self.controller else {
            return
        }

        var sourceView: UIView = source.view
        if sourceView.isDescendant(of: self.headerNode.navigationButtonContainer.rightButtonsBackground) {
            sourceView = self.headerNode.navigationButtonContainer.rightButtonsBackground
        }

        var items: [ContextMenuItem] = []
        for entry in entries {
            let pluginId = entry.pluginId
            let entryType = entry.entryType
            let itemId = entry.itemId
            let iconName = entry.iconName
            items.append(.action(ContextMenuActionItem(
                text: entry.title,
                icon: { (theme: PresentationTheme) in
                    guard let name = iconName else { return nil }
                    return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
                },
                action: { _, f in
                    f(.default)
                    EGPluginHooks.pluginMenuItemTappedHandler?(pluginId, entryType, itemId, nil)
                }
            )))
        }

        let contextController = makeContextController(
            presentationData: self.presentationData,
            source: .reference(PeerInfoContextReferenceContentSource(controller: controller, sourceView: sourceView)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: gesture)
        controller.presentInGlobalOverlay(contextController)
    }
}
