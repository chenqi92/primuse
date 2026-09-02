@preconcurrency import AVFoundation
import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// iOS 本地音乐导入 —— 把用户经系统「文件」选中的音频拷进 app 沙箱固定目录,
/// 再由 `.local` 源的 ScanService / LocalFileSource 解析元数据并写入资料库。
/// macOS 走「选文件夹 + 安全域书签」的 LocalFileSource 流程, 不经过这里。
enum LocalImportService {
    /// 本地导入源 ID 在 UserDefaults 里的持久化 key。
    private static let sourceIDKey = "local_import_source_id"
    /// 明显小于真实音频的文件通常是第三方 File Provider 交出的占位/错误内容。
    private static let minimumReadableAudioBytes: Int64 = 1024
    private static let providerMaterializationRetryDelay: TimeInterval = 0.8
    private static let identityBatchSize = 32
    private static let maximumFailureSamples = 20
    private static let pendingScanKey = "local_import_pending_scan_v1"

    /// 本设备的「本地音乐」源 ID。每台设备独立(UUID 存 UserDefaults):
    /// 同一设备多次导入复用同一个源往里追加; 不同设备各自独立。设备本地源
    /// 不进入 CloudKit；升级时 SourcesStore 也会清理旧版本误同步进来的外设备源。
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

    /// Distinguishes audio copied into Primuse's sandbox from `.local`
    /// references backed by security-scoped File Provider URLs. Only the
    /// former is guaranteed to remain readable without network connectivity.
    static func isManagedSource(_ source: MusicSource) -> Bool {
        DeviceLocalSourcePolicy.isManagedCopy(
            isLocalSource: source.type == .local,
            sourceID: source.id,
            persistedImportSourceID: existingSourceID,
            basePath: source.basePath
        )
    }

    static var hasPendingScan: Bool {
        UserDefaults.standard.bool(forKey: pendingScanKey)
    }

    static func clearPendingScan() {
        UserDefaults.standard.removeObject(forKey: pendingScanKey)
    }

