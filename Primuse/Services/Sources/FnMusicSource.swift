import Foundation
import PrimuseKit

/// Direct, read-only connector for the Feiniu Music app's catalogue service.
/// The legacy `.fnos` NAS placeholder remains separate so old source records
/// are never reinterpreted as a server-side music library.
actor FnMusicSource: RefreshingMetadataSongConnector, ServerLyricsConnector, ServerScrobblingConnector {
    let sourceID: String

    private let api: FnMusicAPI
    private let username: String
    private let password: String
    private let audioCacheDirectory: URL
    private let artworkCacheDirectory: URL
    private var loginTask: Task<Void, Error>?

    private static let pageSize = 50

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        password: String
    ) {
        self.sourceID = sourceID
        self.username = username
        self.password = password
        self.api = FnMusicAPI(
            sourceID: sourceID,
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )

        let root = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        self.audioCacheDirectory = root
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        self.artworkCacheDirectory = root
            .appendingPathComponent("fnmusic_artwork", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try? FileManager.default.createDirectory(at: audioCacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Connection

    func connect() async throws {
        if await api.isLoggedIn { return }
        guard !username.isEmpty, !password.isEmpty else {
            await reportAuthenticationProblem("缺少飞牛音乐账号或密码")
            throw SourceError.authenticationFailed
        }
        if let loginTask {
            try await loginTask.value
            return
        }

        let task = Task { [api, username, password] in
            try await api.login(username: username, password: password)
        }
        loginTask = task
        defer { loginTask = nil }
        do {
            try await task.value
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
        } catch {
            if case SourceError.authenticationFailed = error {
                await reportAuthenticationProblem(
                    "飞牛音乐登录被拒绝，请检查飞牛音乐账号、密码及曲库权限"
                )
            }
            throw error
        }
    }

    func disconnect() async {
        await api.logout()
    }

    private func reportAuthenticationProblem(_ message: String) async {
        await MainActor.run {
            SourceAuthAlert.report(sourceID: sourceID, message: message)
        }
    }

    // MARK: - Catalogue scanning

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        // This is a server catalogue, not a filesystem. The synthetic root is
        // used only by connection diagnostics; scans use scanSongs("/").
        _ = try await trackPage(page: 1, size: 1)
        return [
            RemoteFileItem(
                name: "飞牛音乐",
                path: "/",
                isDirectory: true,
                size: 0,
                modifiedDate: nil
            ),
        ]
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var page = 1
                    var received = 0
                    var expectedTotal: Int?
                    var seenTrackGUIDs: Set<String> = []
                    while true {
                        try Task.checkCancellation()
                        let result = try await self.trackPage(page: page, size: Self.pageSize)

                        guard let pageTotal = result.total else {
                            throw SourceError.connectionFailed("飞牛音乐曲目列表缺少总数，已取消本次扫描")
                        }
                        if let expectedTotal, expectedTotal != pageTotal {
                            throw SourceError.connectionFailed("飞牛音乐曲目总数在扫描期间发生变化，请稍后重试")
                        }
                        expectedTotal = pageTotal

                        guard result.rawCount <= Self.pageSize else {
                            throw SourceError.connectionFailed("飞牛音乐曲目分页数量无效")
                        }
                        if pageTotal == 0 {
                            guard page == 1, result.rawCount == 0 else {
                                throw SourceError.connectionFailed("飞牛音乐曲目分页与总数不一致")
                            }
                            break
                        }
                        guard result.rawCount > 0 else {
                            throw SourceError.connectionFailed("飞牛音乐曲目分页提前结束，已取消本次扫描")
                        }

                        received += result.rawCount
                        for track in result.tracks {
                            try Task.checkCancellation()
                            guard seenTrackGUIDs.insert(track.guid).inserted else {
                                throw SourceError.connectionFailed("飞牛音乐曲目分页包含重复项目，已取消本次扫描")
                            }
                            let scanned = try self.scannedSong(from: track)
                            continuation.yield(scanned)
                        }

                        guard received <= pageTotal else {
                            throw SourceError.connectionFailed("飞牛音乐曲目分页超过声明总数")
                        }
                        if received == pageTotal {
                            break
                        }
                        guard result.rawCount == Self.pageSize else {
                            throw SourceError.connectionFailed("飞牛音乐曲目分页不完整，已取消本次扫描")
                        }
                        page += 1
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let songs = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await scanned in songs {
                        continuation.yield(
                            RemoteFileItem(
                                name: scanned.displayName,
                                path: scanned.song.filePath,
                                isDirectory: false,
                                size: scanned.song.fileSize,
                                modifiedDate: scanned.song.lastModified,
                                revision: scanned.song.revision
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func scannedSong(from track: FnMusicTrack) throws -> ConnectorScannedSong {
        let suffix = track.fileExtension ?? ""
        guard let song = track.makeSong(sourceID: sourceID) else {
            throw SourceError.connectionFailed(
                "飞牛音乐曲目“\(track.title)”缺少可识别的音频格式，已取消本次扫描"
            )
        }
        return ConnectorScannedSong(song: song, displayName: "\(track.title).\(suffix)")
    }

    private func trackPage(page: Int, size: Int) async throws -> FnMusicTrackPage {
        do {
            return try await api.trackPage(page: page, size: size)
        } catch SourceError.authenticationFailed {
            try await connect()
            return try await api.trackPage(page: page, size: size)
        }
    }

    // MARK: - Audio

    func streamingURL(for path: String) async throws -> URL? {
        // The media route needs a Cookie header. Returning a bare URL would
        // work only inside an already-authenticated WebView and fails in the
        // native decoder, so playback deliberately uses fetchRange/localURL.
        nil
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0,
              let trackGUID = FnMusicAPIProtocol.trackGUID(from: path) else {
            return Data()
        }
        try await connect()
        let response: FnMusicRangeResponse
        do {
            response = try await api.fetchRange(trackGUID: trackGUID, offset: offset, length: length)
        } catch SourceError.authenticationFailed {
            try await connect()
            response = try await api.fetchRange(trackGUID: trackGUID, offset: offset, length: length)
        }
        return response.data
    }

    func localURL(for path: String) async throws -> URL {
        guard let trackGUID = FnMusicAPIProtocol.trackGUID(from: path) else {
            throw SourceError.fileNotFound(path)
        }
        let suffix = (path as NSString).pathExtension
        let target = audioCacheDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(
                path: path,
                preferredExtension: suffix.isEmpty ? "bin" : suffix
            )
        )
        if FileManager.default.fileExists(atPath: target.path) { return target }

        try await connect()
        let temporaryURL: URL
        do {
            temporaryURL = try await api.downloadTrack(trackGUID: trackGUID)
        } catch SourceError.authenticationFailed {
            try await connect()
            temporaryURL = try await api.downloadTrack(trackGUID: trackGUID)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
            return target
        }
        try FileManager.default.moveItem(at: temporaryURL, to: target)
        return target
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let local = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: local)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - Artwork / lyrics / playback history

    func imageURL(for path: String) async throws -> URL? {
        guard let coverID = FnMusicAPIProtocol.coverID(from: path) else {
            return path.contains("://") ? URL(string: path) : nil
        }
        let target = artworkCacheDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(path: path, preferredExtension: "image")
        )
        if FileManager.default.fileExists(atPath: target.path) { return target }

        try await connect()
        let revision = FnMusicAPIProtocol.coverRevision(from: path)
        let data: Data
        do {
            data = try await api.coverData(coverID: coverID, revision: revision)
        } catch SourceError.authenticationFailed {
            try await connect()
            data = try await api.coverData(coverID: coverID, revision: revision)
        }
        try data.write(to: target, options: .atomic)
        return target
    }

    func fetchServerLyrics(for path: String) async -> String? {
        guard let trackGUID = FnMusicAPIProtocol.trackGUID(from: path),
              (try? await connect()) != nil else { return nil }
        do {
            return try await api.preferredLyrics(trackGUID: trackGUID)
        } catch SourceError.authenticationFailed {
            guard (try? await connect()) != nil else { return nil }
            return try? await api.preferredLyrics(trackGUID: trackGUID)
        } catch {
            return nil
        }
    }

    func scrobble(songPath: String, submission: Bool) async {
        guard submission,
              let trackGUID = FnMusicAPIProtocol.trackGUID(from: songPath),
              (try? await connect()) != nil else { return }
        do {
            try await api.reportPlayback(trackGUID: trackGUID)
        } catch SourceError.authenticationFailed {
            guard (try? await connect()) != nil else { return }
            _ = try? await api.reportPlayback(trackGUID: trackGUID)
        } catch {
            return
        }
    }

}
