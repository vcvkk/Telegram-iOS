// MARK: exteraGram
import EGLogging
import EGAppGroupIdentifier
import EGSimpleSettings
import SwiftSignalKit
import TelegramUIPreferences
import AccountContext
import Postbox
import Foundation

extension SharedAccountContextImpl {
    // MARK: exteraGram
    func performEGUISettingsMigrationIfNecessary() {
        if self.didPerformEGUISettingsMigration {
            return
        }
        let egMigrationKey = "sg_migrated_sgui_settings_v1"
        if UserDefaults.standard.bool(forKey: egMigrationKey) {
            self.didPerformEGUISettingsMigration = true
            return
        }
        guard let egPrimary = self.egPrimaryAccountContextForMigration() else {
            return
        }
        self.didPerformEGUISettingsMigration = true
        
        let egPreferences: Signal<PreferencesView, NoError> = egPrimary.account.postbox.preferencesView(keys: [ApplicationSpecificPreferencesKeys.EGUISettings])
        let _ = (egPreferences
        |> take(1)
        |> deliverOnMainQueue).start(next: { view in
            let egSettings: EGUISettings = view.values[ApplicationSpecificPreferencesKeys.EGUISettings]?.get(EGUISettings.self) ?? .default
            let egDefaults = UserDefaults.standard
            let egDomainName = egBaseBundleIdentifier()
            let egDomain = egDefaults.persistentDomain(forName: egDomainName) ?? [:]
            if egDomain[EGSimpleSettings.Keys.hideStories.rawValue] == nil {
                EGSimpleSettings.shared.hideStories = egSettings.hideStories
                EGLogger.shared.log("EGSimpleSettings", "Migrated hideStories: \(egSettings.hideStories)")
            }
            if egDomain[EGSimpleSettings.Keys.warnOnStoriesOpen.rawValue] == nil {
                EGSimpleSettings.shared.warnOnStoriesOpen = egSettings.warnOnStoriesOpen
                EGLogger.shared.log("EGSimpleSettings", "Migrated warnOnStoriesOpen: \(egSettings.warnOnStoriesOpen)")
            }
            if egDomain[EGSimpleSettings.Keys.showProfileId.rawValue] == nil {
                EGSimpleSettings.shared.showProfileId = egSettings.showProfileId
                EGLogger.shared.log("EGSimpleSettings", "Migrated showProfileId: \(egSettings.showProfileId)")
            }
            if egDomain[EGSimpleSettings.Keys.sendWithReturnKey.rawValue] == nil {
                EGSimpleSettings.shared.sendWithReturnKey = egSettings.sendWithReturnKey
                EGLogger.shared.log("EGSimpleSettings", "Migrated sendWithReturnKey: \(egSettings.sendWithReturnKey)")
            }
            egDefaults.set(true, forKey: egMigrationKey)
        })
    }
}
