import Foundation
import Observation
import PrimuseKit
import XCTest
import SwiftUI
@testable import Primuse

final class LibraryDisplayConfigurationTests: XCTestCase {
    @MainActor
    func testHomeAndListeningStatsKeepTheSameHistoricalCounts() {
        let calendar = ListeningCalendar.make(locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        let start = PlayHistoryStore.Range.week.statisticsStartDate(now: now, calendar: calendar)
        XCTAssertEqual(start, HomeListeningPeriod.week.interval(now: now, calendar: calendar).start)
        XCTAssertEqual(calendar.component(.day, from: start), 31)
        let monthStart = PlayHistoryStore.Range.month.statisticsStartDate(now: now, calendar: calendar)
        let recentStart = PlayHistoryStore.Range.month.startDate(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: monthStart), 1)
        XCTAssertEqual(calendar.dateComponents([.day], from: recentStart, to: now).day, 30)
        let entries: [PlayHistoryStore.Entry] = (0..<3).map { offset in
            PlayHistoryStore.Entry(songID: offset < 2 ? "archived" : "available", songTitle: offset < 2 ? "历史歌曲" : "当前歌曲",
                                   artistName: "歌手", albumTitle: "专辑", playedAt: start.addingTimeInterval(Double(offset + 1) * 3_600),
                                   listenedSec: 120, sourceID: "source")
        }
        let home = HomeListeningRanking.ranks(events: entries.map(\.listeningEvent), songs: [:], folders: nil,
                                              period: .week, category: .songs, now: now, calendar: calendar)
        let stats = PlayHistoryStore.rankedItems(from: entries, category: .songs, limit: 20)
        XCTAssertEqual(home.map(\.title), stats.map(\.title))
        XCTAssertEqual(home.map(\.playCount), [2, 1])
        XCTAssertEqual(stats.map(\.playCount), [2, 1])
        let summary = PlayHistoryStore.summary(for: entries, calendar: calendar)
        XCTAssertEqual(summary.totalPlays, 3)
        XCTAssertEqual(summary.totalSec, 360)
        XCTAssertEqual(summary.uniqueSongs, 2)
    }

    @MainActor
    func testListeningStatsSnapshotBuildsFromSendableHistoryInput() async {
        let calendar = ListeningCalendar.make(
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        let entries = [
            PlayHistoryStore.Entry(
                songID: "current",
                songTitle: "当前歌曲",
                artistName: "歌手",
                albumTitle: "专辑",
                playedAt: calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 8))!,
                listenedSec: 180,
                sourceID: "source"
            ),
            PlayHistoryStore.Entry(
                songID: "previous",
                songTitle: "上月歌曲",
                artistName: "歌手",
                albumTitle: "专辑",
                playedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 8))!,
                listenedSec: 120,
                sourceID: "source"
            ),
        ]

        let snapshot = await Task.detached(priority: .userInitiated) {
            ListeningStatsView.makeStatsSnapshot(
                entries: entries,
                range: .month,
                displayYear: nil,
                now: now,
                calendar: calendar
            )
        }.value

        XCTAssertTrue(snapshot.hasHistory)
        XCTAssertEqual(snapshot.summary.totalPlays, 1)
        XCTAssertEqual(snapshot.summary.totalSec, 180)
        XCTAssertEqual(snapshot.previousPlayCount, 1)
        XCTAssertEqual(snapshot.topSongs.map(\.title), ["当前歌曲"])
    }

    func testHomeDiscoverySectionsMigrateWithoutReorderingExistingSections() {
        let original: [HomeSectionKind] = [.stats, .playlists, .continueListening, .quickAccess]
        let decoded = HomeSectionConfiguration.decode(HomeSectionConfiguration.encode(original))
        XCTAssertEqual(decoded.filter { original.contains($0) }, original)
        XCTAssertEqual(Array(decoded.prefix(4)), [.stats, .playlists, .folders, .listeningRanking])
        XCTAssertEqual(Set(decoded).count, decoded.count)
        XCTAssertEqual(Set(decoded), Set(HomeSectionKind.allCases))
    }

    func testHomeDiscoveryCustomizedPositionsSurviveRoundTrip() {
        let original: [HomeSectionKind] = [.listeningRanking, .stats, .folders, .playlists]
        let decoded = HomeSectionConfiguration.decode(HomeSectionConfiguration.encode(original))
        XCTAssertEqual(Array(decoded.prefix(original.count)), original)
        XCTAssertEqual(HomeSectionConfiguration.decode(""), HomeSectionConfiguration.defaultOrder)
    }

    func testFreshLibraryUsesRecommendationFirst() {
        XCTAssertEqual(
            LibraryDisplayConfiguration.decodeSectionOrder(""),
            LibraryDisplayConfiguration.defaultSectionOrder
        )
        XCTAssertEqual(
            LibraryDisplayConfiguration.defaultSectionOrder.first,
            .recommendations
        )
    }

    func testExistingCustomOrderKeepsItsShapeWhenRecommendationsAreIntroduced() {
        let oldOrder: [LibrarySection] = [.albums, .songs, .artists, .playlists, .radio]
        let rawValue = LibraryDisplayConfiguration.encodeSectionOrder(oldOrder)

        XCTAssertEqual(
            LibraryDisplayConfiguration.decodeSectionOrder(rawValue),
            [.recommendations, .favorites, .albums, .songs, .artists, .genres, .playlists, .folders, .radio, .statistics]
        )
    }

    func testStoredSectionsRemainUnique() {
        let rawValue = LibraryDisplayConfiguration.encodeSectionOrder([
            .songs, .songs, .recommendations, .radio,
        ])
        let decoded = LibraryDisplayConfiguration.decodeSectionOrder(rawValue)

        XCTAssertEqual(Set(decoded), Set(LibrarySection.allCases))
        XCTAssertEqual(decoded.count, LibrarySection.allCases.count)
    }

    func testSongInfoSupportsMediumAndLargeDetents() {
        XCTAssertEqual(
            SongInfoPresentationConfiguration.detents,
            Set([PresentationDetent.medium, .large])
        )
    }

    func testNavigationModeDefaultsToStandardForMissingOrInvalidValues() {
        XCTAssertEqual(AppNavigationMode.resolve(""), .standard)
        XCTAssertEqual(AppNavigationMode.resolve("future-mode"), .standard)
        XCTAssertEqual(AppNavigationMode.resolve(AppNavigationMode.minimal.rawValue), .minimal)
    }

    func testStandardRootLayoutsRemainWidthAdaptive() {
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .standard, usesRegularWidth: false),
            .standardTabs
        )
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .standard, usesRegularWidth: true),
            .standardSidebar
        )
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .minimal, usesRegularWidth: false),
            .minimal
        )
        XCTAssertEqual(
            AppNavigationLayoutPolicy.rootLayout(mode: .minimal, usesRegularWidth: true),
            .minimal
        )
    }

    func testBottomChromeHasOneOwnerDuringBatchSelection() {
        XCTAssertEqual(
            AppNavigationChromePolicy.bottomChromeOwner(
                mode: .standard,
                batchSelectionActive: false
            ),
            .systemTabBar
        )
        XCTAssertEqual(
            AppNavigationChromePolicy.bottomChromeOwner(
                mode: .standard,
                batchSelectionActive: true
            ),
            .batchSelection
        )
        XCTAssertEqual(
            AppNavigationChromePolicy.bottomChromeOwner(
                mode: .minimal,
                batchSelectionActive: false
            ),
            .minimalNavigation
        )
        XCTAssertEqual(
            AppNavigationChromePolicy.bottomChromeOwner(
                mode: .minimal,
                batchSelectionActive: true
            ),
            .batchSelection
        )

        XCTAssertFalse(
            AppNavigationChromePolicy.hidesSystemTabBar(
                mode: .standard,
                batchSelectionActive: false
            )
        )
        XCTAssertTrue(
            AppNavigationChromePolicy.hidesSystemTabBar(
                mode: .standard,
                batchSelectionActive: true
            )
        )
        XCTAssertTrue(
            AppNavigationChromePolicy.hidesSystemTabBar(
                mode: .minimal,
                batchSelectionActive: false
            )
        )
    }

    func testMinimalLibraryPagesFollowVisibleSectionOrder() {
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(
                visibleSections: [.songs, .albums, .radio]
            ),
            [
                .librarySection(.songs),
                .librarySection(.albums),
                .librarySection(.radio),
            ]
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(visibleSections: []),
            []
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(
                visibleSections: [.songs, .recommendations, .albums]
            ),
            [
                .librarySection(.songs),
                .librarySection(.recommendations),
                .librarySection(.albums),
            ]
        )
    }

    func testMinimalSelectionUsesTheFirstVisibleCategoryAsItsHomePage() {
        let sections: [LibrarySection] = [.favorites, .artists, .songs]
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 0,
                activeLibrarySection: nil,
                visibleSections: sections
            ),
            .librarySection(.favorites)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: .artists,
                visibleSections: sections
            ),
            .librarySection(.artists)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: nil,
                visibleSections: sections
            ),
            .librarySection(.favorites)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 2,
                activeLibrarySection: .songs,
                visibleSections: sections
            ),
            .search
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 99,
                activeLibrarySection: nil,
                visibleSections: sections
            ),
            .librarySection(.favorites)
        )
    }

    func testHiddenCategoriesStayHiddenInMinimalModeAndOldOrdersKeepTheirRelativeOrder() {
        let oldOrder: [LibrarySection] = [.radio, .albums, .songs, .artists, .genres, .playlists, .recommendations]
        let order = LibraryDisplayConfiguration.decodeSectionOrder(
            LibraryDisplayConfiguration.encodeSectionOrder(oldOrder)
        )
        XCTAssertEqual(order.filter(oldOrder.contains), oldOrder)
        let hidden: Set<LibrarySection> = [.recommendations, .favorites, .folders, .statistics]
        let visible = LibraryDisplayConfiguration.visibleSections(
            orderRawValue: LibraryDisplayConfiguration.encodeSectionOrder(order),
            hiddenRawValue: LibraryDisplayConfiguration.encodeHiddenSections(hidden)
        )
        XCTAssertTrue(hidden.isDisjoint(with: visible))
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(visibleSections: visible),
            visible.map(MinimalNavigationPage.librarySection)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: .favorites,
                visibleSections: visible
            ),
            .librarySection(.radio)
        )
    }

    func testAllCategoriesCanBeHiddenWithoutRestoringRecommendations() {
        let visible = LibraryDisplayConfiguration.visibleSections(
            orderRawValue: "",
            hiddenRawValue: LibraryDisplayConfiguration.encodeHiddenSections(Set(LibrarySection.allCases))
        )
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(MinimalNavigationPolicy.homePage(visibleSections: visible), .search)
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(selectedTab: 3, activeLibrarySection: .songs, visibleSections: visible),
            .settings
        )
    }

    func testMinimalDeepLinksSelectTheirLibraryCategory() {
        XCTAssertNil(MinimalNavigationPolicy.section(for: .root))
        XCTAssertEqual(
            MinimalNavigationPolicy.section(for: .section(.songs)),
            .songs
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.section(for: .section(.radio)),
            .radio
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.section(for: .song("song-id")),
            .songs
        )
    }

    func testMinimalChromeHidesOnlyForTheSelectedDetailScope() {
        XCTAssertTrue(
            MinimalNavigationChromePolicy.hidesTopNavigation(
                mode: .minimal,
                selectedTab: 1,
                detailScopes: [.library]
            )
        )
        XCTAssertFalse(
            MinimalNavigationChromePolicy.hidesTopNavigation(
                mode: .minimal,
                selectedTab: 2,
                detailScopes: [.library]
            )
        )
        XCTAssertFalse(
            MinimalNavigationChromePolicy.hidesTopNavigation(
                mode: .standard,
                selectedTab: 1,
                detailScopes: [.library]
            )
        )
        XCTAssertFalse(
            MinimalNavigationChromePolicy.hidesTopNavigation(
                mode: .minimal,
                selectedTab: 1,
                detailScopes: [.library],
                returningScopes: [.library]
            )
        )
    }
}

