import Foundation
import SwiftSignalKit
import TelegramCore

public struct EGUISettings: Equatable, Codable {
    public var hideStories: Bool
    public var showProfileId: Bool
    public var warnOnStoriesOpen: Bool
    public var sendWithReturnKey: Bool
    
    public static var `default`: EGUISettings {
        return EGUISettings(hideStories: false, showProfileId: true, warnOnStoriesOpen: false, sendWithReturnKey: false)
    }
    
    public init(hideStories: Bool, showProfileId: Bool, warnOnStoriesOpen: Bool, sendWithReturnKey: Bool) {
        self.hideStories = hideStories
        self.showProfileId = showProfileId
        self.warnOnStoriesOpen = warnOnStoriesOpen
        self.sendWithReturnKey = sendWithReturnKey
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.hideStories = (try container.decode(Int32.self, forKey: "hideStories")) != 0
        self.showProfileId = (try container.decode(Int32.self, forKey: "showProfileId")) != 0
        self.warnOnStoriesOpen = (try container.decode(Int32.self, forKey: "warnOnStoriesOpen")) != 0
        self.sendWithReturnKey = (try container.decode(Int32.self, forKey: "sendWithReturnKey")) != 0
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.hideStories ? 1 : 0) as Int32, forKey: "hideStories")
        try container.encode((self.showProfileId ? 1 : 0) as Int32, forKey: "showProfileId")
        try container.encode((self.warnOnStoriesOpen ? 1 : 0) as Int32, forKey: "warnOnStoriesOpen")
        try container.encode((self.sendWithReturnKey ? 1 : 0) as Int32, forKey: "sendWithReturnKey")
    }
}

public func updateEGUISettings(engine: TelegramEngine, _ f: @escaping (EGUISettings) -> EGUISettings) -> Signal<Never, NoError> {
    return engine.preferences.update(id: ApplicationSpecificPreferencesKeys.EGUISettings, { entry in
        let currentSettings: EGUISettings
        if let entry = entry?.get(EGUISettings.self) {
            currentSettings = entry
        } else {
            currentSettings = .default
        }
        return SharedPreferencesEntry(f(currentSettings))
    })
}
