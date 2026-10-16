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

extension SingleSongScrapeEntryPoint {
    /// 这个入口要刮哪些部分：歌词页空白处的一键取歌词只找歌词，其余入口按整套算。
    public var requestedParts: ScrapeParts {
        switch self {
        case .nowPlayingAutomaticLyrics, .macNowPlayingAutomaticLyrics:
            .lyrics
        case .songRowActionMenu, .songRowContextMenu, .nowPlayingOptions,
             .macPlayerMenu, .macSongListContextMenu, .appIntent:
            .all
        }
    }
}

extension SingleSongScrapePurpose {
    public var requestedParts: ScrapeParts {
        switch self {
        case .lyricsPreview, .lyricsApply: .lyrics
        case .metadataPreview, .metadataApply: .all
        }
    }
}

/// 刮削入口数「这次能用的源」。默认就开着的内置源（AMLL）只管歌词，也不是用户自己开的：
/// 只找歌词的请求算它；要刮标签、封面的请求不算，还得用户自己开过一个源。不然新装用户
/// 点「刮削」会跑一趟只能找歌词的活，标签和封面一样没补，也看不到去开启刮削源的提示。
public enum ScraperSourceGatePolicy {
    /// - Parameter enabledSourcesOnByDefault: 每个已开的源是不是「默认就开着」的内置源。
    public static func usableSourceCount(
        enabledSourcesOnByDefault: [Bool],
        for parts: ScrapeParts
    ) -> Int {
        let lyricsOnly = parts == .lyrics
        return enabledSourcesOnByDefault.filter { lyricsOnly || !$0 }.count
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
