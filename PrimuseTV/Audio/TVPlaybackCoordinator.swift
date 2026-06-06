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
        case .unsupported(let name): return "「\(name)」类型暂不支持在 Apple TV 直接播放(仅手机 / 电脑)"
        case .missingCredential(let name): return "缺少「\(name)」的登录凭据 —— 请确认手机已登录且开启 iCloud 钥匙串"
        case .failed(let msg): return msg
        }
    }
}

/// 串起 TVStore(持有真实 Song/MusicSource)↔ StreamResolver ↔ TVAudioEngine。
/// 把真实歌曲解析成网络流 URL 并交给 AVPlayer;解析失败转成可展示的 TVPlaybackIssue。
@MainActor
final class TVPlaybackCoordinator {
    private unowned let store: TVStore
    private let engine: TVAudioEngine
    private let registry = StreamResolverRegistry.shared

    init(store: TVStore, engine: TVAudioEngine) {
        self.store = store
        self.engine = engine
    }

    func play(songID: String) async {
        store.playbackIssue = nil
        guard let song = store.library.song(id: songID) else {
            plog("🎬 TV play: song not found id=\(songID)")
            store.playbackIssue = .failed("曲库中找不到这首歌")
            return
        }
        guard let source = store.sourcesStore.source(id: song.sourceID) else {
            plog("🎬 TV play: NO source for '\(song.title)' sourceID=\(song.sourceID)")
            store.playbackIssue = .unsupported(song.sourceID)
            return
        }
        let credential = TVCredentialStore.credential(for: source, bundle: store.credentialBundle)
        plog("🎬 TV play: '\(song.title)' src=\(source.type.rawValue)/\(source.name) cred=\(credential != nil) path=\(song.filePath.suffix(40))")
        do {
            let resolved = try await resolveStream(song: song, source: source, credential: credential, retried: false)
            plog("🎬 TV play: resolved → host=\(resolved.url.host ?? "?") headers=\(resolved.headers.count)")
            engine.load(url: resolved.url,
                        headers: resolved.headers,
                        fileExtension: song.fileFormat.rawValue,
                        title: song.title,
                        artist: song.artistName ?? "",
                        album: song.albumTitle ?? "",
                        duration: song.duration)
            engine.play()
        } catch let error as StreamResolveError {
            plog("🎬 TV play: resolve FAILED — \(error)")
            store.playbackIssue = issue(for: error, source: source)
        } catch {
            plog("🎬 TV play: resolve error — \(error)")
            store.playbackIssue = .failed(error.localizedDescription)
        }
    }

    /// 会话过期(.authFailed)时清掉会话并重试一次(Synology/cloud 用;Subsonic 无状态不会触发)。
    private func resolveStream(song: Song, source: MusicSource,
                              credential: SourceCredential?, retried: Bool) async throws -> ResolvedStream {
        do {
            return try await registry.resolve(for: song, source: source, credential: credential)
        } catch StreamResolveError.authFailed where !retried {
            await registry.invalidateSession(for: source)
            return try await resolveStream(song: song, source: source, credential: credential, retried: true)
        }
    }

    private func issue(for error: StreamResolveError, source: MusicSource) -> TVPlaybackIssue {
        switch error {
        case .unsupportedSourceType(let type): return .unsupported(type.displayName)
        case .missingCredential: return .missingCredential(source.name)
        case .authFailed: return .failed("鉴权失败,请在手机上重新登录该音乐源")
        case .badServerResponse(let code): return .failed("服务器返回 HTTP \(code)")
        case .cannotBuildURL: return .failed("无法构造播放地址")
        case .relayUnavailable:
            return .failed("此来源需经 iPhone 中继播放——请在手机上保持 Primuse 打开、与 Apple TV 同一局域网")
        }
    }
}
#endif
