#if os(tvOS)
import Foundation
import PrimuseKit

/// 播放受阻的可展示原因(在正在播放页提示用户)。
enum TVPlaybackIssue: Equatable {
    case unsupported(String)         // 源类型在 tvOS 不支持(展示名)
    case missingCredential(String)   // 缺凭据(源名)
    case failed(String)

    var message: String {
        switch self {
        case .unsupported(let name):
            return PMString("ext.tv.playback.unsupported", name)
        case .missingCredential(let name):
            return PMString("ext.tv.playback.missingCredential", name)
        case .failed(let msg): return msg
        }
    }
}

private enum TVDecodedDownloadError: Error, LocalizedError, Sendable {
    case invalidContentLength(Int64)
    case incomplete(expected: Int64, actual: Int64)
    case oversizedChunk(requested: Int64, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidContentLength(let length):
            return PMString("ext.tv.error.invalidContentLength", String(length))
        case .incomplete(let expected, let actual):
            return PMString(
                "ext.tv.error.incompleteDownload",
                String(expected),
                String(actual)
            )
        case .oversizedChunk(let requested, let actual):
            return PMString(
                "ext.tv.error.oversizedChunk",
                String(actual),
                String(requested)
            )
        }
    }
}

/// 串起 TVStore(持有真实 Song/MusicSource)↔ StreamResolver ↔ TVAudioEngine。
/// 把真实歌曲解析成网络流 URL 并交给 AVPlayer;解析失败转成可展示的 TVPlaybackIssue。
@MainActor
final class TVPlaybackCoordinator {
    private weak var store: TVStore?
    private let engine: TVAudioEngine
    private let registry = StreamResolverRegistry.shared

    init(store: TVStore, engine: TVAudioEngine) {
        self.store = store
        self.engine = engine
    }

    func resolveRadioStream(
        for station: RadioStation,
        requestID: UUID,
        forceRefresh: Bool
    ) async throws -> URL {
        guard let store else { throw CancellationError() }
        try ensureCurrent(requestID, store: store)

        if !station.requiresSourceStreamResolution {
            guard let url = station.url else { throw StreamResolveError.cannotBuildURL }
            return url
        }

        guard let sourceID = station.sourceID,
              let source = store.sourcesStore.source(id: sourceID),
              source.isEnabled,
              !source.isDeleted else {
            throw StreamResolveError.cannotBuildURL
        }
        if forceRefresh {
            await registry.invalidateSession(for: source)
            try ensureCurrent(requestID, store: store)
        }
        let credential = TVCredentialStore.credential(
            for: source,
            bundle: store.credentialBundle
        )
        let resolved = try await resolveStream(
            song: station.playbackSong,
            source: source,
            credential: credential,
            requestID: requestID,
            retried: false
        )
        try ensureCurrent(requestID, store: store)
        guard resolved.headers.isEmpty,
              let scheme = resolved.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              resolved.url.host?.isEmpty == false,
              resolved.url.user == nil,
              resolved.url.password == nil else {
            throw StreamResolveError.cannotBuildURL
        }
        return resolved.url
    }

    func radioPlaybackIssue(for error: Error, station: RadioStation) -> TVPlaybackIssue {
        if let streamError = error as? StreamResolveError {
            let sourceName = station.sourceID
                .flatMap { store?.sourcesStore.source(id: $0)?.name }
                ?? station.sourceName
                ?? station.name
            return issue(for: streamError, sourceName: sourceName)
        }
        return .failed(error.localizedDescription)
    }

