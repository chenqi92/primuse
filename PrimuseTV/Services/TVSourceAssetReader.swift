#if os(tvOS)
import CryptoKit
import Foundation
import PrimuseKit

/// Reuses the same server adapters as the phone and desktop so resource
/// references retain their authentication and server-specific meaning.
actor TVSourceAssetReader {
    static let shared = TVSourceAssetReader()

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
        type.isSubsonicFamily || [.jellyfin, .emby, .plex, .songloft, .synologyAudioStation].contains(type)
    }

    func artworkData(reference: String, source: MusicSource, credential: SourceCredential?, maximumBytes: Int) async -> Data? {
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
        let client = SynologyAudioStationClient(source: source, credential: credential)
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
