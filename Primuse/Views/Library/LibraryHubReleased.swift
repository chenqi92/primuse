import Foundation
import PrimuseKit

/// 资料库入口在歌曲模型不在内存里时读的东西(6c 单元 4 U3)。模型在内存里时入口照旧读内存模型。
enum LibraryHubReleased {
    /// MV、有声书、环境音三张入口上的头三首,同 `musicVideoSongs` / `spokenWordSongs` / `ambientSongs` 的
    /// `prefix(3)`(可见的、库内顺序)。从曲库目录读;答不了时为 nil(入口留着上一份)。
    @MainActor
    static func tileSongs(library: MusicLibrary) async -> [LibrarySection: [Song]]? {
        guard let reader = PlaybackCatalogAccess.reader(for: library) else { return nil }
        do {
            let ids = try await reader.read { catalog -> [String: [String]] in
                [
                    LibrarySection.musicVideos.rawValue: try catalog.musicVideoCandidates().prefix(3).map(\.id),
                    LibrarySection.spokenWord.rawValue: try catalog.firstSongIDs(LibrarySongScope(kinds: [.spokenWord]), limit: 3),
                    LibrarySection.ambient.rawValue: try catalog.firstSongIDs(LibrarySongScope(kinds: [.ambient]), limit: 3),
                ]
            }
            let songs = try await reader.songsChunked(ids: Array(Set(ids.values.joined())), scope: .visible)
            let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var tiles: [LibrarySection: [Song]] = [:]
            for (raw, sectionIDs) in ids {
                guard let section = LibrarySection(rawValue: raw) else { continue }
                tiles[section] = sectionIDs.compactMap { byID[$0] }
            }
            return tiles
        } catch {
            plog("📚 hub tile previews: catalog read failed (\(error))")
            return nil
        }
    }
}