    func play(
        songID: String,
        requestID: UUID,
        preferMusicVideo: Bool = false,
        startAt: Double = 0,
        autoPlay: Bool = true
    ) async {
        // Keep the store alive for the whole asynchronous playback setup. A queued
        // task may otherwise outlive TVStore and turn an `unowned` access into a trap.
        guard let store, isCurrent(requestID, store: store) else { return }
        store.playbackIssue = nil
        guard let song = store.library.song(id: songID) else {
            plog("🎬 TV play: song not found id=\(songID)")
            guard isCurrent(requestID, store: store) else { return }
            store.playbackIssue = .failed(PMString("ext.tv.playback.songNotFound"))
            return
        }
        guard let source = store.sourcesStore.source(id: song.sourceID) else {
            plog("🎬 TV play: NO source for '\(song.title)' sourceID=\(song.sourceID)")
            guard isCurrent(requestID, store: store) else { return }
            store.playbackIssue = .unsupported(song.sourceID)
            return
        }
        let credential = TVCredentialStore.credential(for: source, bundle: store.credentialBundle)
        var asset = playbackAsset(for: song, preferMusicVideo: preferMusicVideo)
        if asset.song.isStreamDescriptor {
            do {
                asset = try await resolveSTRMPlaybackAsset(
                    asset,
                    source: source,
                    credential: credential,
                    requestID: requestID
                )
            } catch is CancellationError {
                return
            } catch {
                plog("🎬 TV play: STRM resolve error — \(error)")
                guard isCurrent(requestID, store: store) else { return }
                store.playbackIssue = .failed(error.localizedDescription)
                return
            }
        }
        let playbackSong = asset.song
        plog("🎬 TV play: '\(song.title)' src=\(source.type.rawValue)/\(source.name) video=\(asset.isVideo) path=\(playbackSong.filePath.suffix(40))")
        // 非原生格式(APE/WavPack/DSD/OGG/WMA 等 AVPlayer 解不了的):下载到本地后用
        // SFBAudioEngine 本机解码。适用所有源类型(协议 + HTTP)。
        let ext = asset.fileExtension
        if !asset.isVideo, !(ext.isEmpty || Self.nativeFormats.contains(ext)) {
            plog("🎬 TV play: non-native '\(ext)' → SFBAudioEngine decode")
            await playNonNative(
                song: playbackSong,
                source: source,
                credential: credential,
                ext: ext,
                directURL: asset.directURL,
                requestID: requestID,
                startAt: startAt,
                autoPlay: autoPlay
            )
            guard isCurrent(requestID, store: store) else { return }
            return
        }
        if let directURL = asset.directURL {
            guard isCurrent(requestID, store: store) else { return }
            engine.load(url: directURL,
                        headers: [:],
                        fileExtension: ext,
                        title: song.title,
                        artist: song.artistName ?? "",
                        album: song.albumTitle ?? "",
                        duration: song.duration,
                        isVideo: asset.isVideo)
            finishLoadedPlayback(
                song: song,
                source: source,
                credential: credential,
                requestID: requestID,
                startAt: startAt,
                autoPlay: autoPlay
            )
            return
        }
        // 协议直连(SMB/NFS/FTP/SFTP):用原生协议库按 range 读字节直接喂 AVPlayer,不经 iPhone
        // 中继。建得出 reader 即走直连;建不出(配置缺失)回落到 resolveStream(中继 / 其它)。
        if let reader = Self.makeDirectReader(source: source, song: playbackSong, credential: credential) {
            plog("🎬 TV play: direct protocol \(source.type.rawValue)")
            guard isCurrent(requestID, store: store) else { return }
            engine.load(reader: reader, fileExtension: ext,
                        title: song.title, artist: song.artistName ?? "",
                        album: song.albumTitle ?? "", duration: song.duration,
                        isVideo: asset.isVideo)
            finishLoadedPlayback(
                song: song,
                source: source,
                credential: credential,
                requestID: requestID,
                startAt: startAt,
                autoPlay: autoPlay
            )
            return
        }
        do {
            let resolved = try await resolveStream(
                song: playbackSong,
                source: source,
                credential: credential,
                requestID: requestID,
                retried: false
            )
            try ensureCurrent(requestID, store: store)
            plog("🎬 TV play: resolved → host=\(resolved.url.host ?? "?") headers=\(resolved.headers.count)")
            guard isCurrent(requestID, store: store) else { return }
            engine.load(url: resolved.url,
                        headers: resolved.headers,
                        fileExtension: ext,
                        title: song.title,
                        artist: song.artistName ?? "",
                        album: song.albumTitle ?? "",
                        duration: song.duration,
                        isVideo: asset.isVideo)
            finishLoadedPlayback(
                song: song,
                source: source,
                credential: credential,
                requestID: requestID,
                startAt: startAt,
                autoPlay: autoPlay
            )
        } catch is CancellationError {
            return
        } catch let error as StreamResolveError {
            plog("🎬 TV play: resolve FAILED — \(error)")
            guard isCurrent(requestID, store: store) else { return }
            store.playbackIssue = issue(for: error, source: source)
        } catch {
            plog("🎬 TV play: resolve error — \(error)")
            guard isCurrent(requestID, store: store) else { return }
            store.playbackIssue = .failed(error.localizedDescription)
        }
    }

