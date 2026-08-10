import Foundation
public struct EGGHSettings: Codable, Equatable {
    public let announcementsData: String?
    
    public static var defaultValue: EGGHSettings {
        return EGGHSettings(announcementsData: nil)
    }
}