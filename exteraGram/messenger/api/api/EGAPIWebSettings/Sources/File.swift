import Foundation
import loggingimport badges
import AccountContext
import configcoreimport TelegramCore
public func updateEGWebSettingsInteractivelly(context: AccountContext) {
    let _ = getEGApiToken(context: context).startStandalone(next: { token in
        let _ = getEGSettings(token: token).startStandalone(next: { webSettings in
            EGLogger.shared.log("EGAPI", "New EGWebSettings for id \(context.account.peerId.id._internalGetInt64Value()): \(webSettings) ")
            EGSimpleSettings.shared.canUseStealthMode = webSettings.global.storiesAvailable
            EGSimpleSettings.shared.duckyAppIconAvailable = webSettings.global.duckyAppIconAvailable
            EGSimpleSettings.shared.canUseNY = webSettings.global.nyAvailable
            let _ = (context.account.postbox.transaction { transaction in
                updateAppConfiguration(transaction: transaction, { configuration -> AppConfiguration in
                    var configuration = configuration
                    configuration.egWebSettings = webSettings
                    return configuration
                })
            }).startStandalone()
        }, error: { e in
            if case let .generic(errorMessage) = e, let errorMessage = errorMessage {
                EGLogger.shared.log("EGAPI", errorMessage)
            }
        })

        // Sync exteraGram badges using the same token.
        let _ = getEGProfiles(token: token).startStandalone(next: { profiles in
            BadgesController.shared.update(profiles: profiles)
            let status = profiles.isEmpty
                ? "Endpoint returned 0 profiles (not deployed yet?)"
                : "OK: \(profiles.count) profile(s)"
            BadgesController.shared.recordSyncResult(status)
            EGLogger.shared.log("EGBadges", status)
        }, error: { e in
            if case let .generic(errorMessage) = e, let errorMessage = errorMessage {
                let truncated = String(errorMessage.prefix(300))
                BadgesController.shared.recordSyncResult("ERR: \(truncated)")
                EGLogger.shared.log("EGBadges", "Error syncing profiles: \(errorMessage)")
            }
        })
    }, error: { e in
        if case let .generic(errorMessage) = e, let errorMessage = errorMessage {
            EGLogger.shared.log("EGAPI", errorMessage)
        }
    })
}


public func postEGWebSettingsInteractivelly(context: AccountContext, data: [String: Any]) {
    let _ = getEGApiToken(context: context).startStandalone(next: { token in
        let _ = postEGSettings(token: token, data: data).startStandalone(error: { e in
            if case let .generic(errorMessage) = e, let errorMessage = errorMessage {
                EGLogger.shared.log("EGAPI", errorMessage)
            }
        })
    }, error: { e in
        if case let .generic(errorMessage) = e, let errorMessage = errorMessage {
            EGLogger.shared.log("EGAPI", errorMessage)
        }
    })
}
