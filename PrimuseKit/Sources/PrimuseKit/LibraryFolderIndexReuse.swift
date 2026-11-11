import Foundation

/// 整库目录索引是照哪一份输入建的。新出现的歌曲页拿它和当下的输入比，一样才直接用上一页建好的那份。
///
/// 歌曲页每次出现都是新的一页（极简导航顶上换分类会把导航栈里这一页整个换掉），页里自己的
/// `LibraryFolderIndexStore` 跟着重建，目录版式每进一次都要在后台把整库重新分一遍目录，
/// 那段时间页上只有一个转圈。整库的目录只由下面这些决定，都没变时上一页那份照样是对的。
///
/// 有一样对不上就不用：歌曲增删、任何一次歌曲替换（哪怕只改了标签）、歌单（虚拟目录）、
/// 服务端的目录层级、源的设置。宁可多分一次，也不拿一份过期的目录给人看。
public struct LibraryFolderIndexReuseKey: Hashable, Sendable {
    /// 歌曲页用的那份歌（整库的音乐）换过几次。
    public let songsRevision: UInt64
    public let collectionRevision: Int
    /// 每次有歌被替换就换一个。
    public let replacementToken: UUID
    /// 歌单这类虚拟目录的版本。
    public let virtualCollectionRevision: Int
    /// 服务端、网盘扫描出来的目录层级的版本。
    public let hierarchyRevision: Int
    /// 各源的名字、扫描根目录、开关。
    public let sources: [LibraryFolderSourceDescriptor]

    public init(
        songsRevision: UInt64,
        collectionRevision: Int,
        replacementToken: UUID,
        virtualCollectionRevision: Int,
        hierarchyRevision: Int,
        sources: [LibraryFolderSourceDescriptor]
    ) {
        self.songsRevision = songsRevision
        self.collectionRevision = collectionRevision
        self.replacementToken = replacementToken
        self.virtualCollectionRevision = virtualCollectionRevision
        self.hierarchyRevision = hierarchyRevision
        self.sources = sources
    }

    /// 只换了替换令牌（其余输入都没动）的同一份。歌曲页判断这次替换没动目录结构
    /// （只改了标签）时，用它把手里那份索引改记到新令牌下。
    public func replacingToken(_ token: UUID) -> LibraryFolderIndexReuseKey {
        LibraryFolderIndexReuseKey(
            songsRevision: songsRevision,
            collectionRevision: collectionRevision,
            replacementToken: token,
            virtualCollectionRevision: virtualCollectionRevision,
            hierarchyRevision: hierarchyRevision,
            sources: sources
        )
    }
}

/// 最近建好的那一份整库目录索引，给新出现的歌曲页在出现的那一帧同步取用。
///
/// 只留一份（整库那份；按源看的歌曲页不进来），存新的就放掉旧的。读写都上锁，主线程读、
/// 建好后写都可以。被换下、作废的那份由调用方决定在哪儿释放：十万首的索引在主线程上拆
/// 要好几毫秒。
public final class LibraryFolderIndexReuseCache: @unchecked Sendable {
    public static let shared = LibraryFolderIndexReuseCache()

    private let lock = NSLock()
    private var storedKey: LibraryFolderIndexReuseKey?
    private var storedIndex: LibraryFolderIndex?

    public init() {}

    /// 照 `key` 这份输入建的索引；没有、或者存着的是别的输入建的，返回 nil。
    public func index(for key: LibraryFolderIndexReuseKey) -> LibraryFolderIndex? {
        lock.withLock { storedKey == key ? storedIndex : nil }
    }

    /// 记下照 `key` 建好的索引，返回被换下来的那一份（同一份就返回 nil）。
    @discardableResult
    public func store(_ index: LibraryFolderIndex, for key: LibraryFolderIndexReuseKey) -> LibraryFolderIndex? {
        lock.withLock {
            let previous = storedIndex
            storedKey = key
            storedIndex = index
            return previous === index ? nil : previous
        }
    }

    /// 存着的正是 `index`、而且记在 `old` 下时，改记到 `new` 下（输入里只有不影响目录结构的那部分变了）。
    /// 期间已经换成别的索引或别的输入时不动，返回 false。
    @discardableResult
    public func rekey(_ index: LibraryFolderIndex, from old: LibraryFolderIndexReuseKey, to new: LibraryFolderIndexReuseKey) -> Bool {
        lock.withLock {
            guard storedIndex === index, storedKey == old else { return false }
            storedKey = new
            return true
        }
    }

    /// 不在键里的输入变了（网盘目录改了名之类）：整份作废，返回作废的那一份。
    @discardableResult
    public func removeAll() -> LibraryFolderIndex? {
        lock.withLock {
            let previous = storedIndex
            storedKey = nil
            storedIndex = nil
            return previous
        }
    }
}