final class SongSelectionLayoutTests: XCTestCase {
    func testCheckmarkScalesWithinTheReservedLeadingSlot() {
        XCTAssertEqual(
            SongSelectionLayoutMetrics.symbolSize(forScaledValue: 14),
            SongSelectionLayoutMetrics.baseSymbolSize
        )
        XCTAssertEqual(
            SongSelectionLayoutMetrics.symbolSize(forScaledValue: 24),
            24
        )
        XCTAssertEqual(
            SongSelectionLayoutMetrics.symbolSize(forScaledValue: 40),
            SongSelectionLayoutMetrics.maximumSymbolSize
        )
        XCTAssertLessThanOrEqual(
            SongSelectionLayoutMetrics.maximumSymbolSize,
            SongSelectionLayoutMetrics.leadingSlotWidth
        )
        XCTAssertGreaterThanOrEqual(
            SongSelectionLayoutMetrics.minimumRowHeight,
            44
        )
    }
}

final class PlayerAppearancePreferencesTests: XCTestCase {
    func testEveryImmersiveEffectDisplaysLyricsButNativeDoesNot() {
        XCTAssertFalse(FullscreenPlayerEffect.native.displaysLyrics)
        XCTAssertTrue(FullscreenPlayerEffect.immersiveCases.allSatisfy(\.displaysLyrics))
    }

    func testLyricsInteractionPreferencesUseSafeDefaultsAndHonorOverrides() {
        let suiteName = "PlayerAppearancePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(PlayerAppearancePreferences.keepsScreenAwakeForLyricsByDefault)
        XCTAssertTrue(PlayerAppearancePreferences.tapLyricsToSeekIsEnabled(defaults: defaults))

        defaults.set(false, forKey: PlayerAppearancePreferences.tapLyricsToSeekKey)
        XCTAssertFalse(PlayerAppearancePreferences.tapLyricsToSeekIsEnabled(defaults: defaults))
    }
}

final class AutomaticOfflineSafetyTests: XCTestCase {
    func testPathFamilyProtectsEveryTransferAndRefreshArtifact() {
        XCTAssertEqual(
            AudioCachePathFamily.relativePaths(for: "source/song.flac"),
            [
                "source/song.flac",
                "source/song.flac.installing",
                "source/song.flac.partial",
                "source/song.flac.partial\(CloudPlaybackSource.prewarmMarkerSuffix)",
                "source/song.flac.offline",
                "source/song.flac.refresh",
                "source/song.flac.refresh.installing",
                "source/song.flac.refresh.offline",
            ]
        )
    }

    func testSourceWideFailuresDoNotTurnEveryCooldownIntoAnAuthPrompt() {
        let unauthorized = AutomaticOfflineFailureClassifier.classify(
            CloudDriveError.apiError(401, "unauthorized")
        )
        let forbidden = AutomaticOfflineFailureClassifier.classify(
            CloudDriveError.apiError(403, "forbidden")
        )
        let rateLimited = AutomaticOfflineFailureClassifier.classify(
            CloudDriveError.apiError(429, "slow down")
        )
        let serverError = AutomaticOfflineFailureClassifier.classify(
            CloudDriveError.apiError(503, "unavailable")
        )

        XCTAssertEqual(unauthorized, .authentication)
        XCTAssertTrue(unauthorized.authenticationRequired)
        XCTAssertTrue(unauthorized.requiresSourceCooldown)
        XCTAssertEqual(forbidden, .sourceAccessDenied)
        XCTAssertFalse(forbidden.authenticationRequired)
        XCTAssertTrue(forbidden.requiresSourceCooldown)
        XCTAssertEqual(rateLimited, .rateLimited)
        XCTAssertFalse(rateLimited.authenticationRequired)
        XCTAssertTrue(rateLimited.requiresSourceCooldown)
        XCTAssertEqual(serverError, .sourceUnavailable)
        XCTAssertFalse(serverError.authenticationRequired)
        XCTAssertTrue(serverError.requiresSourceCooldown)
    }

