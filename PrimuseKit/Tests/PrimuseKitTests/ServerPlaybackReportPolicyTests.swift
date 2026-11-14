import Foundation
import Testing
@testable import PrimuseKit

@Suite("Server playback report sources")
struct ServerPlaybackReportSourceTests {
    @Test func everyServerLibraryReportsPlayedTracks() {
        for type in [MusicSourceType.subsonic, .navidrome, .airsonic, .gonic,
                     .songloft, .fnMusic, .daoliyu, .jellyfin, .emby, .plex] {
            #expect(ServerPlaybackReportPolicy.supportsPlayedReport(type), "\(type)")
        }
        for type in [MusicSourceType.synologyAudioStation, .audiobookshelf, .tingReader,
                     .webdav, .smb, .synology, .upnp] {
            #expect(!ServerPlaybackReportPolicy.supportsPlayedReport(type), "\(type)")
        }
    }

    /// Jellyfin / Emby 的开始播放会自己记一次,Plex 的进度回报不能只报开头。
    @Test func nowPlayingOnlyWhereItDoesNotCountAPlay() {
        for type in [MusicSourceType.subsonic, .navidrome, .airsonic, .gonic, .songloft] {
            #expect(ServerPlaybackReportPolicy.supportsNowPlayingReport(type), "\(type)")
        }
        for type in [MusicSourceType.jellyfin, .emby, .plex, .fnMusic, .daoliyu] {
            #expect(!ServerPlaybackReportPolicy.supportsNowPlayingReport(type), "\(type)")
        }
    }
}

@Suite("Server playback report timing")
struct ServerPlaybackReportTimingTests {
    private func reports(
        _ moment: ServerPlaybackReportMoment,
        _ type: MusicSourceType,
        spoken: Bool,
        musicSwitch: Bool = true
    ) -> Bool {
        ServerPlaybackReportPolicy.reports(moment, sourceType: type, isSpokenWord: spoken, musicReportingEnabled: musicSwitch)
    }

    @Test("音乐看开关，听够一半报已播放，听完不另报")
    func musicFollowsTheSwitch() {
        #expect(reports(.started, .navidrome, spoken: false))
        #expect(reports(.listenedEnough, .navidrome, spoken: false))
        #expect(reports(.listenedEnough, .jellyfin, spoken: false))
        #expect(!reports(.finished, .jellyfin, spoken: false))
        #expect(!reports(.started, .navidrome, spoken: false, musicSwitch: false))
        #expect(!reports(.listenedEnough, .plex, spoken: false, musicSwitch: false))
    }

    @Test("有声内容不看开关，一律回传")
    func spokenWordIgnoresTheMusicSwitch() {
        #expect(reports(.started, .navidrome, spoken: true, musicSwitch: false))
        #expect(reports(.listenedEnough, .navidrome, spoken: true, musicSwitch: false))
        #expect(reports(.finished, .emby, spoken: true, musicSwitch: false))
    }

    @Test("Jellyfin、Emby、Plex 上的有声内容等这个文件听完才报，免得清掉续播位置")
    func mediaServersMarkSpokenWordPlayedOnlyWhenFinished() {
        for type in [MusicSourceType.jellyfin, .emby, .plex] {
            #expect(!reports(.started, type, spoken: true), "\(type)")
            #expect(!reports(.listenedEnough, type, spoken: true), "\(type)")
            #expect(reports(.finished, type, spoken: true), "\(type)")
        }
        for type in [MusicSourceType.navidrome, .subsonic, .songloft, .fnMusic, .daoliyu] {
            #expect(reports(.listenedEnough, type, spoken: true), "\(type)")
            #expect(!reports(.finished, type, spoken: true), "\(type)")
        }
    }

    @Test("没有回报接口的源什么时候都不报")
    func sourcesWithoutReportsNeverReport() {
        for moment in [ServerPlaybackReportMoment.started, .listenedEnough, .finished] {
            #expect(!reports(moment, .audiobookshelf, spoken: true))
            #expect(!reports(moment, .webdav, spoken: false))
        }
        #expect(!reports(.started, .fnMusic, spoken: false))
    }
}

