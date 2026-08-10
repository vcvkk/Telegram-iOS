import Foundation

@objc public final class MessagesControllerBridge: NSObject {
    private static var instances = [Int: MessagesControllerBridge]()
    private static let lock = NSLock()

    public let currentAccount: Int

    private init(currentAccount: Int) {
        self.currentAccount = currentAccount
        super.init()
    }

    @objc public static func getInstance(account: Int = 0) -> MessagesControllerBridge {
        lock.lock()
        defer { lock.unlock() }
        if let existing = instances[account] {
            return existing
        }
        let created = MessagesControllerBridge(currentAccount: account)
        instances[account] = created
        return created
    }
}
