import Foundation
import MusicKit
import PrimuseKit

/// The SDK owns authorization and transport. The importer only sees a page and
/// its continuation, so cancellation/pagination can be tested without a live account.
struct AppleMusicPlaylistPage: Sendable {
    let name: String
    let tracks: [ExternalPlaylistTrack]
    var next: (@Sendable () async throws -> AppleMusicPlaylistPage?)?

    static func load(id: String) async throws -> AppleMusicPlaylistPage {
        if MusicAuthorization.currentStatus != .authorized {
            guard await MusicAuthorization.request() == .authorized else {
                throw ExternalPlaylistFetcher.FetchError.appleMusicNotAuthorized
            }
        }
        var request = MusicCatalogResourceRequest<MusicKit.Playlist>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.tracks]
        let response = try await request.response()
        guard let playlist = response.items.first else { throw ExternalPlaylistFetcher.FetchError.notFoundOrPrivate }
        return page(name: playlist.name, batch: playlist.tracks)
    }

    private static func page(name: String, batch: MusicItemCollection<Track>?) -> AppleMusicPlaylistPage {
        let tracks = (batch.map(Array.init) ?? []).map { track in
            ExternalPlaylistTrack(title: track.title, artists: [track.artistName],
                album: track.albumTitle, duration: track.duration, externalID: track.id.rawValue)
        }
        var result = AppleMusicPlaylistPage(name: name, tracks: tracks)
        if let batch, batch.hasNextBatch {
            result.next = {
                guard let next = try await batch.nextBatch() else { return nil }
                return page(name: name, batch: next)
            }
        }
        return result
    }
}

/// 按分享链接读取其他音乐 App 的公开歌单(只取歌名、歌手、专辑、时长)。
/// 链接识别、请求与响应格式都在 Kit 的 `ExternalPlaylistImport.swift` 里。
struct ExternalPlaylistFetcher: Sendable {
    private let session: URLSession
    private let appleMusicPage: @Sendable (String) async throws -> AppleMusicPlaylistPage
    private let quotaRegistry: RequestQuotaRegistry
    private static let service = RequestQuota.Service(id: "playlist.public-http", policy: .init(
        maximumConcurrentRequests: 2, maximumAttempts: 2, timeout: 60
    ))

    init(session: URLSession = .shared, quotaRegistry: RequestQuotaRegistry = .shared,
         appleMusicPage: @escaping @Sendable (String) async throws -> AppleMusicPlaylistPage = AppleMusicPlaylistPage.load) {
        self.session = session
        self.appleMusicPage = appleMusicPage
        self.quotaRegistry = quotaRegistry
    }

    static func fetch(sharedText text: String, session: URLSession = .shared) async throws -> ExternalPlaylist {
        try await Self(session: session).fetch(sharedText: text)
    }

    enum FetchError: LocalizedError {
        case unrecognizedLink
        case notFoundOrPrivate
        case unexpectedResponse
        case empty
        case discontinued
        case appleMusicNotAuthorized
        case network(String)

        init(_ error: ExternalPlaylistError) {
            switch error {
            case .unrecognizedLink: self = .unrecognizedLink
            case .notFoundOrPrivate: self = .notFoundOrPrivate
            case .unexpectedResponse: self = .unexpectedResponse
            case .empty: self = .empty
            case .discontinued: self = .discontinued
            }
        }

        var errorDescription: String? {
            switch self {
            case .unrecognizedLink: String(localized: "playlist_import_link_err_unrecognized")
            case .notFoundOrPrivate: String(localized: "playlist_import_link_err_private")
            case .unexpectedResponse: String(localized: "playlist_import_link_err_changed")
            case .empty: String(localized: "playlist_import_err_empty")
            case .discontinued: String(localized: "playlist_import_link_err_discontinued")
            case .appleMusicNotAuthorized: String(localized: "playlist_import_link_err_apple_music_auth")
            case .network(let message):
                String(format: String(localized: "playlist_import_link_err_network_format"), message)
            }
        }
    }

    /// 歌单过大时的上限，防止一个异常响应把分页循环拖成几千次请求。
    static let maximumTracks = 10_000

    func fetch(sharedText text: String) async throws -> ExternalPlaylist {
        do {
            return try await fetchPlaylist(sharedText: text)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as HTTPResponseFailure {
            if failure.isRateLimited || failure.statusCode == 429 || failure.retryAfter != nil {
                throw failure // The common error supplies localized quota and wait text.
            }
            if [403, 404].contains(failure.statusCode) { throw FetchError.notFoundOrPrivate }
            throw FetchError.network(failure.localizedDescription)
        } catch let error as FetchError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw FetchError.network(error.localizedDescription)
        }
    }

