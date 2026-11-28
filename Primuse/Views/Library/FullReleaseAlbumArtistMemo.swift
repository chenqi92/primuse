import Foundation
import PrimuseKit

/// 艺术家页「不列只有单曲、EP 的人」在曲库目录上的名单(RC-b):署名在至少一张「正式专辑」上的专辑艺人 id
/// (`LibraryFullReleaseArtistFilter`,手动选的发行类别经 `LibraryCatalogHost.releaseCategoryOverrides` 对到专辑)。
/// 这条查询 10 万首要 0.43 秒、50 万首要 2.6 秒,所以只在主线程外算(调用方都在 `reader.read` 里),按目录与它的
/// 修订号、手动分类的修订号记住最近的一份:艺人页的列表(换查找、只看喜欢、两种先后、重进页面)与侧栏的人数共用,
/// 修订号没变就不重算;同一组修订号正在算时,后来的等它算完,不另占一个读连接再算一遍。名单的大小是专辑艺人数。
final class FullReleaseAlbumArtistMemo: @unchecked Sendable {
    static let shared = FullReleaseAlbumArtistMemo()

    /// 手动选的发行类别,连同取的那一刻是哪个分类存储、它的修订号(记住的名单按这两样认)。
    struct Choices: Sendable {
        let snapshot: AlbumReleaseCategoryStore.Snapshot
        let revision: Int
        let store: ObjectIdentifier

        @MainActor
        init(_ store: AlbumReleaseCategoryStore) {
            snapshot = store.snapshot
            revision = store.revision
            self.store = ObjectIdentifier(store)
        }
    }

    struct Key: Hashable {
        let catalog: ObjectIdentifier
        let revision: Int64
        let store: ObjectIdentifier
        let choicesRevision: Int
    }

    private let condition = NSCondition()
    private var latest: (key: Key, artistIDs: Set<String>)?
    private var computing: Set<Key> = []
    #if DEBUG
    /// 测试:真算过几次(命中记住的那份不算)。
    private(set) var computationsForTesting = 0
    #endif

    /// 主线程外调用。nil:发行类别还没算齐、目录此刻答不了 —— 是「答不出」,不是「没有人」;答不出的结果不记。
    func artistIDs(catalog: LibraryCatalog, choices: Choices) throws -> Set<String>? {
        let key = Key(
            catalog: ObjectIdentifier(catalog), revision: try catalog.currentRevision(),
            store: choices.store, choicesRevision: choices.revision
        )
        condition.lock()
        while computing.contains(key) { condition.wait() }
        if let latest, latest.key == key {
            condition.unlock()
            return latest.artistIDs
        }
        computing.insert(key)
        condition.unlock()
        var answer: Set<String>?
        defer {
            condition.lock()
            computing.remove(key)
            if let answer { latest = (key, answer) }
            condition.broadcast()
            condition.unlock()
        }
        #if DEBUG
        condition.withLock { computationsForTesting += 1 }
        #endif
        guard let overrides = LibraryCatalogHost.releaseCategoryOverrides(choices.snapshot, catalog: catalog) else { return nil }
        answer = try LibraryFullReleaseArtistFilter(overrides: overrides).artistIDs(catalog: catalog)
        return answer
    }

    #if DEBUG
    func resetForTesting() {
        condition.withLock {
            latest = nil
            computationsForTesting = 0
        }
    }
    #endif
}
