import Foundation

@objc public final class NotificationCenterBridge: NSObject {
    public static let shared = NotificationCenterBridge()

    public static let didReceivedNewMessages = 1
    public static let updateInterfaces = 2
    public static let dialogsNeedReload = 3
    public static let userInfoDidLoad = 4
    public static let chatInfoDidLoad = 5

    private var observers = [Int: NSHashTable<AnyObject>]()
    private let lock = NSLock()

    @objc public static func getInstance() -> NotificationCenterBridge {
        return shared
    }

    @objc public func addObserver(_ observer: AnyObject, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        if observers[id] == nil {
            observers[id] = NSHashTable<AnyObject>.weakObjects()
        }
        observers[id]?.add(observer)
    }

    @objc public func removeObserver(_ observer: AnyObject, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        observers[id]?.remove(observer)
    }

    @objc public func postNotificationName(_ id: Int, args: [Any]? = nil) {
        AndroidUtilities.runOnUIThread { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let list = self.observers[id]?.allObjects ?? []
            self.lock.unlock()

            for observer in list {
                if let handler = observer as? NotificationCenterDelegate {
                    handler.didReceivedNotification(id: id, args: args)
                }
            }
        }
    }
}

@objc public protocol NotificationCenterDelegate: AnyObject {
    func didReceivedNotification(id: Int, args: [Any]?)
}
