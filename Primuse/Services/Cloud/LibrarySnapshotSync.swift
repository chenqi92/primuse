import CloudKit
import Compression
import Foundation
import PrimuseKit

/// Coalesces repeated full-snapshot requests onto one task. Scene transitions
/// and manual sync actions can arrive close together; every caller receives the
/// same result instead of rebuilding the complete payload again.
private actor SnapshotUploadSingleFlight {
    private var inFlight: (id: UUID, task: Task<Bool, Never>)?

    func run(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let inFlight {
            return await inFlight.task.value
        }

        let id = UUID()
        let task = Task { await operation() }
        inFlight = (id, task)
        let result = await task.value
        if inFlight?.id == id {
            inFlight = nil
        }
        return result
    }

    func cancel() {
        inFlight?.task.cancel()
        inFlight = nil
    }
}

/// Serializes CloudKit mutations so a sources-only write cannot race a full
/// snapshot mutation.
private actor SnapshotMutationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 把整库快照(`library-cache.json` + `sources.json`)作为 CKAsset 通过 iCloud 私有库
/// 在设备间传输。songs/albums/artists/playlists 本身不走 CloudKit 逐条同步,所以
/// 像 tvOS 这种不扫描音乐源的端,靠下载这份快照就能浏览完整曲库。
///
/// · iOS / macOS:扫描/变更后 `uploadNow()` 覆盖上传最新快照(整库 + sources)。
/// · tvOS:启动时 `download()` 拉取并写入本地容器,再让 MusicLibrary 重新加载;
///   本机改源后用 `uploadSourcesOnly()` 只回传 sources 字段(不回传启动时下载的旧整库)。
///
/// 复用与 CloudKitSyncService 相同的容器 `iCloud.com.welape.yuanyin`(私有库默认 zone)。
final class LibrarySnapshotSync: Sendable {
    static let shared = LibrarySnapshotSync()

    private let recordType = "LibrarySnapshot"
    private let recordName = "library-snapshot"
    private let credRecordType = "CredentialSnapshot"
    private let credRecordName = "credential-snapshot"
    private let fullUploadSingleFlight = SnapshotUploadSingleFlight()
    private let cloudMutationLock = SnapshotMutationLock()

