import Foundation
import PrimuseKit

/// 专辑、艺人卡片「借哪一首歌的封面」(S3,6c 单元 4 U4a):歌曲模型在内存里时卡片照旧读 `scopedPreferredArtworkSong`;
/// 不在时那张表是空的,这里按 id 从曲库目录问(`preferredArtworkSongID(albumID:/artistID:)`),再按 id 取歌。
/// 问过的按「这一次放掉」记住(`songMutationGenerationForMaintenance` 在每次放掉、装回时变),有上限;卡片各自问,
/// 同一个 id 同时只问一次。只是缓存,不观察:卡片把答案放进自己的状态。
@MainActor
final class ArtworkSongCatalogMemo {
    static let shared = ArtworkSongCatalogMemo()
    static let capacity = 512

    private var generation: Int?
    /// 记的是哪一个曲库的答案(一个进程里可能有几个曲库,测试里就是):换了曲库与换代一样清掉,不拿别的曲库的答案来用。
    private var libraryIdentity: ObjectIdentifier?
    private var answers: [String: String?] = [:]
    private var inFlight: [String: Task<String??, Never>] = [:]

    init() {}

    enum Owner: Hashable {
        case album(String)
        case artist(String)

        var key: String {
            switch self {
            case .album(let id): "album#\(id)"
            case .artist(let id): "artist#\(id)"
            }
        }
    }

    /// 这张卡片借的那首(模型不在内存里时用)。目录答不了或没有这样的歌时为 nil。
    func preferredSong(for owner: Owner, library: MusicLibrary) async -> Song? {
        guard let songID = await preferredSongID(for: owner, library: library) else { return nil }
        return library.unobservedVisibleSong(id: songID)
    }

    func preferredSongID(for owner: Owner, library: MusicLibrary) async -> String? {
        let current = library.songModelGenerationForArtworkMemo
        let identity = ObjectIdentifier(library)
        if generation != current || libraryIdentity != identity {
            generation = current
            libraryIdentity = identity
            answers.removeAll(keepingCapacity: true)
            inFlight.removeAll()
        }
        let key = owner.key
        if let known = answers[key] { return known }
        let task: Task<String??, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            guard let reader = PlaybackCatalogAccess.reader(for: library) else { return nil }
            // 外层 nil:这次没答出来(读失败),不记住,下次再问。
            task = Task<String??, Never> {
                do {
                    switch owner {
                    case .album(let id): return .some(try await reader.preferredArtworkSongID(albumID: id))
                    case .artist(let id): return .some(try await reader.preferredArtworkSongID(artistID: id))
                    }
                } catch {
                    return .none
                }
            }
            inFlight[key] = task
        }
        let answer = await task.value
        inFlight[key] = nil
        guard let answer else { return nil }
        if generation == current, libraryIdentity == identity {
            if answers.count >= Self.capacity { answers.removeAll(keepingCapacity: true) }
            answers[key] = answer
        }
        return answer
    }
}

extension MusicLibrary {
    /// 封面借歌的缓存按它分代:每次放掉、装回歌曲模型都会变。
    var songModelGenerationForArtworkMemo: Int { Int(truncatingIfNeeded: songMutationGenerationForMaintenance) }
}
