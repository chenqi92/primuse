import Testing
@testable import PrimuseKit

@Suite("Single-song scraper source gate")
struct SingleSongScrapeGatePolicyTests {
    @Test("A default-on lyrics source only counts for lyrics-only requests")
    func defaultOnSourceCountsOnlyForLyrics() {
        let onlyDefaultOn = [true]
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: onlyDefaultOn, for: .all) == 0)
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: onlyDefaultOn, for: .cover) == 0)
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: onlyDefaultOn, for: [.metadata, .lyrics]) == 0)
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: onlyDefaultOn, for: .lyrics) == 1)

        let userEnabledToo = [true, false]
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: userEnabledToo, for: .all) == 1)
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: userEnabledToo, for: .lyrics) == 2)
        #expect(ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: [], for: .lyrics) == 0)
    }

    @Test("Only the one-tap lyrics entries and lyrics purposes are lyrics-only")
    func requestedParts() {
        let lyricsEntries: Set<SingleSongScrapeEntryPoint> = [.nowPlayingAutomaticLyrics, .macNowPlayingAutomaticLyrics]
        for entryPoint in SingleSongScrapeEntryPoint.allCases {
            #expect(entryPoint.requestedParts == (lyricsEntries.contains(entryPoint) ? .lyrics : .all))
        }
        #expect(SingleSongScrapePurpose.lyricsPreview.requestedParts == .lyrics)
        #expect(SingleSongScrapePurpose.lyricsApply.requestedParts == .lyrics)
        #expect(SingleSongScrapePurpose.metadataPreview.requestedParts == .all)
        #expect(SingleSongScrapePurpose.metadataApply.requestedParts == .all)
    }

    @Test("Zero, one, and multiple enabled sources are distinguished")
    func sourceCounts() {
        #expect(SingleSongScrapeGatePolicy.decision(
            for: .songRowActionMenu,
            enabledSourceCount: 0
        ) == .requireSource)
        #expect(SingleSongScrapeGatePolicy.decision(
            for: .songRowActionMenu,
            enabledSourceCount: 1
        ) == .proceed)
        #expect(SingleSongScrapeGatePolicy.decision(
            for: .songRowActionMenu,
            enabledSourceCount: 7
        ) == .proceed)
    }

    @Test("Every single-song entry point shares the same source requirement")
    func everyEntryPointIsGated() {
        for entryPoint in SingleSongScrapeEntryPoint.allCases {
            #expect(SingleSongScrapeGatePolicy.decision(
                for: entryPoint,
                enabledSourceCount: 0
            ) == .requireSource)
            #expect(SingleSongScrapeGatePolicy.decision(
                for: entryPoint,
                enabledSourceCount: 1
            ) == .proceed)
        }
    }

    @Test("The decision responds to each current source-count snapshot")
    func sourceToggleResponsiveness() {
        var enabledSourceCount = 0
        #expect(SingleSongScrapeGatePolicy.decision(
            for: .nowPlayingOptions,
            enabledSourceCount: enabledSourceCount
        ) == .requireSource)

        enabledSourceCount = 1
        #expect(SingleSongScrapeGatePolicy.decision(
            for: .nowPlayingOptions,
            enabledSourceCount: enabledSourceCount
        ) == .proceed)

        enabledSourceCount = 0
        #expect(SingleSongScrapeGatePolicy.decision(
            for: .nowPlayingOptions,
            enabledSourceCount: enabledSourceCount
        ) == .requireSource)
    }

    @Test("A blocked SongRow action leaves options closed and supports alert cancel")
    func blockedSongRowAction() {
        var scrapeOptionsPresented = false
        var sourceAlertPresented = false

        let decision = SingleSongScrapeGatePolicy.perform(
            from: .songRowActionMenu,
            enabledSourceCount: 0,
            onProceed: { scrapeOptionsPresented = true },
            onRequireSource: { sourceAlertPresented = true }
        )

        #expect(decision == .requireSource)
        #expect(!scrapeOptionsPresented)
        #expect(sourceAlertPresented)

        sourceAlertPresented = false
        #expect(!sourceAlertPresented)
        #expect(!scrapeOptionsPresented)
    }

    @Test("SongRow context and Now Playing do not start work without a source")
    func blockedEntryActionsDoNotRun() {
        let entries: [SingleSongScrapeEntryPoint] = [
            .songRowContextMenu,
            .nowPlayingOptions,
            .nowPlayingAutomaticLyrics,
            .macNowPlayingAutomaticLyrics,
        ]

        for entryPoint in entries {
            var didStart = false
            var didRequireSource = false
            SingleSongScrapeGatePolicy.perform(
                from: entryPoint,
                enabledSourceCount: 0,
                onProceed: { didStart = true },
                onRequireSource: { didRequireSource = true }
            )
            #expect(!didStart)
            #expect(didRequireSource)
        }
    }

    @Test("An enabled source invokes only the requested action")
    func enabledSourceProceedsOnce() {
        var proceedCount = 0
        var sourceAlertCount = 0

        let decision = SingleSongScrapeGatePolicy.perform(
            from: .nowPlayingOptions,
            enabledSourceCount: 2,
            onProceed: { proceedCount += 1 },
            onRequireSource: { sourceAlertCount += 1 }
        )

        #expect(decision == .proceed)
        #expect(proceedCount == 1)
        #expect(sourceAlertCount == 0)
    }

    @Test("Metadata settings requests are idempotent and survive reconstruction")
    func settingsRouteLifecycle() {
        var route = ScraperSettingsRouteState()
        #expect(!route.isMetadataScrapingPresented)

        route.requestMetadataScraping()
        let firstRequest = route
        route.requestMetadataScraping()
        #expect(route == firstRequest)
        #expect(route.isMetadataScrapingPresented)

        let reconstructedRoute = route
        #expect(reconstructedRoute.isMetadataScrapingPresented)

        route.setMetadataScrapingPresented(false)
        #expect(!route.isMetadataScrapingPresented)
        route.requestMetadataScraping()
        #expect(route.isMetadataScrapingPresented)
    }
}
