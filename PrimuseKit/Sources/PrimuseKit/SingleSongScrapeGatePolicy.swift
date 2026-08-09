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
