import Foundation

public enum ListeningWidgetKind: String, Codable, Sendable {
    /// Episodes to continue, then the newest ones.
    case podcast
    case radio
    /// Episodes in the order they were last heard, finished ones included.
    case recentPodcast

    public var widgetKind: String {
        switch self {
        case .podcast: "PodcastWidget"
        case .radio: "RadioWidget"
        case .recentPodcast: "RecentPodcastWidget"
        }
    }

    /// Plays podcast episodes (rather than stations).
    public var playsEpisodes: Bool { self != .radio }
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

    /// When an episode was last heard, from what the app keeps about it.
    public struct ListeningRecord: Sendable {
        /// Last time playback saved a position in it (every few seconds while
        /// it plays; gone once it is finished).
        public var positionSavedAt: Date?
        /// Start of its latest listen in the play history (heard long enough
        /// to count).
        public var lastListenedAt: Date?
        /// When it was finished — heard through, or marked played by hand.
        public var finishedAt: Date?

        public init(positionSavedAt: Date? = nil, lastListenedAt: Date? = nil, finishedAt: Date? = nil) {
            self.positionSavedAt = positionSavedAt
            self.lastListenedAt = lastListenedAt
            self.finishedAt = finishedAt
        }

        /// Nil for an episode never actually heard: a finish mark alone is a
        /// backlog marked played, not listening.
        public var lastPlayedAt: Date? {
            guard let heard = [positionSavedAt, lastListenedAt].compactMap({ $0 }).max() else { return nil }
            return max(heard, finishedAt ?? heard)
        }
    }

    /// Episodes most recently heard first, finished ones included; never
    /// heard ones are left out.
    public static func recentlyPlayed(
        _ candidates: [(item: ListeningWidgetSnapshot.Item, record: ListeningRecord)]
    ) -> [ListeningWidgetSnapshot.Item] {
        var seen: Set<String> = []
        let heard = candidates.compactMap { candidate -> (item: ListeningWidgetSnapshot.Item, playedAt: Date)? in
            candidate.record.lastPlayedAt.map { (item: candidate.item, playedAt: $0) }
        }
        return Array(heard.sorted {
            $0.playedAt != $1.playedAt ? $0.playedAt > $1.playedAt : $0.item.id < $1.item.id
        }.filter { seen.insert($0.item.id).inserted }.prefix(4).map { $0.item })
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