    /// AVPlayer / AVFoundation 在 tvOS 原生可解码的格式;其余走 SFBAudioEngine。
    static let nativeFormats: Set<String> = [
        "mp3", "aac", "m4a", "alac", "wav", "aiff", "aif", "flac", "opus", "caf", "mp4",
        "m4v", "mov",
    ]

    private struct PlaybackAsset {
        var song: Song
        var fileExtension: String
        var isVideo: Bool
        var directURL: URL?
    }

    private func playbackAsset(for song: Song, preferMusicVideo: Bool) -> PlaybackAsset {
        // 独立 MV(媒体本体是视频)不看 preferMusicVideo —— 没有独立音频可回落。
        guard preferMusicVideo || song.isStandaloneMusicVideo,
              let path = normalizedMusicVideoPath(for: song) else {
            return PlaybackAsset(song: song, fileExtension: song.fileFormat.rawValue.lowercased(), isVideo: false)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let videoFormat = VideoFormat.from(fileExtension: ext),
              videoFormat.isNativelyPlayable else {
            return PlaybackAsset(song: song, fileExtension: song.fileFormat.rawValue.lowercased(), isVideo: false)
        }
        var videoSong = song
        videoSong.filePath = path
        videoSong.fileFormat = AudioFormat.from(fileExtension: ext) ?? song.fileFormat
        // sidecar MV 的 size 未知(目录列举给的是音频的), 置 0 让下游自己探;
        // 独立 MV 的 fileSize 就是视频本身, 保留供 range 读取用。
        videoSong.fileSize = song.isStandaloneMusicVideo ? song.fileSize : 0
        let directURL = URL(string: path).flatMap { $0.scheme == nil ? nil : $0 }
        return PlaybackAsset(song: videoSong, fileExtension: ext, isVideo: true, directURL: directURL)
    }

    private func resolveSTRMPlaybackAsset(
        _ asset: PlaybackAsset,
        source: MusicSource,
        credential: SourceCredential?,
        requestID: UUID
    ) async throws -> PlaybackAsset {
        guard let store else { throw CancellationError() }
        let descriptor = try await readSTRMDescriptor(
            song: asset.song,
            source: source,
            credential: credential
        )
        try ensureCurrent(requestID, store: store)

        var resolvedSong = asset.song
        resolvedSong.fileFormat = descriptor.format
        resolvedSong.fileSize = 0
        switch descriptor.target {
        case .remote(let url):
            return PlaybackAsset(
                song: resolvedSong,
                fileExtension: descriptor.format.rawValue.lowercased(),
                isVideo: false,
                directURL: url
            )
        case .sourcePath(let reference):
            guard let path = STRMSourcePathResolver.resolve(
                reference,
                relativeTo: asset.song.filePath
            ) else {
                throw STRMDescriptorError.invalidTarget
            }
            if source.type == .webdav,
               let wrapper = try? await registry.resolve(
                   for: asset.song,
                   source: source,
                   credential: credential
               ),
               let originURL = OpenListSTRMTargetResolver.resolve(
                   path,
                   wrapperURL: wrapper.url
               ) {
                return PlaybackAsset(
                    song: resolvedSong,
                    fileExtension: descriptor.format.rawValue.lowercased(),
                    isVideo: false,
                    directURL: originURL
                )
            }
            resolvedSong.filePath = path
            return PlaybackAsset(
                song: resolvedSong,
                fileExtension: descriptor.format.rawValue.lowercased(),
                isVideo: false,
                directURL: nil
            )
        }
    }

    private func readSTRMDescriptor(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> STRMDescriptor {
        let maximum = Int64(STRMDescriptorParser.maximumByteCount)
        if let reader = Self.makeDirectReader(source: source, song: song, credential: credential) {
            let size = try await reader.contentLength()
            guard size > 0 else { throw STRMDescriptorError.empty }
            let data = try await reader.read(offset: 0, length: min(size, maximum + 1))
            return try STRMDescriptorParser.parse(data)
        }

        let resolved = try await registry.resolve(for: song, source: source, credential: credential)
        var request = URLRequest(url: resolved.url)
        for (key, value) in resolved.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(maximum)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: Self.lyricsSession,
            maximumBytes: Int(maximum) + 1
        )
        if let http = response as? HTTPURLResponse,
           !(http.statusCode == 200 || http.statusCode == 206) {
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
        return try STRMDescriptorParser.parse(data)
    }

    private func normalizedMusicVideoPath(for song: Song) -> String? {
        guard let raw = song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else { return nil }
        if URL(string: raw)?.scheme != nil { return raw }
        if raw.hasPrefix("/") || raw.contains("/") { return raw }

        let dir = (song.filePath as NSString).deletingLastPathComponent
        guard dir.isEmpty == false, dir != "." else { return raw }
        return (dir as NSString).appendingPathComponent(raw)
    }

    /// 非原生格式:下载整文件到临时路径,交给 SFBAudioEngine 本机解码播放。
    private func finishLoadedPlayback(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        requestID: UUID,
        startAt: Double,
        autoPlay: Bool
    ) {
        if autoPlay {
            engine.play()
        }
        if startAt > 0 {
            engine.seek(to: startAt)
        }
        if !autoPlay {
            engine.pause()
        }
        loadLyrics(song: song, source: source, credential: credential, requestID: requestID)
    }

    private func playNonNative(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        ext: String,
        directURL: URL? = nil,
        requestID: UUID,
        startAt: Double,
        autoPlay: Bool
    ) async {
        guard let store else { return }
        var downloadedTempURL: URL?
        var handedOffToEngine = false
        defer {
            if let downloadedTempURL, !handedOffToEngine {
                _ = try? TVDecodedTemporaryFilePolicy.removeIfManaged(
                    downloadedTempURL,
                    in: FileManager.default.temporaryDirectory
                )
            }
        }
        do {
            let tempURL = try await downloadToTemp(
                song: song,
                source: source,
                credential: credential,
                ext: ext,
                directURL: directURL,
                requestID: requestID
            )
            downloadedTempURL = tempURL
            try ensureCurrent(requestID, store: store)
            guard isCurrent(requestID, store: store) else { return }
            engine.loadDecoded(fileURL: tempURL, title: song.title, artist: song.artistName ?? "",
                               album: song.albumTitle ?? "", duration: song.duration)
            handedOffToEngine = true
            finishLoadedPlayback(
                song: song,
                source: source,
                credential: credential,
                requestID: requestID,
                startAt: startAt,
                autoPlay: autoPlay
            )
        } catch is CancellationError {
            return
        } catch let e as StreamResolveError {
            plog("🎬 TV play: non-native resolve FAILED — \(e)")
            guard isCurrent(requestID, store: store) else { return }
            store.playbackIssue = issue(for: e, source: source)
        } catch {
            plog("🎬 TV play: non-native download error — \(error)")
            guard isCurrent(requestID, store: store) else { return }
            store.playbackIssue = .failed(error.localizedDescription)
        }
    }

    /// 把整文件下载到 tmp:协议源走 reader 分块落盘,HTTP 源走 resolve + URLSession。
    private func downloadToTemp(song: Song, source: MusicSource,
                              credential: SourceCredential?, ext: String,
                              directURL: URL? = nil,
                              requestID: UUID) async throws -> URL {
        guard let store else { throw CancellationError() }
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let tmp = TVDecodedTemporaryFilePolicy.makeURL(
            in: temporaryDirectory,
            fileExtension: ext
        )
        var shouldKeepFile = false
        defer {
            if !shouldKeepFile {
                _ = try? TVDecodedTemporaryFilePolicy.removeIfManaged(
                    tmp,
                    in: temporaryDirectory,
                    fileManager: fileManager
                )
            }
        }
        if let directURL {
            let (downloadedURL, response) = try await StreamResolverHTTPTransport.download(
                for: URLRequest(url: directURL),
                session: Self.lyricsSession
            )
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            try ensureCurrent(requestID, store: store)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw StreamResolveError.badServerResponse(http.statusCode)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tmp)
            shouldKeepFile = true
            return tmp
        }
        if let reader = Self.makeDirectReader(source: source, song: song, credential: credential) {
            let total = try await reader.contentLength()
            try ensureCurrent(requestID, store: store)
            guard ExactChunkedDownloadPolicy.contentLengthIsValid(total) else {
                throw TVDecodedDownloadError.invalidContentLength(total)
            }
            fileManager.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            var offset: Int64 = 0
            let chunk: Int64 = 1 << 20
            while offset < total {
                let len = min(chunk, total - offset)
                let data = try await reader.read(offset: offset, length: len)
                try ensureCurrent(requestID, store: store)
                switch ExactChunkedDownloadPolicy.chunkDecision(
                    requestedLength: len,
                    receivedLength: data.count
                ) {
                case .append:
                    break
                case .rejectEmpty:
                    throw TVDecodedDownloadError.incomplete(expected: total, actual: offset)
                case .rejectOversized:
                    throw TVDecodedDownloadError.oversizedChunk(
                        requested: len,
                        actual: data.count
                    )
                }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
            }
            guard ExactChunkedDownloadPolicy.isComplete(
                expectedLength: total,
                writtenLength: offset
            ) else {
                throw TVDecodedDownloadError.incomplete(expected: total, actual: offset)
            }
            shouldKeepFile = true
            return tmp
        }
        // HTTP 源:解析成 URL + 头,整文件下载。
        let resolved = try await registry.resolve(for: song, source: source, credential: credential)
        try ensureCurrent(requestID, store: store)
        var req = URLRequest(url: resolved.url)
        for (k, v) in resolved.headers { req.setValue(v, forHTTPHeaderField: k) }
        let redirectMode: StreamResolverHTTPRedirectMode = source.type == .fnMusic
            ? .fnMusic
            : .safe
        let (downloadedURL, response) = try await StreamResolverHTTPTransport.download(
            for: req,
            session: Self.lyricsSession,
            redirectMode: redirectMode
        )
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        try ensureCurrent(requestID, store: store)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: tmp)
        shouldKeepFile = true
        return tmp
    }

