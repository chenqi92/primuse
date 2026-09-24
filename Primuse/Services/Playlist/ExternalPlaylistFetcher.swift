import Foundation
import PrimuseKit

/// 按分享链接读取其他音乐 App 的公开歌单(只取歌名、歌手、专辑、时长)。
/// 链接识别、请求与响应格式都在 Kit 的 `ExternalPlaylistImport.swift` 里。
enum ExternalPlaylistFetcher {
    enum FetchError: LocalizedError {
        case unrecognizedLink
        case notFoundOrPrivate
        case unexpectedResponse
        case empty
        case network(String)

        init(_ error: ExternalPlaylistError) {
            switch error {
            case .unrecognizedLink: self = .unrecognizedLink
            case .notFoundOrPrivate: self = .notFoundOrPrivate
            case .unexpectedResponse: self = .unexpectedResponse
            case .empty: self = .empty
            }
        }

        var errorDescription: String? {
            switch self {
            case .unrecognizedLink: String(localized: "playlist_import_link_err_unrecognized")
            case .notFoundOrPrivate: String(localized: "playlist_import_link_err_private")
            case .unexpectedResponse: String(localized: "playlist_import_link_err_changed")
            case .empty: String(localized: "playlist_import_err_empty")
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
        guard case .playlist(let link) = detection else { throw FetchError.unrecognizedLink }

        do {
            let playlist: ExternalPlaylist
            switch link.platform {
            case .netease:
                playlist = try await fetchNetEase(id: link.playlistID, session: session)
            case .qqMusic:
                playlist = try await fetchQQ(id: link.playlistID, session: session)
            case .kuwo, .bodian:
                playlist = try await fetchKuwo(id: link.playlistID, platform: link.platform, session: session)
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

    // MARK: - HTTP

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
