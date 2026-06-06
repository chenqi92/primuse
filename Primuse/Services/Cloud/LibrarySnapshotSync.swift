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
        record["library"] = CKAsset(fileURL: libraryCacheURL)
        if fm.fileExists(atPath: sourcesURL.path) {
            record["sources"] = CKAsset(fileURL: sourcesURL)
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