    /// 按源类型构造直连协议读取器(非 HTTP)。返回 nil 表示该类型不直连(走 resolveStream)。
    /// 随各协议读取器接通逐步扩充。
    nonisolated static func makeDirectReader(source: MusicSource, song: Song,
                                             credential: SourceCredential?) -> ByteRangeReader? {
        makeDirectReader(
            source: source,
            filePath: song.filePath,
            credential: credential
        )
    }

    nonisolated static func makeDirectReader(
        source: MusicSource,
        filePath: String,
        credential: SourceCredential?
    ) -> ByteRangeReader? {
        if source.connectionConfiguration != nil {
            let candidates = source.connectionCandidates.compactMap { candidate -> TVRoutedByteRangeReaderCandidate? in
                let routedSource = source.applyingConnectionCandidate(candidate)
                guard let reader = makeSingleDirectReader(
                    source: routedSource,
                    filePath: filePath,
                    credential: credential
                ) else {
                    return nil
                }
                return TVRoutedByteRangeReaderCandidate(kind: candidate.kind, reader: reader)
            }
            guard candidates.isEmpty == false else { return nil }
            return TVRoutedByteRangeReader(sourceID: source.id, candidates: candidates)
        }
        return makeSingleDirectReader(
            source: source,
            filePath: filePath,
            credential: credential
        )
    }

