import Foundation
import EGSimpleSettings
import Postbox
import TelegramCore


func egDoubleTapMessageAction(incoming: Bool, message: Message) -> String {
    if incoming {
        return EGSimpleSettings.MessageDoubleTapAction.default.rawValue
    } else {
        return EGSimpleSettings.shared.messageDoubleTapActionOutgoing
    }
}
