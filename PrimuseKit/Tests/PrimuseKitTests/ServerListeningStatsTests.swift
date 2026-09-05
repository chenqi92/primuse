import Foundation
import Testing
@testable import PrimuseKit

struct ServerListeningStatsTests {
    @Test func capabilityMatrixOnlyEnablesSourcesWithReliableReadEndpoints() {
        for type in [MusicSourceType.subsonic, .navidrome, .airsonic, .gonic, .jellyfin, .emby] {
            #expect(type.serverListeningStatsCapability == .aggregate)
        }
        #expect(MusicSourceType.plex.serverListeningStatsCapability == .eventHistoryWithAggregateFallback)

        for type in MusicSourceType.allCases where ![
            .subsonic, .navidrome, .airsonic, .gonic, .jellyfin, .emby, .plex,
        ].contains(type) {
            #expect(type.serverListeningStatsCapability == .unavailable)
        }
    }

    @Test func aggregatePayloadForcesAllTimeAndOmitsInventedDimensions() throws {
        let recent = Date(timeIntervalSince1970: 2_000)
        let payload = ServerListeningStatsPayload(
            accountFingerprint: "account-a",
            temporalDetail: .aggregate,
            tracks: [
                .init(remoteTrackID: "1", title: "One", artist: "Artist", album: "Album", playCount: 3),
                .init(remoteTrackID: "2", title: "Two", artist: "Artist", album: "Album", playCount: 2, lastPlayedAt: recent),
                .init(remoteTrackID: "3", title: "Never", playCount: 0),
            ]
        )

        let result = try #require(ServerListeningStatsPresentationBuilder.build(
            payload: payload,
            range: .week
        ))
        #expect(result.appliedRange == .all)
        #expect(result.totalPlays == 5)
        #expect(result.uniqueTracks == 2)
        #expect(result.lastPlayedAt == recent)
        #expect(result.activeDays == nil)
        #expect(result.totalListenedSeconds == nil)
        #expect(result.dailyCounts.isEmpty)
        #expect(result.topTracks.map(\.title) == ["One", "Two"])
        #expect(result.topArtists.first?.playCount == 5)
    }

    @Test func eventPayloadFiltersCalendarWeekAndNeverInventsPlexDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 12
        )))
        let inside = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let outside = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let payload = ServerListeningStatsPayload(
            accountFingerprint: "plex-account",
            temporalDetail: .events,
            events: [
                .init(id: "a", remoteTrackID: "1", title: "One", playedAt: now),
                .init(id: "b", remoteTrackID: "1", title: "One", playedAt: inside),
                .init(id: "c", remoteTrackID: "2", title: "Two", playedAt: outside),
            ]
        )

        let result = try #require(ServerListeningStatsPresentationBuilder.build(
            payload: payload,
            range: .week,
            now: now,
            calendar: calendar
        ))
        #expect(result.totalPlays == 2)
        #expect(result.uniqueTracks == 1)
        #expect(result.activeDays == 2)
        #expect(result.totalListenedSeconds == nil)
        #expect(result.dailyCounts.map(\.playCount) == [1, 1])
    }

    @Test func calendarMonthAndLeapYearIncludeTheirFirstDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31, hour: 12)))
        for range in [ServerListeningStatsRange.month, .year] {
            let first = try #require(calendar.date(from: DateComponents(
                year: 2024, month: range == .month ? 12 : 1, day: 1
            )))
            let payload = ServerListeningStatsPayload(accountFingerprint: "test", temporalDetail: .events, events: [
                .init(id: "before", remoteTrackID: "before", title: "Before", playedAt: first.addingTimeInterval(-1)),
                .init(id: "first", remoteTrackID: "first", title: "First", playedAt: first),
                .init(id: "now", remoteTrackID: "now", title: "Now", playedAt: now),
                .init(id: "future", remoteTrackID: "future", title: "Future", playedAt: now.addingTimeInterval(3600))
            ])
            let result = try #require(ServerListeningStatsPresentationBuilder.build(
                payload: payload, range: range, now: now, calendar: calendar
            ))
            #expect(result.totalPlays == 2)
            #expect(result.dailyCounts.first?.date == first)
            #expect(Set(result.topTracks.map(\.title)) == ["First", "Now"])
        }
    }

    @Test func actualDurationRequiresEveryEventToCarryServerDuration() {
        let invalid = ServerListeningStatsPayload(
            accountFingerprint: "future-service",
            temporalDetail: .events,
            durationAvailability: .actual,
            events: [
                .init(id: "a", remoteTrackID: "1", title: "One", playedAt: Date()),
            ]
        )
        #expect(!invalid.isStructurallyValid)
        #expect(ServerListeningStatsPresentationBuilder.build(payload: invalid, range: .all) == nil)
    }

    @Test func configurationFingerprintSeparatesSourcesAndIgnoresScanState() {
        let editedAt = Date(timeIntervalSince1970: 123)
        let base = MusicSource(
            id: "source-a",
            name: "Server",
            type: .navidrome,
            host: "music.example.com",
            username: "alice",
            lastScannedAt: Date(timeIntervalSince1970: 10),
            songCount: 10,
            modifiedAt: editedAt
        )
        var scanChanged = base
        scanChanged.lastScannedAt = Date(timeIntervalSince1970: 20)
        scanChanged.songCount = 99
        var accountChanged = base
        accountChanged.username = "bob"
        var sourceChanged = base
        sourceChanged.id = "source-b"

        #expect(ServerListeningStatsFingerprint.configuration(for: base)
            == ServerListeningStatsFingerprint.configuration(for: scanChanged))
        #expect(ServerListeningStatsFingerprint.configuration(for: base)
            != ServerListeningStatsFingerprint.configuration(for: accountChanged))
        #expect(ServerListeningStatsFingerprint.configuration(for: base)
            != ServerListeningStatsFingerprint.configuration(for: sourceChanged))
    }

    @Test func snapshotRejectsWrongConfigurationAndUnsupportedSource() {
        let source = MusicSource(
            id: "server",
            name: "Server",
            type: .jellyfin,
            host: "example.com",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let payload = ServerListeningStatsPayload(
            accountFingerprint: "account",
            temporalDetail: .aggregate
        )
        let snapshot = ServerListeningStatsSnapshot(
            sourceID: source.id,
            sourceType: source.type,
            configurationFingerprint: ServerListeningStatsFingerprint.configuration(for: source),
            fetchedAt: Date(),
            payload: payload
        )
        #expect(snapshot.isValid(for: source))

        var edited = source
        edited.username = "another"
        #expect(!snapshot.isValid(for: edited))

        let unsupported = MusicSource(id: "local", name: "Local", type: .local)
        let unsupportedSnapshot = ServerListeningStatsSnapshot(
            sourceID: unsupported.id,
            sourceType: unsupported.type,
            configurationFingerprint: ServerListeningStatsFingerprint.configuration(for: unsupported),
            fetchedAt: Date(),
            payload: payload
        )
        #expect(!unsupportedSnapshot.isValid(for: unsupported))
    }
}
