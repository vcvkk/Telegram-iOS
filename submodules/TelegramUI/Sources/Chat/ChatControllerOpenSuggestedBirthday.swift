import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import UndoUI

extension ChatControllerImpl {
    // MARK: exteraGram
    // Hoisted out of the `openMessage:` closure's media switch. That closure is
    // thousands of lines long, and this case adds two nested screen factories
    // with three escaping closures between them — enough that the type checker
    // gives up on the whole closure with "unable to type-check this expression
    // in reasonable time" and reports nothing usable. Same remedy as the other
    // ChatController* files here: give the body its own declaration so it is
    // type-checked on its own.
    func openSuggestedBirthday(_ birthday: TelegramBirthday) {
        let settingsPromise: Promise<AccountPrivacySettings?>
        if let rootController = self.context.sharedContext.mainWindow?.viewController as? TelegramRootControllerInterface, let current = rootController.getPrivacySettings() {
            settingsPromise = current
        } else {
            settingsPromise = Promise()
            settingsPromise.set(.single(nil) |> then(self.context.engine.privacy.requestAccountPrivacySettings() |> map(Optional.init)))
        }

        let openSettings: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.context.sharedContext.makeBirthdayPrivacyController(context: self.context, settings: settingsPromise, openedFromBirthdayScreen: true, present: { [weak self] c in
                self?.push(c)
            })
        }

        let completion: (TelegramBirthday) -> Void = { [weak self] value in
            guard let self else {
                return
            }
            let _ = self.context.engine.accountData.updateBirthday(birthday: value).startStandalone()

            let content: UndoOverlayContent = .universal(animation: "anim_gift", scale: 0.058, colors: ["__allcolors__": UIColor.white], title: nil, text: self.presentationData.strings.SuggestBirthdate_Accept_Added, customUndoText: nil, timeout: 5.0)
            self.present(UndoOverlayController(presentationData: self.presentationData, content: content, elevatedLayout: false, action: { _ in
                return true
            }), in: .current)
        }

        let controller = self.context.sharedContext.makeBirthdayAcceptSuggestionScreen(context: self.context, birthday: birthday, settings: settingsPromise, openSettings: openSettings, completion: completion)
        self.push(controller)
    }
}