    private nonisolated static func makeSingleDirectReader(
        source: MusicSource,
        filePath: String,
        credential: SourceCredential?
    ) -> ByteRangeReader? {
        switch source.type {
        case .smb:
            return SMBByteReader(source: source, filePath: filePath, credential: credential)
        case .nfs:
            return NFSByteReader(source: source, filePath: filePath)
        case .ftp:
            return FTPByteReader(source: source, filePath: filePath, credential: credential)
        default:
            return nil
        }
    }

    /// 会话过期(.authFailed)时清掉会话并重试一次(Synology/cloud 用;Subsonic 无状态不会触发)。
    private func resolveStream(song: Song, source: MusicSource,
                              credential: SourceCredential?, requestID: UUID,
                              retried: Bool) async throws -> ResolvedStream {
        guard let store else { throw CancellationError() }
        do {
            let resolved = try await registry.resolve(for: song, source: source, credential: credential)
            try ensureCurrent(requestID, store: store)
            return resolved
        } catch StreamResolveError.authFailed where !retried {
            try ensureCurrent(requestID, store: store)
            await registry.invalidateSession(for: source)
            try ensureCurrent(requestID, store: store)
            let resolved = try await resolveStream(
                song: song,
                source: source,
                credential: credential,
                requestID: requestID,
                retried: true
            )
            try ensureCurrent(requestID, store: store)
            return resolved
        }
    }

