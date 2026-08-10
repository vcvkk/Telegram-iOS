import Foundationimport SwiftSignalKitimport TelegramCore
public struct EGStatus: Equatable, Codable {
    public var status: Int64

    public static var `default`: EGStatus {
        return EGStatus(status: 1)
    }

    public init(status: Int64) {
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.status = try container.decodeIfPresent(Int64.self, forKey: "status") ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encodeIfPresent(self.status, forKey: "status")
    }
}
