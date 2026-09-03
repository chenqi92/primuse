import Foundation
import Observation
import PrimuseKit
import XCTest
import SwiftUI
@testable import Primuse

final class LibraryDisplayConfigurationTests: XCTestCase {
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
            [.recommendations, .albums, .songs, .artists, .playlists, .radio]
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

    func testMinimalLibraryPagesFollowVisibleSectionOrder() {
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(
                visibleSections: [.songs, .albums, .radio]
            ),
            [
                .librarySection(.recommendations),
                .librarySection(.songs),
                .librarySection(.albums),
                .librarySection(.radio),
            ]
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(visibleSections: []),
            [.librarySection(.recommendations)]
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.libraryPages(
                visibleSections: [.songs, .recommendations, .albums]
            ),
            [
                .librarySection(.recommendations),
                .librarySection(.songs),
                .librarySection(.albums),
            ]
        )
    }

    func testMinimalSelectionUsesRecommendationsAsItsHomePage() {
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 0,
                activeLibrarySection: nil
            ),
            .librarySection(.recommendations)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: .artists
            ),
            .librarySection(.artists)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 1,
                activeLibrarySection: nil
            ),
            .librarySection(.recommendations)
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 2,
                activeLibrarySection: .songs
            ),
            .search
        )
        XCTAssertEqual(
            MinimalNavigationPolicy.selectedPage(
                selectedTab: 99,
                activeLibrarySection: nil
            ),
            .librarySection(.recommendations)
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
        await manager.refreshConnector(for: sourceID)
        XCTAssertFalse(
            manager.connector(for: source) is NoAvailableConnectionSourceConnector
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

    private static func boundedDownloadTemporaryFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("Primuse-HTTPS-") })
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