    /// Returns as soon as one complete importable file is found. This is used
    /// only to recover a missing local source after an interrupted first
    /// import; hidden transaction files are excluded by the enumerator.
    static var hasRecoverableCompleteFiles: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: musicDirectory.path),
              let enumerator = fm.enumerator(
                  at: musicDirectory,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else {
            return false
        }
        while let file = enumerator.nextObject() as? URL {
            guard isImportableMediaDescriptor(file) else { continue }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
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
            case indexing
            case copying
            case validating
            case committing
            case cancelling
            case finished
            case cancelled
        }

        var phase: Phase
        var currentFileName: String
        var processed: Int
        var total: Int
        var copied: Int
        var duplicateSkipped: Int
        var failed: Int

        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(1, max(0, Double(processed) / Double(total)))
        }
    }

    enum CopyEvent: Sendable {
        case progress(CopyProgress)
        case finished(CopyResult)
    }

    final class CopySession: @unchecked Sendable {
        let events: AsyncStream<CopyEvent>
        private let worker: Task<Void, Never>

        init(events: AsyncStream<CopyEvent>, worker: Task<Void, Never>) {
            self.events = events
            self.worker = worker
        }

        func cancel() {
            worker.cancel()
        }
    }

    private final class WorkerCancellationRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func install(_ task: Task<Void, Never>) {
            lock.withLock { self.task = task }
        }

        func cancel() {
            lock.withLock { task?.cancel() }
        }
    }

    private actor ExecutionGate {
        static let shared = ExecutionGate()
        private var running = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !running {
                running = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                running = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    struct CopyFailure: Error, Sendable, Hashable {
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
        case databaseFailed
        case copyFailed
    }

    struct CopyResult: Sendable {
        var copied = 0
        var duplicateSkipped = 0
        var failed = 0
        var discovered = 0
        var cancelled = false
        var failures: [CopyFailure] = []

        var skipped: Int { duplicateSkipped + failed }
    }

    typealias ProgressHandler = @Sendable (CopyProgress) -> Void

    /// 把「文件」选择器返回的 URL 拷进音乐目录。选择器给的是 security-scoped
    /// URL, 必须 startAccessing 才能读。选中项可以是文件或**文件夹**——文件夹
    /// 会递归(含子目录)枚举出所有受支持音频一并导入。非受支持格式跳过; 重名
    /// 追加序号避免覆盖已导入的歌。
    static func copySession(
        _ pickedURLs: [URL],
        cleanupPickedCopies: Bool = false
    ) -> CopySession {
        let (events, continuation) = AsyncStream.makeStream(
            of: CopyEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let cancellationRelay = WorkerCancellationRelay()
        let worker = Task.detached(priority: .utility) {
            #if os(iOS)
            let backgroundTask = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "LocalMusicImport") {
                    cancellationRelay.cancel()
                }
            }
            #endif
            await ExecutionGate.shared.acquire()
            let result = await copy(
                pickedURLs,
                cleanupPickedCopies: cleanupPickedCopies
            ) { progress in
                continuation.yield(.progress(progress))
            }
            await ExecutionGate.shared.release()
            #if os(iOS)
            await MainActor.run {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            #endif
            continuation.yield(.finished(result))
            continuation.finish()
        }
        cancellationRelay.install(worker)
        continuation.onTermination = { @Sendable _ in worker.cancel() }
        return CopySession(events: events, worker: worker)
    }

    static func copy(
        _ pickedURLs: [URL],
        cleanupPickedCopies: Bool = false,
        progress: ProgressHandler? = nil
    ) async -> CopyResult {
        let dir = ensureMusicDirectory()
        let fm = FileManager.default
        var result = CopyResult()
        defer {
            if cleanupPickedCopies {
                cleanupImportedPickerCopies(pickedURLs, fm: fm)
            }
        }
        let transaction = LocalImportFileTransaction(destinationDirectory: dir)
        let identity: LocalImportIdentityStore
        do {
            try transaction.prepareAndCleanStaging()
            identity = try LocalImportIdentityStore(path: identityDatabaseURL.path)
            // Reserve the stable local-source identity before the first file
            // can commit. Cold-start recovery can then attach completed files
            // even if the process is terminated before the sheet adds a source.
            _ = sourceID
        } catch {
            recordFailure(
                CopyFailure(fileName: "", reason: .databaseFailed, detail: error.localizedDescription),
                in: &result
            )
            return result
        }

        progress?(progressSnapshot(.indexing, fileName: "", processed: 0, result: result))
        await reconcileUnindexedCompleteFiles(
            transaction: transaction,
            identity: identity,
            progress: progress
        )

        result.discovered = discoverImportableCount(pickedURLs, fm: fm, progress: progress)
        var processed = 0
        var pending: [PendingCommit] = []
        pending.reserveCapacity(identityBatchSize)
        let ffmpegDecoder = FFmpegAudioDecoder()

        func flushPending() {
            guard !pending.isEmpty else { return }
            do {
                try identity.recordBatch(pending.map(\.identityEntry))
                result.copied += pending.count
            } catch {
                for item in pending.reversed() {
                    for sidecar in item.sidecars.reversed() {
                        try? transaction.removeCommittedFile(sidecar)
                    }
                    try? transaction.removeCommittedFile(item.audio)
                    recordFailure(
                        CopyFailure(
                            fileName: item.originalFileName,
                            reason: .databaseFailed,
                            detail: error.localizedDescription
                        ),
                        in: &result
                    )
                }
            }
            pending.removeAll(keepingCapacity: true)
        }

        for rootURL in pickedURLs {
            if Task.isCancelled { break }
            await withSecurityScope(rootURL) {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                    processed += 1
                    recordFailure(
                        CopyFailure(fileName: rootURL.lastPathComponent, reason: .notFound, detail: nil),
                        in: &result
                    )
                    return
                }

                if isDirectory.boolValue {
                    guard let enumerator = fm.enumerator(
                        at: rootURL,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    ) else { return }
                    while let fileURL = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        let isRegular = (try? fileURL.resourceValues(
                            forKeys: [.isRegularFileKey]
                        ).isRegularFile) == true
                        guard isRegular, isImportableMediaDescriptor(fileURL) else { continue }
                        await processOne(
                            fileURL,
                            transaction: transaction,
                            identity: identity,
                            ffmpegDecoder: ffmpegDecoder,
                            processed: &processed,
                            result: &result,
                            pending: &pending,
                            progress: progress
                        )
                        if pending.count >= identityBatchSize { flushPending() }
                    }
                } else if isImportableMediaDescriptor(rootURL) {
                    await processOne(
                        rootURL,
                        transaction: transaction,
                        identity: identity,
                        ffmpegDecoder: ffmpegDecoder,
                        processed: &processed,
                        result: &result,
                        pending: &pending,
                        progress: progress
                    )
                    if pending.count >= identityBatchSize { flushPending() }
                } else {
                    processed += 1
                    recordFailure(
                        CopyFailure(
                            fileName: rootURL.lastPathComponent,
                            reason: .unsupportedFormat,
                            detail: nil
                        ),
                        in: &result
                    )
                }
            }
        }

        flushPending()
        if Task.isCancelled {
            result.cancelled = true
            progress?(progressSnapshot(
                .cancelled,
                fileName: "",
                processed: processed,
                result: result
            ))
        } else {
            progress?(progressSnapshot(
                .finished,
                fileName: "",
                processed: processed,
                result: result
            ))
        }
        plog("📥 LocalImport: finished discovered=\(result.discovered) copied=\(result.copied) duplicates=\(result.duplicateSkipped) failed=\(result.failed) cancelled=\(result.cancelled)")
        return result
    }

    private struct PendingCommit {
        let audio: LocalImportFileTransaction.CommittedFile
        let sidecars: [LocalImportFileTransaction.CommittedFile]
        let identityEntry: LocalImportIdentityEntry
        let originalFileName: String
    }

    private struct InjectedCopyFailure: Error {}

    private static var identityDatabaseURL: URL {
        let fm = FileManager.default
        let directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("LocalImport", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)
        return directory.appendingPathComponent("content-identity.sqlite")
    }

    static func recoverIncompleteTransactions() {
        let transaction = LocalImportFileTransaction(destinationDirectory: musicDirectory)
        guard FileManager.default.fileExists(atPath: transaction.stagingDirectory.path) else {
            return
        }
        do {
            try transaction.prepareAndCleanStaging()
            plog("📥 LocalImport: cleaned owned incomplete staging files")
        } catch {
            // A directory without Primuse's exact marker is not ours. Never
            // delete or alter it during recovery.
            plog("⚠️ LocalImport: staging recovery skipped — \(error.localizedDescription)")
        }
    }

    private static func processOne(
        _ sourceURL: URL,
        transaction: LocalImportFileTransaction,
        identity: LocalImportIdentityStore,
        ffmpegDecoder: FFmpegAudioDecoder,
        processed: inout Int,
        result: inout CopyResult,
        pending: inout [PendingCommit],
        progress: ProgressHandler?
    ) async {
        guard !Task.isCancelled else { return }
        let itemOrdinal = processed + 1
        #if DEBUG
        if let delay = debugItemDelayNanoseconds, delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
        }
        #endif
        let fileName = sourceURL.lastPathComponent
        progress?(progressSnapshot(
            .copying,
            fileName: fileName,
            processed: processed,
            result: result
        ))
        #if DEBUG
        if debugPausedItem == itemOrdinal,
           let pause = debugPauseNanoseconds,
           pause > 0 {
            try? await Task.sleep(nanoseconds: pause)
            guard !Task.isCancelled else { return }
        }
        #endif
        waitForProviderMaterializationIfNeeded(sourceURL, fm: .default)

        let stagedResult = coordinatedStageCopy(
            from: sourceURL,
            transaction: transaction,
            options: [],
            fallbackReason: .copyFailed,
            itemOrdinal: itemOrdinal
        )
        var staged: LocalImportFileTransaction.StagedFile
        switch stagedResult {
        case .success(let primary):
            let isStreamDescriptor = PrimuseConstants.supportedStreamDescriptorExtensions.contains(
                sourceURL.pathExtension.lowercased()
            )
            if isStreamDescriptor || primary.byteCount >= minimumReadableAudioBytes {
                staged = primary
            } else {
                transaction.discard(primary)
                switch coordinatedStageCopy(
                    from: sourceURL,
                    transaction: transaction,
                    options: [.forUploading],
                    fallbackReason: .invalidAudioFile,
                    itemOrdinal: itemOrdinal
                ) {
                case .success(let fallback): staged = fallback
                case .failure(let failure):
                    processed += 1
                    recordFailure(failure, in: &result)
                    progress?(progressSnapshot(
                        .copying,
                        fileName: fileName,
                        processed: processed,
                        result: result
                    ))
                    return
                }
            }
        case .failure(let primaryFailure):
            guard !Task.isCancelled else { return }
            switch coordinatedStageCopy(
                from: sourceURL,
                transaction: transaction,
                options: [.forUploading],
                fallbackReason: primaryFailure.reason,
                itemOrdinal: itemOrdinal
            ) {
            case .success(let fallback): staged = fallback
            case .failure(let failure):
                processed += 1
                recordFailure(failure, in: &result)
                progress?(progressSnapshot(
                    .copying,
                    fileName: fileName,
                    processed: processed,
                    result: result
                ))
                return
            }
        }

        guard !Task.isCancelled else {
            transaction.discard(staged)
            return
        }
        progress?(progressSnapshot(
            .validating,
            fileName: fileName,
            processed: processed,
            result: result
        ))
        if let validationFailure = await validateAudio(
            at: staged.url,
            originalName: fileName,
            byteCount: staged.byteCount,
            ffmpegDecoder: ffmpegDecoder
        ) {
            transaction.discard(staged)
            processed += 1
            recordFailure(validationFailure, in: &result)
            progress?(progressSnapshot(
                .validating,
                fileName: fileName,
                processed: processed,
                result: result
            ))
            return
        }

        if pending.contains(where: { $0.audio.sha256 == staged.sha256 }) {
            transaction.discard(staged)
            processed += 1
            result.duplicateSkipped += 1
            progress?(progressSnapshot(
                .committing,
                fileName: fileName,
                processed: processed,
                result: result
            ))
            return
        }

        do {
            if let existing = try identity.entry(forSHA256: staged.sha256) {
                let existingURL = transaction.destinationDirectory
                    .appendingPathComponent(existing.relativePath)
                if FileManager.default.fileExists(atPath: existingURL.path),
                   copiedFileSize(existingURL, fm: .default) == existing.byteCount {
                    transaction.discard(staged)
                    processed += 1
                    result.duplicateSkipped += 1
                    progress?(progressSnapshot(
                        .committing,
                        fileName: fileName,
                        processed: processed,
                        result: result
                    ))
                    return
                }
                try identity.remove(sha256: staged.sha256)
            }

            progress?(progressSnapshot(
                .committing,
                fileName: fileName,
                processed: processed,
                result: result
            ))
            // Persist scan intent before the atomic rename. If the process is
            // killed immediately after the rename, cold-start recovery still
            // knows that a complete file may not have reached the library DB.
            UserDefaults.standard.set(true, forKey: pendingScanKey)
            let committed = try transaction.commit(staged, suggestedFileName: fileName)
            let sidecars = copySidecarsAtomically(
                forAudio: sourceURL,
                audioDest: committed.url,
                transaction: transaction
            )
            pending.append(PendingCommit(
                audio: committed,
                sidecars: sidecars,
                identityEntry: LocalImportIdentityEntry(
                    sha256: committed.sha256,
                    relativePath: committed.url.lastPathComponent,
                    byteCount: committed.byteCount,
                    modificationDate: committed.originalModificationDate
                ),
                originalFileName: fileName
            ))
            processed += 1
            progress?(progressSnapshot(
                .committing,
                fileName: fileName,
                processed: processed,
                result: result
            ))
        } catch is CancellationError {
            transaction.discard(staged)
        } catch {
            transaction.discard(staged)
            processed += 1
            recordFailure(
                CopyFailure(
                    fileName: fileName,
                    reason: failureReason(for: error, fallback: .copyFailed),
                    detail: error.localizedDescription
                ),
                in: &result
            )
        }
    }

    private static func coordinatedStageCopy(
        from source: URL,
        transaction: LocalImportFileTransaction,
        options: NSFileCoordinator.ReadingOptions,
        fallbackReason: FailureReason,
        itemOrdinal: Int
    ) -> Result<LocalImportFileTransaction.StagedFile, CopyFailure> {
        requestProviderDownloadIfNeeded(source, fm: .default, force: false)
        var coordinatorError: NSError?
        var outcome: Result<LocalImportFileTransaction.StagedFile, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source,
            options: options,
            error: &coordinatorError
        ) { readableURL in
            do {
                let staged = try transaction.stageCopy(
                    from: readableURL,
                    originalFileName: source.lastPathComponent
                ) { copiedBytes in
                    #if DEBUG
                    if debugCopyPausedItem == itemOrdinal,
                       copiedBytes > 0,
                       let pause = debugCopyPauseSeconds,
                       pause > 0 {
                        Thread.sleep(forTimeInterval: pause)
                    }
                    if debugInjectedFailureItem == itemOrdinal, copiedBytes > 0 {
                        throw InjectedCopyFailure()
                    }
                    #endif
                }
                outcome = .success(staged)
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinatorError {
            return .failure(CopyFailure(
                fileName: source.lastPathComponent,
                reason: failureReason(for: coordinatorError, fallback: .coordinatedReadFailed),
                detail: coordinatorError.localizedDescription
            ))
        }
        switch outcome {
        case .success(let staged): return .success(staged)
        case .failure(let error):
            return .failure(CopyFailure(
                fileName: source.lastPathComponent,
                reason: failureReason(for: error, fallback: fallbackReason),
                detail: error.localizedDescription
            ))
        case nil:
            return .failure(CopyFailure(
                fileName: source.lastPathComponent,
                reason: fallbackReason,
                detail: nil
            ))
        }
    }

    private static func validateAudio(
        at url: URL,
        originalName: String,
        byteCount: Int64,
        ffmpegDecoder: FFmpegAudioDecoder
    ) async -> CopyFailure? {
        let ext = (originalName as NSString).pathExtension.lowercased()
        if PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
            guard byteCount > 0,
                  byteCount <= Int64(STRMDescriptorParser.maximumByteCount),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  (try? STRMDescriptorParser.parse(data)) != nil else {
                return CopyFailure(
                    fileName: originalName,
                    reason: .invalidAudioFile,
                    detail: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                )
            }
            return nil
        }

        guard byteCount >= minimumReadableAudioBytes else {
            return CopyFailure(
                fileName: originalName,
                reason: looksLikeProviderErrorPayload(url) ? .providerReturnedError : .invalidAudioFile,
                detail: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            )
        }

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration),
           duration.seconds.isFinite,
           duration.seconds > 0,
           let tracks = try? await asset.loadTracks(withMediaType: .audio),
           !tracks.isEmpty {
            return nil
        }
        if let info = try? await ffmpegDecoder.fileInfo(for: url), info.duration > 0 {
            return nil
        }
        return CopyFailure(
            fileName: originalName,
            reason: looksLikeProviderErrorPayload(url) ? .providerReturnedError : .invalidAudioFile,
            detail: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        )
    }

    private static func reconcileUnindexedCompleteFiles(
        transaction: LocalImportFileTransaction,
        identity: LocalImportIdentityStore,
        progress: ProgressHandler?
    ) async {
        guard let files = FileManager.default.enumerator(
            at: transaction.destinationDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }
        let ffmpegDecoder = FFmpegAudioDecoder()
        var pending: [LocalImportIdentityEntry] = []
        pending.reserveCapacity(identityBatchSize)
        while let file = files.nextObject() as? URL {
            if Task.isCancelled { return }
            guard isImportableMediaDescriptor(file) else { continue }
            let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true else { continue }
            let byteCount = Int64(values?.fileSize ?? 0)
            if let indexed = try? identity.entry(forRelativePath: file.lastPathComponent),
               indexed.byteCount == byteCount {
                continue
            }
            progress?(CopyProgress(
                phase: .indexing,
                currentFileName: file.lastPathComponent,
                processed: 0,
                total: 0,
                copied: 0,
                duplicateSkipped: 0,
                failed: 0
            ))
            guard await validateAudio(
                at: file,
                originalName: file.lastPathComponent,
                byteCount: byteCount,
                ffmpegDecoder: ffmpegDecoder
            ) == nil,
            let hash = try? LocalImportFileTransaction.sha256(of: file) else {
                continue
            }
            pending.append(LocalImportIdentityEntry(
                sha256: hash,
                relativePath: file.lastPathComponent,
                byteCount: byteCount,
                modificationDate: values?.contentModificationDate
            ))
            if pending.count >= identityBatchSize {
                try? identity.recordBatch(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        try? identity.recordBatch(pending)
    }

    private static func discoverImportableCount(
        _ roots: [URL],
        fm: FileManager,
        progress: ProgressHandler?
    ) -> Int {
        var count = 0
        for root in roots {
            if Task.isCancelled { break }
            progress?(CopyProgress(
                phase: .discovering,
                currentFileName: root.lastPathComponent,
                processed: 0,
                total: 0,
                copied: 0,
                duplicateSkipped: 0,
                failed: 0
            ))
            let didStart = root.startAccessingSecurityScopedResource()
            deferSecurityScope(root, didStart: didStart) {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                    count += 1
                    return
                }
                guard isDirectory.boolValue else {
                    count += 1
                    return
                }
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return }
                while let file = enumerator.nextObject() as? URL {
                    let regular = (try? file.resourceValues(
                        forKeys: [.isRegularFileKey]
                    ).isRegularFile) == true
                    if regular, isImportableMediaDescriptor(file) { count += 1 }
                }
            }
        }
        return count
    }

    private static func progressSnapshot(
        _ phase: CopyProgress.Phase,
        fileName: String,
        processed: Int,
        result: CopyResult
    ) -> CopyProgress {
        CopyProgress(
            phase: phase,
            currentFileName: fileName,
            processed: processed,
            total: result.discovered,
            copied: result.copied,
            duplicateSkipped: result.duplicateSkipped,
            failed: result.failed
        )
    }

    private static func withSecurityScope(
        _ url: URL,
        operation: () async -> Void
    ) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        await operation()
    }

    private static func deferSecurityScope(
        _ url: URL,
        didStart: Bool,
        operation: () -> Void
    ) {
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        operation()
    }

    #if DEBUG
    private static var debugInjectedFailureItem: Int? {
        ProcessInfo.processInfo.environment["PRIMUSE_IMPORT_FAIL_AT"].flatMap(Int.init)
    }

    private static var debugItemDelayNanoseconds: UInt64? {
        debugNanoseconds(environmentKey: "PRIMUSE_IMPORT_DELAY_MS")
    }

    private static var debugPausedItem: Int? {
        ProcessInfo.processInfo.environment["PRIMUSE_IMPORT_PAUSE_AT"].flatMap(Int.init)
    }

    private static var debugPauseNanoseconds: UInt64? {
        debugNanoseconds(environmentKey: "PRIMUSE_IMPORT_PAUSE_MS")
    }

    private static var debugCopyPausedItem: Int? {
        ProcessInfo.processInfo.environment["PRIMUSE_IMPORT_COPY_PAUSE_AT"].flatMap(Int.init)
    }

    private static var debugCopyPauseSeconds: TimeInterval? {
        ProcessInfo.processInfo.environment["PRIMUSE_IMPORT_COPY_PAUSE_MS"]
            .flatMap(Double.init)
            .map { max(0, $0) / 1_000 }
    }

    private static func debugNanoseconds(environmentKey: String) -> UInt64? {
        guard let milliseconds = ProcessInfo.processInfo.environment[environmentKey]
            .flatMap(UInt64.init) else { return nil }
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        return overflow ? UInt64.max : nanoseconds
    }
    #endif

    /// 把音频同目录的歌词/封面 sidecar 一并带进沙箱 —— 否则导入后
    /// SidecarMetadataLoader 在沙箱里按名找不到, 歌词/封面/MV 全丢。复用它的查找
    /// 规则(同名 .lrc; 同名 MV; 同名 / `<曲名>-cover` / 目录级 cover.jpg 三档封面)定位
    /// 源文件, 统一改名成目标音频的 base(歌词→`<base>.lrc`, 封面→
    /// `<base>-cover.<原扩展>`, MV→`<base>.<原扩展>`), 这样即便音频重名被追加了序号 sidecar 仍能命中。
    private static func copySidecarsAtomically(
        forAudio srcURL: URL,
        audioDest: URL,
        transaction: LocalImportFileTransaction
    ) -> [LocalImportFileTransaction.CommittedFile] {
        let fm = FileManager.default
        let destDir = audioDest.deletingLastPathComponent()
        let destBase = audioDest.deletingPathExtension().lastPathComponent
        var copied: [LocalImportFileTransaction.CommittedFile] = []

        func importSidecar(_ source: URL, destinationName: String) {
            let destination = destDir.appendingPathComponent(destinationName)
            guard !fm.fileExists(atPath: destination.path) else { return }
            switch coordinatedStageCopy(
                from: source,
                transaction: transaction,
                options: [],
                fallbackReason: .copyFailed,
                itemOrdinal: -1
            ) {
            case .success(let staged):
                do {
                    copied.append(try transaction.commit(
                        staged,
                        suggestedFileName: destinationName
                    ))
                } catch {
                    transaction.discard(staged)
                    plog("⚠️ LocalImport: sidecar commit failed for \(source.lastPathComponent): \(error.localizedDescription)")
                }
            case .failure(let failure):
                plog("⚠️ LocalImport: sidecar copy failed for \(failure.fileName): \(failure.detail ?? failure.reason.rawValue)")
            }
        }

        if let lrc = SidecarMetadataLoader.findLyrics(for: srcURL) {
            importSidecar(lrc, destinationName: "\(destBase).\(lrc.pathExtension)")
        }
        if let cover = SidecarMetadataLoader.findCoverArt(for: srcURL) {
            importSidecar(cover, destinationName: "\(destBase)-cover.\(cover.pathExtension)")
        }
        if let mv = SidecarMetadataLoader.findMusicVideo(for: srcURL) {
            importSidecar(mv, destinationName: "\(destBase).\(mv.pathExtension)")
        }
        guard srcURL.lastPathComponent == audioDest.lastPathComponent,
              let siblings = try? fm.contentsOfDirectory(
                  at: srcURL.deletingLastPathComponent(),
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else { return copied }

        for cueURL in siblings where cueURL.pathExtension.caseInsensitiveCompare("cue") == .orderedSame {
            guard let values = try? cueURL.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= 1024 * 1024,
                  let data = try? Data(contentsOf: cueURL, options: .mappedIfSafe),
                  let cue = CueSheetParser.parse(data: data),
                  cue.files.contains(where: {
                      let name = ($0.name.replacingOccurrences(of: "\\", with: "/") as NSString)
                          .lastPathComponent
                      return name.caseInsensitiveCompare(srcURL.lastPathComponent) == .orderedSame
                  }) else { continue }
            importSidecar(cueURL, destinationName: cueURL.lastPathComponent)
        }
        return copied
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

    private static func recordFailure(_ failure: CopyFailure, in result: inout CopyResult) {
        result.failed += 1
        if result.failures.count < maximumFailureSamples {
            result.failures.append(failure)
        }
    }

    private static func copiedFileSize(_ url: URL, fm: FileManager) -> Int64 {
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
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

    private static func isImportableMediaDescriptor(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return PrimuseConstants.supportedAudioExtensions.contains(ext)
            || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext)
    }

}
