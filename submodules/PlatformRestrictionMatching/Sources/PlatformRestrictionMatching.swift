import Foundation
import Postbox
import TelegramCore
import Postbox

public extension Message {
    func isRestricted(platform: String, contentSettings: ContentSettings) -> Bool {
        return self.restrictionReason(platform: platform, contentSettings: contentSettings) != nil
    }
    
    func restrictionReason(platform: String, contentSettings: ContentSettings) -> String? {
        // MARK: exteraGram
        if let author = self.author {
            let chatId = author.id.id._internalGetInt64Value()
            if contentSettings.appConfiguration.egWebSettings.global.forceReasons.contains(chatId) {
                return "Unavailable in exteraGram due to App Store Guidelines"
            } else if contentSettings.appConfiguration.egWebSettings.global.unforceReasons.contains(chatId) {
                return nil
            }
        }
        if let attribute = self.restrictedContentAttribute {
            if let value = attribute.platformText(platform: platform, contentSettings: contentSettings) {
                return value
            }
        }
        return nil
    }
}

public extension RestrictedContentMessageAttribute {
    func platformText(platform: String, contentSettings: ContentSettings, chatId: Int64? = nil) -> String? {
        // MARK: exteraGram
        if let chatId = chatId {
            if contentSettings.appConfiguration.egWebSettings.global.forceReasons.contains(chatId) {
                return "Unavailable in exteraGram due to App Store Guidelines"
            } else if contentSettings.appConfiguration.egWebSettings.global.unforceReasons.contains(chatId) {
                return nil
            }
        }
        for rule in self.rules {
            if rule.reason == "sensitive" {
                continue
            }
            if rule.platform == "all" || rule.platform == "ios" || contentSettings.addContentRestrictionReasons.contains(rule.platform) {
                if !contentSettings.ignoreContentRestrictionReasons.contains(rule.reason) {
                    return rule.text + "\n" + "\(rule.reason)-\(rule.platform)"
                }
            }
        }
        return nil
    }
}

// MARK: exteraGram
public extension Message {
    func canRevealContent(contentSettings: ContentSettings) -> Bool {
        if contentSettings.appConfiguration.egWebSettings.global.canViewMessages && self.flags.contains(.CopyProtected) {
            let messageContentWasUnblocked = self.restrictedContentAttribute != nil && self.isRestricted(platform: "ios", contentSettings: ContentSettings.default) && !self.isRestricted(platform: "ios", contentSettings: contentSettings)
            var authorWasUnblocked: Bool = false
            if let author = self.author {
                authorWasUnblocked = author.restrictionText(platform: "ios", contentSettings: ContentSettings.default) != nil && author.restrictionText(platform: "ios", contentSettings: contentSettings) == nil
            }
            return messageContentWasUnblocked || authorWasUnblocked
        }
        return false
    }
}
