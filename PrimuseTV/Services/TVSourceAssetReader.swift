#if os(tvOS)
import CryptoKit
import Foundation
import PrimuseKit

/// Reuses the same server adapters as the phone and desktop so resource
/// references retain their authentication and server-specific meaning.
actor TVSourceAssetReader {
    static let shared = TVSourceAssetReader()
    private let registry: StreamResolverRegistry
    private let session: URLSession

    init(registry: StreamResolverRegistry = .shared, session: URLSession? = nil) {
        self.registry = registry
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration, delegate: TVInsecureTLSDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private struct CachedConnector {
        let identity: String
        let connector: any MusicSourceConnector
    }
    private var connectors: [String: CachedConnector] = [:]

    /// 群晖 Audio Station 在电视上不经 App 连接器,直接用 Kit 的客户端;同样按源缓存,
    /// 接口发现、QuickConnect 解析与登录会话跨封面、歌词请求复用。
    private struct CachedAudioStationClient {
        let identity: String
        let client: SynologyAudioStationClient
    }
    private var audioStationClients: [String: CachedAudioStationClient] = [:]

    nonisolated static func supports(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily
            || [.jellyfin, .emby, .plex, .songloft, .synology, .synologyAudioStation, .audiobookshelf, .tingReader]
                .contains(type)
    }

    private struct CachedAudiobookshelfClient {
        let identity: String
        let client: AudiobookshelfServiceClient
    }
    private var audiobookshelfClients: [String: CachedAudiobookshelfClient] = [:]

    private var audiobookshelfItems: [String: AudiobookshelfCatalogItem] = [:]

    /// 把本机这首歌的位置报到 Audiobookshelf(整本书的时间轴由条目的文件布局换算)。
    func reportAudiobookshelfProgress(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        position: TimeInterval,
        isFinished: Bool
    ) async {
        guard source.type == .audiobookshelf,
              let reference = AudiobookshelfAPIProtocol.trackReference(from: song.filePath) else { return }
        let client = audiobookshelfClient(for: source, credential: credential)
        do {
            let item: AudiobookshelfCatalogItem
            if let cached = audiobookshelfItems[reference.itemID] {
                item = cached
            } else if let fetched = try await client.item(id: reference.itemID) {
                audiobookshelfItems[reference.itemID] = fetched
                item = fetched
            } else {
                return
            }
            guard let payload = item.serverProgress(for: reference.kind, position: position, isFinished: isFinished) else { return }
            try await client.updateMediaProgress(
                itemID: item.id,
                episodeID: payload.episodeID,
                currentTime: payload.currentTime,
                duration: payload.duration,
                isFinished: payload.isFinished
            )
        } catch {
            plog("🎧 TV Audiobookshelf progress push failed '\(song.title)': \(error.localizedDescription)")
        }
    }

    /// 封面与进度上报共用一份登录会话;配置或凭据变了才重建。
    private func audiobookshelfClient(for source: MusicSource, credential: SourceCredential?) -> AudiobookshelfServiceClient {
        let identity = Self.cacheIdentity(source: source, credential: credential)
        if let cached = audiobookshelfClients[source.id], cached.identity == identity { return cached.client }
        if let stale = audiobookshelfClients.removeValue(forKey: source.id) {
            Task { await stale.client.invalidateSession() }
        }
        let client = AudiobookshelfServiceClient(source: source, credential: credential)
        audiobookshelfClients[source.id] = CachedAudiobookshelfClient(identity: identity, client: client)
        return client
    }

    private struct CachedTingReaderClient {
        let identity: String
        let client: TingReaderServiceClient
    }
    private var tingReaderClients: [String: CachedTingReaderClient] = [:]

    /// 把本机这一章的位置报到 Ting Reader。服务端按章记,不用换算时间轴。
    func reportTingReaderProgress(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        position: TimeInterval,
        isFinished: Bool
    ) async {
        guard source.type == .tingReader,
              let reference = TingReaderAPIProtocol.trackReference(from: song.filePath) else { return }
        do {
            try await tingReaderClient(for: source, credential: credential).updateProgress(
                bookID: reference.bookID,
                chapterID: reference.chapterID,
                position: TingReaderProgressPolicy.reportedPosition(
                    position: position,
                    duration: song.duration,
                    isFinished: isFinished
                ),
                duration: song.duration
            )
        } catch {
            plog("🎧 TV Ting Reader progress push failed '\(song.title)': \(error.localizedDescription)")
        }
    }

    /// 服务端记的这一条的进度(别的客户端听到的位置),换条目时拿来续播;源不记进度、取不到时为 nil。
    func serverSpokenWordProgress(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async -> TVServerSpokenWordProgress? {
        do {
            switch source.type {
            case .tingReader:
                guard let reference = TingReaderAPIProtocol.trackReference(from: song.filePath) else { return nil }
                let chapters = try await tingReaderClient(for: source, credential: credential)
                    .chapters(bookID: reference.bookID)
                guard let chapter = chapters.first(where: { $0.id == reference.chapterID }),
                      let progress = TingReaderProgressPolicy.progress(for: chapter) else { return nil }
                return TVServerSpokenWordProgress(
                    position: progress.position,
                    duration: progress.duration,
                    isFinished: progress.isFinished,
                    updatedAt: progress.updatedAt
                )
            case .audiobookshelf:
                guard let reference = AudiobookshelfAPIProtocol.trackReference(from: song.filePath) else { return nil }
                let client = audiobookshelfClient(for: source, credential: credential)
                let records = try await client.mediaProgress().filter { $0.libraryItemID == reference.itemID }
                guard !records.isEmpty else { return nil }
                let item: AudiobookshelfCatalogItem
                if let cached = audiobookshelfItems[reference.itemID] {
                    item = cached
                } else if let fetched = try await client.item(id: reference.itemID) {
                    audiobookshelfItems[reference.itemID] = fetched
                    item = fetched
                } else {
                    return nil
                }
                // 书是整本一条进度,播客每集一条;换算到这个文件 / 这一集。
                for record in records {
                    guard let track = item.trackProgress(from: record).first(where: { $0.kind == reference.kind }) else {
                        continue
                    }
                    return TVServerSpokenWordProgress(
                        position: track.position,
                        duration: track.duration,
                        isFinished: track.isFinished,
                        updatedAt: record.lastUpdate ?? Date()
                    )
                }
                return nil
            default:
                return nil
            }
        } catch {
            plog("🎧 TV server progress read failed '\(song.title)': \(error.localizedDescription)")
            return nil
        }
    }

    /// 封面与进度上报共用一份登录会话;配置或凭据变了才重建。
    private func tingReaderClient(for source: MusicSource, credential: SourceCredential?) -> TingReaderServiceClient {
        let identity = Self.cacheIdentity(source: source, credential: credential)
        if let cached = tingReaderClients[source.id], cached.identity == identity { return cached.client }
        if let stale = tingReaderClients.removeValue(forKey: source.id) {
            Task { await stale.client.invalidateSession() }
        }
        let client = TingReaderServiceClient(source: source, credential: credential)
        tingReaderClients[source.id] = CachedTingReaderClient(identity: identity, client: client)
        return client
    }

    func artworkData(reference: String, source: MusicSource, credential: SourceCredential?, maximumBytes: Int) async -> Data? {
        if source.type == .synology {
            // 文件源保存的是 NAS 上的图片路径,须和音频一样通过 File Station 鉴权读取。
            guard reference.hasPrefix("/"), !reference.hasPrefix("//"), maximumBytes > 0 else { return nil }
            let artwork = Song(id: "artwork:\(source.id):\(reference)", title: "", fileFormat: .mp3,
                               filePath: reference, sourceID: source.id)
            do {
                let resolved = try await registry.resolve(for: artwork, source: source, credential: credential)
                var request = URLRequest(url: resolved.url)
                for (name, value) in resolved.headers { request.setValue(value, forHTTPHeaderField: name) }
                let (data, response) = try await StreamResolverHTTPTransport.data(
                    for: request, session: session, maximumBytes: maximumBytes
                )
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
                return data
            } catch { return nil }
        }
        let candidates = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
        let routes = candidates.isEmpty
            ? [source]
            : candidates.map { source.applyingConnectionCandidate($0) }
        for routed in routes {
            guard !Task.isCancelled else { return nil }
            do {
                let data: Data?
                if routed.type == .synologyAudioStation {
                    // 只认扫描时写进 `coverArtFileName` 的引用;没有封面时是 nil,交给刮削。
                    guard SynologyAudioStationCoverReference(rawValue: reference) != nil else { return nil }
                    data = try await audioStationClient(for: routed, credential: credential)
                        .artwork(reference: reference, maxBytes: maximumBytes)
                } else if routed.type == .audiobookshelf {
                    guard AudiobookshelfAPIProtocol.coverItemID(fromReference: reference) != nil else { return nil }
                    data = try await audiobookshelfClient(for: routed, credential: credential)
                        .coverData(reference: reference, maximumBytes: maximumBytes)
                } else if routed.type == .tingReader {
                    guard TingReaderAPIProtocol.coverReference(from: reference) != nil else { return nil }
                    data = try await tingReaderClient(for: routed, credential: credential)
                        .coverData(reference: reference, maximumBytes: maximumBytes)
                } else {
                    guard let connector = connector(for: routed, credential: credential) else { return nil }
                    data = try await connector.fetchArtworkData(for: reference, maximumBytes: maximumBytes, purpose: .thumbnail)
                }
                try Task.checkCancellation()
                return data
            } catch is CancellationError { return nil }
            catch { continue }
        }
        return nil
    }

    func lyrics(path: String, source: MusicSource, credential: SourceCredential?) async -> ServerLyricsReadResult {
        let candidates = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
        let routes = candidates.isEmpty
            ? [source]
            : candidates.map { source.applyingConnectionCandidate($0) }
        for routed in routes {
            guard !Task.isCancelled else { return .unavailable }
            let result: ServerLyricsReadResult
            if routed.type == .daoliyu {
                do {
                    let text = try await DaoLiYuServiceClient(source: routed, credential: credential)
                        .preferredLyrics(trackPath: path)
                    result = text.flatMap { $0.isEmpty ? nil : $0 }.map(ServerLyricsReadResult.content) ?? .absent
                } catch { continue }
            } else if routed.type == .synologyAudioStation {
                guard let id = SynologyAudioStationAPI.songID(fromTrackPath: path) else { return .unavailable }
                do {
                    let text = try await audioStationClient(for: routed, credential: credential).lyrics(id: id)
                    result = text.map(ServerLyricsReadResult.content) ?? .absent
                } catch let error as SynologyAudioStationError {
                    // 套件没有歌词接口时服务端永远给不出歌词,如实说「没有」(与 iPhone 端一致)。
                    switch error {
                    case .apiNotFound, .unsupportedVersion: result = .absent
                    default: continue
                    }
                } catch { continue }
            } else {
                guard let connector = connector(for: routed, credential: credential) as? any ServerLyricsConnector else { return .unavailable }
                result = await connector.readServerLyrics(for: path)
            }
            guard !Task.isCancelled else { return .unavailable }
            if case .unavailable = result { continue }
            return result
        }
        return .unavailable
    }

    /// Subsonic 一族的接口不给编码:按 `ContainerCodecProbe` 要的那几段经原文件流(`format=raw`)
    /// 读 M4A 这类容器的文件头,认出里面装的是 ALAC 还是 AAC。返回该记进 `Song.audioCodec` 的值
    /// (认不出时是容器本身,表示读过);连不上或服务端不认 Range 时为 nil,下次再读。
    func inspectedContainerCodec(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async -> AudioFormat? {
        guard source.type.readsContainerCodecFromFileHeader,
              !song.isStreamDescriptor,
              song.fileFormat.holdsVariousCodecs else { return nil }
        let candidates = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
        let routes = candidates.isEmpty
            ? [source]
            : candidates.map { source.applyingConnectionCandidate($0) }
        for routed in routes {
            guard !Task.isCancelled,
                  let connector = connector(for: routed, credential: credential) else { return nil }
            do {
                var probe = ContainerCodecProbe(container: song.fileFormat, fileSize: song.fileSize)
                while case .read(let offset, let length) = probe.step {
                    guard length > 0 else {
                        probe.consume(Data())
                        continue
                    }
                    let data = try await connector.fetchRange(path: song.filePath, offset: offset, length: length)
                    try Task.checkCancellation()
                    probe.consume(data)
                }
                guard case .finished(let codec) = probe.step else { return nil }
                return ContainerAudioCodecPolicy.inspectedCodec(codec, container: song.fileFormat)
            } catch is CancellationError {
                return nil
            } catch {
                plog("🎵 TV container codec read failed '\(song.title)': \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    nonisolated static func cacheIdentity(source: MusicSource, credential: SourceCredential?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let material = (try? encoder.encode(source)) ?? Data()
        let secret = (try? encoder.encode([credential?.username, credential?.password, credential?.token])) ?? Data()
        return SHA256.hash(data: material + secret).map { String(format: "%02x", $0) }.joined()
    }

    private func connector(for source: MusicSource, credential: SourceCredential?) -> (any MusicSourceConnector)? {
        let identity = Self.cacheIdentity(source: source, credential: credential)
        if let cached = connectors[source.id], cached.identity == identity { return cached.connector }
        let value: any MusicSourceConnector
        if source.type.isSubsonicFamily {
            value = SubsonicSource(sourceID: source.id, sourceType: source.type,
                host: source.host ?? "", port: source.port, useSsl: source.useSsl,
                basePath: source.basePath, username: credential?.username ?? source.username ?? "",
                password: credential?.password ?? credential?.token ?? "",
                alternateTLSValidationHostname: source.alternateTLSValidationHostname)
        } else if source.type == .songloft {
            value = SongloftSource(sourceID: source.id, host: source.host ?? "",
                port: source.port, useSSL: source.useSsl, basePath: source.basePath,
                username: credential?.username ?? source.username ?? "", password: credential?.password ?? "",
                alternateTLSValidationHostname: source.alternateTLSValidationHostname)
        } else {
            let kind: MediaServerSource.Kind
            switch source.type {
            case .jellyfin: kind = .jellyfin
            case .emby: kind = .emby
            case .plex: kind = .plex
            default: return nil
            }
            value = MediaServerSource(sourceID: source.id, kind: kind,
                host: source.host ?? "", port: source.port, useSsl: source.useSsl,
                basePath: source.basePath, username: credential?.username ?? source.username ?? "",
                secret: credential?.password ?? credential?.token ?? "", authType: source.authType,
                alternateTLSValidationHostname: source.alternateTLSValidationHostname)
        }
        connectors[source.id] = CachedConnector(identity: identity, connector: value)
        return value
    }

    private func audioStationClient(for source: MusicSource, credential: SourceCredential?) -> SynologyAudioStationClient {
        let identity = Self.cacheIdentity(source: source, credential: credential)
        if let cached = audioStationClients[source.id], cached.identity == identity { return cached.client }
        if let stale = audioStationClients.removeValue(forKey: source.id) {
            Task { await stale.client.invalidateSession() }
        }
        let client = SynologyAudioStationClient(
            source: source, credential: credential,
            deviceName: source.deviceId?.isEmpty == false ? SynologyAudioStationStreamResolver.trustedDeviceName : nil
        )
        audioStationClients[source.id] = CachedAudioStationClient(identity: identity, client: client)
        return client
    }
}

@MainActor
extension TVStore {
    func songArtworkData(songID: String, coverRef: String?, animationCacheKey: String? = nil) async -> Data? {
        let source = library.song(id: songID).flatMap { self.source(id: $0.sourceID) }
        guard source?.isEnabled != false, source?.isDeleted != true else { return nil }
        let credential = source.flatMap { TVCredentialStore.credential(for: $0, bundle: credentialBundle) }
        let data = await TVArtworkLoader.shared.songCover(
            songID: songID, coverRef: coverRef,
            fnMusicSourceID: source?.id, fnMusicClient: source.flatMap { fnMusicClient(for: $0.id) },
            animationCacheKey: animationCacheKey, source: source, credential: credential
        )
        guard !Task.isCancelled, source.map({ self.source(id: $0.id) == $0 }) ?? true else { return nil }
        return data
    }
}

#endif

/// 服务端记的一条有声内容的进度,已经换算到这一条自己(书里的一个文件 / 一章 / 播客的一集)上。
struct TVServerSpokenWordProgress: Sendable, Equatable {
    let position: TimeInterval
    let duration: TimeInterval
    let isFinished: Bool
    let updatedAt: Date
}