@Suite("Server playback report requests")
struct ServerPlaybackReportRequestTests {
    /// 2026-11-14 08:30:05.250 UTC
    private let playedAt = Date(timeIntervalSince1970: 1_794_645_005.25)

    private func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }

    @Test func subsonicPlayedCarriesListenTimeInMilliseconds() {
        let items = SubsonicScrobbleRequest.queryItems(songID: "song-1", submission: true, playedAt: playedAt)
        #expect(value("id", in: items) == "song-1")
        #expect(value("submission", in: items) == "true")
        #expect(value("time", in: items) == "1794645005250")
    }

    @Test func subsonicNowPlayingHasNoTime() {
        let items = SubsonicScrobbleRequest.queryItems(songID: "song-1", submission: false, playedAt: playedAt)
        #expect(value("submission", in: items) == "false")
        #expect(value("time", in: items) == nil)
    }

    @Test func jellyfinPlayedUsesISODateSoThePlayCountGoesUp() {
        let request = MediaServerPlaybackReportRequest.jellyfinPlayed(userID: "user-1", itemID: "item-9", playedAt: playedAt)
        #expect(request.method == "POST")
        #expect(request.path == "/Users/user-1/PlayedItems/item-9")
        #expect(request.queryItems == [URLQueryItem(name: "datePlayed", value: "2026-11-14T08:30:05Z")])
    }

    @Test func jellyfinFallbackUsesUserPlayedItems() {
        let request = MediaServerPlaybackReportRequest.jellyfinUserPlayedItem(userID: "user-1", itemID: "item-9", playedAt: playedAt)
        #expect(request.method == "POST")
        #expect(request.path == "/UserPlayedItems/item-9")
        #expect(value("userId", in: request.queryItems) == "user-1")
        #expect(value("datePlayed", in: request.queryItems) == "2026-11-14T08:30:05Z")
    }

    @Test func embyPlayedUsesItsCompactUTCDate() {
        let request = MediaServerPlaybackReportRequest.embyPlayed(userID: "7", itemID: "4512", playedAt: playedAt)
        #expect(request.method == "POST")
        #expect(request.path == "/Users/7/PlayedItems/4512")
        #expect(request.queryItems == [URLQueryItem(name: "DatePlayed", value: "20261114083005")])
    }

    @Test func plexScrobbleMarksTheTrackPlayed() {
        let request = MediaServerPlaybackReportRequest.plexScrobble(ratingKey: "345")
        #expect(request.method == "GET")
        #expect(request.path == "/:/scrobble")
        #expect(request.queryItems == [
            URLQueryItem(name: "key", value: "345"),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    @Test func datesStayInUTCWhateverTheDeviceZone() {
        #expect(ServerPlaybackReportTime.embyCompact(Date(timeIntervalSince1970: 0)) == "19700101000000")
        #expect(ServerPlaybackReportTime.iso8601(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        #expect(ServerPlaybackReportTime.millisecondsSince1970(Date(timeIntervalSince1970: -5)) == 0)
    }
}

@Suite("Server playback report failures")
struct ServerPlaybackReportFailureTests {
    @Test func serverHiccupsWaitButRefusalsAreDropped() {
        for status in [408, 429, 500, 502, 503, 504] {
            #expect(ServerPlaybackReportFailurePolicy.disposition(httpStatus: status) == .retryLater, "\(status)")
        }
        for status in [400, 401, 403, 404, 405, 409, 410, 422] {
            #expect(ServerPlaybackReportFailurePolicy.disposition(httpStatus: status) == .drop, "\(status)")
        }
    }

    @Test func networkProblemsWait() {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotConnectToHost,
                     .cannotFindHost, .networkConnectionLost, .dataNotAllowed,
                     .secureConnectionFailed, .cancelled] {
            #expect(ServerPlaybackReportFailurePolicy.disposition(urlErrorCode: code.rawValue) == .retryLater, "\(code)")
        }
        for code in [URLError.Code.badURL, .unsupportedURL, .userAuthenticationRequired,
                     .appTransportSecurityRequiresSecureConnection] {
            #expect(ServerPlaybackReportFailurePolicy.disposition(urlErrorCode: code.rawValue) == .drop, "\(code)")
        }
    }
}

