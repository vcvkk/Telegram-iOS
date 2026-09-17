import Foundation

public struct EGWebSettings: Codable, Equatable {
    public let global: EGGlobalSettings
    public let user: EGUserSettings
    
    public static var defaultValue: EGWebSettings {
        return EGWebSettings(global: EGGlobalSettings(ytPip: true, qrLogin: true, storiesAvailable: false, canViewMessages: true, canEditSettings: false, canShowTelescope: false, announcementsData: nil, regdateFormat: "month", forceReasons: [], unforceReasons: [], duckyAppIconAvailable: true, nyAvailable: false), user: EGUserSettings(contentReasons: [], canSendTelescope: false))
    }
}

public struct EGGlobalSettings: Codable, Equatable {
    public let ytPip: Bool
    public let qrLogin: Bool
    public let storiesAvailable: Bool
    public let canViewMessages: Bool
    public let canEditSettings: Bool
    public let canShowTelescope: Bool
    public let announcementsData: String?
    public let regdateFormat: String
    public let forceReasons: [Int64]
    public let unforceReasons: [Int64]
    public let duckyAppIconAvailable: Bool
    public let nyAvailable: Bool
}

public struct EGUserSettings: Codable, Equatable {
    public let contentReasons: [String]
    public let canSendTelescope: Bool
}


public extension EGUserSettings {
    func expandedContentReasons() -> [String] {
        return contentReasons.compactMap { base64String in
            guard let data = Data(base64Encoded: base64String),
                  let decodedString = String(data: data, encoding: .utf8) else {
                return nil
            }
            return decodedString
        }
    }
}
