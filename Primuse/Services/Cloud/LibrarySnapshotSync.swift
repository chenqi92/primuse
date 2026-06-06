import CloudKit
import Foundation
import PrimuseKit

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
    private let credRecordType = "CredentialSnapshot"
    private let credRecordName = "credential-snapshot"

    private var database: CKDatabase {
        CKContainer(identifier: containerID).privateCloudDatabase
    }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName) }
    private var credRecordID: CKRecord.ID { CKRecord.ID(recordName: credRecordName) }

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Primuse", isDirectory: true)
    }
    private var libraryCacheURL: URL { directory.appendingPathComponent("library-cache.json") }
    private var sourcesURL: URL { directory.appendingPathComponent("sources.json") }

    // MARK: 上传(iOS / macOS)

    /// 把本地快照覆盖上传到 iCloud。无本地快照则跳过。返回是否真正上传成功
    /// (供 UI 给出真实反馈;失败/跳过都返回 false)。
    @discardableResult
    func uploadNow() async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryCacheURL.path) else {
            plog("LibrarySnapshotSync: no local library-cache.json, skip upload")
            return false
        }
        let record = CKRecord(recordType: recordType, recordID: recordID)
        // 整库快照走【内联 gzip Data】而非 CKAsset：实测 tvOS 下 CKAsset 的字节
        // 经常下载失败(record 能取到、asset.fileURL 指向的缓存文件却不存在),而内联
        // Data(和凭据同通道)稳定可靠。仅当压缩后超过 ~800KB(超大库)才回退 CKAsset。
        attachSnapshot(record, fileURL: libraryCacheURL, gzKey: "libraryGz", assetKey: "library")
        if fm.fileExists(atPath: sourcesURL.path) {
            attachSnapshot(record, fileURL: sourcesURL, gzKey: "sourcesGz", assetKey: "sources")
        }
        record["modifiedAt"] = Date() as CKRecordValue
        var ok = false
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            plog("LibrarySnapshotSync: uploaded snapshot")
            ok = true
        } catch {
            plog("LibrarySnapshotSync: upload failed — \(error)")
        }
        #if !os(tvOS)
        await gatherAndUploadCredentials()
        #endif
        return ok
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
            // 先试内联 gzip(新版上传走这条),回退 CKAsset(旧记录/超大库)。
            if extractSnapshot(record, gzKey: "libraryGz", assetKey: "library", to: libraryCacheURL, fm: fm) {
                changed = true
            }
            _ = extractSnapshot(record, gzKey: "sourcesGz", assetKey: "sources", to: sourcesURL, fm: fm)
            plog("LibrarySnapshotSync: downloaded snapshot (library=\(changed))")
            return changed
        } catch {
            plog("LibrarySnapshotSync: no snapshot / download failed — \(error)")
            return false
        }
    }

    // MARK: 快照字段编解码(内联 gzip 优先,CKAsset 回退)

    /// 内联阈值:压缩后小于此值就内联进 CKRecord(单字段/整记录上限 1MB,留余量)。
    private static let inlineGzLimit = 800_000

    /// 把 `fileURL` 的内容压缩后内联进 record;过大则回退 CKAsset。
    private func attachSnapshot(_ record: CKRecord, fileURL: URL, gzKey: String, assetKey: String) {
        guard let raw = try? Data(contentsOf: fileURL) else { return }
        if let gz = try? (raw as NSData).compressed(using: .zlib) as Data, gz.count < Self.inlineGzLimit {
            record[gzKey] = gz as CKRecordValue
        } else {
            record[assetKey] = CKAsset(fileURL: fileURL)
        }
    }

    /// 从 record 还原快照写到 `dest`:先试内联 gzip,再回退 CKAsset。成功返回 true。
    private func extractSnapshot(_ record: CKRecord, gzKey: String, assetKey: String, to dest: URL, fm: FileManager) -> Bool {
        if let gz = record[gzKey] as? Data,
           let raw = try? (gz as NSData).decompressed(using: .zlib) as Data {
            try? fm.removeItem(at: dest)
            do { try raw.write(to: dest); return true } catch { return false }
        }
        if let asset = record[assetKey] as? CKAsset, let url = asset.fileURL,
           fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: dest)
            do { try fm.copyItem(at: url, to: dest); return true } catch { return false }
        }
        return false
    }

    // MARK: 凭据(CloudKit encryptedValues 端到端加密;密钥由系统 iCloud 钥匙串托管)

    /// tvOS:拉取并解密凭据包(供流式解析用)。
    func downloadCredentials() async -> CredentialBundle? {
        do {
            let record = try await database.record(for: credRecordID)
            guard let data = record.encryptedValues["credentials"] as? Data else { return nil }
            let bundle = CredentialBundle.decode(data)
            plog("LibrarySnapshotSync: downloaded credentials (\(bundle?.entries.count ?? 0))")
            return bundle
        } catch {
            plog("LibrarySnapshotSync: no credentials / download failed — \(error)")
            return nil
        }
    }

    /// 覆盖上传加密凭据包(空包且无中继端点时跳过)。
    func uploadCredentials(_ bundle: CredentialBundle) async {
        guard !bundle.entries.isEmpty || bundle.relay != nil, let data = try? bundle.jsonData() else { return }
        let record = CKRecord(recordType: credRecordType, recordID: credRecordID)
        record.encryptedValues["credentials"] = data
        record["modifiedAt"] = Date() as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            plog("LibrarySnapshotSync: uploaded credentials (\(bundle.entries.count))")
        } catch {
            plog("LibrarySnapshotSync: credential upload failed — \(error)")
        }
    }

    #if !os(tvOS)
    /// iOS / macOS:从本地 sources.json 读源,采集各源凭据(密码 / OAuth token /
    /// client 密钥)→ 加密上传,供 Apple TV 流式播放时解析。
    private func gatherAndUploadCredentials() async {
        guard let data = try? Data(contentsOf: sourcesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sources = try? decoder.decode([MusicSource].self, from: data) else { return }

        var entries: [String: CredentialEntry] = [:]
        for source in sources where source.isEnabled && !source.isDeleted {
            var entry = CredentialEntry(username: source.username)
            entry.password = KeychainService.getPassword(for: source.id)
            let tokenManager = CloudTokenManager(sourceID: source.id)
            if let tokens = await tokenManager.getTokens() {
                entry.token = tokens.accessToken
                entry.refreshToken = tokens.refreshToken
                entry.extra = tokens.extra ?? [:]
            }
            if let creds = await tokenManager.getAppCredentials() {
                entry.clientID = creds.clientId
                entry.clientSecret = creds.clientSecret
            }
            if !entry.isEmpty { entries[source.id] = entry }
        }
        var bundle = CredentialBundle(entries: entries)
        bundle.relay = PhoneRelayServer.shared.endpoint()   // iPhone 中继端点(开启时)
        await uploadCredentials(bundle)
    }
    #endif
}
