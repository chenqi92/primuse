import Foundation
import PrimuseKit
import SwiftUI

/// MV 页在歌曲模型不在内存里时的那份 MV(S5b,6c 单元 4 U8b):可见音乐里带 MV 的歌,库内顺序,从曲库目录读
/// (`musicVideoRowList`)—— 与 `musicVideoSongs` 同一些、同一先后。页面照原来的排序排、照原来的规则挑顶上那支,
/// 所以排出来的与模型在内存里时一样。一次至多物化 `LibraryScale.maxMaterializedRows` 支;更多时、目录读不了时
/// 答不了,页面替自己占用模型,与改之前一样等装回来。
enum MusicVideoCatalogSource {
    enum Answer: Equatable {
        case songs([Song])
        case cannotAnswer

        var songs: [Song]? {
            if case .songs(let songs) = self { return songs }
            return nil
        }
    }

    @MainActor
    static func read(in library: MusicLibrary) async -> Answer {
        guard let reader = library.readableCatalogReader else { return .cannotAnswer }
        do {
            let songs: [Song]? = try await reader.read { catalog in
                let rows = try catalog.musicVideoRowList()
                guard rows.count <= LibraryScale.maxMaterializedRows else { return nil }
                return try catalog.songs(rowids: rows.rowids)
            }
            guard let songs else {
                plog("🎬 MV page: more music videos than one read holds; waiting for the song model")
                return .cannotAnswer
            }
            return .songs(songs)
        } catch {
            plog("🎬 MV page: catalog read failed (\(error))")
            return .cannotAnswer
        }
    }

    /// 页面读的那一份:模型在内存里时同以前读 `musicVideoSongs`;不在时读目录那一份(还没读到时是空的)。
    @MainActor
    static func songs(in library: MusicLibrary, catalog answer: Answer?) -> [Song] {
        // crash-pattern: allow legacy-library-api 模型在内存里时同原来;不在时读目录那一份
        library.isReady ? library.musicVideoSongs : (answer?.songs ?? [])
    }

    /// 模型不在内存里、目录那一份还没读到:页面显示加载,不显示「没有 MV」。
    @MainActor
    static func isWaiting(in library: MusicLibrary, catalog answer: Answer?) -> Bool {
        !library.isReady && answer?.songs == nil
    }

    /// 目录答不了:页面替自己占用模型(`.songModelPage`),装回来照旧读数组。
    @MainActor
    static func needsTheSongModel(in library: MusicLibrary, catalog answer: Answer?) -> Bool {
        !library.isReady && answer == .cannotAnswer
    }
}

extension View {
    /// 歌曲模型不在内存里时把曲库目录里的 MV 读进 `answer`,目录有变化时重读;模型在内存里时写 nil。
    func musicVideoCatalogSource(_ answer: Binding<MusicVideoCatalogSource.Answer?>) -> some View {
        modifier(MusicVideoCatalogSourceModifier(answer: answer))
    }
}

private struct MusicVideoCatalogSourceModifier: ViewModifier {
    @Binding var answer: MusicVideoCatalogSource.Answer?
    @Environment(MusicLibrary.self) private var library

    private struct Key: Equatable {
        let isReady: Bool
        let isUsable: Bool
        let catalog: [UInt64]?
    }

    private var key: Key {
        guard !library.isReady, let revisions = library.catalogHost?.revisions, revisions.isReadable else {
            return Key(isReady: library.isReady, isUsable: library.isUsable, catalog: nil)
        }
        return Key(isReady: false, isUsable: library.isUsable,
                   catalog: [revisions.songs, revisions.membership, revisions.everything])
    }

    func body(content: Content) -> some View {
        let key = key
        return content.task(id: key) {
            guard !key.isReady else {
                if answer != nil { answer = nil }
                return
            }
            guard key.isUsable else { return }
            if answer?.songs != nil {
                // 扫描、补读这类连着改目录的时候停一会儿再读。
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            let next = await MusicVideoCatalogSource.read(in: library)
            guard !Task.isCancelled, next != answer else { return }
            answer = next
        }
    }
}