    func testSourceUnavailableCooldownDefersOnlySiblingJobs() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cooldown = now.addingTimeInterval(120)
        XCTAssertEqual(
            AutomaticOfflineSourceCooldownPolicy.adjustedAttemptDate(
                current: now,
                jobSourceID: "source-a",
                failedSourceID: "source-a",
                cooldownUntil: cooldown,
                failureKind: .sourceUnavailable
            ),
            cooldown
        )
        XCTAssertEqual(
            AutomaticOfflineSourceCooldownPolicy.adjustedAttemptDate(
                current: now,
                jobSourceID: "source-b",
                failedSourceID: "source-a",
                cooldownUntil: cooldown,
                failureKind: .sourceUnavailable
            ),
            now
        )
        XCTAssertEqual(
            AutomaticOfflineSourceCooldownPolicy.adjustedAttemptDate(
                current: now,
                jobSourceID: "source-a",
                failedSourceID: "source-a",
                cooldownUntil: cooldown,
                failureKind: .transient
            ),
            now
        )
    }

    func testDiscardCanCreditUntrustedBytesButPreserveRequiresDoubleSpace() {
        let physical = Int64(300 * 1_024 * 1_024)
        let recoverable = Int64(400 * 1_024 * 1_024)
        let discardAvailable = AutomaticOfflineDiskAdmissionPolicy.adjustedAvailableBytes(
            physicalAvailableBytes: physical,
            refreshDisposition: .discardUntrusted,
            recoverableArtifactBytes: recoverable
        )
        let preserveAvailable = AutomaticOfflineDiskAdmissionPolicy.adjustedAvailableBytes(
            physicalAvailableBytes: physical,
            refreshDisposition: .preserveExisting,
            recoverableArtifactBytes: recoverable
        )

        XCTAssertEqual(discardAvailable, physical + recoverable)
        XCTAssertEqual(preserveAvailable, physical)
        XCTAssertEqual(
            AutomaticOfflineDownloadPolicy.eligibility(
                applicationIsActive: true,
                hasDeterminedNetwork: true,
                isReachable: true,
                isExpensive: false,
                isConstrained: false,
                isLowPowerModeEnabled: false,
                hasSeriousThermalPressure: false,
                availableDiskBytes: discardAvailable,
                expectedDownloadBytes: 100 * 1_024 * 1_024,
                isPlaybackBuffering: false
            ),
            .allowed
        )
    }

    func testDiscardDeletionLeaseWaitsForAnActiveArtifactUser() async {
        let path = "lease-test/\(UUID().uuidString).flac"
        let acquiredActive = await AudioCacheManager.shared.acquirePathFamilyLease(path: path)
        let active = try! XCTUnwrap(acquiredActive)
        let acquiredReplacement = await AudioCacheManager.shared.acquirePathFamilyLease(path: path)
        let replacement = try! XCTUnwrap(acquiredReplacement)
        let hasActiveLease = await AudioCacheManager.shared.pathFamilyHasOtherLeases(
            path: path,
            excluding: replacement
        )
        XCTAssertTrue(hasActiveLease)
        await AudioCacheManager.shared.releasePathFamilyLease(active)
        let hasLeaseAfterRelease = await AudioCacheManager.shared.pathFamilyHasOtherLeases(
            path: path,
            excluding: replacement
        )
        XCTAssertFalse(hasLeaseAfterRelease)
        await AudioCacheManager.shared.releasePathFamilyLease(replacement)
    }

    func testDiscardRetryDeletesOnlyCanonicalBytesAndKeepsRefreshResumeData() {
        let canonical = URL(fileURLWithPath: "/cache/song.flac")
        let cleanupPaths = Set(
            AutomaticOfflineUntrustedCleanupPolicy.canonicalURLs(for: canonical).map(\.path)
        )

        XCTAssertTrue(cleanupPaths.contains(canonical.path))
        XCTAssertTrue(cleanupPaths.contains(canonical.path + ".offline"))
        XCTAssertFalse(cleanupPaths.contains(canonical.path + ".refresh"))
        XCTAssertFalse(cleanupPaths.contains(canonical.path + ".refresh.installing"))
        XCTAssertFalse(cleanupPaths.contains(canonical.path + ".refresh.offline"))
    }

    func testRecoverableDiskCreditUsesSparseAllocatedBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticOfflineSparseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("song.flac")
        XCTAssertTrue(FileManager.default.createFile(atPath: canonical.path, contents: Data([0x01])))
        let handle = try FileHandle(forWritingTo: canonical)
        try handle.truncate(atOffset: 1_024 * 1_024 * 1_024)
        try handle.close()

        let values = try canonical.resourceValues(forKeys: [
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ])
        let logicalBytes = Int64(values.fileSize ?? 0)
        let allocatedBytes = Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 0
        )
        let credited = AutomaticOfflineUntrustedCleanupPolicy.recoverableAllocatedBytes(
            for: canonical
        )

        XCTAssertEqual(logicalBytes, 1_024 * 1_024 * 1_024)
        XCTAssertEqual(credited, allocatedBytes)
        XCTAssertLessThan(credited, logicalBytes)
    }

    func testAlwaysDownloadAllowsBoundedStreamDescriptorResolution() {
        let streamDescriptor = Song(
            id: "stream",
            title: "Unbounded stream",
            fileFormat: .mp3,
            filePath: "radio.strm",
            sourceID: "source",
            fileSize: 0
        )
        let ordinarySong = Song(
            id: "file",
            title: "Bounded file",
            fileFormat: .mp3,
            filePath: "song.mp3",
            sourceID: "source",
            fileSize: 1_024
        )
        var unknownSizeSong = ordinarySong
        unknownSizeSong.id = "unknown"
        unknownSizeSong.fileSize = 0

        XCTAssertTrue(AutomaticOfflineSongPolicy.supports(streamDescriptor))
        XCTAssertFalse(AutomaticOfflineSongPolicy.supports(unknownSizeSong))
        XCTAssertTrue(AutomaticOfflineSongPolicy.supports(ordinarySong))
    }

    func testAutomaticRefreshNeverCoalescesWithAWeakerOrManualTransfer() {
        XCTAssertFalse(AutomaticOfflineTaskJoinPolicy.canJoin(
            existingArtifactSignature: nil,
            existingDisposition: .none,
            requestedArtifactSignature: "desired-artifact",
            requestedDisposition: .preserveExisting
        ))
        XCTAssertFalse(AutomaticOfflineTaskJoinPolicy.canJoin(
            existingArtifactSignature: "desired-artifact",
            existingDisposition: .preserveExisting,
            requestedArtifactSignature: nil,
            requestedDisposition: .none
        ))
        XCTAssertFalse(AutomaticOfflineTaskJoinPolicy.canJoin(
            existingArtifactSignature: "desired-artifact",
            existingDisposition: .none,
            requestedArtifactSignature: nil,
            requestedDisposition: .none
        ))
        XCTAssertTrue(AutomaticOfflineTaskJoinPolicy.canJoin(
            existingArtifactSignature: nil,
            existingDisposition: .none,
            requestedArtifactSignature: nil,
            requestedDisposition: .none
        ))
        XCTAssertTrue(AutomaticOfflineTaskJoinPolicy.canJoin(
            existingArtifactSignature: "desired-artifact",
            existingDisposition: .discardUntrusted,
            requestedArtifactSignature: "desired-artifact",
            requestedDisposition: .preserveExisting
        ))
    }

    func testBlockedUntrustedArtifactCannotBeUsedByBackgroundReaders() {
        let path = "source/song.flac"
        XCTAssertFalse(AutomaticOfflineCachedReadPolicy.allows(
            path: path,
            blockedPaths: [path]
        ))
        XCTAssertTrue(AutomaticOfflineCachedReadPolicy.allows(
            path: path,
            blockedPaths: []
        ))
    }

    func testArtifactProvenanceFailsClosedAndChangesWithScopeOrRevision() {
        let baseline = AutomaticOfflineArtifactPolicy.signature(
            sourceID: "source",
            filePath: "/album/disc.flac",
            fileFormat: "flac",
            fileSize: 42_000,
            revision: "rev-1",
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            sourceIdentitySignature: "endpoint-a"
        )
        let movedAccount = AutomaticOfflineArtifactPolicy.signature(
            sourceID: "source",
            filePath: "/album/disc.flac",
            fileFormat: "flac",
            fileSize: 42_000,
            revision: "rev-1",
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            sourceIdentitySignature: "endpoint-b"
        )
        let replacedContent = AutomaticOfflineArtifactPolicy.signature(
            sourceID: "source",
            filePath: "/album/disc.flac",
            fileFormat: "flac",
            fileSize: 42_000,
            revision: "rev-2",
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            sourceIdentitySignature: "endpoint-a"
        )

        XCTAssertTrue(AutomaticOfflineArtifactPolicy.provenanceIsTrusted(
            recordedArtifactSignature: baseline,
            desiredArtifactSignature: baseline
        ))
        XCTAssertFalse(AutomaticOfflineArtifactPolicy.provenanceIsTrusted(
            recordedArtifactSignature: nil,
            desiredArtifactSignature: baseline
        ))
        XCTAssertNotEqual(baseline, movedAccount)
        XCTAssertNotEqual(baseline, replacedContent)
    }

    func testRefreshDispositionNeverDowngradesAnUntrustedReplacement() {
        XCTAssertEqual(
            AutomaticOfflineRefreshDisposition.strongest(.none, .preserveExisting),
            .preserveExisting
        )
        XCTAssertEqual(
            AutomaticOfflineRefreshDisposition.strongest(.preserveExisting, .discardUntrusted),
            .discardUntrusted
        )
        XCTAssertEqual(
            AutomaticOfflineArtifactPolicy.refreshDisposition(
                fileExists: true,
                recordedArtifactSignature: "old-revision",
                desiredArtifactSignature: "new-revision",
                recordedSourceIdentitySignature: "same-account",
                desiredSourceIdentitySignature: "same-account"
            ),
            .preserveExisting
        )
        XCTAssertEqual(
            AutomaticOfflineArtifactPolicy.refreshDisposition(
                fileExists: true,
                recordedArtifactSignature: "old-revision",
                desiredArtifactSignature: "new-revision",
                recordedSourceIdentitySignature: "old-account",
                desiredSourceIdentitySignature: "new-account"
            ),
            .discardUntrusted
        )
        XCTAssertEqual(
            AutomaticOfflineArtifactPolicy.refreshDisposition(
                fileExists: true,
                recordedArtifactSignature: nil,
                desiredArtifactSignature: "new-revision",
                recordedSourceIdentitySignature: nil,
                desiredSourceIdentitySignature: "new-account"
            ),
            .discardUntrusted
        )
    }

    func testAtomicRefreshKeepsOldBytesWhenStagingIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticOfflineSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("song.flac")
        let missingStaging = directory.appendingPathComponent("song.flac.refresh")
        try Data("old-playable-bytes".utf8).write(to: canonical)

        XCTAssertThrowsError(
            try OfflineCacheAtomicReplacement.replace(
                staging: missingStaging,
                canonical: canonical
            )
        )
        XCTAssertEqual(try Data(contentsOf: canonical), Data("old-playable-bytes".utf8))
    }

    func testAtomicInstallReplacesTruncatedTargetAndInterruptedStaging() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticOfflineInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.flac")
        let target = directory.appendingPathComponent("song.flac.refresh")
        let interrupted = URL(fileURLWithPath: target.path + ".installing")
        let expected = Data(repeating: 0x5A, count: 64 * 1024)
        try expected.write(to: source)
        try Data(repeating: 0x01, count: 128).write(to: target)
        try Data(repeating: 0x02, count: 64).write(to: interrupted)

        try OfflineCacheAtomicReplacement.install(
            source: source,
            target: target,
            move: false
        )

        XCTAssertEqual(try Data(contentsOf: target), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    }

    func testTenThousandJournalPayloadsStayCompactWithoutLyricsDuplication() throws {
        let lyrics = String(repeating: "long lyrics line ", count: 8_192)
        let song = Song(
            id: "song",
            title: "Title",
            fileFormat: .flac,
            filePath: "/album/song.flac",
            sourceID: "source",
            fileSize: 42_000,
            lyricsText: lyrics
        )
        let snapshots = (0..<10_000).map { index -> AutomaticOfflineJobSongSnapshot in
            var indexedSong = song
            indexedSong.id = "song-\(index)"
            return AutomaticOfflineJobSongSnapshot(indexedSong)
        }
        let completionDeltas = (0..<10_000).map { index in
            AutomaticOfflineCompletionDeltaPayload(
                completedSignatures: ["song-\(index)": "content-\(index)"],
                artifactPath: "source/song-\(index).flac",
                artifactSignature: "artifact-\(index)",
                sourceIdentitySignature: "scope",
                sourceID: "source"
            )
        }
        let encoder = JSONEncoder()
        let snapshotData = try encoder.encode(snapshots)
        let deltaData = try encoder.encode(completionDeltas)

        XCTAssertLessThan(snapshotData.count, 2_000_000)
        XCTAssertLessThan(deltaData.count, 3_000_000)
        XCTAssertFalse(String(decoding: snapshotData, as: UTF8.self).contains("long lyrics line"))
    }

    func testTenThousandArtifactQueueBuildsOneLinearCompletionIndex() {
        let desired = (0..<10_000).map { index in
            let artifactIndex = index / 2
            let song = Song(
                id: "song-\(index)",
                title: "Song \(index)",
                fileFormat: .flac,
                filePath: "/album/artifact-\(artifactIndex).flac",
                sourceID: "source",
                fileSize: 42_000
            )
            return AlwaysDownloadDesiredSong(
                song: song,
                playlistIDs: ["playlist"],
                contentSignature: "content-\(index)",
                sourceIdentitySignature: "scope",
                artifactPath: "source/artifact-\(artifactIndex).flac",
                artifactSignature: "artifact-signature-\(artifactIndex)"
            )
        }

        let index = AutomaticOfflineArtifactIndex.make(from: desired)
        XCTAssertEqual(index.count, 5_000)
        XCTAssertEqual(
            Set(index[AutomaticOfflineArtifactIndex.key(
                path: "source/artifact-123.flac",
                signature: "artifact-signature-123"
            )] ?? []),
            ["song-246", "song-247"]
        )
    }

    func testFirstEnableExistingUnknownFilePlansDiscardBeforeDownload() {
        let requiredSongIDs = AutomaticOfflineDownloadPolicy.requiredSongIDs(
            desiredSignatures: ["song": "desired-content"],
            completedSignatures: [:],
            missingSongIDs: []
        )
        XCTAssertTrue(requiredSongIDs.contains("song"))

        let disposition = AutomaticOfflineArtifactPolicy.refreshDisposition(
            fileExists: true,
            recordedArtifactSignature: nil,
            desiredArtifactSignature: "desired-artifact",
            recordedSourceIdentitySignature: nil,
            desiredSourceIdentitySignature: "current-account"
        )
        XCTAssertEqual(disposition, .discardUntrusted)
    }

    func testOfflineTransferSizePolicyCapsSmallAndUnknownArtifacts() throws {
        let expected: Int64 = 1_024
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(expectedSize: expected),
            expected + 4 * 1_024
        )
        XCTAssertNoThrow(try OfflineTransferSizePolicy.validate(
            actualSize: expected + 4 * 1_024,
            expectedSize: expected
        ))
        XCTAssertThrowsError(try OfflineTransferSizePolicy.validate(
            actualSize: expected + 4 * 1_024 + 1,
            expectedSize: expected
        ))
        XCTAssertThrowsError(try OfflineTransferSizePolicy.validate(
            actualSize: 0,
            expectedSize: 0,
            maximumBytes: 1_024
        ))

        let gib: Int64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: 0,
                cacheLimitBytes: 2 * gib,
                availableDiskBytes: 10 * gib
            ),
            2 * gib
        )
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: 0,
                cacheLimitBytes: 0,
                availableDiskBytes: gib
            ),
            gib - AutomaticOfflineDownloadPolicy.diskHeadroomBytes
        )
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: 3 * gib,
                cacheLimitBytes: 2 * gib,
                availableDiskBytes: 10 * gib
            ),
            2 * gib
        )
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: 0,
                cacheLimitBytes: 0,
                availableDiskBytes: 3 * gib
                    + AutomaticOfflineDownloadPolicy.diskHeadroomBytes,
                otherReservedBytes: 2 * gib
            ),
            gib
        )
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: 2 * gib,
                cacheLimitBytes: 3 * gib,
                availableDiskBytes: 3 * gib
                    + AutomaticOfflineDownloadPolicy.diskHeadroomBytes,
                otherReservedBytes: 2 * gib
            ),
            gib
        )
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: 2 * gib,
                cacheLimitBytes: 3 * gib,
                availableDiskBytes: 5 * gib
                    + AutomaticOfflineDownloadPolicy.diskHeadroomBytes,
                otherReservedBytes: 2 * gib,
                otherConfiguredCacheReservedBytes: 0
            ),
            2 * gib + OfflineTransferSizePolicy.oversizeToleranceBytes
        )

        let mib: Int64 = 1_024 * 1_024
        let expectedAtAdmissionBoundary = 100 * mib
        let availableAtAdmissionBoundary = 600 * mib
        XCTAssertEqual(
            AutomaticOfflineDownloadPolicy.eligibility(
                applicationIsActive: true,
                hasDeterminedNetwork: true,
                isReachable: true,
                isExpensive: false,
                isConstrained: false,
                isLowPowerModeEnabled: false,
                hasSeriousThermalPressure: false,
                availableDiskBytes: availableAtAdmissionBoundary,
                expectedDownloadBytes: expectedAtAdmissionBoundary,
                isPlaybackBuffering: false
            ),
            .allowed
        )
        XCTAssertEqual(
            OfflineTransferSizePolicy.maximumAllowedBytes(
                expectedSize: expectedAtAdmissionBoundary,
                cacheLimitBytes: 2 * gib,
                availableDiskBytes: availableAtAdmissionBoundary
            ),
            expectedAtAdmissionBoundary + OfflineTransferSizePolicy.oversizeToleranceBytes
        )
    }

    func testFiniteCacheCapacityRequiresEvictionBelowActiveReservations() {
        let gib: Int64 = 1_024 * 1_024 * 1_024
        XCTAssertFalse(AudioCacheTransferCapacityPolicy.isSatisfied(
            currentSize: gib + gib / 2,
            limitBytes: 2 * gib,
            reservedBytes: gib
        ))
        XCTAssertTrue(AudioCacheTransferCapacityPolicy.isSatisfied(
            currentSize: gib,
            limitBytes: 2 * gib,
            reservedBytes: gib
        ))
        XCTAssertTrue(AudioCacheTransferCapacityPolicy.isSatisfied(
            currentSize: 10 * gib,
            limitBytes: AudioCacheLimitPolicy.unlimitedBytes,
            reservedBytes: gib
        ))
    }

    func testSTRMConnectorMaterializationOnlyAllowsLocalSources() {
        XCTAssertFalse(
            OfflineSTRMConnectorMaterializationPolicy
                .permitsConnectorMaterialization(sourceType: .webdav)
        )
        XCTAssertTrue(
            OfflineSTRMConnectorMaterializationPolicy
                .permitsConnectorMaterialization(sourceType: .local)
        )
        XCTAssertTrue(
            OfflineSTRMConnectorMaterializationPolicy
                .permitsConnectorMaterialization(sourceType: .appleMusicLibrary)
        )
    }

    func testOfflineContentRangeRequiresExactOpenEndedResumeInterval() throws {
        XCTAssertEqual(
            try OfflineHTTPContentRangePolicy.validate(
                header: "bytes 100-199/200",
                expectedStart: 100,
                contentLength: 100,
                maximumBytes: 256
            ),
            OfflineHTTPContentRange(start: 100, end: 199, total: 200)
        )
        XCTAssertThrowsError(try OfflineHTTPContentRangePolicy.validate(
            header: "bytes 0-99/200",
            expectedStart: 100,
            contentLength: 100,
            maximumBytes: 256
        ))
        XCTAssertThrowsError(try OfflineHTTPContentRangePolicy.validate(
            header: "bytes 100-149/200",
            expectedStart: 100,
            contentLength: 50,
            maximumBytes: 256
        ))
        XCTAssertThrowsError(try OfflineHTTPContentRangePolicy.validate(
            header: "bytes 100-299/300",
            expectedStart: 100,
            contentLength: 200,
            maximumBytes: 256
        ))
    }

    func testSignedURLRetryDoesNotTurnCancellationOrTransportFailureIntoASecondRequest() {
        XCTAssertTrue(OfflineDirectDownloadRetryPolicy.shouldRefreshSignedURL(
            after: CloudDriveError.apiError(403, "expired")
        ))
        XCTAssertFalse(OfflineDirectDownloadRetryPolicy.shouldRefreshSignedURL(
            after: URLError(.cancelled)
        ))
        XCTAssertFalse(OfflineDirectDownloadRetryPolicy.shouldRefreshSignedURL(
            after: URLError(.timedOut)
        ))
    }

    func testAudioCacheScopeAdoptsOnlyKnownLegacyUpgradeCandidates() {
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: nil,
                currentSignature: "scope-a",
                legacyAdoptionAllowed: true
            ),
            .adoptLegacy
        )
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: nil,
                currentSignature: "scope-a",
                legacyAdoptionAllowed: false
            ),
            .quarantineExisting
        )
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: "scope-b",
                currentSignature: "scope-a",
                legacyAdoptionAllowed: true
            ),
            .quarantineExisting
        )
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: "scope-a",
                currentSignature: "scope-a",
                legacyAdoptionAllowed: false
            ),
            .allowExisting
        )
        // Adding a public address to a NAS source moves the full scope but not
        // the credential scope: the downloaded bytes stay.
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: "scope-a",
                currentSignature: "scope-b",
                legacyAdoptionAllowed: false,
                recordedCredentialSignature: "credentials-a",
                currentCredentialSignature: "credentials-a"
            ),
            .adoptRouteChange
        )
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: "scope-a",
                currentSignature: "scope-b",
                legacyAdoptionAllowed: false,
                recordedCredentialSignature: "credentials-a",
                currentCredentialSignature: "credentials-b"
            ),
            .quarantineExisting
        )
        // Bytes with no recorded scope were never proved to belong to this
        // account; a matching credential scope must not adopt them.
        XCTAssertEqual(
            SourceAudioCacheScopePolicy.reconciliation(
                recordedSignature: nil,
                currentSignature: "scope-b",
                legacyAdoptionAllowed: false,
                recordedCredentialSignature: "credentials-a",
                currentCredentialSignature: "credentials-a"
            ),
            .quarantineExisting
        )
        XCTAssertFalse(SourceAudioCacheScopePolicy.allowsRead(
            sourceID: "source",
            validatedSourceIDs: [],
            blockedSourceIDs: []
        ))
        XCTAssertFalse(SourceAudioCacheScopePolicy.allowsRead(
            sourceID: "source",
            validatedSourceIDs: ["source"],
            blockedSourceIDs: ["source"]
        ))
        XCTAssertTrue(SourceAudioCacheScopePolicy.allowsRead(
            sourceID: "source",
            validatedSourceIDs: ["source"],
            blockedSourceIDs: []
        ))
    }

    func testSourceScopeQuarantinePreservesBytesOutsideActiveCache() async throws {
        let sourceID = "scope-quarantine-\(UUID().uuidString)"
        let relativePath = "\(sourceID)/track.flac"
        let caches = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let activeSourceDirectory = caches
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        let quarantineSourceDirectory = caches
            .appendingPathComponent("primuse_audio_cache_quarantine", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: activeSourceDirectory)
            try? FileManager.default.removeItem(at: quarantineSourceDirectory)
        }

        try FileManager.default.createDirectory(
            at: activeSourceDirectory,
            withIntermediateDirectories: true
        )
        let expected = Data("preserve cached audio".utf8)
        try expected.write(to: activeSourceDirectory.appendingPathComponent("track.flac"))
        await AudioCacheManager.shared.recordAccess(path: relativePath)
        await AudioCacheManager.shared.pin(
            path: relativePath,
            byteCount: Int64(expected.count)
        )

        let generation = Int.random(in: 1...Int.max)
        let beganQuarantine = await AudioCacheManager.shared.beginSourcePurge(
            prefix: "\(sourceID)/",
            generation: generation
        )
        XCTAssertTrue(beganQuarantine)
        let quarantined = await AudioCacheManager.shared.quarantineSourceCacheDirectoryIfReady(
            prefix: "\(sourceID)/",
            generation: generation,
            recordedSignature: "scope-a",
            replacementSignature: "scope-b"
        )
        XCTAssertTrue(quarantined)
        await AudioCacheManager.shared.endSourcePurge(
            prefix: "\(sourceID)/",
            generation: generation
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: activeSourceDirectory.path))
        let records = try FileManager.default.contentsOfDirectory(
            at: quarantineSourceDirectory,
            includingPropertiesForKeys: nil
        )
        let record = try XCTUnwrap(records.first)
        let preservedURL = record
            .appendingPathComponent("payload", isDirectory: true)
            .appendingPathComponent("track.flac")
        XCTAssertEqual(try Data(contentsOf: preservedURL), expected)
        let snapshot = await AudioCacheManager.shared.snapshot(
            path: relativePath,
            fileExists: false,
            byteCount: nil
        )
        XCTAssertEqual(snapshot, .notCached)
    }

    func testSourcePurgeGateRejectsLateOlderGenerationAndNewLeases() async {
        let prefix = "scope-gate-\(UUID().uuidString)/"
        let path = prefix + "song.flac"
        await AudioCacheManager.shared.endSourcePurge(prefix: prefix, generation: 2)
        let lateBegin = await AudioCacheManager.shared.beginSourcePurge(
            prefix: prefix,
            generation: 1
        )
        XCTAssertFalse(lateBegin)
        let currentBegin = await AudioCacheManager.shared.beginSourcePurge(
            prefix: prefix,
            generation: 3
        )
        XCTAssertTrue(currentBegin)
        let blockedLease = await AudioCacheManager.shared.acquirePathFamilyLease(path: path)
        XCTAssertNil(blockedLease)

        await AudioCacheManager.shared.endSourcePurge(prefix: prefix, generation: 4)
        let allowedLease = await AudioCacheManager.shared.acquirePathFamilyLease(path: path)
        XCTAssertNotNil(allowedLease)
        if let allowedLease {
            await AudioCacheManager.shared.releasePathFamilyLease(allowedLease)
        }
    }

    func testAlwaysDownloadScopeIdentityIgnoresScanDirectorySelection() throws {
        var source = MusicSource(
            id: "source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            username: "user"
        )
        source.extraConfig = String(
            data: try JSONEncoder().encode(["/Music/A"]),
            encoding: .utf8
        )
        let first = MusicSourceScopeFingerprint.make(
            for: source,
            directories: nil,
            includeSourceID: true
        )
        source.extraConfig = String(
            data: try JSONEncoder().encode(["/Music/B"]),
            encoding: .utf8
        )
        let second = MusicSourceScopeFingerprint.make(
            for: source,
            directories: nil,
            includeSourceID: true
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            MusicSourceScopeFingerprint.make(
                for: source,
                directories: ["/Music/A"],
                includeSourceID: true
            ),
            MusicSourceScopeFingerprint.make(
                for: source,
                directories: ["/Music/B"],
                includeSourceID: true
            )
        )
    }

    func testSourceSecurityRevisionChangesCredentialScopeWithoutUsingSecretMaterial() {
        let source = MusicSource(
            id: "security-revision-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            username: "user"
        )

        let first = MusicSourceSecurityRevision.scopedFingerprint(
            for: source,
            revision: 41
        )
        let second = MusicSourceSecurityRevision.scopedFingerprint(
            for: source,
            revision: 42
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            first,
            MusicSourceSecurityRevision.scopedFingerprint(
                for: source,
                revision: 41
            )
        )
    }

    @MainActor
    func testOnlyCredentialRefreshAdvancesSourceSecurityRevision() async throws {
        let sourceID = "security-refresh-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID,
            name: "Local",
            type: .local,
            basePath: "/tmp",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let manager = SourceManager(sourcesProvider: { [source] in [source] })
        let initial = try XCTUnwrap(
            MusicSourceSecurityRevision.revision(for: sourceID)
        )

        await manager.refreshConnector(for: sourceID)
        XCTAssertEqual(MusicSourceSecurityRevision.revision(for: sourceID), initial)

        try manager.credentialsWillChange(for: sourceID)
        XCTAssertEqual(
            MusicSourceSecurityRevision.revision(for: sourceID),
            initial + 1
        )
        MusicSourceSecurityRevision.reloadPersistedStateForTesting()
        XCTAssertEqual(
            MusicSourceSecurityRevision.revision(for: sourceID),
            initial + 1
        )
        XCTAssertTrue(
            manager.connector(for: source) is NoAvailableConnectionSourceConnector
        )
        await manager.refreshConnector(for: sourceID)
        XCTAssertTrue(
            manager.connector(for: source) is NoAvailableConnectionSourceConnector
        )

        manager.credentialsChangeOutcomeUncertain(for: sourceID)
        try manager.credentialsWillChange(for: sourceID)
        XCTAssertEqual(
            MusicSourceSecurityRevision.revision(for: sourceID),
            initial + 2
        )
        XCTAssertTrue(
            manager.connector(for: source) is NoAvailableConnectionSourceConnector
        )

        try manager.credentialsDidChange(for: sourceID)
        // 凭据真的换过: 调用方显式 force, 和视图层保存密码后的调用一致。
        await manager.refreshConnector(for: sourceID, force: true)
        XCTAssertFalse(
            manager.connector(for: source) is NoAvailableConnectionSourceConnector
        )
        await manager.disconnectAll()
    }

    /// 只改显示名这类保存不能掐掉正在播放的流: refreshConnector 默认先比对
    /// 作用域指纹, 只有明确 force 的调用方 (重新认证 / 改连接字段) 才推进
    /// stream epoch 并退休连接器。
    @MainActor
    func testNonSecurityConnectorRefreshKeepsActiveStream() async throws {
        let sourceID = "refresh-scope-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID,
            name: "Local",
            type: .local,
            basePath: "/tmp",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let manager = SourceManager(sourcesProvider: { [source] in [source] })

        // 先让管理器读到这个源的权威指纹。
        await manager.refreshConnector(for: sourceID, force: true)

        let ticket = CloudPlaybackSource.streamEpochTicket(sourceID: sourceID)
        await manager.refreshConnector(for: sourceID)
        XCTAssertTrue(
            CloudPlaybackSource.isStreamEpochTicketCurrent(sourceID: sourceID, ticket: ticket)
        )

        await manager.refreshConnector(for: sourceID, force: true)
        XCTAssertFalse(
            CloudPlaybackSource.isStreamEpochTicketCurrent(sourceID: sourceID, ticket: ticket)
        )
        await manager.disconnectAll()
    }

    @MainActor
    func testProvenUnchangedCredentialWriteAbortsPendingRevision() async throws {
        let sourceID = "security-abort-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID,
            name: "Local",
            type: .local,
            basePath: "/tmp",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let manager = SourceManager(sourcesProvider: { [source] in [source] })
        let initial = try XCTUnwrap(
            MusicSourceSecurityRevision.revision(for: sourceID)
        )

        try manager.credentialsWillChange(for: sourceID)
        XCTAssertEqual(
            MusicSourceSecurityRevision.revision(for: sourceID),
            initial + 1
        )
        try manager.credentialsDidNotChange(for: sourceID)
        XCTAssertEqual(
            MusicSourceSecurityRevision.revision(for: sourceID),
            initial
        )
        await manager.refreshConnector(for: sourceID)
        XCTAssertFalse(
            manager.connector(for: source) is NoAvailableConnectionSourceConnector
        )
        await manager.disconnectAll()
    }

    func testSourceCacheNamespaceSurvivesSecurityStateReload() throws {
        let sourceID = "security-namespace-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID,
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            username: "listener"
        )
        let fingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)

        try MusicSourceSecurityRevision.registerCacheNamespace(
            sourceID: sourceID,
            scopedFingerprint: fingerprint
        )
        MusicSourceSecurityRevision.reloadPersistedStateForTesting()

        XCTAssertEqual(
            MusicSourceSecurityRevision.cacheNamespace(for: sourceID),
            MusicSourceSecurityRevision.cacheNamespace(
                scopedFingerprint: fingerprint
            )
        )
    }

    func testCredentialRotationInvalidatesPreResolutionStreamEpoch() {
        let sourceID = "stream-epoch-\(UUID().uuidString)"
        let ticket = CloudPlaybackSource.streamEpochTicket(sourceID: sourceID)

        CloudPlaybackSource.cancelSessions(sourceID: sourceID)

        XCTAssertFalse(
            CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: sourceID,
                ticket: ticket
            )
        )
    }

    func testConnectorPendingValidationAcceptsOnlyNewSourceRevision() {
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let current = Date(timeIntervalSinceReferenceDate: 101)

        XCTAssertTrue(SourceConnectorScopePolicy.canEstablishDuringPendingValidation(
            previousModifiedAt: nil,
            requestedModifiedAt: old
        ))
        XCTAssertTrue(SourceConnectorScopePolicy.canEstablishDuringPendingValidation(
            previousModifiedAt: old,
            requestedModifiedAt: current
        ))
        XCTAssertFalse(SourceConnectorScopePolicy.canEstablishDuringPendingValidation(
            previousModifiedAt: old,
            requestedModifiedAt: old
        ))
        XCTAssertFalse(SourceConnectorScopePolicy.canEstablishDuringPendingValidation(
            previousModifiedAt: current,
            requestedModifiedAt: old
        ))
    }

    @MainActor
    func testNewlyAddedSourceCanCreateConnectorImmediatelyAfterNotification() async {
        let sourceID = "connector-add-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID,
            name: "Local",
            type: .local,
            basePath: "/tmp",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let manager = SourceManager(sourcesProvider: { [source] in [source] })

        NotificationCenter.default.post(
            name: .primuseSourcesDidChange,
            object: nil,
            userInfo: ["ids": [sourceID]]
        )
        let connector = manager.connector(for: source)

        XCTAssertFalse(connector is NoAvailableConnectionSourceConnector)
        await manager.disconnectAll()
    }

    @MainActor
    func testDirectoryBrowsingUsesAccountLinkedSourceAfterSecurityInvalidation() async {
        let sourceID = "directory-account-link-\(UUID().uuidString)"
        let presentedSource = MusicSource(
            id: sourceID,
            name: "Baidu",
            type: .baiduPan,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        var linkedSource = presentedSource
        linkedSource.cloudAccountID = "baidu-account"
        linkedSource.modifiedAt = Date(timeIntervalSinceReferenceDate: 101)
        let manager = SourceManager(sourcesProvider: { [linkedSource] in [linkedSource] })

        _ = manager.connector(for: presentedSource)
        NotificationCenter.default.post(
            name: .primuseSourcesDidChange,
            object: nil,
            userInfo: [
                "ids": [sourceID],
                "scopeFingerprints": [
                    sourceID: MusicSourceSecurityRevision.scopedFingerprint(for: linkedSource),
                ],
            ]
        )

        XCTAssertTrue(
            manager.connector(for: presentedSource) is NoAvailableConnectionSourceConnector
        )
        let resolved = await manager.connectorForDirectoryBrowsing(
            fallback: presentedSource
        )
        XCTAssertEqual(resolved.source.cloudAccountID, linkedSource.cloudAccountID)
        XCTAssertFalse(resolved.connector is NoAvailableConnectionSourceConnector)
        await manager.disconnectAll()
    }

    @MainActor
    func testDirectoryConnectorLookupDoesNotPublishInternalCacheMutations() async {
        let sourceTypes: [MusicSourceType] = [
            .smb, .webdav, .ftp, .sftp, .nfs, .qnap, .ugreen, .fnos, .s3,
            .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115,
            .pan123,
        ]

        for sourceType in sourceTypes {
            let source = MusicSource(
                id: "directory-observation-\(sourceType.rawValue)-\(UUID().uuidString)",
                name: sourceType.displayName,
                type: sourceType,
                host: "source.invalid",
                useSsl: false,
                username: "",
                basePath: "/music",
                shareName: "music",
                exportPath: "/music",
                authType: .none,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
            )
            let manager = SourceManager(sourcesProvider: { [source] in [source] })
            _ = manager.connector(for: source)

            let unexpectedInvalidation = expectation(
                description: "connector cache invalidated \(sourceType.rawValue) observation"
            )
            unexpectedInvalidation.isInverted = true
            withObservationTracking {
                _ = manager.connector(for: source)
            } onChange: {
                unexpectedInvalidation.fulfill()
            }

            await manager.removeConnector(for: source.id)
            await fulfillment(of: [unexpectedInvalidation], timeout: 0.05)
            await manager.disconnectAll()
        }
    }

    func testValidationErrorsThatApplyToWholeEndpointUseSourceCooldown() {
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                OfflineTransferValidationError.invalidContentRange
            ),
            .sourceUnavailable
        )
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                OfflineTransferValidationError.oversized(actual: 2, maximum: 1)
            ),
            .sourceUnavailable
        )
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                OfflineTransferValidationError.insufficientCapacity(required: 2, available: 1)
            ),
            .resourceDeferred
        )
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                OfflineTransferValidationError.incomplete(actual: 1, expected: 2)
            ),
            .transient
        )
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                OfflineTransferValidationError.invalidChunk(actual: 1, expected: 2)
            ),
            .transient
        )
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                AutomaticOfflineTransferDeferralError.unboundedAutomaticTransfer
            ),
            .sourceUnavailable
        )
        XCTAssertEqual(
            AutomaticOfflineFailureClassifier.classify(
                AutomaticOfflineTransferDeferralError.artifactLeased
            ),
            .transient
        )
        XCTAssertTrue(AutomaticOfflineFailureKind.sourceUnavailable.requiresSourceCooldown)
        XCTAssertTrue(AutomaticOfflineFailureKind.resourceDeferred.requiresSourceCooldown)
    }

    func testContentChangeKeepsDurableAutomaticPinAsRefreshFallback() async {
        let path = "content-refresh-\(UUID().uuidString)/song.flac"
        await AudioCacheManager.shared.pin(
            path: path,
            byteCount: 1_024,
            forPlaylistIDs: ["playlist"]
        )
        let persisted = await AudioCacheManager.shared
            .automaticPlaylistPinnedRelativePaths(matching: [path])
        XCTAssertEqual(persisted, [path])
        XCTAssertEqual(
            AutomaticOfflineContentChangePolicy.protectedPaths(
                candidates: [path],
                livePlaylistPaths: [],
                persistedPlaylistPaths: persisted,
                blockedUntrustedPaths: []
            ),
            [path]
        )
        XCTAssertTrue(
            AutomaticOfflineContentChangePolicy.protectedPaths(
                candidates: [path],
                livePlaylistPaths: [path],
                persistedPlaylistPaths: persisted,
                blockedUntrustedPaths: [path]
            ).isEmpty
        )
        await AudioCacheManager.shared.removeEntry(path: path)
    }

    func testConnectorCacheRejectsPreviousAccountFingerprintAndPendingWindow() {
        XCTAssertTrue(SourceConnectorScopePolicy.canReuse(
            cachedFingerprint: "scope-b",
            requestedFingerprint: "scope-b",
            requiredFingerprint: "scope-b",
            validationPending: false
        ))
        XCTAssertFalse(SourceConnectorScopePolicy.canReuse(
            cachedFingerprint: "scope-a",
            requestedFingerprint: "scope-a",
            requiredFingerprint: "scope-b",
            validationPending: false
        ))
        XCTAssertFalse(SourceConnectorScopePolicy.canReuse(
            cachedFingerprint: "scope-b",
            requestedFingerprint: "scope-b",
            requiredFingerprint: "scope-b",
            validationPending: true
        ))
    }

    func testBoundedHTTPSRedirectTargetCannotExceedDownloadLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineBoundedDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://redirect-target.invalid/audio")!)
        OfflineBoundedDownloadURLProtocol.configure(body: Data(repeating: 0x41, count: 5))
        let before = Self.boundedDownloadTemporaryFiles()

        do {
            let result = try await TrustedHTTPTransport.download(
                for: request,
                session: session,
                maximumRangedBodyBytes: 4,
                wholeResponsePrefixLimit: nil
            )
            try? FileManager.default.removeItem(at: result.0)
            XCTFail("Expected the redirected HTTPS body limit to reject the response")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
        XCTAssertEqual(Self.boundedDownloadTemporaryFiles(), before)
    }

    func testStreamingDownloadSessionControlCancelsLateInstalledTaskAndWaits() async {
        let control = StreamingDownloadSessionControl()
        let probe = StreamingDownloadCancellationProbe()
        control.cancel()

        let task = Task {
            defer { control.finish() }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await probe.markCancelled()
            }
        }
        control.install(task)
        await control.waitForTermination()

        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testStagedSourceCacheDeletionPreservesReplacementDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimuseSourceCacheDeletionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: sourceDirectory.appendingPathComponent("old.cache")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = SourceManager.stageCacheDirectoriesForDeletion([sourceDirectory])
        XCTAssertEqual(staged.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.path))

        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let replacement = sourceDirectory.appendingPathComponent("new.cache")
        try Data("new".utf8).write(to: replacement)

        SourceManager.deleteStagedCacheDirectories(staged)

        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged[0].path))
    }

    /// 清缓存的枚举 + 删除必须真的不占主 actor (nonisolated static 只是编译期
    /// 护栏, 这里要的是运行期的行为证据), 并且跳过 pinned 与在途文件: 正在
    /// 播放的 `.partial` 与正在下载的 `.offline` 被删掉不会让写入端退出, 只会
    /// 让这首歌之后每次读都 miss、离线任务报错变红。
    ///
    /// 不能用 `Thread.isMainThread` 判断: 它在异步上下文里不可用, 而且挂起点
    /// 之后的线程本来就和任务隔离域不是一回事。这里改成量真正的契约 —— 删除
    /// 进行期间主 actor 必须仍然能被调度。主 actor 上先挂一个心跳任务, 删除跑
    /// 在游离任务上; 如果删除占着主 actor, 心跳一次都推进不了。
    func testClearAudioCacheHelperSkipsPinnedAndInFlightFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimuseAudioCacheClearTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let basePath = root.appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let sourceDirectory = basePath.appendingPathComponent("source-a", isDirectory: true)
        let smbDirectory = root.appendingPathComponent("primuse_smb_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: smbDirectory, withIntermediateDirectories: true)

        // 多放一些可删文件, 让删除有真实的工作量, 心跳才有可观测的窗口。
        var bulkRemovable: [URL] = []
        for index in 0..<300 {
            let url = sourceDirectory.appendingPathComponent("bulk-\(index).cache")
            try Data(repeating: 3, count: 4096).write(to: url)
            bulkRemovable.append(url)
        }

        let removable = sourceDirectory.appendingPathComponent("gone.cache")
        let pinned = sourceDirectory.appendingPathComponent("pinned.cache")
        let streaming = sourceDirectory.appendingPathComponent("live.flac.partial")
        let staleStreaming = sourceDirectory.appendingPathComponent("stale.flac.partial")
        let offline = sourceDirectory.appendingPathComponent("download.flac.offline")
        let smbFile = smbDirectory.appendingPathComponent("scratch.tmp")
        for url in [removable, pinned, streaming, staleStreaming, offline, smbFile] {
            try Data(repeating: 7, count: 1024).write(to: url)
        }

        let heartbeat = await MainActorHeartbeat()
        let ticker = Task { @MainActor in await heartbeat.run() }

        let outcome = await Task.detached(priority: .utility) { () async -> (Int64, Int) in
            let result = await SourceManager.removeUnpinnedAudioCacheFiles(
                dirs: [basePath, smbDirectory],
                basePath: basePath,
                removableDirPaths: [smbDirectory.path],
                pinnedRelativePaths: ["source-a/pinned.cache"],
                protectedAbsolutePaths: [streaming.path, offline.path]
            )
            return (result.freedBytes, result.failedCount)
        }.value

        await heartbeat.stop()
        await ticker.value
        let ticks = await heartbeat.ticks
        XCTAssertGreaterThan(
            ticks, 0,
            "删除期间主 actor 一次都没被调度到, 说明这段阻塞的文件操作占了主 actor"
        )
        XCTAssertGreaterThan(outcome.0, 0)
        XCTAssertEqual(outcome.1, 0)
        for url in bulkRemovable {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: streaming.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: offline.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleStreaming.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: smbDirectory.path))
    }

    /// 临时目录整删是「文件都删光了」之后的收尾。只要本轮跳过了在途文件,
    /// 就不能再递归删掉整个目录, 否则跳过等于没跳过。
    func testClearAudioCacheHelperKeepsTemporaryDirectoryHoldingProtectedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimuseAudioCacheClearKeepTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let basePath = root.appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let smbDirectory = root.appendingPathComponent("primuse_smb_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: smbDirectory, withIntermediateDirectories: true)
        let live = smbDirectory.appendingPathComponent("live.flac.partial")
        try Data(repeating: 3, count: 512).write(to: live)

        let failed = await Task.detached(priority: .utility) { () async -> Int in
            await SourceManager.removeUnpinnedAudioCacheFiles(
                dirs: [basePath, smbDirectory],
                basePath: basePath,
                removableDirPaths: [smbDirectory.path],
                pinnedRelativePaths: [],
                protectedAbsolutePaths: [live.path]
            ).failedCount
        }.value

        XCTAssertEqual(failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    func testPurgePartialHelperKeepsInFlightStagingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimusePartialPurgeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let basePath = root.appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let sourceDirectory = basePath.appendingPathComponent("source-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let completed = sourceDirectory.appendingPathComponent("done.flac")
        let stalePartial = sourceDirectory.appendingPathComponent("stale.flac.partial")
        let staleMarker = sourceDirectory.appendingPathComponent("stale.flac.partial.prewarmed")
        let staleOffline = sourceDirectory.appendingPathComponent("stale.flac.offline")
        let livePartial = sourceDirectory.appendingPathComponent("live.flac.partial")
        let liveOffline = sourceDirectory.appendingPathComponent("live.flac.offline")
        for url in [completed, stalePartial, staleMarker, staleOffline, livePartial, liveOffline] {
            try Data(repeating: 5, count: 1024).write(to: url)
        }

        let result = await Task.detached(priority: .utility) { () async -> (Int64, Int) in
            let purged = await SourceManager.removePartialFiles(
                basePath: basePath,
                protectedAbsolutePaths: [livePartial.path, liveOffline.path]
            )
            return (purged.freedBytes, purged.failedCount)
        }.value

        XCTAssertGreaterThan(result.0, 0)
        XCTAssertEqual(result.1, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: livePartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveOffline.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePartial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOffline.path))
    }

    /// 后台自动缓存的「整文件」模式写的是同一份 `<canonical>.offline`, 却只
    /// 登记在 `backgroundAudioCacheTasks` 里。保护集只看 `offlineDownloadTasks`
    /// 的话, 「清理半成品」会在预热跑到一半时 unlink 掉暂存文件, 下一个
    /// chunk 重开 FileHandle 直接 ENOENT。
    func testProtectedInFlightPathsCoverBackgroundPrewarmStagingFiles() {
        let basePath = URL(
            fileURLWithPath: "/tmp/primuse-protected-in-flight",
            isDirectory: true
        )
        let sessionPartial = basePath
            .appendingPathComponent("source-a/playing.flac.partial").path
        let offlineTaskKey = "source-a/manual.flac"
        let backgroundTaskKey = "source-b/prewarm.flac"

        let protectedPaths = SourceManager.protectedInFlightAudioCachePaths(
            basePath: basePath,
            sessionPaths: [sessionPartial],
            offlineDownloadTaskKeys: [offlineTaskKey],
            backgroundAudioCacheTaskKeys: [backgroundTaskKey]
        )

        func stagingPath(_ taskKey: String, suffix: String = "") -> String {
            basePath.appendingPathComponent(taskKey).path + suffix + ".offline"
        }
        XCTAssertTrue(protectedPaths.contains(sessionPartial))
        XCTAssertTrue(
            protectedPaths.contains(sessionPartial + CloudPlaybackSource.prewarmMarkerSuffix)
        )
        XCTAssertTrue(protectedPaths.contains(stagingPath(offlineTaskKey)))
        XCTAssertTrue(protectedPaths.contains(stagingPath(offlineTaskKey, suffix: ".refresh")))
        XCTAssertTrue(protectedPaths.contains(stagingPath(backgroundTaskKey)))
        XCTAssertTrue(protectedPaths.contains(stagingPath(backgroundTaskKey, suffix: ".refresh")))
        XCTAssertFalse(protectedPaths.contains(stagingPath("source-a/idle.flac")))
    }

    /// 清缓存在后台要跑好几秒, 期间主 actor 完全可以开新的 streaming session
    /// 或让一次离线下载 pin 成功。删除必须按批复核保护集: 复核之后才受保护
    /// 的文件要留下, 而且不能算成「删除失败」吓用户。
    func testClearAudioCacheHelperRevalidatesProtectionBetweenBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimuseAudioCacheRevalidateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let basePath = root.appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let sourceDirectory = basePath.appendingPathComponent("source-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        var files: [URL] = []
        for index in 0..<3 {
            let url = sourceDirectory.appendingPathComponent("track-\(index).cache")
            try Data(repeating: 4, count: 1024).write(to: url)
            files.append(url)
        }
        let everyPath = Set(files.map(\.path))
        let probe = AudioCacheProtectionRefreshProbe()

        let result = await Task.detached(priority: .utility) { () async -> (Int64, Int) in
            let outcome = await SourceManager.removeUnpinnedAudioCacheFiles(
                dirs: [basePath],
                basePath: basePath,
                removableDirPaths: [],
                pinnedRelativePaths: [],
                protectedAbsolutePaths: [],
                batchSize: 1,
                refreshProtection: {
                    // 第一批删完之后主 actor 又开了播放 / pin: 剩下的全部受保护。
                    let call = await probe.record()
                    let refreshed: Set<String> = call > 1 ? everyPath : []
                    return (pinned: [], protected: refreshed)
                }
            )
            return (outcome.freedBytes, outcome.failedCount)
        }.value

        XCTAssertGreaterThan(result.0, 0)
        XCTAssertEqual(result.1, 0)
        let survivors = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(survivors.count, 2)
        let refreshCount = await probe.count
        XCTAssertEqual(refreshCount, 3)
    }

    /// 「清理半成品」同样要按批复核 —— 点下按钮之后才开始播的那首歌, 它的
    /// `.partial` 不能被这一轮删掉。
    func testPurgePartialHelperRevalidatesProtectionBetweenBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimusePartialPurgeRevalidateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let basePath = root.appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let sourceDirectory = basePath.appendingPathComponent("source-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        var partials: [URL] = []
        for index in 0..<3 {
            let url = sourceDirectory.appendingPathComponent("track-\(index).flac.partial")
            try Data(repeating: 6, count: 1024).write(to: url)
            partials.append(url)
        }
        let everyPath = Set(partials.map(\.path))
        let probe = AudioCacheProtectionRefreshProbe()

        let failed = await Task.detached(priority: .utility) { () async -> Int in
            await SourceManager.removePartialFiles(
                basePath: basePath,
                protectedAbsolutePaths: [],
                batchSize: 1,
                refreshProtection: {
                    let call = await probe.record()
                    let refreshed: Set<String> = call > 1 ? everyPath : []
                    return (pinned: [], protected: refreshed)
                }
            ).failedCount
        }.value

        XCTAssertEqual(failed, 0)
        let survivors = partials.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(survivors.count, 2)
    }

    /// 整源清理必须在主 actor 上只做一次 rename, 递归删除交给后台。
    @MainActor
    func testPurgeAudioCacheStagesDirectoryBeforeDeleting() async throws {
        let sourceID = "purge-staging-\(UUID().uuidString)"
        let cacheRoot = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let sourceDirectory = cacheRoot.appendingPathComponent(sourceID, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        for index in 0..<64 {
            try Data(repeating: 1, count: 256).write(
                to: sourceDirectory.appendingPathComponent("track-\(index).flac")
            )
        }

        let manager = SourceManager(sourcesProvider: { [] })
        manager.deleteSourceCaches(sourceID: sourceID)

        // rename 是同步完成的: 调用返回时规范目录已经离开命名空间。
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.path))

        func stagedEntries() -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
            return names.filter { $0.hasPrefix(".primuse-deleting-\(sourceID)") }
        }
        let deadline = Date().addingTimeInterval(10)
        while !stagedEntries().isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(stagedEntries().isEmpty)
    }

    /// 停用一个源必须停掉它名下的整源离线批量, 而不是只取消扫描:
    /// 此前用户在蜂窝网下关掉源, 剩余歌曲仍会一首接一首继续下载。
    @MainActor
    func testDisablingSourceCancelsWholeSourceOfflineBatch() async throws {
        let sourceID = "offline-disable-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID, name: "Disable fixture", type: .webdav,
            host: "nas.invalid", authType: .none
        )
        let songs = (0..<6).map { index in
            Song(
                id: "\(sourceID)-\(index)", title: "Song \(index)",
                fileFormat: .flac, filePath: "/music/song-\(index).flac",
                sourceID: sourceID, fileSize: 4_096
            )
        }
        let connector = SuspendingOfflineConnector(sourceID: sourceID)
        let manager = SourceManager(
            sourcesProvider: { [source] },
            songsProvider: { songs },
            connectorFactory: { _ in connector }
        )
        defer {
            try? FileManager.default.removeItem(
                at: FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("primuse_audio_cache", isDirectory: true)
                    .appendingPathComponent(sourceID, isDirectory: true)
            )
        }
        // 先把 audio cache scope 校验推到完成, 否则每首歌都会在触到
        // connector 之前就以 sourceUnavailable 结束。
        await manager.ensureOfflineAudioSnapshot(for: songs[0])

        let batch = Task { @MainActor in
            await manager.downloadSourceForOffline(sourceID: sourceID, songs: songs)
        }
        var started = 0
        let deadline = Date().addingTimeInterval(5)
        while started == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            started = await connector.connectAttempts
        }
        guard started > 0 else {
            batch.cancel()
            _ = await batch.value
            throw XCTSkip("离线下载在本环境没有走到 connector, 无法验证取消传播")
        }
        XCTAssertTrue(manager.activeOfflineSourceCacheSourceIDs.contains(sourceID))

        manager.sourceAvailabilityDidChange(sourceID: sourceID, isEnabled: false)

        let result = await batch.value
        XCTAssertEqual(result.completedCount, 0)
        XCTAssertFalse(manager.activeOfflineSourceCacheSourceIDs.contains(sourceID))
        let cancelled = await connector.cancelledCount
        XCTAssertGreaterThan(cancelled, 0)
        // 取消之后不再排新的歌: 并发上限是 2, 不应该把 6 首都跑一遍。
        let attempts = await connector.connectAttempts
        XCTAssertLessThan(attempts, songs.count)
    }

    /// 同一个源第二次「整源缓存」是替换语义 (UI 直接丢掉上一轮的 run):
    /// 旧那一轮必须被取消并排空, 否则它脱离登记表继续下载, 停用源也停不掉;
    /// 同时旧 run 收尾不能提前抹掉「正在缓存」状态, 新那一轮还在跑。
    @MainActor
    func testSecondSourceOfflineBatchReplacesRunningBatch() async throws {
        let sourceID = "offline-replace-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID, name: "Replace fixture", type: .webdav,
            host: "nas.invalid", authType: .none
        )
        let songs = (0..<6).map { index in
            Song(
                id: "\(sourceID)-\(index)", title: "Song \(index)",
                fileFormat: .flac, filePath: "/music/song-\(index).flac",
                sourceID: sourceID, fileSize: 4_096
            )
        }
        let connector = SuspendingOfflineConnector(sourceID: sourceID)
        let manager = SourceManager(
            sourcesProvider: { [source] },
            songsProvider: { songs },
            connectorFactory: { _ in connector }
        )
        defer {
            try? FileManager.default.removeItem(
                at: FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("primuse_audio_cache", isDirectory: true)
                    .appendingPathComponent(sourceID, isDirectory: true)
            )
        }
        await manager.ensureOfflineAudioSnapshot(for: songs[0])

        let first = Task { @MainActor in
            await manager.downloadSourceForOffline(sourceID: sourceID, songs: songs)
        }
        var started = 0
        let deadline = Date().addingTimeInterval(5)
        while started == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            started = await connector.connectAttempts
        }
        guard started > 0 else {
            first.cancel()
            _ = await first.value
            throw XCTSkip("离线下载在本环境没有走到 connector, 无法验证替换语义")
        }
        XCTAssertTrue(manager.activeOfflineSourceCacheSourceIDs.contains(sourceID))

        // 第二轮登记后会取消并等待第一轮退出, 所以 first 只可能因为被替换而返回。
        let second = Task { @MainActor in
            await manager.downloadSourceForOffline(sourceID: sourceID, songs: songs)
        }
        let firstResult = await first.value
        XCTAssertEqual(firstResult.completedCount, 0)
        let cancelledAfterReplacement = await connector.cancelledCount
        XCTAssertGreaterThan(cancelledAfterReplacement, 0)
        // 旧 run 的收尾不能把新 run 的「正在缓存」状态一起抹掉。
        XCTAssertTrue(manager.activeOfflineSourceCacheSourceIDs.contains(sourceID))

        // 登记表里现在是新那一轮, 停用源必须能取消到它。
        manager.sourceAvailabilityDidChange(sourceID: sourceID, isEnabled: false)
        _ = await second.value
        XCTAssertFalse(manager.activeOfflineSourceCacheSourceIDs.contains(sourceID))
    }

    private static func boundedDownloadTemporaryFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("Primuse-HTTPS-") })
    }
}

