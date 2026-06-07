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
            return TVL("「\(name)」类型暂不支持在 Apple TV 直接播放(仅手机 / 电脑)",
                       "“\(name)” can’t play directly on Apple TV yet (phone / computer only)")
        case .missingCredential(let name):
            return TVL("缺少「\(name)」的登录凭据 —— 请确认手机已登录且开启 iCloud 钥匙串",
                       "Missing credentials for “\(name)” — sign in on your phone with iCloud Keychain on")
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
            store.playbackIssue = .failed(TVL("曲库中找不到这首歌", "Song not found in the library"))
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
            loadLyrics(song: song, source: source, credential: credential)
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

    // MARK: 歌词

    /// 加载歌词:先本地缓存(随快照同步下来的 / 之前抓过的),再直接从音乐源读同目录的
    /// `.lrc` sidecar —— 不再依赖手机端是否抓过(TV 本就连着源、有凭证)。`lyricsFileName`
    /// 指向源里的歌词文件(NAS 是 `.lrc` 真实路径,云盘是 item ID),复用 stream resolver
    /// 解出下载地址即可。
    private func loadLyrics(song: Song, source: MusicSource, credential: SourceCredential?) {
        Task { [weak store, song, source, credential] in
            let songID = song.id
            if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID), !cached.isEmpty {
                store?.applyLyrics(Self.toTVLyrics(cached), forSongID: songID)
                return
            }
            // .json = 本机缓存名(上面已查过);其余非空值视为源里的歌词文件路径。
            guard let lf = song.lyricsFileName, !lf.isEmpty, !lf.hasSuffix(".json") else { return }
            var lrcSong = song
            lrcSong.filePath = lf
            do {
                let resolved = try await StreamResolverRegistry.shared.resolve(
                    for: lrcSong, source: source, credential: credential)
                var req = URLRequest(url: resolved.url)
                for (k, v) in resolved.headers { req.setValue(v, forHTTPHeaderField: k) }
                let (data, _) = try await Self.lyricsSession.data(for: req)
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                let lines = LyricsParser.parse(text)
                guard !lines.isEmpty else { return }
                _ = await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: songID, force: false)
                store?.applyLyrics(Self.toTVLyrics(lines), forSongID: songID)
                plog("🎬 TV source-lyrics loaded \(lines.count) lines for '\(song.title)'")
            } catch {
                plog("🎬 TV source-lyrics fetch failed '\(song.title)': \(error)")
            }
        }
    }

    private nonisolated static func toTVLyrics(_ lines: [LyricLine]) -> [TVLyricLine] {
        lines.map { line in
            TVLyricLine(time: line.timestamp, text: line.text,
                        // start/end 是相对歌曲起点的绝对时间戳;卡拉OK扫词需要每字时长。
                        syllables: (line.syllables ?? []).map { TVSyllable(w: $0.text, d: max(0.001, $0.end - $0.start)) },
                        translation: "")
        }
    }

    /// 取 .lrc 用的 session:接受自签证书(个人 NAS),与播放用的 resource loader 同策略。
    private static let lyricsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: TVInsecureTLSDelegate(), delegateQueue: nil)
    }()

    private func issue(for error: StreamResolveError, source: MusicSource) -> TVPlaybackIssue {
        switch error {
        case .unsupportedSourceType(let type): return .unsupported(type.displayName)
        case .missingCredential: return .missingCredential(source.name)
        case .authFailed: return .failed(TVL("鉴权失败,请在手机上重新登录该音乐源", "Authentication failed — re-sign in to this source on your phone"))
        case .badServerResponse(let code): return .failed(TVL("服务器返回 HTTP \(code)", "Server returned HTTP \(code)"))
        case .cannotBuildURL: return .failed(TVL("无法构造播放地址", "Couldn’t build a playback URL"))
        case .relayUnavailable:
            return .failed(TVL("此来源需经 iPhone 中继播放——请在手机上保持 Primuse 打开、与 Apple TV 同一局域网",
                               "This source needs iPhone relay — keep Primuse open on your phone, on the same Wi-Fi as the Apple TV"))
        }
    }
}
#endif
