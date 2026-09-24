import Foundation
import MusicKit
import PrimuseKit

/// 按分享链接读取其他音乐 App 的公开歌单(只取歌名、歌手、专辑、时长)。
/// 链接识别、请求与响应格式都在 Kit 的 `ExternalPlaylistImport.swift` 里。
enum ExternalPlaylistFetcher {
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

    static func fetch(sharedText text: String, session: URLSession = .shared) async throws -> ExternalPlaylist {
        var detection = ExternalPlaylistLink.detect(in: text)
        // 短链接最多跟两次（有的平台短链先跳一个中转页）。跳完仍认不出就当作不支持。
        for _ in 0..<2 {
            guard case .needsRedirect(let url, _) = detection else { break }
            let resolved = try await resolveRedirect(url, session: session)
            guard resolved != url else { break }
            detection = ExternalPlaylistLink.detect(url: resolved)
        }
        if detection == .discontinued { throw FetchError.discontinued }
        guard case .playlist(let link) = detection else { throw FetchError.unrecognizedLink }

        do {
            let playlist: ExternalPlaylist
            switch link.platform {
            case .netease:
                playlist = try await fetchNetEase(id: link.playlistID, session: session)
            case .qqMusic:
                playlist = try await fetchQQ(id: link.playlistID, session: session)
            case .kuwo:
                playlist = try await fetchKuwo(id: link.playlistID, platform: .kuwo, session: session)
            case .bodian:
                playlist = try await fetchBodian(link, session: session)
            case .kugou:
                playlist = try await fetchKugou(link, session: session)
            case .migu:
                playlist = try await fetchMigu(id: link.playlistID, session: session)
            case .soda:
                playlist = try await fetchSoda(id: link.playlistID, session: session)
            case .appleMusic:
                playlist = try await fetchAppleMusic(id: link.playlistID)
            case .spotify:
                playlist = try await fetchSpotify(id: link.playlistID, session: session)
            }
            guard !playlist.tracks.isEmpty else { throw FetchError.empty }
            return playlist
        } catch let error as ExternalPlaylistError {
            throw FetchError(error)
        }
    }

    // MARK: - Platforms

    private static func fetchNetEase(id: String, session: URLSession) async throws -> ExternalPlaylist {
        let detail = try ExternalPlaylistDecoder.netEasePlaylist(
            try await data(for: ExternalPlaylistRequests.netEasePlaylist(id: id), session: session)
        )
        var tracksByID = detail.tracksByID
        let missing = detail.trackIDs.prefix(maximumTracks).filter { tracksByID[$0] == nil }
        var start = missing.startIndex
        while start < missing.endIndex {
            try Task.checkCancellation()
            let end = missing.index(start, offsetBy: ExternalPlaylistRequests.netEaseSongDetailBatchSize, limitedBy: missing.endIndex) ?? missing.endIndex
            let batch = Array(missing[start..<end])
            let details = try ExternalPlaylistDecoder.netEaseSongDetails(
                try await data(for: ExternalPlaylistRequests.netEaseSongDetails(ids: batch), session: session)
            )
            tracksByID.merge(details) { current, _ in current }
            start = end
        }
        let tracks = detail.trackIDs.prefix(maximumTracks).compactMap { tracksByID[$0] }
        return ExternalPlaylist(name: detail.name, platform: .netease, tracks: tracks)
    }