/// 下载会一直挂着直到被取消的假 connector。
private actor SuspendingOfflineConnector: MusicSourceConnector {
    nonisolated let sourceID: String
    private(set) var connectAttempts = 0
    private(set) var cancelledCount = 0

    init(sourceID: String) { self.sourceID = sourceID }

    func connect() async throws {
        connectAttempts += 1
        do {
            try await Task.sleep(for: .seconds(20))
        } catch {
            cancelledCount += 1
            throw error
        }
        throw SourceError.timeout
    }
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw URLError(.unsupportedURL) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw URLError(.unsupportedURL)
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 记录「每批删除前复核保护集」这个回调被调了几次, 顺便让第一批之后的
/// 复核把剩下的文件全部标成受保护。
private actor AudioCacheProtectionRefreshProbe {
    private(set) var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}

private actor StreamingDownloadCancellationProbe {
    private(set) var wasCancelled = false

    func markCancelled() {
        wasCancelled = true
    }
}

private final class OfflineBoundedDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()

    static func configure(body: Data) {
        lock.withLock { responseBody = body }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.lock.withLock { Self.responseBody }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class LibrarySearchNavigationTests: XCTestCase {
    func testLeavingParentDoesNotClearTheNewFolder() {
        let navigation = LibrarySearchNavigation()
        let parent = UUID()
        let child = UUID()
        let childScope = LibrarySearchScope(title: "Disc", songIDs: ["disc-song"], includesSubfolders: true)
        navigation.register(owner: parent, tab: 1) {
            LibrarySearchScope(title: "Album", songIDs: ["disc-song", "album-song"])
        }
        navigation.register(owner: child, tab: 1) { childScope }
        navigation.remove(owner: parent)
        XCTAssertEqual(navigation.scope(for: 1), childScope)
        navigation.remove(owner: child)
        XCTAssertNil(navigation.scope(for: 1))
    }

    func testScopeIsResolvedWhenSearchOpensAndIsolatedByTab() {
        let navigation = LibrarySearchNavigation()
        var songs: Set<String> = ["first"]
        let owner = UUID()
        navigation.register(owner: owner, tab: 1) {
            LibrarySearchScope(title: "Playlist", songIDs: songs)
        }
        songs.insert("new")
        let captured = navigation.scope(for: 1)
        navigation.remove(owner: owner)
        XCTAssertEqual(captured?.songIDs, ["first", "new"])
        XCTAssertNil(navigation.scope(for: 0))
        XCTAssertNil(navigation.scope(for: 1))
        XCTAssertNil(navigation.scope(for: 3))
    }

    func testDirectoryOverviewKeepsGlobalSearch() {
        let navigation = LibrarySearchNavigation()
        navigation.register(owner: UUID(), tab: 1) { nil }
        XCTAssertNil(navigation.scope(for: 1))
    }

    func testHomeAndSettingsNeverCaptureScopesEvenWithLibraryDetailPages() {
        let navigation = LibrarySearchNavigation()
        for tab in [0, 1, 2, 3] {
            navigation.register(owner: UUID(), tab: tab) {
                LibrarySearchScope(title: "Album", songIDs: ["song"], kind: .album)
            }
        }
        XCTAssertNotNil(navigation.scope(for: 1))
        for tab in [0, 2, 3] {
            XCTAssertNil(navigation.scope(for: tab))
        }
    }

    func testReturningToLibraryRootClearsThePreviousDetailScope() {
        let navigation = LibrarySearchNavigation()
        let detail = UUID()
        navigation.register(owner: detail, tab: 1) {
            LibrarySearchScope(title: "Playlist", songIDs: ["song"])
        }
        navigation.remove(owner: detail)
        XCTAssertNil(navigation.scope(for: 1))
    }

    func testReturningToParentRestoresItsScope() {
        let navigation = LibrarySearchNavigation()
        let parent = UUID()
        let child = UUID()
        navigation.register(owner: parent, tab: 1) { LibrarySearchScope(title: "Parent", songIDs: ["a", "b"]) }
        navigation.register(owner: child, tab: 1) { LibrarySearchScope(title: "Child", songIDs: ["b"]) }
        navigation.remove(owner: child)
        XCTAssertEqual(navigation.scope(for: 1)?.songIDs, ["a", "b"])
    }
}

/// 主 actor 心跳: 只要主 actor 还能被调度, `ticks` 就会增长。用来证明某段
/// 阻塞工作确实没有占着主 actor —— 比在异步上下文里看线程身份更贴近契约。
@MainActor
private final class MainActorHeartbeat {
    private(set) var ticks = 0
    private var isStopped = false

    func run() async {
        // 上限只是防止调用方忘记 stop 时空转, 正常路径由 `stop()` 结束。
        while !isStopped, ticks < 1_000_000 {
            ticks += 1
            await Task.yield()
        }
    }

    func stop() { isStopped = true }
}
