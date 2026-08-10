import Foundation

@objc public final class TLRPC: NSObject {
    @objc public final class User: NSObject {
        @objc public var id: Int64 = 0
        @objc public var first_name: String?
        @objc public var last_name: String?
        @objc public var username: String?
        @objc public var phone: String?
        @objc public var is_bot: Bool = false
    }

    @objc public final class Chat: NSObject {
        @objc public var id: Int64 = 0
        @objc public var title: String?
        @objc public var username: String?
        @objc public var participants_count: Int32 = 0
    }

    @objc public final class Message: NSObject {
        @objc public var id: Int32 = 0
        @objc public var message: String?
        @objc public var date: Int32 = 0
        @objc public var from_id: Int64 = 0
        @objc public var peer_id: Int64 = 0
    }
}
