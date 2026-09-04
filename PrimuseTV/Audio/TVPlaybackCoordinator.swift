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

struct TVResolvedRadioStream: Equatable, Sendable {
    let url: URL
    let headers: [String: String]
}

private enum TVDecodedDownloadError: Error, LocalizedError, Sendable {
    case invalidContentLength(Int64)
    case incomplete(expected: Int64, actual: Int64)
    case oversizedChunk(requested: Int64, actual: Int)
    case insufficientStorage(required: Int64, available: Int64)

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
        case .insufficientStorage(let required, let available):
            return PMString("local_import_insufficient_space", required, available)
        }
    }
}

/// Keeps protocol-reader writes off the main actor. `TVPlaybackCoordinator`
/// owns UI state, but multi-gigabyte decoder downloads must not perform every
/// synchronous `FileHandle.write` on the UI executor.
private actor TVDecodedFileWriter {
    private let handle: FileHandle
    private var isClosed = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) throws {
        guard !isClosed else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
    }

    func close() throws {
        guard !isClosed else { return }
        isClosed = true
        try handle.close()
    }
}

enum TVLyricsLoadingStrategy: Equatable, Sendable {
    case fnMusicService
    case subsonicServer
    case sourceFile
}

enum TVLyricsLoadingPolicy {
    static func strategy(for sourceType: MusicSourceType) -> TVLyricsLoadingStrategy {
        if sourceType == .fnMusic { return .fnMusicService }
        if sourceType.isSubsonicFamily { return .subsonicServer }
        return .sourceFile
    }
}

/// 串起 TVStore(持有真实 Song/MusicSource)↔ StreamResolver ↔ TVAudioEngine。
/// 把真实歌曲解析成网络流 URL 并交给 AVPlayer;解析失败转成可展示的 TVPlaybackIssue。
@MainActor
final class TVPlaybackCoordinator {
    private weak var store: TVStore?
    private let engine: TVAudioEngine
    private let registry = StreamResolverRegistry.shared
    private var lyricsTask: Task<Void, Never>?
    private var playbackMetadataTask: Task<Void, Never>?
    private var playbackMetadataTaskIdentity: PlaybackMetadataIdentity?
    private var playbackMetadataTaskToken: UUID?
    private var playbackMetadataSelectionIdentity: PlaybackMetadataIdentity?
    private var playbackMetadataFailureCounts: [PlaybackMetadataIdentity: Int] = [:]
    private var playbackMetadataCompletedIdentities: Set<PlaybackMetadataIdentity> = []

    private struct PlaybackMetadataIdentity: Hashable, Sendable {
        let songID: String
        let sourceID: String
        let filePath: String
        let revision: String?
        let fileSize: Int64

        init(_ song: Song) {
            songID = song.id
            sourceID = song.sourceID
            filePath = song.filePath
            revision = song.revision
            fileSize = song.fileSize
        }
    }

    init(store: TVStore, engine: TVAudioEngine) {
        self.store = store
        self.engine = engine
    }

