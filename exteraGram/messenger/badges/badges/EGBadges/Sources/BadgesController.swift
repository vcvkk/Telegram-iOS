// MARK: exteraGram

import Foundation
/// Singleton that owns the in-memory badge cache and exposes the public badge API.
/// Mirrors Android `BadgesController` / `ApiBadgeSource`.
///
/// Cache keys are plain positive Int64 IDs (the numeric portion of the peer's Telegram ID,
/// without the -100 channel prefix used in Bot API).
public final class BadgesController {
    public static let shared = BadgesController()

    /// Posted on the main thread whenever the cache is written (bulk sync or inject).
    /// Observers (e.g. PeerInfoScreenNode) use this to trigger a re-layout.
    public static let cacheUpdatedNotification = Notification.Name("EGBadgeCacheUpdated")

    // Hardcoded badge document IDs (from Android APK reverse engineering).
    public static let DEV_BADGE       = EGBadgeDTO(documentId: 5359407509327085568)
    public static let SUPPORTER_BADGE = EGBadgeDTO(documentId: 5391059537102927631)

    private let persistenceKey = "eg_badges_v1"
    /// String-keyed so JSONEncoder/Decoder can handle the dictionary.
    private var cache: [String: EGBadgeInfo] = [:]

    /// Last sync result — set by EGAPIWebSettings after each attempt (success or failure).
    public private(set) var lastSyncStatus: String = "Never synced"

    private init() {
        loadFromDefaults()
    }

    // MARK: - Public API

    /// Returns the badge for a peer by its plain numeric ID (positive for both users and channels).
    public func getBadge(peerIdValue: Int64) -> EGBadgeDTO? {
        cache[key(peerIdValue)]?.badge
    }

    public func hasBadge(peerIdValue: Int64) -> Bool {
        getBadge(peerIdValue: peerIdValue) != nil
    }

    public func isDeveloper(peerIdValue: Int64) -> Bool {
        cache[key(peerIdValue)]?.status == .developer
    }

    /// Returns true if the chat/channel is an official exteraGram channel (developer status).
    public func isExtera(peerIdValue: Int64) -> Bool {
        cache[key(peerIdValue)]?.status == .developer
    }

    public func canChangeBadge(peerIdValue: Int64) -> Bool {
        guard let info = cache[key(peerIdValue)] else { return false }
        return info.canChangeBadge || info.status == .developer
    }

    /// The default badge for a peer: DEV_BADGE for developers, SUPPORTER_BADGE otherwise.
    public func getDefaultBadge(peerIdValue: Int64) -> EGBadgeDTO {
        isDeveloper(peerIdValue: peerIdValue) ? Self.DEV_BADGE : Self.SUPPORTER_BADGE
    }

    // MARK: - Cache management

    /// Bulk-update the cache from a fresh API response (called after each sync).
    public func update(profiles: [EGProfileDTO]) {
        for profile in profiles {
            let k = key(profile.id)
            if profile.deleted == true {
                cache.removeValue(forKey: k)
            } else if profile.status != .default || profile.badge != nil {
                cache[k] = EGBadgeInfo(
                    badge: profile.badge,
                    status: profile.status,
                    canChangeBadge: profile.canChangeBadge ?? false
                )
            } else {
                cache.removeValue(forKey: k)
            }
        }
        saveToDefaults()
    }

    /// Debug helper: force-inject (or remove) a badge for any peer without an API call.
    /// Pass `nil` to remove the badge entirely.
    public func injectBadge(_ badge: EGBadgeDTO?, forPeerIdValue peerIdValue: Int64) {
        let k = key(peerIdValue)
        if let badge = badge {
            let existing = cache[k]
            cache[k] = EGBadgeInfo(
                badge: badge,
                status: existing?.status ?? .developer,
                canChangeBadge: existing?.canChangeBadge ?? true
            )
        } else {
            cache.removeValue(forKey: k)
        }
        saveToDefaults()
    }

    /// Update a single peer's badge locally (called after the user changes their own badge via bot).
    public func updateLocalBadge(peerIdValue: Int64, badge: EGBadgeDTO?) {
        let k = key(peerIdValue)
        guard let existing = cache[k] else { return }
        cache[k] = EGBadgeInfo(badge: badge, status: existing.status, canChangeBadge: existing.canChangeBadge)
        saveToDefaults()
    }

    // MARK: - Persistence

    private func key(_ id: Int64) -> String { "\(id)" }

    private func loadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: EGBadgeInfo].self, from: data)
        else { return }
        cache = decoded
    }

    private func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: BadgesController.cacheUpdatedNotification, object: nil)
        }
    }

    /// Returns all cached peer IDs (as strings) — useful for debug/diagnostics.
    public var allCachedPeerIds: [String] { Array(cache.keys) }

    /// Called by EGAPIWebSettings to record the outcome of the last profiles sync.
    public func recordSyncResult(_ status: String) {
        lastSyncStatus = status
    }
}
