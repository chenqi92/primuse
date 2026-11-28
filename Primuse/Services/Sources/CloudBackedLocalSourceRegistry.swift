import Foundation

/// Device-local registry of `.local` sources discovered at runtime to live in
/// iCloud Drive or another evictable File Provider (for example macOS Desktop
/// & Documents synced to iCloud, or multi-root references whose non-primary
/// root is in iCloud).
public final class CloudBackedLocalSourceRegistry: @unchecked Sendable {
    public static let shared = CloudBackedLocalSourceRegistry()
    public static let didChangeNotification = Notification.Name("primuse.cloudBackedLocalSourcesDidChange")
    public static let storageKey = "primuse.cloudBackedLocalSourceIDs.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedSourceIDs: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        self.storedSourceIDs = Set(saved)
    }

    public var sourceIDs: Set<String> {
        lock.withLock { storedSourceIDs }
    }

    public func contains(_ sourceID: String) -> Bool {
        lock.withLock { storedSourceIDs.contains(sourceID) }
    }

    @discardableResult
    public func setCloudBacked(_ isCloudBacked: Bool, for sourceID: String) -> Bool {
        guard !sourceID.isEmpty else { return false }
        let changed: Bool = lock.withLock {
            let didChange: Bool
            if isCloudBacked {
                didChange = storedSourceIDs.insert(sourceID).inserted
            } else {
                didChange = storedSourceIDs.remove(sourceID) != nil
            }
            if didChange {
                defaults.set(Array(storedSourceIDs).sorted(), forKey: Self.storageKey)
            }
            return didChange
        }
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        return changed
    }

    @discardableResult
    public func register(sourceID: String) -> Bool {
        setCloudBacked(true, for: sourceID)
    }

    @discardableResult
    public func unregister(sourceID: String) -> Bool {
        setCloudBacked(false, for: sourceID)
    }
}