    func resolveRadioStream(
        for station: RadioStation,
        requestID: UUID,
        forceRefresh: Bool
    ) async throws -> TVResolvedRadioStream {
        guard let store else { throw CancellationError() }
        try ensureCurrent(requestID, store: store)

        if !station.requiresSourceStreamResolution {
            guard let url = station.url else { throw StreamResolveError.cannotBuildURL }
            return TVResolvedRadioStream(url: url, headers: [:])
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
        guard let scheme = resolved.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              resolved.url.host?.isEmpty == false,
              resolved.url.user == nil,
              resolved.url.password == nil else {
            throw StreamResolveError.cannotBuildURL
        }
        return TVResolvedRadioStream(url: resolved.url, headers: resolved.headers)
    }

    func cancelAuxiliaryTasks() {
        lyricsTask?.cancel()
        lyricsTask = nil
        playbackMetadataTask?.cancel()
        playbackMetadataTask = nil
        playbackMetadataTaskIdentity = nil
        playbackMetadataTaskToken = nil
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
        cancelAuxiliaryTasks()
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
        let displayArtistName = store.library.artistDisplayName(for: song) ?? ""
        plog("🎬 TV play: '\(song.title)' src=\(source.type.rawValue)/\(source.name) video=\(asset.isVideo) path=\(playbackSong.filePath.suffix(40))")
        let format = AudioFormat.from(fileExtension: asset.fileExtension)
            ?? playbackSong.fileFormat
        let wavProbeOutcome: RemoteWAVPlaybackPolicy.ProbeOutcome?
        if !asset.isVideo, format == .wav {
            wavProbeOutcome = await probeWAVPayload(
                asset: asset,
                source: source,
                credential: credential,
                requestID: requestID
            )
            guard isCurrent(requestID, store: store) else { return }
        } else {
            wavProbeOutcome = nil
        }
        let serverTranscodesWMA = format == .wma
            && source.type.isSubsonicFamily
            && asset.directStream == nil
        let delivery = TVPlaybackFormatRoutingPolicy.delivery(
            for: format,
            isVideo: asset.isVideo,
            serverTranscodesWMA: serverTranscodesWMA,
            wavProbeOutcome: wavProbeOutcome
        )

        if case .decodedTemporaryFile(let decoderExtension, let inspectWAV) = delivery {
            plog("🎬 TV play: decoded '\(decoderExtension)' → complete local file")
            await playNonNative(
                song: playbackSong,
                source: source,
                credential: credential,
                ext: decoderExtension,
                directStream: asset.directStream,
                inspectWAVAfterDownload: inspectWAV,
                requestID: requestID,
                startAt: startAt,
                autoPlay: autoPlay
            )
            guard isCurrent(requestID, store: store) else { return }
            return
        }
        let playbackExtension: String
        if case .avPlayer(let fileExtension) = delivery {
            playbackExtension = fileExtension
        } else {
            playbackExtension = asset.fileExtension
        }
        if let directStream = asset.directStream {
            guard isCurrent(requestID, store: store) else { return }
            engine.load(url: directStream.url,
                        headers: directStream.headers,
                        fileExtension: playbackExtension,
                        title: song.title,
                        artist: displayArtistName,
                        album: song.albumTitle ?? "",
                        duration: song.duration,
                        isVideo: asset.isVideo,
                        cueStartTime: song.cueStartTime,
                        cueEndTime: song.cueEndTime)
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
            engine.load(reader: reader, fileExtension: playbackExtension,
                        title: song.title, artist: displayArtistName,
                        album: song.albumTitle ?? "", duration: song.duration,
                        isVideo: asset.isVideo,
                        cueStartTime: song.cueStartTime,
                        cueEndTime: song.cueEndTime)
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
                        fileExtension: playbackExtension,
                        title: song.title,
                        artist: displayArtistName,
                        album: song.albumTitle ?? "",
                        duration: song.duration,
                        isVideo: asset.isVideo,
                        cueStartTime: song.cueStartTime,
                        cueEndTime: song.cueEndTime)
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

    /// Retained for diagnostics/tests; the actual decision uses the shared
    /// `AudioFormat.requiresFFmpeg` contract plus explicit transcode/probe data.
    static let nativeFormats = Set(
        AudioFormat.allCases.lazy.filter { !$0.requiresFFmpeg }.map(\.rawValue)
    )

    private struct PlaybackAsset {
        var song: Song
        var fileExtension: String
        var isVideo: Bool
        var directStream: ResolvedStream?
    }

    private func playbackAsset(for song: Song, preferMusicVideo: Bool) -> PlaybackAsset {
        // 独立 MV(媒体本体是视频)不看 preferMusicVideo —— 没有独立音频可回落。
        guard preferMusicVideo || song.isStandaloneMusicVideo,
              let path = normalizedMusicVideoPath(for: song) else {
            return PlaybackAsset(
                song: song,
                fileExtension: song.fileFormat.rawValue.lowercased(),
                isVideo: false,
                directStream: nil
            )
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let videoFormat = VideoFormat.from(fileExtension: ext),
              videoFormat.isNativelyPlayable else {
            return PlaybackAsset(
                song: song,
                fileExtension: song.fileFormat.rawValue.lowercased(),
                isVideo: false,
                directStream: nil
            )
        }
        var videoSong = song
        videoSong.filePath = path
        videoSong.fileFormat = AudioFormat.from(fileExtension: ext) ?? song.fileFormat
        // sidecar MV 的 size 未知(目录列举给的是音频的), 置 0 让下游自己探;
        // 独立 MV 的 fileSize 就是视频本身, 保留供 range 读取用。
        videoSong.fileSize = song.isStandaloneMusicVideo ? song.fileSize : 0
        let directStream = URL(string: path).flatMap { url in
            url.scheme == nil ? nil : ResolvedStream(url: url)
        }
        return PlaybackAsset(
            song: videoSong,
            fileExtension: ext,
            isVideo: true,
            directStream: directStream
        )
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
                directStream: ResolvedStream(url: url)
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
                    directStream: ResolvedStream(
                        url: originURL,
                        headers: wrapper.headers
                    )
                )
            }
            resolvedSong.filePath = path
            return PlaybackAsset(
                song: resolvedSong,
                fileExtension: descriptor.format.rawValue.lowercased(),
                isVideo: false,
                directStream: nil
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
            do {
                let size = try await reader.contentLength()
                guard size > 0 else { throw STRMDescriptorError.empty }
                let data = try await reader.read(offset: 0, length: min(size, maximum + 1))
                await reader.close()
                return try STRMDescriptorParser.parse(data)
            } catch {
                await reader.close()
                throw error
            }
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

    private func probeWAVPayload(
        asset: PlaybackAsset,
        source: MusicSource,
        credential: SourceCredential?,
        requestID: UUID
    ) async -> RemoteWAVPlaybackPolicy.ProbeOutcome {
        let maximum = Int64(256 * 1_024)
        do {
            let prefix: Data
            if let directStream = asset.directStream {
                prefix = try await fetchHTTPPrefix(
                    directStream,
                    maximumLength: maximum,
                    redirectMode: source.type == .fnMusic ? .fnMusic : .safe
                )
            } else if let reader = Self.makeDirectReader(
                source: source,
                song: asset.song,
                credential: credential
            ) {
                do {
                    let total = try await reader.contentLength()
                    prefix = try await reader.read(
                        offset: 0,
                        length: min(maximum, total)
                    )
                    await reader.close()
                } catch {
                    await reader.close()
                    throw error
                }
            } else {
                let resolved = try await resolveStream(
                    song: asset.song,
                    source: source,
                    credential: credential,
                    requestID: requestID,
                    retried: false
                )
                prefix = try await fetchHTTPPrefix(
                    resolved,
                    maximumLength: maximum,
                    redirectMode: source.type == .fnMusic ? .fnMusic : .safe
                )
            }
            guard let store else { return .unavailable }
            try ensureCurrent(requestID, store: store)
            switch AudioFileSignaturePolicy.inspect(prefix) {
            case .dtsInWave, .dts:
                return .dts
            case .riffWave:
                return .pcm
            default:
                return .unavailable
            }
        } catch is CancellationError {
            return .unavailable
        } catch {
            plog("🎬 TV WAV probe unavailable — \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func fetchHTTPPrefix(
        _ stream: ResolvedStream,
        maximumLength: Int64,
        redirectMode: StreamResolverHTTPRedirectMode
    ) async throws -> Data {
        guard let range = SafeByteRange.httpHeader(offset: 0, length: maximumLength) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: stream.url)
        for (key, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: Self.lyricsSession,
            maximumBytes: Int(maximumLength),
            redirectMode: redirectMode
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 206:
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length")
                    .flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: 0,
                requestedLength: maximumLength
            ) != nil else { throw URLError(.badServerResponse) }
        case 200:
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: 0,
                requestedLength: maximumLength
            ) else { throw URLError(.badServerResponse) }
        default:
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
        return data
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
        engine.startPlayback(at: startAt, autoPlay: autoPlay)
        loadLyrics(song: song, source: source, credential: credential, requestID: requestID)
        schedulePlaybackMetadataRead(
            song: song,
            source: source,
            credential: credential,
            requestID: requestID
        )
    }

    private func schedulePlaybackMetadataRead(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        requestID: UUID
    ) {
        let identity = PlaybackMetadataIdentity(song)
        if playbackMetadataSelectionIdentity != identity {
            playbackMetadataSelectionIdentity = identity
            playbackMetadataFailureCounts.removeAll(keepingCapacity: true)
        }
        let failureCount = playbackMetadataFailureCounts[identity] ?? 0
        guard PlaybackMetadataBackfillPolicy.shouldStart(
            sourceType: source.type,
            hasMissingMetadata: PlaybackMetadataBackfillPolicy.hasMissingCoreMetadata(
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                duration: song.duration
            ),
            isCueTrack: song.isCueTrack,
            isStreamDescriptor: song.isStreamDescriptor,
            isAlreadyReading: playbackMetadataTaskIdentity == identity,
            completedForCurrentFile: playbackMetadataCompletedIdentities.contains(identity),
            failedAttemptCount: failureCount
        ) else {
            return
        }

        let token = UUID()
        playbackMetadataTaskIdentity = identity
        playbackMetadataTaskToken = token
        playbackMetadataTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.runPlaybackMetadataRead(
                identity: identity,
                token: token,
                song: song,
                source: source,
                credential: credential,
                requestID: requestID
            )
        }
    }

    private func runPlaybackMetadataRead(
        identity: PlaybackMetadataIdentity,
        token: UUID,
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        requestID: UUID
    ) async {
        defer {
            if playbackMetadataTaskToken == token {
                playbackMetadataTask = nil
                playbackMetadataTaskIdentity = nil
                playbackMetadataTaskToken = nil
            }
        }

        while !Task.isCancelled {
            guard let store,
                  playbackMetadataTaskToken == token,
                  isCurrent(requestID, store: store),
                  store.library.song(id: identity.songID).map(PlaybackMetadataIdentity.init)
                    == identity else {
                return
            }

            let pool = TVMetadataReaderPool(source: source, credential: credential)
            let result = await TVMetadataEnricher.enrich(
                song: song,
                sidecars: SidecarDirectoryIndex<TVDirEntry>([]),
                using: pool
            )
            await pool.closeAll()

            guard !Task.isCancelled,
                  playbackMetadataTaskToken == token,
                  isCurrent(requestID, store: store),
                  let live = store.library.song(id: identity.songID),
                  PlaybackMetadataIdentity(live) == identity else {
                return
            }

            switch result.status {
            case .enriched:
                let updated = SongUserMetadataPolicy.preservingUserEdits(
                    from: live,
                    in: result.song
                )
                playbackMetadataFailureCounts[identity] = nil
                playbackMetadataCompletedIdentities.insert(identity)
                applyPlaybackMetadata(updated, requestID: requestID, store: store)
                if store.lyrics.isEmpty,
                   let cached = await MetadataAssetStore.shared.cachedLyrics(
                    forSongID: updated.id
                   ), !cached.isEmpty,
                   isCurrent(requestID, store: store) {
                    store.applyLyrics(
                        Self.toTVLyrics(cached, duration: updated.duration),
                        forSongID: updated.id
                    )
                }
                return
            case .cancelled:
                return
            case .failed, .timedOut:
                let failureCount = (playbackMetadataFailureCounts[identity] ?? 0) + 1
                playbackMetadataFailureCounts[identity] = failureCount
                guard let delay = PlaybackMetadataBackfillPolicy.retryDelay(
                    afterFailedAttempt: failureCount
                ) else {
                    plog(
                        "TV WebDAV playback metadata read stopped after "
                            + "\(failureCount) attempts for '\(song.title)'"
                    )
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func applyPlaybackMetadata(
        _ song: Song,
        requestID: UUID,
        store: TVStore
    ) {
        guard isCurrent(requestID, store: store),
              store.nowPlaying.songID == song.id else {
            return
        }
        store.library.replaceSongs([song])
        let artist = store.library.artistDisplayName(for: song)
            ?? song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? PMString("ext.tv.unknownArtist")
        store.nowPlaying.coverRef = song.coverArtFileName
        store.nowPlaying.title = song.title
        store.nowPlaying.artist = artist
        store.nowPlaying.album = song.albumTitle ?? ""
        store.nowPlaying.albumID = song.albumID ?? ""
        store.nowPlaying.duration = song.duration
        store.nowPlaying.format = song.fileFormat.displayName
        store.nowPlaying.bitrate = song.bitRate ?? 0
        store.nowPlaying.sampleRate = Double(song.sampleRate ?? 0) / 1_000
        engine.updateCatalogMetadata(
            title: song.title,
            artist: artist,
            album: song.albumTitle ?? "",
            duration: song.duration
        )
    }

    private func playNonNative(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        ext: String,
        directStream: ResolvedStream? = nil,
        inspectWAVAfterDownload: Bool,
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
            var tempURL = try await downloadToTemp(
                song: song,
                source: source,
                credential: credential,
                ext: ext,
                directStream: directStream,
                requestID: requestID
            )
            if inspectWAVAfterDownload {
                tempURL = try await decoderURLAfterWAVInspection(tempURL)
            }
            downloadedTempURL = tempURL
            try ensureCurrent(requestID, store: store)
            guard isCurrent(requestID, store: store) else { return }
            let displayArtistName = store.library.artistDisplayName(for: song) ?? ""
            try engine.loadDecoded(
                fileURL: tempURL,
                title: song.title,
                artist: displayArtistName,
                album: song.albumTitle ?? "",
                duration: song.duration,
                cueStartTime: song.cueStartTime,
                cueEndTime: song.cueEndTime
            )
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
                              directStream: ResolvedStream? = nil,
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
        let initialBudget = await Self.decodedDownloadBudget(in: temporaryDirectory)
        if song.fileSize > 0 {
            try Self.validateDownloadSize(song.fileSize, budget: initialBudget)
        }
        if let directStream {
            var request = URLRequest(url: directStream.url)
            for (key, value) in directStream.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (downloadedURL, response) = try await StreamResolverHTTPTransport.download(
                for: request,
                session: Self.lyricsSession,
                redirectMode: source.type == .fnMusic ? .fnMusic : .safe
            )
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            try ensureCurrent(requestID, store: store)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw StreamResolveError.badServerResponse(http.statusCode)
            }
            try await Self.validateDownloadedFile(
                downloadedURL,
                response: response,
                initialBudget: initialBudget
            )
            try FileManager.default.moveItem(at: downloadedURL, to: tmp)
            shouldKeepFile = true
            return tmp
        }
        if let reader = Self.makeDirectReader(source: source, song: song, credential: credential) {
            do {
                let total = try await reader.contentLength()
                try ensureCurrent(requestID, store: store)
                guard ExactChunkedDownloadPolicy.contentLengthIsValid(total), total > 0 else {
                    throw TVDecodedDownloadError.invalidContentLength(total)
                }
                try Self.validateDownloadSize(total, budget: initialBudget)
                let writer = try TVDecodedFileWriter(url: tmp)
                do {
                    var offset: Int64 = 0
                    let chunk: Int64 = 1 << 20
                    while offset < total {
                        try Task.checkCancellation()
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
                        try await writer.append(data)
                        offset += Int64(data.count)
                    }
                    guard ExactChunkedDownloadPolicy.isComplete(
                        expectedLength: total,
                        writtenLength: offset
                    ) else {
                        throw TVDecodedDownloadError.incomplete(expected: total, actual: offset)
                    }
                    try await writer.close()
                } catch {
                    try? await writer.close()
                    throw error
                }
                await reader.close()
                shouldKeepFile = true
                return tmp
            } catch {
                await reader.close()
                throw error
            }
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
        try await Self.validateDownloadedFile(
            downloadedURL,
            response: response,
            initialBudget: initialBudget
        )
        try FileManager.default.moveItem(at: downloadedURL, to: tmp)
        shouldKeepFile = true
        return tmp
    }

    private nonisolated static func decodedDownloadBudget(in directory: URL) async -> Int64 {
        let available: Int64? = await Task.detached(priority: .utility) {
            guard let capacity = try? directory.resourceValues(
                forKeys: [.volumeAvailableCapacityKey]
            ).volumeAvailableCapacity else {
                return nil
            }
            return Int64(capacity)
        }.value
        return TVDecodedDownloadStoragePolicy.writableBudget(availableCapacity: available)
    }

    private nonisolated static func validateDownloadSize(
        _ size: Int64,
        budget: Int64
    ) throws {
        guard TVDecodedDownloadStoragePolicy.accepts(
            contentLength: size,
            writableBudget: budget
        ) else {
            throw TVDecodedDownloadError.insufficientStorage(
                required: max(0, size),
                available: max(0, budget)
            )
        }
    }

    private nonisolated static func validateDownloadedFile(
        _ fileURL: URL,
        response: URLResponse,
        initialBudget: Int64
    ) async throws {
        let actual: Int64 = try await Task.detached(priority: .utility) {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? -1)
        }.value
        guard actual > 0 else {
            throw TVDecodedDownloadError.invalidContentLength(actual)
        }
        try validateDownloadSize(actual, budget: initialBudget)
        let expected = response.expectedContentLength
        if expected > 0, expected != actual {
            throw TVDecodedDownloadError.incomplete(expected: expected, actual: actual)
        }
    }

    private func decoderURLAfterWAVInspection(_ fileURL: URL) async throws -> URL {
        let signature = try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            return AudioFileSignaturePolicy.inspect(data)
        }.value
        guard signature == .dtsInWave || signature == .dts else { return fileURL }

        let destination = TVDecodedTemporaryFilePolicy.makeURL(
            in: fileURL.deletingLastPathComponent(),
            fileExtension: AudioFormat.dts.rawValue
        )
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
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

    /// 加载歌词:先本地缓存(随快照同步下来的 / 之前抓过的),再按源能力读取服务端歌词
    /// 或源内 `.lrc` sidecar。`lyricsFileName` 指向源里的歌词文件(NAS 是 `.lrc`
    /// 真实路径,云盘是 item ID),复用 stream resolver 解出下载地址即可。
    private func loadLyrics(song: Song, source: MusicSource,
                            credential: SourceCredential?, requestID: UUID) {
        lyricsTask?.cancel()
        lyricsTask = Task { [weak self, weak store, song, source, credential] in
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

            switch TVLyricsLoadingPolicy.strategy(for: source.type) {
            case .fnMusicService:
                guard let client = store.fnMusicClient(for: source.id) else { return }
                do {
                    guard let text = try await client.preferredLyrics(trackPath: song.filePath),
                          !text.isEmpty else { return }
                    try self.ensureCurrent(requestID, store: store)
                    try await self.cacheAndApplyServerLyrics(
                        text,
                        song: song,
                        requestID: requestID,
                        store: store,
                        logSource: "Feiniu Music"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrent(requestID, store: store) else { return }
                    plog("🎬 TV Feiniu Music lyrics fetch failed '\(song.title)': \(error)")
                }
                return
            case .subsonicServer:
                let result = await self.readSubsonicServerLyrics(
                    for: song.filePath,
                    source: source,
                    credential: credential
                )
                guard self.isCurrent(requestID, store: store) else { return }
                switch result {
                case .content(let text):
                    do {
                        try await self.cacheAndApplyServerLyrics(
                            text,
                            song: song,
                            requestID: requestID,
                            store: store,
                            logSource: source.type.displayName
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        guard self.isCurrent(requestID, store: store) else { return }
                        plog("🎬 TV Subsonic lyrics apply failed '\(song.title)': \(error)")
                    }
                case .absent:
                    break
                case .unavailable:
                    plog("🎬 TV Subsonic lyrics unavailable for '\(song.title)'")
                }
                return
            case .sourceFile:
                break
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

    private func cacheAndApplyServerLyrics(
        _ text: String,
        song: Song,
        requestID: UUID,
        store: TVStore,
        logSource: String
    ) async throws {
        let lines = LyricsParser.parseText(text)
        guard !lines.isEmpty else { return }
        let wrote = await MetadataAssetStore.shared.cacheLyrics(
            lines,
            forSongID: song.id,
            force: false
        )
        try ensureCurrent(requestID, store: store)
        if wrote {
            store.applyLyrics(
                Self.toTVLyrics(lines, duration: song.duration),
                forSongID: song.id
            )
            plog("🎬 TV \(logSource) lyrics loaded \(lines.count) lines for '\(song.title)'")
        } else if let preserved = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
                  !preserved.isEmpty {
            try ensureCurrent(requestID, store: store)
            store.applyLyrics(
                Self.toTVLyrics(preserved, duration: song.duration),
                forSongID: song.id
            )
        }
    }

    private func readSubsonicServerLyrics(
        for path: String,
        source: MusicSource,
        credential: SourceCredential?
    ) async -> SubsonicLyricsReadResult {
        let runtime = SourceConnectionRuntime.shared
        let candidates = await runtime.orderedCandidates(for: source)
        if candidates.isEmpty {
            return await SubsonicLyricsClient(session: Self.lyricsSession).readLyrics(
                forSongPath: path,
                source: source,
                credential: credential
            )
        }

        for candidate in candidates {
            guard !Task.isCancelled else { return .unavailable }
            let routedSource = source.applyingConnectionCandidate(candidate)
            let result = await SubsonicLyricsClient(session: Self.lyricsSession).readLyrics(
                forSongPath: path,
                source: routedSource,
                credential: credential
            )
            switch result {
            case .content(_), .absent:
                await runtime.record(candidate.kind, for: source.id)
                return result
            case .unavailable:
                continue
            }
        }
        return .unavailable
    }

    /// 取歌词文本:协议直连源用 reader 直读小文件;HTTP/云盘走 StreamResolver 解 URL 下载。
    private func fetchLyricText(song: Song, source: MusicSource,
                                credential: SourceCredential?, requestID: UUID) async throws -> String? {
        guard let store else { throw CancellationError() }
        if let reader = Self.makeDirectReader(source: source, song: song, credential: credential) {
            do {
                let size = try await reader.contentLength()
                try ensureCurrent(requestID, store: store)
                guard size > 0, size < 512 * 1024 else {
                    await reader.close()
                    return nil
                }
                let data = try await reader.read(offset: 0, length: size)
                try ensureCurrent(requestID, store: store)
                await reader.close()
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            } catch {
                await reader.close()
                throw error
            }
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

    nonisolated static func toTVLyrics(
        _ lines: [LyricLine],
        duration _: TimeInterval
    ) -> [TVLyricLine] {
        let documentWritingDirection = LyricWritingDirectionPolicy.resolve(in: lines)
        return lines.map { line in
            TVLyricLine(id: line.id,
                        time: line.timestamp,
                        text: line.text,
                        isSynchronized: line.isSynchronized,
                        // start/end 是相对歌曲起点的绝对时间戳；保留间隔才能避免静音期继续扫光。
                        syllables: (line.syllables ?? []).map {
                            TVSyllable(
                                w: $0.text,
                                start: $0.start,
                                end: $0.end,
                                endTiming: $0.endTiming
                            )
                        },
                        translation: "",
                        writingDirection: LyricWritingDirectionPolicy.resolvePresentationDirection(
                            for: line,
                            documentFallback: documentWritingDirection
                        ))
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
