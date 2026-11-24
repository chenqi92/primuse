import Foundation
import PrimuseKit

/// 跨线程的取消标记:目录读在 GCD 队列上跑,读不到 Swift 任务的取消状态。
final class LibraryCatalogCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

extension LibraryCatalogReader {
    /// 按曲库目录建文件夹索引(主线程外)。所在任务被取消时中途放弃,抛 `CancellationError`;
    /// 目录读不了时抛 `LibraryCatalogReaderError.unavailable`,调用方照旧按内存里的歌建。
    func folderIndex(
        _ build: @escaping @Sendable (
            _ catalog: LibraryCatalog,
            _ isCancelled: @escaping @Sendable () -> Bool
        ) throws -> LibraryFolderIndex
    ) async throws -> LibraryFolderIndex {
        let flag = LibraryCatalogCancellationFlag()
        return try await withTaskCancellationHandler {
            try await read { catalog in
                try build(catalog) { flag.isCancelled }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

extension MusicLibrary {
    /// 目录此刻可读时给出读接口,否则 nil(文件夹索引等照旧走内存)。
    var readableCatalogReader: LibraryCatalogReader? {
        guard let host = catalogHost, host.revisions.isReadable else { return nil }
        return host.reader
    }

    /// 文件夹索引复用键里的目录修订号:目录不可读时为 0。
    var folderIndexCatalogRevision: Int64 {
        guard let host = catalogHost, host.revisions.isReadable else { return 0 }
        return host.revisions.catalogRevision
    }
}

/// 文件夹索引里「目录里有、配置里没有」的源的描述:与首页、歌曲页、车机按内存建时补的那份一样。
enum LibraryFolderUnlistedSource {
    static func descriptor(
        sourceID: String,
        appleMusicName: String,
        genericName: String
    ) -> LibraryFolderSourceDescriptor {
        LibraryFolderSourceDescriptor(
            sourceID: sourceID,
            displayName: sourceID == AppleMusicLibraryIdentity.sourceID ? appleMusicName : genericName,
            scanRoots: [],
            pathSemantics: .opaque
        )
    }
}