@Suite("Pending server playback report queue")
struct PendingServerPlaybackReportQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(_ source: String = "source-a", minutesAgo: Double, id: UUID = UUID()) -> PendingServerPlaybackReport {
        PendingServerPlaybackReport(
            id: id,
            sourceID: source,
            songID: "song",
            songPath: "/songs/1.flac",
            playedAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    @Test func keepsAMonthAndDropsClockSkewedEntries() {
        let day: Double = 24 * 60
        let fresh = report(minutesAgo: 29 * day)
        let stale = report(minutesAgo: 31 * day)
        let future = report(minutesAgo: -2 * day)
        let nearFuture = report(minutesAgo: -60)
        let kept = PendingServerPlaybackReportQueuePolicy.retained([stale, fresh, future, nearFuture], now: now)
        #expect(kept.map(\.id) == [fresh.id, nearFuture.id])
    }

    @Test func capKeepsTheNewestAndOrdersOldestFirst() {
        let limit = PendingServerPlaybackReportQueuePolicy.maximumEntries
        var entries: [PendingServerPlaybackReport] = []
        for index in 0..<limit {
            entries = PendingServerPlaybackReportQueuePolicy.adding(
                report(minutesAgo: Double(limit - index + 10)),
                to: entries,
                now: now
            )
        }
        let oldest = entries.first
        let newest = report(minutesAgo: 1)
        entries = PendingServerPlaybackReportQueuePolicy.adding(newest, to: entries, now: now)
        #expect(entries.count == limit)
        #expect(entries.last == newest)
        #expect(!entries.contains(where: { $0.id == oldest?.id }))
        #expect(entries == entries.sorted { $0.playedAt < $1.playedAt })
    }

    @Test func duplicateIDsAreKeptOnce() {
        let id = UUID()
        let kept = PendingServerPlaybackReportQueuePolicy.retained(
            [report(minutesAgo: 5, id: id), report(minutesAgo: 4, id: id)],
            now: now
        )
        #expect(kept.count == 1)
    }

    @Test func refusalIsDroppedAndUnreachableSourceNeverCounts() {
        let pending = report(minutesAgo: 3)
        #expect(PendingServerPlaybackReportQueuePolicy.afterFailure(
            pending, disposition: .drop, sourceReachable: false
        ) == nil)
        var current = pending
        for _ in 0..<50 {
            current = PendingServerPlaybackReportQueuePolicy.afterFailure(
                current, disposition: .retryLater, sourceReachable: false
            ) ?? current
        }
        #expect(current == pending)
    }

    /// 源连得上、这一条却一直送不到:到上限放弃,不让它一直堵在队头。
    @Test func entryThatKeepsFailingOnAReachableSourceIsGivenUp() {
        var current: PendingServerPlaybackReport? = report(minutesAgo: 3)
        var attempts = 0
        while let entry = current {
            current = PendingServerPlaybackReportQueuePolicy.afterFailure(
                entry, disposition: .retryLater, sourceReachable: true
            )
            attempts += 1
            #expect(attempts <= PendingServerPlaybackReportQueuePolicy.maximumFailedAttempts)
        }
        #expect(attempts == PendingServerPlaybackReportQueuePolicy.maximumFailedAttempts)
    }

    @Test func deliveryStartsWithTheOldestListenOfEachSource() {
        let a1 = report("source-a", minutesAgo: 50)
        let b1 = report("source-b", minutesAgo: 40)
        let a2 = report("source-a", minutesAgo: 30)
        let b2 = report("source-b", minutesAgo: 20)
        let plan = PendingServerPlaybackReportQueuePolicy.deliveryPlan([b2, a2, b1, a1])
        #expect(plan.map(\.sourceID) == ["source-a", "source-b"])
        #expect(plan[0].reports == [a1, a2])
        #expect(plan[1].reports == [b1, b2])
    }

    @Test func survivesAJSONRoundTrip() throws {
        let original = report(minutesAgo: 7)
        let decoded = try JSONDecoder().decode(
            PendingServerPlaybackReport.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }
}
