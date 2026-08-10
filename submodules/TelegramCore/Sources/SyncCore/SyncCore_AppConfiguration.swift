import Foundation
import Postbox
import EGWebSettingsScheme
import EGGHSettingsScheme

public struct AppConfiguration: Codable, Equatable {
    // MARK: exteraGram
    public var egWebSettings: EGWebSettings
    public var egGHSettings: EGGHSettings
    
    public var data: JSON?
    public var hash: Int32
    
    public static var defaultValue: AppConfiguration {
        return AppConfiguration(egWebSettings: EGWebSettings.defaultValue, egGHSettings: EGGHSettings.defaultValue, data: nil, hash: 0)
    }
    
    init(egWebSettings: EGWebSettings, egGHSettings: EGGHSettings, data: JSON?, hash: Int32) {
        self.egWebSettings = egWebSettings
        self.egGHSettings = egGHSettings
        self.data = data
        self.hash = hash
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        
        self.egWebSettings = (try container.decodeIfPresent(EGWebSettings.self, forKey: "sg")) ?? EGWebSettings.defaultValue
        self.egGHSettings = (try container.decodeIfPresent(EGGHSettings.self, forKey: "sggh")) ?? EGGHSettings.defaultValue
        self.data = try container.decodeIfPresent(JSON.self, forKey: "data")
        self.hash = (try container.decodeIfPresent(Int32.self, forKey: "storedHash")) ?? 0
    }

    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        
        try container.encode(self.egWebSettings, forKey: "sg")
        try container.encode(self.egGHSettings, forKey: "sggh")
        try container.encodeIfPresent(self.data, forKey: "data")
        try container.encode(self.hash, forKey: "storedHash")
    }
}