    private var database: CKDatabase? {
        CloudKitRuntime.makeContainer()?.privateCloudDatabase
    }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName) }
    private var credRecordID: CKRecord.ID { CKRecord.ID(recordName: credRecordName) }

    private enum RecordSaveOutcome {
        case success
        case conflict(CKRecord)
        case failure(Error?)
    }

    private var directory: URL {
        // tvOS 只允许写 Caches / tmp,Application Support 不可创建/写入,会导致
        // 快照写盘失败("No such file or directory")。tvOS 改用 Caches。
        #if os(tvOS)
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return base.appendingPathComponent("Primuse", isDirectory: true)
    }
    private var libraryCacheURL: URL { directory.appendingPathComponent("library-cache.json") }
    private var sourcesURL: URL { directory.appendingPathComponent("sources.json") }

    // MARK: 上传(iOS / macOS)

    /// 把本地快照覆盖上传到 iCloud。无本地快照则跳过。返回是否真正上传成功
    /// (供 UI 给出真实反馈;失败/跳过都返回 false)。
    @discardableResult
    func uploadNow() async -> Bool {
        await fullUploadSingleFlight.run { [self] in
            await withCloudMutationLock {
                await self.performUploadNow()
            }
        }
    }

    /// Scene transitions may begin while a delayed foreground upload is still
    /// running. Cancel it so snapshot CPU/network work cannot leak into UIKit's
    /// scene-update watchdog window.
    func cancelUpload() async {
        await fullUploadSingleFlight.cancel()
    }

    private func performUploadNow() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let database else {
            plog("LibrarySnapshotSync: CloudKit unavailable in this build, skip upload")
            return false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryCacheURL.path) else {
            plog("LibrarySnapshotSync: no local library-cache.json, skip upload")
            return false
        }

        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch is CancellationError {
            return false
        } catch {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        guard !Task.isCancelled else { return false }

        // Work on the fetched record (and its change tag) instead of deleting
        // the last known-good snapshot first. Explicitly clear both alternate
        // representations so changedKeys removes stale fields atomically.
        for key in ["libraryGz", "library", "sourcesGz", "sources", "lyricsGz"] {
            record[key] = nil
        }
        // 整库快照走【内联 gzip Data】而非 CKAsset:实测 tvOS 下 CKAsset 的字节经常
        // 下载失败,而内联 Data(和凭据同通道)稳定可靠。压缩后超 ~800KB 才回退 CKAsset。
        guard let libraryAttachment = attachSnapshot(
            record,
            fileURL: libraryCacheURL,
            gzKey: "libraryGz",
            assetKey: "library"
        ) else {
            plog("LibrarySnapshotSync: cannot stage library snapshot, keeping cloud record unchanged")
            return false
        }
        defer {
            if let stagingURL = libraryAttachment.stagingURL {
                try? fm.removeItem(at: stagingURL)
            }
        }
        let libInfo = libraryAttachment.info
        var srcInfo = "sources=skip"
        if fm.fileExists(atPath: sourcesURL.path) {
            srcInfo = attachSourcesSnapshot(record, gzKey: "sourcesGz", assetKey: "sources")
        }
        // 歌词:把本机已抓到的歌词(MetadataAssetStore 里的 .json)随快照传给 TV。
        if let lyrics = Self.gatherInlineLyricsBlob() {
            record["lyricsGz"] = lyrics.gz as CKRecordValue
            srcInfo += "; lyricsGz=\(lyrics.gz.count)B files=\(lyrics.snapshot.fileCount) skipped=\(lyrics.snapshot.skippedFileCount)"
        }
        record["modifiedAt"] = Date() as CKRecordValue
        guard !Task.isCancelled else { return false }

        var outcome = await saveChangedRecord(record, in: database)
        if case .conflict(let serverRecord) = outcome {
            // Another device changed the singleton after our fetch. Rebase the
            // complete local snapshot fields onto its current change tag and
            // retry once, preserving any future/unknown server fields.
            for key in ["libraryGz", "library", "sourcesGz", "sources", "lyricsGz", "modifiedAt"] {
                serverRecord[key] = record[key]
            }
            outcome = await saveChangedRecord(serverRecord, in: database)
        }
        let ok: Bool
        switch outcome {
        case .success:
            plog("LibrarySnapshotSync: uploaded snapshot [\(libInfo); \(srcInfo)]")
            ok = true
        case .conflict:
            plog("LibrarySnapshotSync: upload conflict persisted after retry")
            ok = false
        case .failure(let error):
            plog("LibrarySnapshotSync: upload failed — \(error?.localizedDescription ?? "no per-record result")")
            ok = false
        }
        #if !os(tvOS)
        let credentialOutcome: SnapshotCredentialTransferOutcome
        if Task.isCancelled {
            credentialOutcome = .failed
        } else {
            credentialOutcome = await gatherAndUploadCredentials()
        }
        return SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: ok,
            credentialOutcome: credentialOutcome
        )
        #else
        return ok
        #endif
    }

    /// 只覆盖服务器记录里的 `sources` 字段,**不动 library/歌词**。
    ///
    /// tvOS 改源(启用/停用/删除)后用这条:tvOS 本机的 `library-cache.json` 是启动时
    /// 下载的旧整库副本,若走 `uploadNow()` 会把它盲回传、回退手机端新扫描的曲库。
    /// 这里先拉取服务器现有记录(保留其 libraryGz/library/lyricsGz 等字段原样),
    /// 仅把本地 `sources.json` 重新内联进 sources 字段后存回。无本地 sources 则跳过。
    @discardableResult
    func uploadSourcesOnly(includingTombstones tombstones: [MusicSource] = []) async -> Bool {
        await withCloudMutationLock { [self] in
            await performUploadSourcesOnly(includingTombstones: tombstones)
        }
    }

    private func performUploadSourcesOnly(includingTombstones tombstones: [MusicSource]) async -> Bool {
        guard let database else {
            plog("LibrarySnapshotSync: CloudKit unavailable in this build, skip sources upload")
            return false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcesURL.path) || !tombstones.isEmpty else {
            plog("LibrarySnapshotSync: no local sources.json, skip sources-only upload")
            return false
        }
        // 取服务器现有记录(带 change-tag),在其之上只改 sources —— library 字段维持服务器原值,
        // 不会被本机旧副本覆盖。记录不存在时新建一条(此时只有 sources,等手机下次整库上传补全)。
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            plog("LibrarySnapshotSync: no existing snapshot for sources-only — creating sources-only record (\(error))")
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        var srcInfo = prepareSourcesRecord(record, fm: fm, tombstones: tombstones)
        var outcome = await saveChangedRecord(record, in: database)
        if case .conflict(let serverRecord) = outcome {
            // Re-merge against the actual winner before retrying; simply
            // reusing our first payload would discard the concurrent edit.
            srcInfo = prepareSourcesRecord(serverRecord, fm: fm, tombstones: tombstones)
            outcome = await saveChangedRecord(serverRecord, in: database)
        }
        switch outcome {
        case .success:
            plog("LibrarySnapshotSync: uploaded sources-only [\(srcInfo)]")
            return true
        case .conflict:
            plog("LibrarySnapshotSync: sources-only conflict persisted after retry")
            return false
        case .failure(let error):
            plog("LibrarySnapshotSync: sources-only upload failed — \(error?.localizedDescription ?? "no per-record result")")
            return false
        }
    }

    private func prepareSourcesRecord(
        _ record: CKRecord,
        fm: FileManager,
        tombstones: [MusicSource]
    ) -> String {
        // Merge the server fields with the latest local file every time this is
        // called, including conflict retry.
        guard let localData = localSourcesData(including: tombstones) else {
            return "sourcesGz=no-file"
        }
        let payload: Data
        if let incoming = sourcesSnapshotData(from: record, fm: fm),
           let merged = Self.mergeSourcesJSON(localData: localData, incomingData: incoming) {
            payload = merged.data
            do {
                // A retry-only tombstone may outlive its locally purged source
                // row. Do not write that row back into the user-facing store;
                // the durable cleanup journal owns it until propagation wins.
                if tombstones.isEmpty {
                    try merged.data.write(to: sourcesURL, options: .atomic)
                }
                plog("LibrarySnapshotSync: merged sources before upload local=\(merged.localCount) remote=\(merged.incomingCount) total=\(merged.totalCount)")
            } catch {
                plog("LibrarySnapshotSync: merged sources write failed — \(error)")
            }
        } else {
            payload = localData
        }
        record["sourcesGz"] = nil
        record["sources"] = nil
        let info = attachSourcesSnapshot(
            record,
            rawData: payload,
            gzKey: "sourcesGz",
            assetKey: "sources"
        )
        record["modifiedAt"] = Date() as CKRecordValue
        return info
    }

    /// Combines the live local file with durable tombstones captured before a
    /// permanent delete removed their rows. LWW still lets a newer local restore
    /// supersede an older queued delete.
    private func localSourcesData(including tombstones: [MusicSource]) -> Data? {
        let local = try? Data(contentsOf: sourcesURL)
        guard !tombstones.isEmpty else { return local }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let tombstoneData = try? encoder.encode(tombstones),
              let emptyData = try? encoder.encode([MusicSource]()) else {
            return nil
        }
        return Self.mergeSourcesJSON(
            localData: tombstoneData,
            incomingData: local ?? emptyData
        )?.data
    }

    private func saveChangedRecord(
        _ record: CKRecord,
        in database: CKDatabase,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .changedKeys
    ) async -> RecordSaveOutcome {
        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: savePolicy
            )
            switch saveResults[record.recordID] {
            case .success:
                return .success
            case .failure(let error):
                if let server = Self.serverRecordChangedRecord(from: error) {
                    return .conflict(server)
                }
                return .failure(error)
            case .none:
                return .failure(nil)
            }
        } catch {
            if let server = Self.serverRecordChangedRecord(from: error) {
                return .conflict(server)
            }
            return .failure(error)
        }
    }

    private static func serverRecordChangedRecord(from error: Error) -> CKRecord? {
        guard let cloudError = error as? CKError, cloudError.code == .serverRecordChanged else {
            return nil
        }
        return (cloudError as NSError).userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
    }

    private func withCloudMutationLock(
        _ operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await cloudMutationLock.acquire()
        let result = await operation()
        await cloudMutationLock.release()
        return result
    }

    // MARK: 下载(tvOS)

    /// 拉取最新快照写入本地容器。成功返回 true(调用方据此决定是否重载库)。
    @discardableResult
    func download() async -> Bool {
        guard let database else {
            plog("LibrarySnapshotSync: CloudKit unavailable in this build, skip download")
            return false
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let record = try await database.record(for: recordID)
            // 字段级诊断:服务器这条记录到底带了什么(libraryGz 有没有、多大)。
            let gzSize = (record["libraryGz"] as? Data)?.count
            let hasAsset = record["library"] as? CKAsset != nil
            plog("LibrarySnapshotSync: record fields libraryGz=\(gzSize.map { "\($0)B" } ?? "nil") library(asset)=\(hasAsset) keys=\(record.allKeys())")
            var changed = false
            // 先试内联 gzip(新版上传走这条),回退 CKAsset(旧记录/超大库)。
            if extractSnapshot(record, gzKey: "libraryGz", assetKey: "library", to: libraryCacheURL, fm: fm) {
                changed = true
            }
            _ = extractSourcesSnapshot(record, to: sourcesURL, fm: fm)
            Self.restoreLyrics(from: record, fm: fm)
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
    private static let maxLibraryRawBytes = 64 * 1024 * 1024
    private static let maxSourcesRawBytes = 8 * 1024 * 1024
    private static let maxLyricsBlobRawBytes = 16 * 1024 * 1024
    private static let maxLyricsUploadRawBytes = 4 * 1024 * 1024
    private static let maxSingleLyricsFileBytes = 1 * 1024 * 1024
    private static let maxInlineSnapshotInputBytes = 8 * 1024 * 1024

    /// 收集本机 MetadataAssetStore 的歌词文件 → {文件名: base64} 的 JSON。
    private static func gatherLyricsBlob(
        maximumOutputBytes: Int = maxLyricsUploadRawBytes
    ) -> LyricsSnapshotEncoder.Result? {
        LyricsSnapshotEncoder.encodeDirectory(
            MetadataAssetStore.shared.lyricsDirectoryURL,
            maximumOutputBytes: maximumOutputBytes,
            maximumFileBytes: maxSingleLyricsFileBytes
        )
    }

    private struct InlineLyricsBlob {
        let snapshot: LyricsSnapshotEncoder.Result
        let gz: Data
    }

    /// CloudKit's inline field has a compressed-size limit. A raw 4 MB budget
    /// can still produce an incompressible gzip larger than that limit (for
    /// example, base64-heavy translated lyrics), which previously made the
    /// whole lyrics snapshot disappear. Retry with progressively smaller raw
    /// budgets and keep the newest subset chosen by LyricsSnapshotEncoder.
    private static func gatherInlineLyricsBlob() -> InlineLyricsBlob? {
        let guaranteedRawBudget = max(2, inlineGzLimit - 64 * 1024)
        let budgets = [
            maxLyricsUploadRawBytes,
            2 * 1024 * 1024,
            1 * 1024 * 1024,
            guaranteedRawBudget,
        ]
        var attempted = Set<Int>()
        for budget in budgets where attempted.insert(budget).inserted {
            guard let snapshot = gatherLyricsBlob(maximumOutputBytes: budget),
                  let gz = gzip(snapshot.data) else { continue }
            if gz.count < inlineGzLimit {
                return InlineLyricsBlob(snapshot: snapshot, gz: gz)
            }
        }
        return nil
    }

    /// tvOS:把快照里的歌词文件还原到本机 MetadataAssetStore(文件名不变,
    /// cachedLyrics(forSongID:) 即可按同名读回)。
    private static func restoreLyrics(from record: CKRecord, fm: FileManager) {
        guard let gzField = record["lyricsGz"] as? Data,
              let raw = gunzip(gzField, maxOutputBytes: maxLyricsBlobRawBytes) else { return }
        writeLyrics(blob: raw, fm: fm)
    }

    /// 把歌词 blob(解压后的 JSON `{文件名: base64}`)还原到本机 MetadataAssetStore。
    /// CloudKit 与 LAN 直传两条路共用(各自先把 gzip 字段解压再调这里)。
    static func writeLyrics(blob raw: Data, fm: FileManager) {
        guard let blob = try? JSONDecoder().decode([String: String].self, from: raw) else { return }
        let dir = MetadataAssetStore.shared.lyricsDirectoryURL
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        for (name, b64) in blob {
            guard isSafeLyricsFileName(name),
                  let fileURL = safeChildURL(in: dir, fileName: name),
                  let data = Data(base64Encoded: b64),
                  data.count <= 1_000_000 else { continue }
            try? data.write(to: fileURL)
            n += 1
        }
        plog("LibrarySnapshotSync: restored \(n) lyrics files")
    }

    /// gzip(zlib) 压缩 / 解压。CloudKit 的 `*Gz` 字段与 LAN 直传载荷共用同一份字节。
    static func gzip(_ raw: Data) -> Data? { try? (raw as NSData).compressed(using: .zlib) as Data }
    static func gunzip(_ gz: Data, maxOutputBytes: Int = maxLibraryRawBytes) -> Data? {
        var raw = Data()
        raw.reserveCapacity(min(maxOutputBytes, max(64 * 1024, gz.count * 2)))
        do {
            _ = try inflateZlib(gz, maxOutputBytes: maxOutputBytes) { chunk in
                raw.append(contentsOf: chunk)
            }
            return raw
        } catch {
            plog("LibrarySnapshotSync: streaming decompress failed — \(error)")
            return nil
        }
    }

    @discardableResult
    static func gunzipToFile(_ gz: Data, maxOutputBytes: Int, destination: URL, fm: FileManager) -> Int? {
        let dir = destination.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmp) else {
            return nil
        }
        do {
            let written = try inflateZlib(gz, maxOutputBytes: maxOutputBytes) { chunk in
                if let base = chunk.baseAddress, chunk.count > 0 {
                    try handle.write(contentsOf: Data(bytes: base, count: chunk.count))
                }
            }
            try? handle.close()
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tmp, to: destination)
            return written
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            plog("LibrarySnapshotSync: streaming file decompress failed — \(error)")
            return nil
        }
    }

    private static func inflateZlib(
        _ gz: Data,
        maxOutputBytes: Int,
        emit: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws -> Int {
        guard maxOutputBytes > 0 else {
            throw SnapshotDecompressionError.invalidLimit
        }
        guard !gz.isEmpty, gz.count <= maxOutputBytes else {
            throw SnapshotDecompressionError.compressedTooLarge
        }

        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(
            dst_ptr: scratch,
            dst_size: 0,
            src_ptr: UnsafePointer(scratch),
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw SnapshotDecompressionError.initFailed
        }
        defer { compression_stream_destroy(&stream) }

        let dstSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }

        return try gz.withUnsafeBytes { rawBuffer -> Int in
            let src = rawBuffer.bindMemory(to: UInt8.self)
            guard let srcBase = src.baseAddress else {
                throw SnapshotDecompressionError.emptyInput
            }
            stream.src_ptr = srcBase
            stream.src_size = src.count

            var total = 0
            while true {
                stream.dst_ptr = dst
                stream.dst_size = dstSize
                let status = compression_stream_process(&stream, 0)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstSize - stream.dst_size
                    if produced > 0 {
                        total += produced
                        guard total <= maxOutputBytes else {
                            throw SnapshotDecompressionError.outputTooLarge
                        }
                        try emit(UnsafeBufferPointer(start: dst, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        return total
                    }
                    if stream.src_size == 0, produced == 0 {
                        throw SnapshotDecompressionError.incompleteStream
                    }
                default:
                    throw SnapshotDecompressionError.invalidStream
                }
            }
        }
    }

    private enum SnapshotDecompressionError: Error, CustomStringConvertible {
        case invalidLimit
        case compressedTooLarge
        case initFailed
        case emptyInput
        case outputTooLarge
        case incompleteStream
        case invalidStream

        var description: String {
            switch self {
            case .invalidLimit: "invalid decompression limit"
            case .compressedTooLarge: "compressed field too large"
            case .initFailed: "cannot initialize zlib stream"
            case .emptyInput: "empty compressed input"
            case .outputTooLarge: "decompressed field too large"
            case .incompleteStream: "incomplete zlib stream"
            case .invalidStream: "invalid zlib stream"
            }
        }
    }

    private static func isSafeLyricsFileName(_ name: String) -> Bool {
        LyricsSnapshotEncoder.isValidFileName(name)
    }

    private static func safeChildURL(in directory: URL, fileName: String) -> URL? {
        let base = directory.standardizedFileURL
        let url = directory.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.path.hasPrefix(basePrefix),
              url.deletingLastPathComponent().standardizedFileURL.path == base.path else {
            return nil
        }
        return url
    }

    private struct SnapshotAttachment {
        let info: String
        let stagingURL: URL?
    }

    /// 把 `fileURL` 的内容压缩后内联进 record;过大则回退 CKAsset。CKAsset 必须
    /// 指向本次上传独占的稳定副本: library-cache.json 会被持续刮削的持久化任务
    /// 原子替换,直接引用活文件会让 CloudKit 报 Asset File Modified。
    private func attachSnapshot(
        _ record: CKRecord,
        fileURL: URL,
        gzKey: String,
        assetKey: String
    ) -> SnapshotAttachment? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let size = values?.fileSize
        if let size, size <= Self.maxInlineSnapshotInputBytes,
           let raw = try? Data(contentsOf: fileURL),
           let gz = try? (raw as NSData).compressed(using: .zlib) as Data,
           gz.count < Self.inlineGzLimit {
            record[gzKey] = gz as CKRecordValue
            return SnapshotAttachment(info: "\(gzKey)=inline \(gz.count)B", stagingURL: nil)
        }

        guard !Task.isCancelled else { return nil }
        let stagingURL = directory.appendingPathComponent(
            ".library-sync-\(UUID().uuidString).json",
            isDirectory: false
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL, to: stagingURL)
            record[assetKey] = CKAsset(fileURL: stagingURL)
            let rawDescription = size.map { " raw=\($0)B" } ?? ""
            return SnapshotAttachment(
                info: "\(assetKey)=asset\(rawDescription)",
                stagingURL: stagingURL
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            plog("LibrarySnapshotSync: staging snapshot asset failed — \(error)")
            return nil
        }
    }

    /// Sources contain a Synology trusted-device token used to skip TOTP on
    /// this device. Keep that token in the local sources.json, but never put it
    /// into the cross-device snapshot payload.
    private func attachSourcesSnapshot(
        _ record: CKRecord,
        rawData: Data? = nil,
        gzKey: String,
        assetKey: String
    ) -> String {
        guard let raw = rawData ?? (try? Data(contentsOf: sourcesURL)),
              raw.count <= Self.maxSourcesRawBytes,
              let sanitized = Self.sanitizedSourcesData(raw) else {
            return "\(gzKey)=no-file"
        }
        if let gz = try? (sanitized as NSData).compressed(using: .zlib) as Data,
           gz.count < Self.inlineGzLimit {
            record[gzKey] = gz as CKRecordValue
            return "\(gzKey)=inline \(gz.count)B"
        }

        let assetURL = directory.appendingPathComponent("sources-sync.json")
        do {
            try sanitized.write(to: assetURL, options: .atomic)
            record[assetKey] = CKAsset(fileURL: assetURL)
            return "\(assetKey)=asset"
        } catch {
            return "\(assetKey)=write-failed"
        }
    }

    private static func sanitizedSourcesData(_ data: Data) -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var sources = try? decoder.decode([MusicSource].self, from: data) else { return nil }
        for index in sources.indices {
            sources[index].deviceId = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(sources)
    }

    /// 从 record 还原快照写到 `dest`:先试内联 gzip,再回退 CKAsset。成功返回 true。
    private func extractSnapshot(_ record: CKRecord, gzKey: String, assetKey: String, to dest: URL, fm: FileManager) -> Bool {
        if let gzField = record[gzKey] as? Data {
            // CloudKit 返回的 Data 可能是非连续/特殊 backing,先强制连续拷贝再解压。
            let gz = Data(gzField)
            guard let bytes = Self.gunzipToFile(gz, maxOutputBytes: Self.maxLibraryRawBytes, destination: dest, fm: fm) else {
                plog("LibrarySnapshotSync: extract \(gzKey) DECOMPRESS failed (\(gz.count)B)")
                return false
            }
            plog("LibrarySnapshotSync: extract \(gzKey) OK → \(bytes)B at \(dest.path)")
            return true
        }
        if let asset = record[assetKey] as? CKAsset, let url = asset.fileURL,
           fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: dest)
            do { try fm.copyItem(at: url, to: dest); return true } catch { return false }
        }
        return false
    }

    /// Sources are mutable user configuration, so snapshot restore must merge
    /// per source instead of overwriting the whole file.
    private func extractSourcesSnapshot(_ record: CKRecord, to dest: URL, fm: FileManager) -> Bool {
        guard let incoming = sourcesSnapshotData(from: record, fm: fm) else { return false }
        let local = try? Data(contentsOf: dest)
        guard let merged = Self.mergeSourcesJSON(localData: local, incomingData: incoming) else {
            plog("LibrarySnapshotSync: sources merge failed; keeping local sources.json")
            return false
        }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try merged.data.write(to: dest, options: .atomic)
            plog("LibrarySnapshotSync: merged sources snapshot local=\(merged.localCount) incoming=\(merged.incomingCount) total=\(merged.totalCount) at \(dest.path)")
            return true
        } catch {
            plog("LibrarySnapshotSync: write merged sources failed — \(error)")
            return false
        }
    }

    private func mergeSourcesForUpload(with record: CKRecord, fm: FileManager) -> SourcesMergeResult? {
        guard let local = try? Data(contentsOf: sourcesURL),
              let incoming = sourcesSnapshotData(from: record, fm: fm) else {
            return nil
        }
        return Self.mergeSourcesJSON(localData: local, incomingData: incoming)
    }

    private func sourcesSnapshotData(from record: CKRecord, fm: FileManager) -> Data? {
        if let gzField = record["sourcesGz"] as? Data {
            let gz = Data(gzField)
            guard let raw = Self.gunzip(gz, maxOutputBytes: Self.maxSourcesRawBytes) else {
                plog("LibrarySnapshotSync: extract sourcesGz DECOMPRESS failed (\(gz.count)B)")
                return nil
            }
            return raw
        }
        if let asset = record["sources"] as? CKAsset,
           let url = asset.fileURL,
           fm.fileExists(atPath: url.path) {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > Self.maxSourcesRawBytes {
                plog("LibrarySnapshotSync: sources asset too large (\(size.intValue)B)")
                return nil
            }
            return try? Data(contentsOf: url)
        }
        return nil
    }

    private struct SourcesMergeResult {
        let data: Data
        let localCount: Int
        let incomingCount: Int
        let totalCount: Int
    }

    private static func mergeSourcesJSON(localData: Data?, incomingData: Data) -> SourcesMergeResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var incoming = try? decoder.decode([MusicSource].self, from: incomingData) else {
            return nil
        }
        // Snapshot records created by older releases may contain Synology's
        // per-device trust token. Strip it before merging so another device's
        // cloud payload cannot replace or seed local TOTP state.
        for index in incoming.indices {
            incoming[index].deviceId = nil
        }
        let local = localData.flatMap { try? decoder.decode([MusicSource].self, from: $0) } ?? []

        var merged = normalizeSources(incoming)
        for source in local {
            if let current = merged[source.id] {
                merged[source.id] = mergeSource(local: source, incoming: current)
            } else {
                merged[source.id] = source
            }
        }

        let sources = merged.values.sorted {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sources) else { return nil }
        return SourcesMergeResult(
            data: data,
            localCount: local.count,
            incomingCount: incoming.count,
            totalCount: sources.count
        )
    }

    private static func normalizeSources(_ sources: [MusicSource]) -> [String: MusicSource] {
        var result: [String: MusicSource] = [:]
        for source in sources {
            if let existing = result[source.id] {
                result[source.id] = mergeSource(local: existing, incoming: source)
            } else {
                result[source.id] = source
            }
        }
        return result
    }

    private static func mergeSource(local: MusicSource, incoming: MusicSource) -> MusicSource {
        let localClock = sourceClock(local)
        let incomingClock = sourceClock(incoming)
        var winner: MusicSource
        if localClock > incomingClock {
            winner = local
        } else if incomingClock > localClock {
            winner = incoming
        } else if local.isDeleted != incoming.isDeleted {
            winner = local.isDeleted ? local : incoming
        } else {
            winner = incoming
        }

        if !winner.isDeleted {
            // Device-local authentication state always comes from the local
            // row, independent of which user-editable payload wins LWW.
            winner.deviceId = local.deviceId
            if winner.lastScannedAt == nil {
                winner.lastScannedAt = local.lastScannedAt
            }
            if winner.songCount == 0, local.songCount > 0 {
                winner.songCount = local.songCount
            }
        }
        return winner
    }

    private static func sourceClock(_ source: MusicSource) -> Date {
        max(source.modifiedAt, source.deletedAt ?? .distantPast)
    }

    // MARK: 凭据(CloudKit encryptedValues 端到端加密;密钥由系统 iCloud 钥匙串托管)

    private struct CredentialRemovalPlan: Sendable {
        let sourceIDs: Set<String>
        let relayIfMatching: RelayEndpoint?
    }

    /// tvOS:拉取并解密凭据包(供流式解析用)。
    func downloadCredentials() async -> CredentialBundle? {
        guard let database else {
            plog("LibrarySnapshotSync: CloudKit unavailable in this build, skip credential download")
            return nil
        }
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

    /// 覆盖上传加密凭据包。空包先读取现有 change tag，并把本次实际观察到的
    /// 凭据作为删除计划；发生冲突时只重放这些删除，保留另一台设备刚新增的项。
    /// CloudKit 没有带 record change tag 的 record-ID 删除，因此空结果保存为不含
    /// 秘密的加密空 tombstone，而不是无条件删除整个单例记录。
    @discardableResult
    func uploadCredentials(_ bundle: CredentialBundle) async -> Bool {
        guard let database else {
            plog("LibrarySnapshotSync: CloudKit unavailable in this build, skip credential upload")
            return false
        }

        let existingRecord: CKRecord?
        do {
            existingRecord = try await database.record(for: credRecordID)
        } catch let error as CKError where error.code == .unknownItem {
            existingRecord = nil
        } catch {
            plog("LibrarySnapshotSync: credential upload preflight failed — \(error)")
            return false
        }

        guard CredentialBundlePolicy.writeAction(for: bundle) == .deleteRecord else {
            return await saveCredentialBundle(bundle, existingRecord: existingRecord, in: database)
        }
        guard let existingRecord else { return true }
        guard let data = existingRecord.encryptedValues["credentials"] as? Data,
              let current = CredentialBundle.decode(data) else {
            plog("LibrarySnapshotSync: empty credential upload skipped; cloud payload unavailable")
            return false
        }
        let plan = CredentialRemovalPlan(
            sourceIDs: Set(current.entries.keys),
            relayIfMatching: current.relay
        )
        let updated = CredentialBundlePolicy.removing(
            sourceIDs: plan.sourceIDs,
            relayIfMatching: plan.relayIfMatching,
            from: current
        )
        return await saveCredentialBundle(
            updated,
            existingRecord: existingRecord,
            in: database,
            removalPlan: plan
        )
    }

    /// Best-effort privacy cleanup used by source soft-delete. This is a
    /// targeted read-modify-write instead of uploading the caller's in-memory
    /// bundle: a TV whose CloudKit download is temporarily unavailable must not
    /// replace credentials belonging to other active devices/sources with an
    /// incomplete local value.
    @discardableResult
    func removeCredentialFromCloud(forSourceID sourceID: String) async -> Bool {
        await withCloudMutationLock { [self] in
            await performRemoveCredentialFromCloud(forSourceID: sourceID)
        }
    }

    private func performRemoveCredentialFromCloud(forSourceID sourceID: String) async -> Bool {
        guard let database else {
            plog("LibrarySnapshotSync: CloudKit unavailable, skip credential removal source=\(sourceID.prefix(8))…")
            return false
        }

        let record: CKRecord
        do {
            record = try await database.record(for: credRecordID)
        } catch let error as CKError where error.code == .unknownItem {
            return true
        } catch {
            plog("LibrarySnapshotSync: credential removal fetch failed source=\(sourceID.prefix(8))… — \(error)")
            return false
        }

        guard let data = record.encryptedValues["credentials"] as? Data,
              let current = CredentialBundle.decode(data) else {
            // An unreadable/missing payload is not an empty authority signal.
            // Keep it untouched so a transient/schema issue cannot erase other
            // devices' still-valid credentials.
            plog("LibrarySnapshotSync: credential removal skipped; cloud payload unavailable source=\(sourceID.prefix(8))…")
            return false
        }
        guard current.entries[sourceID] != nil else { return true }

        let plan = CredentialRemovalPlan(sourceIDs: [sourceID], relayIfMatching: nil)
        let updated = CredentialBundlePolicy.removing(
            sourceIDs: plan.sourceIDs,
            relayIfMatching: nil,
            from: current
        )
        return await saveCredentialBundle(
            updated,
            existingRecord: record,
            in: database,
            removalPlan: plan
        )
    }

    private func saveCredentialBundle(
        _ bundle: CredentialBundle,
        existingRecord: CKRecord?,
        in database: CKDatabase,
        removalPlan: CredentialRemovalPlan? = nil,
        conflictRetriesRemaining: Int = 1
    ) async -> Bool {
        guard let data = try? bundle.jsonData() else {
            plog("LibrarySnapshotSync: credential payload encoding failed")
            return false
        }
        let record = existingRecord ?? CKRecord(recordType: credRecordType, recordID: credRecordID)
        record.encryptedValues["credentials"] = data
        record["modifiedAt"] = Date() as CKRecordValue
        var outcome = await saveChangedRecord(
            record,
            in: database,
            savePolicy: .ifServerRecordUnchanged
        )
        if case .conflict(let serverRecord) = outcome {
            if let removalPlan {
                guard conflictRetriesRemaining > 0 else {
                    plog("LibrarySnapshotSync: credential removal conflict persisted ids=\(removalPlan.sourceIDs.count)")
                    return false
                }
                guard let serverData = serverRecord.encryptedValues["credentials"] as? Data,
                      let serverBundle = CredentialBundle.decode(serverData) else {
                    plog("LibrarySnapshotSync: credential removal conflict payload unavailable")
                    return false
                }
                let rebased = CredentialBundlePolicy.removing(
                    sourceIDs: removalPlan.sourceIDs,
                    relayIfMatching: removalPlan.relayIfMatching,
                    from: serverBundle
                )
                guard rebased != serverBundle else { return true }
                return await saveCredentialBundle(
                    rebased,
                    existingRecord: serverRecord,
                    in: database,
                    removalPlan: removalPlan,
                    conflictRetriesRemaining: conflictRetriesRemaining - 1
                )
            }
            serverRecord.encryptedValues["credentials"] = data
            serverRecord["modifiedAt"] = record["modifiedAt"]
            outcome = await saveChangedRecord(
                serverRecord,
                in: database,
                savePolicy: .ifServerRecordUnchanged
            )
        }
        switch outcome {
        case .success:
            let kind = CredentialBundlePolicy.writeAction(for: bundle) == .deleteRecord
                ? "empty change-tagged tombstone"
                : "\(bundle.entries.count) entries"
            plog("LibrarySnapshotSync: uploaded credentials (\(kind))")
            return true
        case .conflict:
            plog("LibrarySnapshotSync: credential upload conflict persisted after retry")
            return false
        case .failure(let error):
            plog("LibrarySnapshotSync: credential upload failed — \(error?.localizedDescription ?? "no per-record result")")
            return false
        }
    }

    #if !os(tvOS)
    /// iOS / macOS:从本地 sources.json 读源,采集各源凭据(密码 / OAuth token /
    /// client 密钥)成凭据包。`respectingChannel`:走 iCloud 时为 true,会尊重用户的
    /// 「凭据同步」开关;LAN 直传是用户显式扫码发起 + 端到端加密 + 仅本地一跳,故传
    /// false 不受该开关限制(用户既然扫码就是要把源连过去)。
    func gatherCredentialBundle(respectingChannel: Bool) async -> CredentialBundle? {
        if respectingChannel, !CloudSyncChannel.isEnabled(.credentials) { return CredentialBundle() }
        guard let data = try? Data(contentsOf: sourcesURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sources = try? decoder.decode([MusicSource].self, from: data) else { return nil }

        var entries: [String: CredentialEntry] = [:]
        // 含手机上「停用」的源:Apple TV 可能本地启用某个手机上停用的源来播放,
        // 若只传已启用源的凭证,TV 上会「缺登录凭证」无法播。只排除已删除的。
        for source in sources where !source.isDeleted {
            var entry = CredentialEntry(username: source.username)
            if source.type.requiresCredentials, source.authType != .none {
                switch KeychainService.passwordLookup(for: source.id) {
                case .found(let password):
                    entry.password = password
                case .notFound:
                    break
                case .temporarilyUnavailable(let status):
                    plog("⏳ LibrarySnapshotSync: skip credential snapshot; Keychain temporarily unavailable source=\(source.id.prefix(8))… status=\(status)")
                    return nil
                case .failed(let status):
                    plog("⛔ LibrarySnapshotSync: skip credential snapshot; Keychain read failed source=\(source.id.prefix(8))… status=\(status)")
                    return nil
                }
            }
            let tokenManager = CloudTokenManager(sourceID: source.id)
            switch await tokenManager.lookupTokens() {
            case .found(let tokens):
                entry.token = tokens.accessToken
                entry.refreshToken = tokens.refreshToken
                entry.extra = tokens.extra ?? [:]
            case .notFound:
                break
            case .temporarilyUnavailable(let status):
                plog("⏳ LibrarySnapshotSync: skip credential snapshot; cloud tokens temporarily unavailable source=\(source.id.prefix(8))… status=\(status)")
                return nil
            case .failed(let status):
                plog("⛔ LibrarySnapshotSync: skip credential snapshot; cloud token read failed source=\(source.id.prefix(8))… status=\(status)")
                return nil
            }
            switch await tokenManager.lookupAppCredentials() {
            case .found(let creds):
                entry.clientID = creds.clientId
                entry.clientSecret = creds.clientSecret
            case .notFound:
                break
            case .temporarilyUnavailable(let status):
                plog("⏳ LibrarySnapshotSync: skip credential snapshot; cloud app credentials temporarily unavailable source=\(source.id.prefix(8))… status=\(status)")
                return nil
            case .failed(let status):
                plog("⛔ LibrarySnapshotSync: skip credential snapshot; cloud app credential read failed source=\(source.id.prefix(8))… status=\(status)")
                return nil
            }
            if !entry.isEmpty { entries[source.id] = entry }
        }
        var bundle = CredentialBundle(entries: entries)
        bundle.relay = PhoneRelayServer.shared.endpoint()   // iPhone 中继端点(开启时)
        return bundle
    }

    /// CloudKit:采集凭据并加密上传(尊重「凭据同步」开关)。
    private func gatherAndUploadCredentials() async -> SnapshotCredentialTransferOutcome {
        guard CloudSyncChannel.isEnabled(.credentials) else { return .skipped }
        guard let bundle = await gatherCredentialBundle(respectingChannel: true) else {
            plog("LibrarySnapshotSync: credential snapshot preparation failed")
            return .failed
        }
        return await uploadCredentials(bundle) ? .succeeded : .failed
    }

    // MARK: LAN 直传(扫码,绕开 iCloud)

    /// 构建与 CloudKit 快照同构的整库 + 源 + 歌词 + 凭据载荷(各 `*Gz` 是同一份压缩字节)。
    func buildLANPayload() async -> LANSyncPayload? {
        let credentials = await gatherCredentialBundle(respectingChannel: false)
        let credentialOutcome: SnapshotCredentialTransferOutcome = credentials == nil
            ? .failed
            : .succeeded
        guard SnapshotTransferCompletionPolicy.canSendLAN(
            credentialOutcome: credentialOutcome
        ), let credentials else {
            plog("LibrarySnapshotSync: LAN payload preparation aborted; credentials unavailable")
            return nil
        }

        var payload = LANSyncPayload()
        if let raw = try? Data(contentsOf: libraryCacheURL) { payload.libraryGz = Self.gzip(raw) }
        if let raw = try? Data(contentsOf: sourcesURL),
           let sanitized = Self.sanitizedSourcesData(raw) {
            payload.sourcesGz = Self.gzip(sanitized)
        }
        if let lyrics = Self.gatherLyricsBlob() { payload.lyricsGz = Self.gzip(lyrics.data) }
        payload.credentials = credentials
        return payload
    }

    /// 把整库 + 源 + 凭据 AES-GCM 加密后直接 POST 给 Apple TV(`primuse://pair` 扫码端点)。
    /// 调用前应先 `MusicLibrary.persistNow()`,否则 library-cache.json 可能不是最新。
    func sendToTVOverLAN(_ link: LANPairLink) async -> Bool {
        guard let payload = await buildLANPayload(),
              let json = try? payload.jsonData(),
              let box = LANSyncCrypto.seal(json, key: link.key),
              let url = link.configURL else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(link.pairCode, forHTTPHeaderField: "X-Primuse-Pair-Code")
        req.timeoutInterval = 30
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: box)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            plog("LibrarySnapshotSync: LAN send → \(ok ? "OK" : "fail") (\(box.count)B) \(link.host):\(link.port)")
            return ok
        } catch {
            plog("LibrarySnapshotSync: LAN send failed — \(error)")
            return false
        }
    }
    #endif

    #if os(tvOS)
    /// tvOS:把 iPhone 经局域网直传来的载荷落盘(整库 + 源 + 歌词),与 CloudKit
    /// `download()` 写盘同路。返回整库是否变化(供调用方决定是否重载)。凭据由调用方
    /// (TVStore)单独经 TVCredentialStore 持久化。
    @discardableResult
    func applyLANPayload(_ payload: LANSyncPayload) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var libraryChanged = false
        if let gz = payload.libraryGz,
           Self.gunzipToFile(gz, maxOutputBytes: Self.maxLibraryRawBytes, destination: libraryCacheURL, fm: fm) != nil {
            libraryChanged = true
        }
        if let gz = payload.sourcesGz,
           let incoming = Self.gunzip(gz, maxOutputBytes: Self.maxSourcesRawBytes),
           let merged = Self.mergeSourcesJSON(localData: try? Data(contentsOf: sourcesURL), incomingData: incoming) {
            try? fm.createDirectory(at: sourcesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? merged.data.write(to: sourcesURL, options: .atomic)
            plog("LibrarySnapshotSync: merged LAN sources local=\(merged.localCount) incoming=\(merged.incomingCount) total=\(merged.totalCount)")
        }
        if let gz = payload.lyricsGz, let raw = Self.gunzip(gz, maxOutputBytes: Self.maxLyricsBlobRawBytes) {
            Self.writeLyrics(blob: raw, fm: fm)
        }
        plog("LibrarySnapshotSync: applied LAN payload (library=\(libraryChanged))")
        return libraryChanged
    }
    #endif
}
