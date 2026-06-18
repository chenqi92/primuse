import Foundation
import PrimuseKit

/// iOS 本地音乐导入 —— 把用户经系统「文件」选中的音频拷进 app 沙箱固定目录,
/// 再复用 `.local` 源 + LibraryScanner 把元数据/时长/封面/歌词读出来入库。
/// macOS 走「选文件夹 + 安全域书签」的 LocalFileSource 流程, 不经过这里。
enum LocalImportService {
    /// 本地导入源 ID 在 UserDefaults 里的持久化 key。
    private static let sourceIDKey = "local_import_source_id"
    /// 明显小于真实音频的文件通常是第三方 File Provider 交出的占位/错误内容。
    private static let minimumReadableAudioBytes: Int64 = 1024
    private static let copyBufferSize = 1024 * 1024
    private static let providerMaterializationRetryDelay: TimeInterval = 0.8

    /// 本设备的「本地音乐」源 ID。每台设备独立(UUID 存 UserDefaults):
    /// 同一设备多次导入复用同一个源往里追加; 不同设备各自独立, 即便源记录
    /// 随 CloudKit 同步过去也不会因固定 ID 互相覆盖(basePath 是各自的沙箱
    /// 路径, 在别的设备上本就无效, 会优雅降级为扫不到)。
    static var sourceID: String {
        if let existing = UserDefaults.standard.string(forKey: sourceIDKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: sourceIDKey)
        return new
    }

    /// 只读当前持久化的本地导入源 ID, 不存在返回 nil —— 不像 `sourceID` 那样
    /// 懒创建并写 UserDefaults。判断"某源是不是本地导入源"这类只读场景(算占用、
    /// 删源回收校验)用它, 避免仅仅查看源列表就在从未导入的设备上凭空写入 ID。
    static var existingSourceID: String? {
        UserDefaults.standard.string(forKey: sourceIDKey)
    }