    private static func fetchQQ(id: String, session: URLSession) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var name = ""
        var begin = 0
        while tracks.count < maximumTracks {
            try Task.checkCancellation()
            let page = try ExternalPlaylistDecoder.qqPlaylistPage(
                try await data(for: ExternalPlaylistRequests.qqPlaylist(id: id, begin: begin), session: session)
            )
            if name.isEmpty { name = page.name }
            tracks.append(contentsOf: page.tracks)
            begin += page.tracks.count
            guard !page.tracks.isEmpty, begin < page.total else { break }
        }
        return ExternalPlaylist(name: name, platform: .qqMusic, tracks: Array(tracks.prefix(maximumTracks)))
    }

    private static func fetchKuwo(
        id: String,
        platform: ExternalPlaylistPlatform,
        session: URLSession
    ) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var name = ""
        var page = 0
        while tracks.count < maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.kuwoPlaylistPage(
                try await data(for: ExternalPlaylistRequests.kuwoPlaylist(id: id, page: page), session: session)
            )
            if name.isEmpty { name = result.name }
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        return ExternalPlaylist(name: name, platform: platform, tracks: Array(tracks.prefix(maximumTracks)))
    }

    /// 波点请求要带一个设备号，匿名随机即可；同一次运行内保持不变。
    private static let bodianDeviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private static func fetchBodian(_ link: ExternalPlaylistLink, session: URLSession) async throws -> ExternalPlaylist {
        // 链接里没写 source 时两种都试：5 = 波点自建歌单，4 = 从酷我同步来的。
        let sources = link.parameters["source"].map { [$0] } ?? ["5", "4"]
        for source in sources {
            var tracks: [ExternalPlaylistTrack] = []
            var page = 1
            while tracks.count < maximumTracks {
                try Task.checkCancellation()
                let result = try ExternalPlaylistDecoder.bodianPage(try await data(
                    for: ExternalPlaylistRequests.bodianPlaylist(
                        id: link.playlistID, source: source, page: page, deviceID: bodianDeviceID
                    ),
                    session: session
                ))
                tracks.append(contentsOf: result.tracks)
                page += 1
                guard !result.tracks.isEmpty, tracks.count < result.total else { break }
            }
            guard !tracks.isEmpty else { continue }
            let name = (try? await data(
                for: ExternalPlaylistRequests.bodianPlaylistInfo(id: link.playlistID, source: source, deviceID: bodianDeviceID),
                session: session
            )).flatMap(ExternalPlaylistDecoder.bodianPlaylistName) ?? ""
            return ExternalPlaylist(name: name, platform: .bodian, tracks: Array(tracks.prefix(maximumTracks)))
        }
        throw FetchError.notFoundOrPrivate
    }

    private static func fetchKugou(_ link: ExternalPlaylistLink, session: URLSession) async throws -> ExternalPlaylist {
        if let shareQuery = link.parameters["shareQuery"] {
            // 新版分享页只公开前 10 首，拿全要酷狗 App 的签名密钥 —— 不内置那种东西。
            let page = try ExternalPlaylistDecoder.kugouSharePage(
                try await data(for: ExternalPlaylistRequests.kugouShare(query: shareQuery), session: session)
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
        while tracks.count < maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.kugouSpecialPage(
                try await data(for: ExternalPlaylistRequests.kugouSpecial(id: link.playlistID, page: page), session: session)
            )
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        let name = (try? await data(for: ExternalPlaylistRequests.kugouSpecialInfo(id: link.playlistID), session: session))
            .flatMap(ExternalPlaylistDecoder.kugouSpecialName) ?? ""
        return ExternalPlaylist(name: name, platform: .kugou, tracks: Array(tracks.prefix(maximumTracks)))
    }

    private static func fetchMigu(id: String, session: URLSession) async throws -> ExternalPlaylist {
        var tracks: [ExternalPlaylistTrack] = []
        var page = 1
        while tracks.count < maximumTracks {
            try Task.checkCancellation()
            let result = try ExternalPlaylistDecoder.miguPage(
                try await data(for: ExternalPlaylistRequests.miguPlaylist(id: id, page: page), session: session)
            )
            tracks.append(contentsOf: result.tracks)
            page += 1
            guard !result.tracks.isEmpty, tracks.count < result.total else { break }
        }
        let name = (try? await data(for: ExternalPlaylistRequests.miguPlaylistInfo(id: id), session: session))
            .flatMap(ExternalPlaylistDecoder.miguPlaylistName) ?? ""
        return ExternalPlaylist(name: name, platform: .migu, tracks: Array(tracks.prefix(maximumTracks)))
    }

    private static func fetchSoda(id: String, session: URLSession) async throws -> ExternalPlaylist {
        let page = try ExternalPlaylistDecoder.sodaPlaylistPage(
            try await html(for: ExternalPlaylistRequests.sodaPlaylistPage(id: id), session: session)
        )
        return ExternalPlaylist(
            name: page.name,
            platform: .soda,
            tracks: page.tracks,
            isPartial: page.tracks.count >= ExternalPlaylistRequests.sodaPageLimit
        )
    }

    private static func fetchSpotify(id: String, session: URLSession) async throws -> ExternalPlaylist {
        let page = try ExternalPlaylistDecoder.spotifyEmbedPage(
            try await html(for: ExternalPlaylistRequests.spotifyEmbed(id: id), session: session)
        )
        return ExternalPlaylist(
            name: page.name,
            platform: .spotify,
            tracks: page.tracks,
            isPartial: page.tracks.count >= ExternalPlaylistRequests.spotifyEmbedLimit
        )
    }

    /// Apple Music 走系统 MusicKit 的目录接口，能分页取全。要先得到「媒体与 Apple Music」授权。
    private static func fetchAppleMusic(id: String) async throws -> ExternalPlaylist {
        if MusicAuthorization.currentStatus != .authorized {
            guard await MusicAuthorization.request() == .authorized else {
                throw FetchError.appleMusicNotAuthorized
            }
        }
        var request = MusicCatalogResourceRequest<MusicKit.Playlist>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.tracks]
        let response: MusicCatalogResourceResponse<MusicKit.Playlist>
        do {
            response = try await request.response()
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        guard let playlist = response.items.first else { throw FetchError.notFoundOrPrivate }
        var tracks: [ExternalPlaylistTrack] = []
        var batch = playlist.tracks
        while let current = batch, tracks.count < maximumTracks {
            try Task.checkCancellation()
            for track in current {
                tracks.append(ExternalPlaylistTrack(
                    title: track.title,
                    artists: [track.artistName],
                    album: track.albumTitle,
                    duration: track.duration,
                    externalID: track.id.rawValue
                ))
            }
            guard current.hasNextBatch else { break }
            batch = try? await current.nextBatch()
        }
        return ExternalPlaylist(name: playlist.name, platform: .appleMusic, tracks: Array(tracks.prefix(maximumTracks)))
    }

    // MARK: - HTTP

    private static func html(for request: ExternalPlaylistRequest, session: URLSession) async throws -> String {
        let bytes = try await data(for: request, session: session)
        guard let text = String(data: bytes, encoding: .utf8) else { throw FetchError.unexpectedResponse }
        return text
    }

    /// 网络层失败(连接被重置、超时)重试一次; 平台明确的拒绝不重试。
    private static func data(for request: ExternalPlaylistRequest, session: URLSession) async throws -> Data {
        do {
            return try await attempt(request, session: session)
        } catch FetchError.network {
            try await Task.sleep(for: .seconds(1))
            return try await attempt(request, session: session)
        }
    }

    private static func attempt(_ request: ExternalPlaylistRequest, session: URLSession) async throws -> Data {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 20)
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 || http.statusCode == 403 { throw FetchError.notFoundOrPrivate }
                guard (200..<300).contains(http.statusCode) else {
                    throw FetchError.network("HTTP \(http.statusCode)")
                }
            }
            return data
        } catch let error as FetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
    }

    /// 短链接跳转后的最终地址。URLSession 会自动跟随重定向，响应里的 URL 就是落点。
    private static func resolveRedirect(_ url: URL, session: URLSession) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(ExternalPlaylistRequests.browserUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return response.url ?? url
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
    }
}
