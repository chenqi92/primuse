import CloudKit
import Compression
import Foundation
import PrimuseKit

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
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryCacheURL.path) else {
            plog("LibrarySnapshotSync: no local library-cache.json, skip upload")
            return false
        }
        // 先删旧记录再重建:旧记录可能残留下载不下来的 library CKAsset;而且对一条
        // 已存在的记录用「新建(无 change-tag)+ .allKeys」覆盖偶发不落字段。删后重建是
        // 干净一致的写入。记录不存在时 deleteRecord 抛错,忽略即可。
        do {
            try await database.deleteRecord(withID: recordID)
            plog("LibrarySnapshotSync: cleared old snapshot record before re-upload")
        } catch {
            // unknownItem(记录本就不存在)是正常的,不打扰。
        }

        let record = CKRecord(recordType: recordType, recordID: recordID)
        // 整库快照走【内联 gzip Data】而非 CKAsset:实测 tvOS 下 CKAsset 的字节经常
        // 下载失败,而内联 Data(和凭据同通道)稳定可靠。压缩后超 ~800KB 才回退 CKAsset。
        let libInfo = attachSnapshot(record, fileURL: libraryCacheURL, gzKey: "libraryGz", assetKey: "library")
        var srcInfo = "sources=skip"
        if fm.fileExists(atPath: sourcesURL.path) {
            srcInfo = attachSourcesSnapshot(record, gzKey: "sourcesGz", assetKey: "sources")
        }
        // 歌词:把本机已抓到的歌词(MetadataAssetStore 里的 .json)随快照传给 TV。
        if let blob = Self.gatherLyricsBlob(),
           let gz = try? (blob as NSData).compressed(using: .zlib) as Data, gz.count < Self.inlineGzLimit {
            record["lyricsGz"] = gz as CKRecordValue
            srcInfo += "; lyricsGz=\(gz.count)B"
        }
        record["modifiedAt"] = Date() as CKRecordValue
        var ok = false
        do {
            let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            switch saveResults[recordID] {
            case .success:
                plog("LibrarySnapshotSync: uploaded snapshot [\(libInfo); \(srcInfo)]")
                ok = true
            case .failure(let err):
                plog("LibrarySnapshotSync: upload per-record FAILED — \(err)")
            case .none:
                plog("LibrarySnapshotSync: upload returned no result for record")
            }
        } catch {
            plog("LibrarySnapshotSync: upload failed — \(error)")
        }
        #if !os(tvOS)
        await gatherAndUploadCredentials()
        #endif
        return ok
    }

    /// 只覆盖服务器记录里的 `sources` 字段,**不动 library/歌词**。
    ///
    /// tvOS 改源(启用/停用/删除)后用这条:tvOS 本机的 `library-cache.json` 是启动时
    /// 下载的旧整库副本,若走 `uploadNow()` 会把它盲回传、回退手机端新扫描的曲库。
    /// 这里先拉取服务器现有记录(保留其 libraryGz/library/lyricsGz 等字段原样),
    /// 仅把本地 `sources.json` 重新内联进 sources 字段后存回。无本地 sources 则跳过。
    @discardableResult
    func uploadSourcesOnly() async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcesURL.path) else {
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
        // 先把服务器上现有 sources 与本地 sources 做逐源合并,避免 TV 用启动时
        // 下载到的旧文件把手机/电脑上刚做的删除或编辑整包覆盖掉。
        if let merged = mergeSourcesForUpload(with: record, fm: fm) {
            try? merged.data.write(to: sourcesURL, options: .atomic)
            plog("LibrarySnapshotSync: merged sources before upload local=\(merged.localCount) remote=\(merged.incomingCount) total=\(merged.totalCount)")
        }

        // 先清掉两种旧的 sources 表示,再按当前文件大小择一写入,避免内联/资产并存。
        record["sourcesGz"] = nil
        record["sources"] = nil
        let srcInfo = attachSourcesSnapshot(record, gzKey: "sourcesGz", assetKey: "sources")
        record["modifiedAt"] = Date() as CKRecordValue
        var ok = false
        do {
            let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            switch saveResults[recordID] {
            case .success:
                plog("LibrarySnapshotSync: uploaded sources-only [\(srcInfo)]")
                ok = true
            case .failure(let err):
                plog("LibrarySnapshotSync: sources-only upload per-record FAILED — \(err)")
            case .none:
                plog("LibrarySnapshotSync: sources-only upload returned no result for record")
            }
        } catch {
            plog("LibrarySnapshotSync: sources-only upload failed — \(error)")
        }
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

    /// 收集本机 MetadataAssetStore 的全部歌词文件 → {文件名: base64} 的 JSON。
    private static func gatherLyricsBlob() -> Data? {
        let dir = MetadataAssetStore.shared.lyricsDirectoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        var blob: [String: String] = [:]
        for f in files where !f.hasDirectoryPath {
            guard isSafeLyricsFileName(f.lastPathComponent) else { continue }
            if let data = try? Data(contentsOf: f), !data.isEmpty {
                blob[f.lastPathComponent] = data.base64EncodedString()
            }
        }
        guard !blob.isEmpty else { return nil }
        // NSJSONSerialization may raise an Objective-C exception instead of
        // returning an Error while bridging a large Swift dictionary. Such an
        // exception bypasses `try?` and terminates the process. The payload is
        // already Codable, so keep this path entirely in Swift.
        return try? JSONEncoder().encode(blob)
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
        name.range(of: #"^[A-Fa-f0-9]{32}\.json$"#, options: .regularExpression) != nil
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

    /// 把 `fileURL` 的内容压缩后内联进 record;过大则回退 CKAsset。返回简要说明供日志。
    @discardableResult
    private func attachSnapshot(_ record: CKRecord, fileURL: URL, gzKey: String, assetKey: String) -> String {
        guard let raw = try? Data(contentsOf: fileURL) else { return "\(gzKey)=no-file" }
        if let gz = try? (raw as NSData).compressed(using: .zlib) as Data, gz.count < Self.inlineGzLimit {
            record[gzKey] = gz as CKRecordValue
            return "\(gzKey)=inline \(gz.count)B"
        } else {
            record[assetKey] = CKAsset(fileURL: fileURL)
            return "\(assetKey)=asset"
        }
    }

    /// Sources contain a Synology trusted-device token used to skip TOTP on
    /// this device. Keep that token in the local sources.json, but never put it
    /// into the cross-device snapshot payload.
    private func attachSourcesSnapshot(_ record: CKRecord, gzKey: String, assetKey: String) -> String {
        guard let raw = try? Data(contentsOf: sourcesURL),
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
    /// client 密钥)成凭据包。`respectingChannel`:走 iCloud 时为 true,会尊重用户的
    /// 「凭据同步」开关;LAN 直传是用户显式扫码发起 + 端到端加密 + 仅本地一跳,故传
    /// false 不受该开关限制(用户既然扫码就是要把源连过去)。
    func gatherCredentialBundle(respectingChannel: Bool) async -> CredentialBundle {
        if respectingChannel, !CloudSyncChannel.isEnabled(.credentials) { return CredentialBundle() }
        guard let data = try? Data(contentsOf: sourcesURL) else { return CredentialBundle() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sources = try? decoder.decode([MusicSource].self, from: data) else { return CredentialBundle() }

        var entries: [String: CredentialEntry] = [:]
        // 含手机上「停用」的源:Apple TV 可能本地启用某个手机上停用的源来播放,
        // 若只传已启用源的凭证,TV 上会「缺登录凭证」无法播。只排除已删除的。
        for source in sources where !source.isDeleted {
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
        return bundle
    }

    /// CloudKit:采集凭据并加密上传(尊重「凭据同步」开关)。
    private func gatherAndUploadCredentials() async {
        guard CloudSyncChannel.isEnabled(.credentials) else { return }
        await uploadCredentials(await gatherCredentialBundle(respectingChannel: true))
    }

    // MARK: LAN 直传(扫码,绕开 iCloud)

    /// 构建与 CloudKit 快照同构的整库 + 源 + 歌词 + 凭据载荷(各 `*Gz` 是同一份压缩字节)。
    func buildLANPayload() async -> LANSyncPayload {
        var payload = LANSyncPayload()
        if let raw = try? Data(contentsOf: libraryCacheURL) { payload.libraryGz = Self.gzip(raw) }
        if let raw = try? Data(contentsOf: sourcesURL),
           let sanitized = Self.sanitizedSourcesData(raw) {
            payload.sourcesGz = Self.gzip(sanitized)
        }
        if let blob = Self.gatherLyricsBlob() { payload.lyricsGz = Self.gzip(blob) }
        payload.credentials = await gatherCredentialBundle(respectingChannel: false)
        return payload
    }

    /// 把整库 + 源 + 凭据 AES-GCM 加密后直接 POST 给 Apple TV(`primuse://pair` 扫码端点)。
    /// 调用前应先 `MusicLibrary.persistNow()`,否则 library-cache.json 可能不是最新。
    func sendToTVOverLAN(_ link: LANPairLink) async -> Bool {
        let payload = await buildLANPayload()
        guard let json = try? payload.jsonData(),
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