    /// 沙箱内存放导入音频的目录(Documents/LocalMusic)。放 Documents 而非
    /// Caches —— 这些是用户自己的歌, 不能在低存储时被系统回收。
    static var musicDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("LocalMusic", isDirectory: true)
    }

    /// 确保目录存在并返回。首次创建时排除 iCloud 备份: 导入的音频可能很大,
    /// 真正需要备份的是曲库 DB, 音频本身可重新导入。
    @discardableResult
    static func ensureMusicDirectory() -> URL {
        var dir = musicDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    /// 构造/复用「本地音乐」源。basePath 指向沙箱目录, scannedDirectories=["/"]
    /// 覆盖整个目录 —— ScanService 对 `.local` 源要求 scannedDirectories 非空
    /// 才会真正扫描。
    static func makeSource(name: String) -> MusicSource {
        let dir = ensureMusicDirectory()
        return MusicSource(
            id: sourceID,
            name: name,
            type: .local,
            basePath: dir.path,
            extraConfig: MusicSource.encodeScannedDirectories(["/"], into: nil, type: .local)
        )
    }

    struct CopyProgress: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            case discovering
            case copying
            case finished
            case cancelled
        }

        var phase: Phase
        var currentFileName: String
        var processed: Int
        var total: Int
        var copied: Int
        var skipped: Int

        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(1, max(0, Double(processed) / Double(total)))
        }
    }

    enum CopyEvent: Sendable {
        case progress(CopyProgress)
        case finished(CopyResult)
    }

    struct CopyFailure: Sendable, Hashable {
        let fileName: String
        let reason: FailureReason
        let detail: String?
    }

    enum FailureReason: String, Sendable, Hashable {
        case unsupportedFormat
        case notFound
        case permissionDenied
        case notEnoughSpace
        case coordinatedReadFailed
        case invalidAudioFile
        case providerReturnedError
        case copyFailed
    }

    struct CopyResult: Sendable {
        var copied = 0
        var skipped = 0
        var discovered = 0
        var cancelled = false
        var failures: [CopyFailure] = []
    }

    typealias ProgressHandler = @Sendable (CopyProgress) -> Void

    /// 把「文件」选择器返回的 URL 拷进音乐目录。选择器给的是 security-scoped
    /// URL, 必须 startAccessing 才能读。选中项可以是文件或**文件夹**——文件夹
    /// 会递归(含子目录)枚举出所有受支持音频一并导入。非受支持格式跳过; 重名
    /// 追加序号避免覆盖已导入的歌。
    static func copyEvents(
        _ pickedURLs: [URL],
        cleanupPickedCopies: Bool = false
    ) -> AsyncStream<CopyEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let result = copy(pickedURLs, cleanupPickedCopies: cleanupPickedCopies) { progress in
                    continuation.yield(.progress(progress))
                }
                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    static func copy(
        _ pickedURLs: [URL],
        cleanupPickedCopies: Bool = false,
        progress: ProgressHandler? = nil
    ) -> CopyResult {
        let dir = ensureMusicDirectory()
        let fm = FileManager.default
        var result = CopyResult()
        var scopedURLs: [(url: URL, didStart: Bool)] = []
        defer {
            for scoped in scopedURLs where scoped.didStart {
                scoped.url.stopAccessingSecurityScopedResource()
            }
            if cleanupPickedCopies {
                cleanupImportedPickerCopies(pickedURLs, fm: fm)
            }
        }

        var audioURLs: [URL] = []
        for url in pickedURLs {
            if Task.isCancelled {
                result.cancelled = true
                progress?(CopyProgress(
                    phase: .cancelled,
                    currentFileName: url.lastPathComponent,
                    processed: 0,
                    total: 0,
                    copied: result.copied,
                    skipped: result.skipped
                ))
                return result
            }
            progress?(CopyProgress(
                phase: .discovering,
                currentFileName: url.lastPathComponent,
                processed: 0,
                total: 0,
                copied: result.copied,
                skipped: result.skipped
            ))
            // 文件夹 URL 的 security-scoped 访问覆盖整个子树, 在此 startAccessing
            // 一次即可枚举/拷贝里面的文件; 单个文件同理。
            let scoped = url.startAccessingSecurityScopedResource()
            scopedURLs.append((url, scoped))

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                recordFailure(
                    CopyFailure(fileName: url.lastPathComponent, reason: .notFound, detail: nil),
                    in: &result
                )
                continue
            }
            if isDir.boolValue {
                audioURLs.append(contentsOf: audioFiles(under: url, fm: fm))
            } else if PrimuseConstants.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                audioURLs.append(url)
            } else {
                recordFailure(
                    CopyFailure(fileName: url.lastPathComponent, reason: .unsupportedFormat, detail: nil),
                    in: &result
                )
            }
        }
        result.discovered = audioURLs.count

        for (index, audioURL) in audioURLs.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                progress?(CopyProgress(
                    phase: .cancelled,
                    currentFileName: audioURL.lastPathComponent,
                    processed: index,
                    total: audioURLs.count,
                    copied: result.copied,
                    skipped: result.skipped
                ))
                return result
            }
            progress?(CopyProgress(
                phase: .copying,
                currentFileName: audioURL.lastPathComponent,
                processed: index,
                total: audioURLs.count,
                copied: result.copied,
                skipped: result.skipped
            ))
            copyOne(audioURL, into: dir, fm: fm, result: &result)
            progress?(CopyProgress(
                phase: .copying,
                currentFileName: audioURL.lastPathComponent,
                processed: index + 1,
                total: audioURLs.count,
                copied: result.copied,
                skipped: result.skipped
            ))
        }

        progress?(CopyProgress(
            phase: .finished,
            currentFileName: "",
            processed: audioURLs.count,
            total: audioURLs.count,
            copied: result.copied,
            skipped: result.skipped
        ))
        plog("📥 LocalImport: finished discovered=\(result.discovered) copied=\(result.copied) skipped=\(result.skipped) failures=\(result.failures.count)")
        return result
    }

    /// 拷一个音频文件进目标目录(非受支持格式跳过, 重名追加序号)。
    private static func copyOne(_ url: URL, into dir: URL, fm: FileManager, result: inout CopyResult) {
        guard PrimuseConstants.supportedAudioExtensions.contains(url.pathExtension.lowercased()) else {
            recordFailure(
                CopyFailure(fileName: url.lastPathComponent, reason: .unsupportedFormat, detail: nil),
                in: &result
            )
            return
        }
        // 重复导入同一文件夹/文件时, 同名+同体积(+同修改时间)视为已导入过, 直接跳过 ——
        // 否则 uniqueDestination 会追加 " 2" 拷成新物理文件, 扫描后变成两首一样的歌。
        if let existing = existingImportedDuplicate(of: url, in: dir, fm: fm) {
            plog("📥 LocalImport: 跳过重复 '\(url.lastPathComponent)' (已存在 \(existing.lastPathComponent))")
            result.skipped += 1
            return
        }
        let dest = uniqueDestination(for: url.lastPathComponent, in: dir, fm: fm)
        plog("📥 LocalImport: importing '\(url.lastPathComponent)' \(resourceDebugDescription(for: url, fm: fm))")
        waitForProviderMaterializationIfNeeded(url, fm: fm)

        // 对 File Provider 的 open-in-place URL, 普通 coordinated read 会触发
        // startProvidingItemAtURL, 系统会等远端文件 materialize 后才进入 accessor。
        // 如果 provider 仍交出占位小文件, 再用 forUploading 临时快照兜底一次。
        let primaryFailure = copyCoordinatedFile(
            from: url,
            to: dest,
            fm: fm,
            options: [],
            label: "coordinated-read",
            fallbackReason: .copyFailed
        )
        if primaryFailure == nil, copiedFileSize(dest, fm: fm) >= minimumReadableAudioBytes {
            result.copied += 1
            copySidecars(forAudio: url, audioDest: dest, fm: fm)
            return
        }

        if let primaryFailure {
            plog("📥 LocalImport: coordinated read failed for '\(url.lastPathComponent)': \(primaryFailure.detail ?? primaryFailure.reason.rawValue)")
        } else {
            let sizeText = ByteCountFormatter.string(fromByteCount: copiedFileSize(dest, fm: fm), countStyle: .file)
            plog("📥 LocalImport: coordinated read produced tiny file for '\(url.lastPathComponent)' (\(sizeText)); retrying upload snapshot")
        }
        try? fm.removeItem(at: dest)

        if let fallbackFailure = copyCoordinatedFile(
            from: url,
            to: dest,
            fm: fm,
            options: [.forUploading],
            label: "uploading-snapshot",
            fallbackReason: primaryFailure?.reason ?? .copyFailed
        ) {
            recordFailure(fallbackFailure, in: &result)
            return
        }

        if let invalidFailure = validateCopiedAudio(dest, originalName: url.lastPathComponent, fm: fm) {
            recordFailure(invalidFailure, in: &result)
            return
        }

        result.copied += 1
        copySidecars(forAudio: url, audioDest: dest, fm: fm)
    }

    /// 把音频同目录的歌词/封面 sidecar 一并带进沙箱 —— 否则导入后
    /// SidecarMetadataLoader 在沙箱里按名找不到, 歌词/封面全丢。复用它的查找
    /// 规则(同名 .lrc; 同名 / `<曲名>-cover` / 目录级 cover.jpg 三档封面)定位
    /// 源文件, 统一改名成目标音频的 base(歌词→`<base>.lrc`, 封面→
    /// `<base>-cover.<原扩展>`), 这样即便音频重名被追加了序号 sidecar 仍能命中。
    private static func copySidecars(forAudio srcURL: URL, audioDest: URL, fm: FileManager) {
        let destDir = audioDest.deletingLastPathComponent()
        let destBase = audioDest.deletingPathExtension().lastPathComponent

        if let lrc = SidecarMetadataLoader.findLyrics(for: srcURL) {
            let dest = destDir.appendingPathComponent("\(destBase).\(lrc.pathExtension)")
            if !fm.fileExists(atPath: dest.path) {
                _ = copyCoordinatedFile(from: lrc, to: dest, fm: fm, options: [], label: "sidecar", fallbackReason: .copyFailed)
            }
        }
        if let cover = SidecarMetadataLoader.findCoverArt(for: srcURL) {
            let dest = destDir.appendingPathComponent("\(destBase)-cover.\(cover.pathExtension)")
            if !fm.fileExists(atPath: dest.path) {
                _ = copyCoordinatedFile(from: cover, to: dest, fm: fm, options: [], label: "sidecar", fallbackReason: .copyFailed)
            }
        }
    }

    private static func copyCoordinatedFile(
        from source: URL,
        to dest: URL,
        fm: FileManager,
        options: NSFileCoordinator.ReadingOptions,
        label: String,
        fallbackReason: FailureReason
    ) -> CopyFailure? {
        requestProviderDownloadIfNeeded(source, fm: fm, force: false)

        var coordError: NSError?
        var thrownError: Error?
        var copySucceeded = false
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: options, error: &coordError) { readURL in
            do {
                try copyFileByReadingBytes(from: readURL, to: dest, fm: fm)
                copySucceeded = true
            } catch {
                thrownError = error
            }
        }
        if copySucceeded {
            let sizeText = ByteCountFormatter.string(fromByteCount: copiedFileSize(dest, fm: fm), countStyle: .file)
            plog("📥 LocalImport: \(label) copied '\(source.lastPathComponent)' -> \(sizeText)")
            return nil
        }
        if let coordError {
            return CopyFailure(
                fileName: source.lastPathComponent,
                reason: failureReason(for: coordError, fallback: .coordinatedReadFailed),
                detail: coordError.localizedDescription
            )
        }
        if let thrownError {
            return CopyFailure(
                fileName: source.lastPathComponent,
                reason: failureReason(for: thrownError, fallback: fallbackReason),
                detail: thrownError.localizedDescription
            )
        }
        return CopyFailure(fileName: source.lastPathComponent, reason: fallbackReason, detail: nil)
    }

    private static func waitForProviderMaterializationIfNeeded(_ url: URL, fm: FileManager) {
        guard Task.isCancelled == false,
              isLikelyTinyProviderItem(url, fm: fm) else {
            return
        }

        requestProviderDownloadIfNeeded(url, fm: fm, force: true)
        Thread.sleep(forTimeInterval: providerMaterializationRetryDelay)

        guard Task.isCancelled == false else { return }
        let size = copiedFileSize(url, fm: fm)
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if size >= minimumReadableAudioBytes {
            plog("📥 LocalImport: provider materialized '\(url.lastPathComponent)' -> \(sizeText)")
        } else {
            plog("📥 LocalImport: provider still tiny after download request '\(url.lastPathComponent)' -> \(sizeText)")
        }
    }

    /// 选中音频异常小(< 1KB)时几乎可断定是 File Provider 尚未 materialize 交出的
    /// 占位 —— 真实音频不可能这么小。不再要求系统给它打 ubiquitous 标记: 部分第三方
    /// 网盘扩展不打这个标记, 之前因此跳过了下载重试。代价仅是对真·本地小文件多一次
    /// 无害的下载请求 + 一拍等待, 而真实音频本就不会落进这个分支。
    private static func isLikelyTinyProviderItem(_ url: URL, fm: FileManager) -> Bool {
        copiedFileSize(url, fm: fm) < minimumReadableAudioBytes
    }

    private static func requestProviderDownloadIfNeeded(_ url: URL, fm: FileManager, force: Bool) {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        let isUbiquitous = values?.isUbiquitousItem == true
        // force 路径(占位兜底)即便系统没打 ubiquitous 标记也照样请求一次:
        // startDownloadingUbiquitousItem 对非 ubiquitous 文件只是无害报错, 却能救
        // 那些不打标记却支持协调读触发下载的第三方网盘。非 force 路径仍只在确为
        // ubiquitous 且尚未下载完成时请求, 避免无谓调用。
        guard force || (isUbiquitous && values?.ubiquitousItemDownloadingStatus != .current) else {
            return
        }
        do {
            try fm.startDownloadingUbiquitousItem(at: url)
            plog("📥 LocalImport: requested iCloud/FileProvider download for '\(url.lastPathComponent)'")
        } catch {
            plog("📥 LocalImport: download request failed for '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
    }

    private static func copyFileByReadingBytes(from source: URL, to dest: URL, fm: FileManager) throws {
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: dest)
        do {
            defer {
                try? input.close()
                try? output.close()
            }

            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: copyBufferSize) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }

        if let modified = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            var values = URLResourceValues()
            values.contentModificationDate = modified
            var destination = dest
            try? destination.setResourceValues(values)
        }
    }

    private static func recordFailure(_ failure: CopyFailure, in result: inout CopyResult) {
        result.skipped += 1
        result.failures.append(failure)
    }

    private static func copiedFileSize(_ url: URL, fm: FileManager) -> Int64 {
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func validateCopiedAudio(
        _ url: URL,
        originalName: String,
        fm: FileManager
    ) -> CopyFailure? {
        let size = copiedFileSize(url, fm: fm)
        guard size >= minimumReadableAudioBytes else {
            let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let isProviderError = looksLikeProviderErrorPayload(url)
            plog("📥 LocalImport: 拒绝无效音频 '\(originalName)' size=\(sizeText) providerError=\(isProviderError) \(audioHeaderDebugDescription(for: url))")
            try? fm.removeItem(at: url)
            return CopyFailure(
                fileName: originalName,
                reason: isProviderError ? .providerReturnedError : .invalidAudioFile,
                detail: sizeText
            )
        }
        return nil
    }

    /// 网盘 File Provider 常把后端的错误响应(JSON)当文件内容交出来 —— 典型如
    /// `{"error_code":31,...}` / `{"errno":...}`。这类小文件不是"还没下下来的占位",
    /// 而是服务端明确拒绝给文件(需会员/防盗链/无下载权限), 用更精准的文案引导用户
    /// 改走内置云盘源, 而不是泛泛地提示"重新导入"。
    private static func looksLikeProviderErrorPayload(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        return trimmed.contains("\"error") || trimmed.contains("error_code")
            || trimmed.contains("errno") || trimmed.contains("errmsg")
            || trimmed.contains("\"code\"") || trimmed.contains("\"message\"")
    }

    private static func resourceDebugDescription(for url: URL, fm: FileManager) -> String {
        var parts: [String] = []
        if let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .isRegularFileKey,
            .isDirectoryKey
        ]) {
            if let fileSize = values.fileSize {
                parts.append("providerSize=\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")
            }
            if let isUbiquitous = values.isUbiquitousItem {
                parts.append("ubiquitous=\(isUbiquitous)")
            }
            if let downloadingStatus = values.ubiquitousItemDownloadingStatus {
                parts.append("downloadStatus=\(downloadingStatus.rawValue)")
            }
            if let isRegularFile = values.isRegularFile {
                parts.append("regular=\(isRegularFile)")
            }
            if let isDirectory = values.isDirectory {
                parts.append("dir=\(isDirectory)")
            }
        }
        let statSize = copiedFileSize(url, fm: fm)
        if statSize > 0 {
            parts.append("statSize=\(ByteCountFormatter.string(fromByteCount: statSize, countStyle: .file))")
        }
        return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
    }

    private static func audioHeaderDebugDescription(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "head=unreadable" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), !data.isEmpty else {
            return "head=empty"
        }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "head=\(hex)"
    }

    private static func failureReason(for error: Error, fallback: FailureReason) -> FailureReason {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return fallback }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileNoSuchFile:
            return .notFound
        case .fileReadNoPermission, .fileWriteNoPermission:
            return .permissionDenied
        case .fileWriteOutOfSpace:
            return .notEnoughSpace
        default:
            return fallback
        }
    }

    private static func cleanupImportedPickerCopies(_ urls: [URL], fm: FileManager) {
        for url in urls where isSafeImportedPickerCopy(url) {
            do {
                try fm.removeItem(at: url)
                plog("📥 LocalImport: removed picker copy '\(url.lastPathComponent)'")
            } catch {
                plog("📥 LocalImport: failed to remove picker copy '\(url.lastPathComponent)': \(error.localizedDescription)")
            }
        }
    }

    private static func isSafeImportedPickerCopy(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let standardized = url.standardizedFileURL.path
        let fm = FileManager.default
        let candidateRoots = [
            fm.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Inbox", isDirectory: true),
            fm.temporaryDirectory
        ].compactMap { $0?.standardizedFileURL.path }
        return candidateRoots.contains { root in
            standardized == root || standardized.hasPrefix(root + "/")
        }
    }

    /// 递归枚举文件夹(含子目录)里所有受支持的音频文件, 跳过隐藏文件。
    private static func audioFiles(under folder: URL, fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let fileURL as URL in enumerator {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular,
                  PrimuseConstants.supportedAudioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            out.append(fileURL)
        }
        return out
    }

    /// 重复导入判定: 目标目录里是否已有「同名(或同名追加过序号)且体积一致、修改时间
    /// 接近」的文件。拷贝时会保留源文件的修改时间, 故同一文件再次导入能命中而跳过;
    /// 仅靠体积已是音频很强的同一性信号, 修改时间再加一道防误判(不同歌极难同名又同字节)。
    private static func existingImportedDuplicate(of source: URL, in dir: URL, fm: FileManager) -> URL? {
        let sourceSize = copiedFileSize(source, fm: fm)
        guard sourceSize > 0 else { return nil }
        let sourceMTime = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let name = source.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var candidates = [dir.appendingPathComponent(name)]
        var i = 2
        while true {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(n)
            guard fm.fileExists(atPath: candidate.path) else { break }
            candidates.append(candidate)
            i += 1
        }

        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            guard copiedFileSize(candidate, fm: fm) == sourceSize else { continue }
            if let sourceMTime,
               let candidateMTime = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               abs(candidateMTime.timeIntervalSince(sourceMTime)) > 2 {
                continue
            }
            return candidate
        }
        return nil
    }

    /// 目标目录已存在同名文件时追加 " 2"/" 3"…, 不覆盖。
    private static func uniqueDestination(for fileName: String, in dir: URL, fm: FileManager) -> URL {
        let first = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: first.path) else { return first }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