    // MARK: 歌词

    /// 加载歌词:先本地缓存(随快照同步下来的 / 之前抓过的),飞牛音乐再读取服务端首选歌词，
    /// 其它来源直接读同目录的 `.lrc` sidecar。`lyricsFileName` 指向源里的歌词文件
    /// (NAS 是 `.lrc` 真实路径,云盘是 item ID),复用 stream resolver 解出下载地址即可。
    private func loadLyrics(song: Song, source: MusicSource,
                            credential: SourceCredential?, requestID: UUID) {
        Task { [weak self, weak store, song, source, credential] in
            guard let self, let store,
                  self.isCurrent(requestID, store: store) else { return }
            let songID = song.id
            if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID), !cached.isEmpty {
                guard self.isCurrent(requestID, store: store) else { return }
                store.applyLyrics(
                    Self.toTVLyrics(cached, duration: song.duration),
                    forSongID: songID
                )
                return
            }
            guard self.isCurrent(requestID, store: store) else { return }

            if source.type == .fnMusic {
                guard let client = store.fnMusicClient(for: source.id) else { return }
                do {
                    guard let text = try await client.preferredLyrics(trackPath: song.filePath),
                          !text.isEmpty else { return }
                    try self.ensureCurrent(requestID, store: store)
                    let lines = LyricsParser.parseText(text)
                    guard !lines.isEmpty else { return }
                    let wrote = await MetadataAssetStore.shared.cacheLyrics(
                        lines,
                        forSongID: songID,
                        force: false
                    )
                    try self.ensureCurrent(requestID, store: store)
                    if wrote {
                        store.applyLyrics(
                            Self.toTVLyrics(lines, duration: song.duration),
                            forSongID: songID
                        )
                        plog("🎬 TV Feiniu Music lyrics loaded \(lines.count) lines for '\(song.title)'")
                    } else if let preserved = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID),
                              !preserved.isEmpty {
                        try self.ensureCurrent(requestID, store: store)
                        store.applyLyrics(
                            Self.toTVLyrics(preserved, duration: song.duration),
                            forSongID: songID
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrent(requestID, store: store) else { return }
                    plog("🎬 TV Feiniu Music lyrics fetch failed '\(song.title)': \(error)")
                }
                return
            }

            // 歌词文件路径:① song.lyricsFileName 指向的源内 .lrc(.json 是本机缓存名,已查过);
            // ② 协议直连源(SMB/NFS/FTP)按音频路径推同名 .lrc —— 即便扫描时没记录歌词,播放时
            //    也能就地从 NAS 同目录读到。
            let isDirect = Self.makeDirectReader(source: source, song: song, credential: credential) != nil
            var lrcPath: String?
            if let lf = song.lyricsFileName, !lf.isEmpty, !lf.hasSuffix(".json") {
                lrcPath = lf
            } else if isDirect {
                let ns = song.filePath as NSString
                if !ns.pathExtension.isEmpty { lrcPath = ns.deletingPathExtension + ".lrc" }
            }
            guard let lrcPath else { return }
            var lrcSong = song
            lrcSong.filePath = lrcPath
            do {
                guard let text = try await self.fetchLyricText(
                    song: lrcSong,
                    source: source,
                    credential: credential,
                    requestID: requestID
                ),
                      !text.isEmpty else { return }
                try self.ensureCurrent(requestID, store: store)
                let lines = LyricsParser.parse(text)
                guard !lines.isEmpty else { return }
                _ = await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: songID, force: false)
                try self.ensureCurrent(requestID, store: store)
                store.applyLyrics(
                    Self.toTVLyrics(lines, duration: song.duration),
                    forSongID: songID
                )
                plog("🎬 TV source-lyrics loaded \(lines.count) lines for '\(song.title)'")
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(requestID, store: store) else { return }
                plog("🎬 TV source-lyrics fetch failed '\(song.title)': \(error)")
            }
        }
    }

    /// 取歌词文本:协议直连源用 reader 直读小文件;HTTP/云盘走 StreamResolver 解 URL 下载。
    private func fetchLyricText(song: Song, source: MusicSource,
                                credential: SourceCredential?, requestID: UUID) async throws -> String? {
        guard let store else { throw CancellationError() }
        if let reader = Self.makeDirectReader(source: source, song: song, credential: credential) {
            let size = try await reader.contentLength()
            try ensureCurrent(requestID, store: store)
            guard size > 0, size < 512 * 1024 else { return nil }
            let data = try await reader.read(offset: 0, length: size)
            try ensureCurrent(requestID, store: store)
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        let resolved = try await StreamResolverRegistry.shared.resolve(for: song, source: source, credential: credential)
        try ensureCurrent(requestID, store: store)
        var req = URLRequest(url: resolved.url)
        for (k, v) in resolved.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await StreamResolverHTTPTransport.data(
            for: req,
            session: Self.lyricsSession,
            maximumBytes: 512 * 1_024,
            redirectMode: source.type == .fnMusic ? .fnMusic : .safe
        )
        try ensureCurrent(requestID, store: store)
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func toTVLyrics(
        _ lines: [LyricLine],
        duration _: TimeInterval
    ) -> [TVLyricLine] {
        let writingDirection = LyricWritingDirectionPolicy.resolve(in: lines)
        return lines.map { line in
            TVLyricLine(id: line.id,
                        time: line.timestamp,
                        text: line.text,
                        isSynchronized: line.isSynchronized,
                        // start/end 是相对歌曲起点的绝对时间戳;卡拉OK扫词需要每字时长。
                        syllables: (line.syllables ?? []).map { TVSyllable(w: $0.text, d: max(0.001, $0.end - $0.start)) },
                        translation: "",
                        writingDirection: writingDirection)
        }
    }

    /// 取 .lrc 用的 session:接受自签证书(个人 NAS),与播放用的 resource loader 同策略。
    private static let lyricsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: TVInsecureTLSDelegate(), delegateQueue: nil)
    }()

    private func isCurrent(_ requestID: UUID, store: TVStore) -> Bool {
        store.isCurrentPlaybackRequest(requestID, isCancelled: Task.isCancelled)
    }

    private func ensureCurrent(_ requestID: UUID, store: TVStore) throws {
        guard isCurrent(requestID, store: store) else { throw CancellationError() }
    }

    private func issue(for error: StreamResolveError, source: MusicSource) -> TVPlaybackIssue {
        issue(for: error, sourceName: source.name)
    }

    private func issue(for error: StreamResolveError, sourceName: String) -> TVPlaybackIssue {
        switch error {
        case .unsupportedSourceType(let type): return .unsupported(type.displayName)
        case .missingCredential: return .missingCredential(sourceName)
        case .needs2FA: return .failed(PMString("ext.tv.test.needs2FA"))
        case .authFailed: return .failed(PMString("ext.tv.playback.authFailed"))
        case .badServerResponse(let code): return .failed(PMString("ext.tv.playback.httpError", code))
        case .cannotBuildURL: return .failed(PMString("ext.tv.playback.cannotBuildURL"))
        case .relayUnavailable:
            return .failed(PMString("ext.tv.playback.relayUnavailable"))
        }
    }
}
#endif