    private func fetchPlaylist(sharedText text: String) async throws -> ExternalPlaylist {
        try Task.checkCancellation()
        var detection = ExternalPlaylistLink.detect(in: text)
        // 短链接最多跟两次（有的平台短链先跳一个中转页）。跳完仍认不出就当作不支持。
        for _ in 0..<2 {
            guard case .needsRedirect(let url, _) = detection else { break }
            let resolved = try await resolveRedirect(url)
            guard resolved != url else { break }
            detection = ExternalPlaylistLink.detect(url: resolved)
        }
        if detection == .discontinued { throw FetchError.discontinued }
        guard case .playlist(let link) = detection else { throw FetchError.unrecognizedLink }

        do {
            let playlist: ExternalPlaylist
            switch link.platform {
            case .netease:
                playlist = try await fetchNetEase(id: link.playlistID)
            case .qqMusic:
                playlist = try await fetchQQ(id: link.playlistID)
            case .kuwo:
                playlist = try await fetchKuwo(id: link.playlistID, platform: .kuwo)
            case .bodian:
                playlist = try await fetchBodian(link)
            case .kugou:
                playlist = try await fetchKugou(link)
            case .migu:
                playlist = try await fetchMigu(id: link.playlistID)
            case .soda:
                playlist = try await fetchSoda(id: link.playlistID)
            case .appleMusic:
                playlist = try await fetchAppleMusic(id: link.playlistID)
            case .spotify:
                playlist = try await fetchSpotify(id: link.playlistID)
            case .deezer:
                playlist = try await fetchDeezer(id: link.playlistID)
            case .bilibili:
                playlist = link.parameters["kind"] == "fav"
                    ? try await fetchBilibiliFavorites(id: link.playlistID)
                    : try await fetchBilibiliMenu(id: link.playlistID)
            case .youtube:
                playlist = try await fetchYouTube(id: link.playlistID)
            }
            try Task.checkCancellation()
            guard !playlist.tracks.isEmpty else { throw FetchError.empty }
            return playlist
        } catch let error as ExternalPlaylistError {
            throw FetchError(error)
        }
    }

    // MARK: - Platforms

    private func fetchNetEase(id: String) async throws -> ExternalPlaylist {
        let detail = try ExternalPlaylistDecoder.netEasePlaylist(
            try await data(for: ExternalPlaylistRequests.netEasePlaylist(id: id))
        )
        var tracksByID = detail.tracksByID
        let missing = detail.trackIDs.prefix(Self.maximumTracks).filter { tracksByID[$0] == nil }
        var start = missing.startIndex
        while start < missing.endIndex {
            try Task.checkCancellation()
            let end = missing.index(start, offsetBy: ExternalPlaylistRequests.netEaseSongDetailBatchSize, limitedBy: missing.endIndex) ?? missing.endIndex
            let batch = Array(missing[start..<end])
            let details = try ExternalPlaylistDecoder.netEaseSongDetails(
                try await data(for: ExternalPlaylistRequests.netEaseSongDetails(ids: batch))
            )
            tracksByID.merge(details) { current, _ in current }
            start = end
        }
        let tracks = detail.trackIDs.prefix(Self.maximumTracks).compactMap { tracksByID[$0] }
        return ExternalPlaylist(name: detail.name, platform: .netease, tracks: tracks)
    }

