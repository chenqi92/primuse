import CloudKit
import Foundation

/// 把整库快照(`library-cache.json` + `sources.json`)作为 CKAsset 通过 iCloud 私有库
/// 在设备间传输。songs/albums/artists/playlists 本身不走 CloudKit 逐条同步,所以
/// 像 tvOS 这种不扫描音乐源的端,靠下载这份快照就能浏览完整曲库。
///
/// · iOS / macOS:扫描/变更后 `uploadNow()` 覆盖上传最新快照。
/// · tvOS:启动时 `download()` 拉取并写入本地容器,再让 MusicLibrary 重新加载。
///
/// 复用与 CloudKitSyncService 相同的容器 `iCloud.com.welape.yuanyin`(私有库默认 zone)。
final class LibrarySnapshotSync: Sendable {
    static let shared = LibrarySnapshotSync()

    private let containerID = "iCloud.com.welape.yuanyin"
    private let recordType = "LibrarySnapshot"
    private let recordName = "library-snapshot"

    private var database: CKDatabase {
        CKContainer(identifier: containerID).privateCloudDatabase
    }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName) }

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Primuse", isDirectory: true)
    }
    private var libraryCacheURL: URL { directory.appendingPathComponent("library-cache.json") }
    private var sourcesURL: URL { directory.appendingPathComponent("sources.json") }

    // MARK: 上传(iOS / macOS)

    /// 把本地快照覆盖上传到 iCloud。无本地快照则跳过。
    func uploadNow() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryCacheURL.path) else {
            plog("LibrarySnapshotSync: no local library-cache.json, skip upload")
            return
        }
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["library"] = CKAsset(fileURL: libraryCacheURL)
        if fm.fileExists(atPath: sourcesURL.path) {
            record["sources"] = CKAsset(fileURL: sourcesURL)
        }
        record["modifiedAt"] = Date() as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            plog("LibrarySnapshotSync: uploaded snapshot")
        } catch {
            plog("LibrarySnapshotSync: upload failed — \(error)")
        }
    }

    // MARK: 下载(tvOS)

    /// 拉取最新快照写入本地容器。成功返回 true(调用方据此决定是否重载库)。
    @discardableResult
    func download() async -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let record = try await database.record(for: recordID)
            var changed = false
            if let asset = record["library"] as? CKAsset, let url = asset.fileURL {
                try? fm.removeItem(at: libraryCacheURL)
                try fm.copyItem(at: url, to: libraryCacheURL)
                changed = true
            }
            if let asset = record["sources"] as? CKAsset, let url = asset.fileURL {
                try? fm.removeItem(at: sourcesURL)
                try fm.copyItem(at: url, to: sourcesURL)
            }
            plog("LibrarySnapshotSync: downloaded snapshot")
            return changed
        } catch {
            plog("LibrarySnapshotSync: no snapshot / download failed — \(error)")
            return false
        }
    }
}
