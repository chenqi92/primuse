import Foundation

public enum ListeningWidgetKind: String, Codable, Sendable {
    case podcast, radio

    public var widgetKind: String { self == .podcast ? "PodcastWidget" : "RadioWidget" }
    private var key: String { "widget.listening.\(rawValue)" }

    public func load() -> ListeningWidgetSnapshot? {
        guard WidgetSettings.syncEnabled() else { return nil }
        return WidgetSharedStore.load(ListeningWidgetSnapshot.self, key: key)?
            .limited(to: WidgetSettings.sharedDataScope())
    }

    @discardableResult
    public func save(_ snapshot: ListeningWidgetSnapshot) -> Bool {
        guard WidgetSharedStore.load(ListeningWidgetSnapshot.self, key: key) != snapshot else { return false }
        WidgetSharedStore.save(snapshot, key: key)
        return true
    }

    public func clear() {
        if WidgetSharedStore.defaults?.object(forKey: key) != nil {
            WidgetSharedStore.defaults?.removeObject(forKey: key)
        }
    }
}

/// Only display metadata and stable IDs cross into the extension; playback URLs stay in the app.
public struct ListeningWidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var coverImageName: String?
        public var fractionComplete: Double?

        public init(id: String, title: String, subtitle: String, coverImageName: String? = nil,
                    fractionComplete: Double? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.coverImageName = coverImageName
            self.fractionComplete = fractionComplete.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        }
    }

    public var items: [Item]
    public init(items: [Item]) { self.items = Array(items.prefix(4)) }

    public func limited(to scope: WidgetSharedDataScope) -> Self {
        Self(items: items.map { item in
            var item = item
            if !scope.includesCover { item.coverImageName = nil }
            if !scope.includesProgress { item.fractionComplete = nil }
            return item
        })
    }
}

public enum ListeningWidgetPolicy {
    public static let coverPrefix = "widget_listening_"

    public struct Candidate: Sendable {
        public var item: ListeningWidgetSnapshot.Item
        public var lastPlayedAt: Date?
        public var publishedAt: Date
        public var isFinished: Bool

        public init(item: ListeningWidgetSnapshot.Item, lastPlayedAt: Date? = nil,
                    publishedAt: Date = .distantPast, isFinished: Bool = false) {
            self.item = item
            self.lastPlayedAt = lastPlayedAt
            self.publishedAt = publishedAt
            self.isFinished = isFinished
        }
    }

    /// Continue unfinished episodes first, then show the newest additions without duplicates.
    public static func select(_ candidates: [Candidate]) -> [ListeningWidgetSnapshot.Item] {
        var seen: Set<String> = []
        return Array(candidates.filter { !$0.isFinished }.sorted {
            if $0.lastPlayedAt != $1.lastPlayedAt {
                return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            }
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            return $0.item.id < $1.item.id
        }.filter { seen.insert($0.item.id).inserted }.prefix(4).map(\.item))
    }
}