    private func fetchQQ(id: String) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var name = ""
        var begin = 0
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let page = try ExternalPlaylistDecoder.qqPlaylistPage(
                try await data(for: ExternalPlaylistRequests.qqPlaylist(id: id, begin: begin))
            )
            if name.isEmpty { name = page.name }
            tracks.append(contentsOf: page.tracks)
            begin += page.tracks.count
            guard !page.tracks.isEmpty, begin < page.total else { break }
        }
        return ExternalPlaylist(name: name, platform: .qqMusic, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    private func fetchKuwo(
        id: String,
        platform: ExternalPlaylistPlatform
    ) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var name = ""
        var page = 0
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.kuwoPlaylistPage(
                try await data(for: ExternalPlaylistRequests.kuwoPlaylist(id: id, page: page))
            )
            if name.isEmpty { name = result.name }
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        return ExternalPlaylist(name: name, platform: platform, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    /// 波点请求要带一个设备号，匿名随机即可；同一次运行内保持不变。
    private static let bodianDeviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private func fetchBodian(_ link: ExternalPlaylistLink) async throws -> ExternalPlaylist {
        // 链接里没写 source 时两种都试：5 = 波点自建歌单，4 = 从酷我同步来的。
        let sources = link.parameters["source"].map { [$0] } ?? ["5", "4"]
        for source in sources {
            var tracks: [ExternalPlaylistTrack] = []
            var page = 1
            while tracks.count < Self.maximumTracks {
                try Task.checkCancellation()
                let result = try ExternalPlaylistDecoder.bodianPage(try await data(
                    for: ExternalPlaylistRequests.bodianPlaylist(
                        id: link.playlistID, source: source, page: page, deviceID: Self.bodianDeviceID
                    )
                ))
                tracks.append(contentsOf: result.tracks)
                page += 1
                guard !result.tracks.isEmpty, tracks.count < result.total else { break }
            }
            guard !tracks.isEmpty else { continue }
            let name = (try await optionalData(
                for: ExternalPlaylistRequests.bodianPlaylistInfo(id: link.playlistID, source: source, deviceID: Self.bodianDeviceID)
            )).flatMap(ExternalPlaylistDecoder.bodianPlaylistName) ?? ""
            return ExternalPlaylist(name: name, platform: .bodian, tracks: Array(tracks.prefix(Self.maximumTracks)))
        }
        throw FetchError.notFoundOrPrivate
    }

    private func fetchKugou(_ link: ExternalPlaylistLink) async throws -> ExternalPlaylist {
        if let shareQuery = link.parameters["shareQuery"] {
            // 新版分享页只公开前 10 首，拿全要酷狗 App 的签名密钥 —— 不内置那种东西。
            let page = try ExternalPlaylistDecoder.kugouSharePage(
                try await data(for: ExternalPlaylistRequests.kugouShare(query: shareQuery))
            )
            return ExternalPlaylist(
                name: page.name,
                platform: .kugou,
                tracks: page.tracks,
                isPartial: page.tracks.count >= ExternalPlaylistRequests.kugouSharePreviewLimit
            )
        }
        var tracks: [ExternalPlaylistTrack] = []
        var page = 1
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.kugouSpecialPage(
                try await data(for: ExternalPlaylistRequests.kugouSpecial(id: link.playlistID, page: page))
            )
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        let name = (try await optionalData(for: ExternalPlaylistRequests.kugouSpecialInfo(id: link.playlistID)))
            .flatMap(ExternalPlaylistDecoder.kugouSpecialName) ?? ""
        return ExternalPlaylist(name: name, platform: .kugou, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    private func fetchMigu(id: String) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var page = 1
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.miguPage(
                try await data(for: ExternalPlaylistRequests.miguPlaylist(id: id, page: page))
            )
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        let name = (try await optionalData(for: ExternalPlaylistRequests.miguPlaylistInfo(id: id)))
            .flatMap(ExternalPlaylistDecoder.miguPlaylistName) ?? ""
        return ExternalPlaylist(name: name, platform: .migu, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    private func fetchSoda(id: String) async throws -> ExternalPlaylist {
        let page = try ExternalPlaylistDecoder.sodaPlaylistPage(
            try await html(for: ExternalPlaylistRequests.sodaPlaylistPage(id: id))
        )
        return ExternalPlaylist(
            name: page.name,
            platform: .soda,
            tracks: page.tracks,
            isPartial: page.tracks.count >= ExternalPlaylistRequests.sodaPageLimit
        )
    }

    private func fetchSpotify(id: String) async throws -> ExternalPlaylist {
        let page = try ExternalPlaylistDecoder.spotifyEmbedPage(
            try await html(for: ExternalPlaylistRequests.spotifyEmbed(id: id))
        )
        return ExternalPlaylist(
            name: page.name,
            platform: .spotify,
            tracks: page.tracks,
            isPartial: page.tracks.count >= ExternalPlaylistRequests.spotifyEmbedLimit
        )
    }

    /// Apple Music 走系统 MusicKit 的目录接口，能分页取全。要先得到「媒体与 Apple Music」授权。
    private func fetchAppleMusic(id: String) async throws -> ExternalPlaylist {
        do {
            try Task.checkCancellation()
            let playlist = try await appleMusicPage(id)
            var tracks: [ExternalPlaylistTrack] = []
            var batch = playlist
            while true {
                try Task.checkCancellation()
                tracks.append(contentsOf: batch.tracks.prefix(Self.maximumTracks - tracks.count))
                guard tracks.count < Self.maximumTracks, let next = batch.next else { break }
                guard let nextPage = try await next() else { throw FetchError.unexpectedResponse }
                batch = nextPage
            }
            return ExternalPlaylist(name: playlist.name, platform: .appleMusic, tracks: tracks)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func fetchDeezer(id: String) async throws -> ExternalPlaylist {
        let name = try ExternalPlaylistDecoder.deezerPlaylistName(
            try await data(for: ExternalPlaylistRequests.deezerPlaylist(id: id))
        )
        var tracks: [ExternalPlaylistTrack] = []
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let page = try ExternalPlaylistDecoder.deezerTracksPage(
                try await data(for: ExternalPlaylistRequests.deezerTracks(id: id, index: tracks.count))
            )
            tracks.append(contentsOf: page.tracks)
            guard !page.tracks.isEmpty, tracks.count < page.total else { break }
        }
        return ExternalPlaylist(name: name, platform: .deezer, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    private func fetchBilibiliMenu(id: String) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var page = 1
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.bilibiliMenuPage(
                try await data(for: ExternalPlaylistRequests.bilibiliMenu(id: id, page: page))
            )
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        let name = (try await optionalData(for: ExternalPlaylistRequests.bilibiliMenuInfo(id: id)))
            .flatMap(ExternalPlaylistDecoder.bilibiliMenuName) ?? ""
        return ExternalPlaylist(name: name, platform: .bilibili, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    private func fetchBilibiliFavorites(id: String) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var name = ""
        var page = 1
        while tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.bilibiliFavoritesPage(
                try await data(for: ExternalPlaylistRequests.bilibiliFavorites(id: id, page: page))
            )
            if name.isEmpty { name = result.page.name }
            tracks.append(contentsOf: result.page.tracks)
            page += 1
            guard result.hasMore else { break }
        }
        return ExternalPlaylist(name: name, platform: .bilibili, tracks: Array(tracks.prefix(Self.maximumTracks)))
    }

    /// 歌单页给前 100 条和续页令牌，续页走网页自己用的 browse 接口。续页失败时保留已拿到的并标记不完整。
    private func fetchYouTube(id: String) async throws -> ExternalPlaylist {
        let first = try ExternalPlaylistDecoder.youtubePlaylistPage(
            try await html(for: ExternalPlaylistRequests.youtubePlaylistPage(id: id))
        )
        var tracks = first.tracks
        var continuation = first.continuation
        var partialReason: ExternalPlaylist.PartialReason?
        while let token = continuation, tracks.count < Self.maximumTracks {
            try Task.checkCancellation()
            guard let clientVersion = first.clientVersion else { partialReason = .incomplete; break }
            let (request, body) = ExternalPlaylistRequests.youtubeContinuation(token: token, clientVersion: clientVersion)
            do {
                let next = try ExternalPlaylistDecoder.youtubeContinuationPage(
                    try await data(for: request, body: body, replay: .idempotent)
                )
                guard !next.tracks.isEmpty else { break }
                tracks.append(contentsOf: next.tracks)
                continuation = next.continuation
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as HTTPResponseFailure where failure.isRateLimitFailure || failure.statusCode == 503 {
                try Task.checkCancellation()
                // Admission already retained the service cooldown. Preserve completed
                // pages and the absolute deadline for an explicit preview/retry choice.
                partialReason = .rateLimited(statusCode: failure.statusCode,
                    retryAt: Date().addingTimeInterval(failure.retryAfter ?? Self.service.policy.defaultCooldown))
                break
            } catch {
                try Task.checkCancellation()
                partialReason = .incomplete
                break
            }
        }
        if tracks.count >= Self.maximumTracks, continuation != nil, partialReason == nil {
            partialReason = .incomplete
        }
        return ExternalPlaylist(
            name: first.name,
            platform: .youtube,
            tracks: Array(tracks.prefix(Self.maximumTracks)),
            partialReason: partialReason
        )
    }

    // MARK: - HTTP

    private func html(for request: ExternalPlaylistRequest) async throws -> String {
        let bytes = try await data(for: request)
        guard let text = String(data: bytes, encoding: .utf8) else { throw FetchError.unexpectedResponse }
        return text
    }

    /// Only safe reads may replay. The sole POST is YouTube's read-only browse query.
    private func data(for request: ExternalPlaylistRequest, body: Data? = nil,
                      replay: RequestExecutor.Replay = .never) async throws -> Data {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 60)
        if let body {
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = body
        }
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        return try await send(urlRequest, replay: body == nil ? .idempotent : replay).data
    }

    private func optionalData(for request: ExternalPlaylistRequest) async throws -> Data? {
        do { return try await data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // A missing optional title must not discard completed pages. Any
            // provider cooldown is already retained by the shared registry.
            return nil
        }
    }

    private func send(_ request: URLRequest, replay: RequestExecutor.Replay) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = request.url, let quota = RequestQuota(service: Self.service, url: url) else {
            throw FetchError.unrecognizedLink
        }
        do {
            return try await quotaRegistry.execute(for: quota, replay: replay) {
                try await session.data(for: request)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    /// URLSession follows redirects; only a successful final response supplies a destination.
    private func resolveRedirect(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(ExternalPlaylistRequests.browserUserAgent, forHTTPHeaderField: "User-Agent")
        return try await send(request, replay: .idempotent).response.url ?? url
    }
}
