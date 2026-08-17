import Foundation

public enum SingleSongScrapeEntryPoint: CaseIterable, Sendable {
    case songRowActionMenu
    case songRowContextMenu
    case nowPlayingOptions
    case nowPlayingAutomaticLyrics
    case macPlayerMenu
    case macSongListContextMenu
    case macNowPlayingAutomaticLyrics
    case appIntent
}

public enum SingleSongScrapePurpose: Hashable, Sendable {
    case metadataPreview
    case metadataApply
    case lyricsPreview
    case lyricsApply
}

public struct SingleSongScrapeKey: Hashable, Sendable {
    public let songID: String
    public let purpose: SingleSongScrapePurpose

    public init(songID: String, purpose: SingleSongScrapePurpose) {
        self.songID = songID
        self.purpose = purpose
    }
}

public struct SingleSongScrapeActivity: Equatable, Sendable {
    public let runID: UUID
    public let key: SingleSongScrapeKey

    public init(runID: UUID, key: SingleSongScrapeKey) {
        self.runID = runID
        self.key = key
    }
}

public enum SingleSongScrapeAdmission: Equatable, Sendable {
    case start
    case join(runID: UUID)
    case busy(active: SingleSongScrapeActivity)
}

public enum SingleSongScrapeSessionPolicy {
    public static func admission(
        active: SingleSongScrapeActivity?,
        request: SingleSongScrapeKey
    ) -> SingleSongScrapeAdmission {
        guard let active else { return .start }
        if active.key == request {
            return .join(runID: active.runID)
        }
        return .busy(active: active)
    }
}

public enum SingleSongScrapeGateDecision: Equatable, Sendable {
    case proceed
    case requireSource
}

public enum SingleSongScrapeGatePolicy {
    public static func decision(
        for _: SingleSongScrapeEntryPoint,
        enabledSourceCount: Int
    ) -> SingleSongScrapeGateDecision {
        enabledSourceCount > 0 ? .proceed : .requireSource
    }

    @discardableResult
    public static func perform(
        from entryPoint: SingleSongScrapeEntryPoint,
        enabledSourceCount: Int,
        onProceed: () -> Void,
        onRequireSource: () -> Void
    ) -> SingleSongScrapeGateDecision {
        let decision = decision(
            for: entryPoint,
            enabledSourceCount: enabledSourceCount
        )
        switch decision {
        case .proceed:
            onProceed()
        case .requireSource:
            onRequireSource()
        }
        return decision
    }
}

public enum ScraperSettingsRouteDestination: Equatable, Sendable {
    case metadataScraping
}

public struct ScraperSettingsRouteState: Equatable, Sendable {
    public private(set) var destination: ScraperSettingsRouteDestination?

    public init(destination: ScraperSettingsRouteDestination? = nil) {
        self.destination = destination
    }

    public var isMetadataScrapingPresented: Bool {
        destination == .metadataScraping
    }

    public mutating func requestMetadataScraping() {
        destination = .metadataScraping
    }

    public mutating func setMetadataScrapingPresented(_ isPresented: Bool) {
        destination = isPresented ? .metadataScraping : nil
    }
}
