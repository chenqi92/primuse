import Foundation
import Testing
@testable import PrimuseKit

@Suite("Song details state")
struct SongDetailsStateTests {
    @Test("Dynamic STRM remains playable with unknown duration")
    func dynamicStreamIsIncompleteInsteadOfFailed() {
        #expect(SongDetailsState.resolve(
            duration: 0,
            isStandaloneMusicVideo: false,
            isPlayable: true,
            isReading: false,
            isWaitingForSource: false,
            isIncomplete: true,
            hasConfirmedFailure: false
        ) == .playableIncomplete)
    }

    @Test("Disconnected source recovers back to reading")
    func sourceRecovery() {
        let waiting = SongDetailsState.resolve(
            duration: 0,
            isStandaloneMusicVideo: false,
            isPlayable: true,
            isReading: false,
            isWaitingForSource: true,
            isIncomplete: false,
            hasConfirmedFailure: false
        )
        let recovered = SongDetailsState.resolve(
            duration: 0,
            isStandaloneMusicVideo: false,
            isPlayable: true,
            isReading: true,
            isWaitingForSource: false,
            isIncomplete: false,
            hasConfirmedFailure: false
        )

        #expect(waiting == .waitingForSource)
        #expect(recovered == .reading)
    }

    @Test("Confirmed parser failure does not masquerade as loading")
    func confirmedParserFailure() {
        #expect(SongDetailsState.resolve(
            duration: 0,
            isStandaloneMusicVideo: false,
            isPlayable: true,
            isReading: false,
            isWaitingForSource: false,
            isIncomplete: false,
            hasConfirmedFailure: true
        ) == .confirmedFailure)
    }

    @Test("Completed duration always clears stale failure state")
    func completedDurationWins() {
        #expect(SongDetailsState.resolve(
            duration: 180,
            isStandaloneMusicVideo: false,
            isPlayable: true,
            isReading: false,
            isWaitingForSource: true,
            isIncomplete: true,
            hasConfirmedFailure: true
        ) == .ready)
    }
}

@Suite("Backfill state policies")
struct BackfillStatePolicyTests {
    @Test("Unknown duration can complete independently from title inspection")
    func independentInspectionLegs() {
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 0,
            format: .dts,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            durationInspectionComplete: true
        ))
        #expect(MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 0,
            format: .dts,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: false,
            durationInspectionComplete: true
        ))
    }

    @Test("Cancellation does not consume a transient retry")
    func cancellationIsNeutral() {
        #expect(!MetadataBackfillRetryPolicy.shouldCountTransientFailure(
            isCancellation: true,
            isTransient: true
        ))
        #expect(MetadataBackfillRetryPolicy.shouldCountTransientFailure(
            isCancellation: false,
            isTransient: true
        ))
    }
}

@Suite("User metadata protection")
struct SongUserMetadataPolicyTests {
    @Test("Background technical refresh preserves explicit tag edits")
    func preservesUserIdentityAndRefreshesDuration() {
        var existing = song(title: "手工标题", duration: 0)
        existing.artistName = "手工艺术家"
        existing.albumArtistName = "旧专辑艺术家"
        existing.userMetadataEditedAt = Date(timeIntervalSince1970: 1_750_000_000)

        var incoming = song(title: "源标题", duration: 192)
        incoming.artistName = "源艺术家"
        incoming.albumArtistName = "新专辑艺术家"
        incoming.bitRate = 320

        let merged = SongUserMetadataPolicy.preservingUserEdits(
            from: existing,
            in: incoming
        )
        #expect(merged.title == "手工标题")
        #expect(merged.artistName == "手工艺术家")
        #expect(merged.albumArtistName == "旧专辑艺术家")
        #expect(merged.duration == 192)
        #expect(merged.bitRate == 320)
        #expect(merged.userMetadataEditedAt == existing.userMetadataEditedAt)
    }

    @Test("Background refresh fills album artist for legacy edited songs")
    func fillsLegacyAlbumArtistWithoutReplacingUserArtist() {
        var existing = song(title: "手工标题", duration: 0)
        existing.artistName = "手工艺术家"
        existing.userMetadataEditedAt = Date(timeIntervalSince1970: 1_750_000_000)

        var incoming = song(title: "源标题", duration: 192)
        incoming.artistName = "源艺术家"
        incoming.albumArtistName = "源专辑艺术家"

        let merged = SongUserMetadataPolicy.preservingUserEdits(
            from: existing,
            in: incoming
        )
        #expect(merged.artistName == "手工艺术家")
        #expect(merged.albumArtistName == "源专辑艺术家")
    }

    private func song(title: String, duration: TimeInterval) -> Song {
        Song(
            id: "song",
            title: title,
            duration: duration,
            fileFormat: .mp3,
            filePath: "/song.mp3",
            sourceID: "source",
            fileSize: 1_024
        )
    }
}
