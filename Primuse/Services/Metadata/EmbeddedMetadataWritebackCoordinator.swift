import CryptoKit
import Foundation
import PrimuseKit

/// The provider-facing identity of one audio object. Adapters should prefer a
/// provider revision (ETag, rev, content hash, etc.); size and mtime are the
/// compatibility fallback for ordinary filesystems.
struct EmbeddedMetadataRemoteFileState: Sendable, Equatable {
    let fileSize: Int64
    let modifiedDate: Date?
    /// Revision persisted by the scanner and returned to the local Song row.
    /// This is often a content hash, which remains useful across provider API
    /// versions and catches same-size, same-mtime replacements.
    let revision: String?
    /// Provider token required by a conditional replacement request. Some
    /// services expose this separately from their content fingerprint (for
    /// example Dropbox `rev` and OneDrive `eTag`).
    let replacementToken: String?
    let isLocalFileRevision: Bool

    init(
        fileSize: Int64,
        modifiedDate: Date?,
        revision: String?,
        replacementToken: String? = nil,
        isLocalFileRevision: Bool = false
    ) {
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
        self.revision = revision
        self.replacementToken = replacementToken
        self.isLocalFileRevision = isLocalFileRevision
    }

    func matches(_ other: Self) -> Bool {
        switch (replacementToken, other.replacementToken) {
        case let (token?, otherToken?):
            guard token == otherToken else { return false }
        case (nil, nil):
            break
        case (_?, nil), (nil, _?):
            return false
        }
        switch (revision, other.revision) {
        case let (revision?, otherRevision?):
            return revision == otherRevision
        case (nil, nil):
            break
        case (_?, nil), (nil, _?):
            return false
        }
        guard fileSize == other.fileSize else { return false }
        guard let modifiedDate, let otherModifiedDate = other.modifiedDate else {
            return false
        }
        // Several NAS/FTP implementations expose whole-second mtimes.
        return abs(modifiedDate.timeIntervalSince(otherModifiedDate)) < 1
    }

    func matchesScannedSong(_ song: Song) -> Bool {
        if let scanned = song.revision {
            guard let revision else { return false }
            return isLocalFileRevision ? Self.revisionMatches(song, current: revision) : scanned == revision
        }
        return matchesScannedAudio(song)
    }

    /// 本机文件夹源的 revision 还并着同名封面、歌词、MV 文件的指纹(见
    /// `EmbeddedMetadataWritebackAdapter.revisionFoldsSidecarFingerprints`)。刮削、存歌词在歌旁边
    /// 写了这些文件之后，库里记的 revision 就旧了；写回、改名动的只是音频本身，音频还是扫描时
    /// 那一份(大小、修改时间都对得上)就不算冲突。音频真被别处改过照旧拒绝。
    func matchesScannedSong(_ song: Song, revisionFoldsSidecarFingerprints: Bool) -> Bool {
        if matchesScannedSong(song) { return true }
        return revisionFoldsSidecarFingerprints && song.revision != nil && matchesScannedAudio(song)
    }

    /// 音频本身(大小、修改时间)还是库里记的那一份。
    func matchesScannedAudio(_ song: Song) -> Bool {
        guard song.fileSize > 0, fileSize > 0, fileSize == song.fileSize else {
            return false
        }
        guard let songDate = song.lastModified, let modifiedDate else { return false }
        return abs(songDate.timeIntervalSince(modifiedDate)) < 1
    }

    static func revisionMatches(_ song: Song, current: String?) -> Bool {
        if song.revision == current { return true }
        // Older local scans stored the size/mtime/sidecar digest alone.
        // A change predating import does not require rereading the library on upgrade.
        guard let current, current.hasPrefix("local:"), let separator = current.firstIndex(of: "|"),
              song.revision == nil || song.revision == String(current[..<separator]),
              let bits = UInt64(current[current.index(after: separator)...], radix: 16) else { return false }
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)) <= song.dateAdded
    }

    /// 冲突日志用：只说哪一项对不上，不带 ETag 原文与路径。
    func mismatchSummary(againstScanned song: Song) -> String {
        let revisionState: String
        switch (song.revision, revision) {
        case let (scanned?, current?): revisionState = scanned == current ? "same" : "differs"
        case (nil, nil): revisionState = "none"
        case (_?, nil): revisionState = "missingNow"
        case (nil, _?): revisionState = "notScanned"
        }
        let dateDelta = song.lastModified.flatMap { scanned in
            modifiedDate.map { String(format: "%.1f", $0.timeIntervalSince(scanned)) }
        } ?? "-"
        return "revision=\(revisionState) size=\(song.fileSize == fileSize ? "same" : "\(song.fileSize)->\(fileSize)") mtimeDelta=\(dateDelta)"
    }

    func mismatchSummary(against other: Self) -> String {
        let revisionState = revision == other.revision ? "same" : "differs"
        let dateDelta = modifiedDate.flatMap { date in
            other.modifiedDate.map { String(format: "%.1f", $0.timeIntervalSince(date)) }
        } ?? "-"
        return "revision=\(revisionState) size=\(fileSize == other.fileSize ? "same" : "\(fileSize)->\(other.fileSize)") mtimeDelta=\(dateDelta) token=\(replacementToken == other.replacementToken ? "same" : "differs")"
    }

    var hasReliableConflictGuard: Bool {
        revision?.isEmpty == false || (fileSize > 0 && modifiedDate != nil)
    }
}

/// 刮削往音频文件里写封面、歌词时的规矩。整文件事务反正要整首下载，在替换之前看一眼文件里已有的。
struct EmbeddedAssetWritePolicy: Sendable, Equatable {
    /// 文件里已经有封面就不换（只补全缺失时）。远程歌曲的内嵌封面常常还没读到，不能拿在线图把它换掉。
    var keepsExistingCover = false
    /// 文件里已经有歌词就不换（只补全缺失时）。
    var keepsExistingLyrics = false
    /// 要写的和文件里现有的一样就不整首重写。
    var skipsUnchanged = true
    /// 文件里已经有歌词、这一轮又要换时用的按字段替换请求：不整段写歌词（会把几份原文合成一份，或者留下
    /// 旧的那份），只换正在用的那一份。这次只有歌词要写时就在这次事务里按它改（`.replacedByField`）；还要换
    /// 封面时事务里不动歌词，交回 `.leftForFieldReplace`，调用方随后用新的文件身份拿它再写一次。
    /// nil 时照旧整段写。
    var lyricsFieldReplacement: EmbeddedLyricsFieldRequest? = nil

    /// 照原样整段替换（手动保存、标签编辑走的路）。
    static let replace = EmbeddedAssetWritePolicy(keepsExistingCover: false, keepsExistingLyrics: false, skipsUnchanged: false)

    /// 文件里有没有任何歌词：读标签读到的各份原文、译文字段；MP3 再按字节数一下歌词帧（读不出文字的也算）。
    static func fileHasLyrics(_ metadata: FileMetadataReader.Metadata, rawLyricsFrameCount: Int?) -> Bool {
        var texts: [String] = []
        if let text = metadata.lyricsText { texts.append(text) }
        if let text = metadata.translatedLyricsText { texts.append(text) }
        texts.append(contentsOf: metadata.lyricsVariants.map(\.text))
        texts.append(contentsOf: Array(metadata.languageTaggedLyrics.values))
        texts.append(contentsOf: Array(metadata.languageTaggedTranslations.values))
        return ScrapedLyricsEmbedPlan.fileHasLyrics(texts: texts, rawFieldCount: rawLyricsFrameCount)
    }

    /// 封面、歌词按规矩筛掉不该写的之后还剩什么。纯判定，便于测试。
    static func filtered(
        coverData: Data?, lyricsText: String?,
        existingCover: Data?, existingLyrics: String?,
        policy: EmbeddedAssetWritePolicy
    ) -> (coverData: Data?, lyricsText: String?) {
        var cover = coverData
        var lyrics = lyricsText
        if let newCover = cover, let current = existingCover, !current.isEmpty,
           policy.keepsExistingCover || (policy.skipsUnchanged && current == newCover) {
            cover = nil
        }
        let currentLyrics = existingLyrics.map(normalizedLyrics) ?? ""
        if let newLyrics = lyrics, !currentLyrics.isEmpty,
           policy.keepsExistingLyrics || (policy.skipsUnchanged && currentLyrics == normalizedLyrics(newLyrics)) {
            lyrics = nil
        }
        return (cover, lyrics)
    }

    static func normalizedLyrics(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// 按 `EmbeddedAssetWritePolicy` 写时（刮削），歌词这一项最后怎么处理的。照原样整段替换时一直是 `.notIncluded`。
enum EmbeddedAssetLyricsHandling: Sendable, Equatable {
    /// 这次没带歌词。
    case notIncluded
    /// 文件里已有（只补缺失）或和现在的一样，没写。
    case kept
    /// 文件里原来没有歌词，和封面一起写进了默认字段。
    case written
    /// 文件里已有歌词、这次只写歌词：在这次事务里按字段换掉了正在用的那一份（写入器的回报按请求 id 取）。
    case replacedByField
    /// 文件里已有歌词、这次还要换封面：事务里没动歌词，留给调用方按字段替换正在用的那一份。
    case leftForFieldReplace
}

enum EmbeddedMetadataWritebackStage: String, Sendable, Equatable {
    case inspect
    case download
    case edit
    case replace
    case readback
}

enum EmbeddedMetadataCoordinatedWritebackError: LocalizedError, Equatable {
    case unsupported
    case conflict
    case invalidRemoteState
    case accessDenied(source: String, stage: EmbeddedMetadataWritebackStage, reason: SourceFileMutationError)
    /// `isTransient`: the underlying failure was a timeout, a dropped
    /// connection or a server error, which may not happen again.
    case operationFailed(
        source: String,
        stage: EmbeddedMetadataWritebackStage,
        detail: String,
        isTransient: Bool = false
    )
    case remoteVerificationFailed(source: String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "metadata_writeback_error_unsupported")
        case .conflict:
            return String(localized: "metadata_writeback_error_conflict")
        case .invalidRemoteState:
            return String(localized: "metadata_writeback_error_invalid_state")
        case .accessDenied(let source, let stage, let reason):
            return String(format: String(localized: "metadata_writeback_error_stage_format"),
                          source, stage.localizedName, reason.localizedDescription)
        case .operationFailed(let source, let stage, let detail, _):
            return String(
                format: String(localized: "metadata_writeback_error_stage_format"),
                source,
                stage.localizedName,
                detail
            )
        case .remoteVerificationFailed(let source):
            return String(
                format: String(localized: "metadata_writeback_error_readback_format"),
                source
            )
        }
    }
}

private extension EmbeddedMetadataWritebackStage {
    var localizedName: String {
        switch self {
        case .inspect: return String(localized: "metadata_writeback_stage_inspect")
        case .download: return String(localized: "metadata_writeback_stage_download")
        case .edit: return String(localized: "metadata_writeback_stage_edit")
        case .replace: return String(localized: "metadata_writeback_stage_replace")
        case .readback: return String(localized: "metadata_writeback_stage_readback")
        }
    }
}

/// Minimal surface every writable file source implements. The complete
/// writeback transaction deliberately lives outside individual connectors so
/// providers cannot accidentally omit conflict checks or remote verification.
protocol EmbeddedMetadataWritebackAdapter: MusicSourceConnector {
    /// 扫描时记进歌曲 revision 的，除了音频本身还有同名封面、歌词、MV 文件的指纹。
    static var revisionFoldsSidecarFingerprints: Bool { get }
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState
    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws
    func replaceMetadataFileReturningPath(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws -> String
    func invalidateMetadataWritebackCache(for path: String) async
    /// 改写之前要做的准备(本机文件:还没下到这台设备的 iCloud 文件先下载)。改名这类只读属性的
    /// 操作不经过这里。
    func prepareForMetadataWriteback(at path: String) async throws
}

/// 一个音频文件此刻的身份和标签。标签保存撞上「编辑期间被别处改过」时单独重读这一首用,
/// 不必让用户去重扫整个音乐源。
struct EmbeddedMetadataFileSnapshot: Sendable {
    let state: EmbeddedMetadataRemoteFileState
    let tags: EmbeddedMetadataVerification

    /// 这一行换成文件现在的身份;标签不动。
    func applyingIdentity(to song: Song) -> Song {
        var refreshed = song
        refreshed.fileSize = state.fileSize
        refreshed.lastModified = state.modifiedDate
        refreshed.revision = state.revision
        return refreshed
    }
}

extension MusicSourceConnector {
    /// 默认:能做整文件写回的连接器读一遍文件现在的身份和标签;别的连接器不支持。
    func embeddedMetadataSnapshot(for path: String) async throws -> EmbeddedMetadataFileSnapshot {
        guard let adapter = self as? any EmbeddedMetadataWritebackAdapter else {
            throw EmbeddedMetadataCoordinatedWritebackError.unsupported
        }
        return try await EmbeddedMetadataWritebackCoordinator.snapshot(adapter: adapter, path: path)
    }
}

/// A replacement may commit before its verification download fails. Preserve
/// the new address even then, without treating unverified tags as a saved edit.
struct EmbeddedMetadataReplacementReadbackError: LocalizedError {
    let filePath: String
    let fileSize: Int64
    let detail: String

    var errorDescription: String? { detail }
}

extension EmbeddedMetadataWritebackAdapter {
    static var revisionFoldsSidecarFingerprints: Bool { false }

    func invalidateMetadataWritebackCache(for path: String) async {}

    func prepareForMetadataWriteback(at path: String) async throws {}

    func replaceMetadataFileReturningPath(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws -> String {
        try await replaceMetadataFile(at: path, with: localURL, expected: expected)
        return path
    }

    func writeEmbeddedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyrics: EmbeddedLyricsEdit,
        writesTextTags: Bool
    ) async throws -> EmbeddedMetadataWritebackResult {
        try await EmbeddedMetadataWritebackCoordinator.write(
            adapter: self,
            original: original,
            updated: updated,
            coverData: coverData,
            lyrics: lyrics,
            writesTextTags: writesTextTags
        )
    }

    func writeEmbeddedAssets(
        original: Song,
        coverData: Data?,
        lyrics: EmbeddedLyricsEdit,
        policy: EmbeddedAssetWritePolicy
    ) async throws -> EmbeddedMetadataWritebackResult {
        try await EmbeddedMetadataWritebackCoordinator.write(
            adapter: self,
            original: original,
            updated: original,
            coverData: coverData,
            lyrics: lyrics,
            writesTextTags: false,
            assetPolicy: policy
        )
    }

    func writeEmbeddedComment(
        _ comment: EmbeddedLyricsEdit,
        for song: Song
    ) async throws -> EmbeddedMetadataWritebackResult {
        try await EmbeddedMetadataWritebackCoordinator.write(
            adapter: self,
            original: song,
            updated: song,
            coverData: nil,
            lyrics: .keep,
            writesTextTags: false,
            comment: comment
        )
    }

    /// Convenience for path-addressed providers. ID-addressed cloud drives
    /// implement `metadataWritebackState` with their native item lookup API.
    func listedMetadataWritebackState(
        for path: String,
        rootPath: String = "/"
    ) async throws -> EmbeddedMetadataRemoteFileState {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? rootPath : parent
        let name = (path as NSString).lastPathComponent
        guard let item = try await listFiles(at: directory).first(where: {
            $0.path == path || ($0.name == name && !$0.isDirectory)
        }) else {
            throw SourceError.fileNotFound(path)
        }
        return EmbeddedMetadataRemoteFileState(
            fileSize: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision
        )
    }
}

enum EmbeddedMetadataWritebackCoordinator {
    static func write<Adapter: EmbeddedMetadataWritebackAdapter>(
        adapter: Adapter,
        original: Song,
        updated: Song,
        coverData: Data?,
        lyrics: EmbeddedLyricsEdit = .keep,
        writesTextTags: Bool = true,
        comment: EmbeddedLyricsEdit = .keep,
        assetPolicy: EmbeddedAssetWritePolicy = .replace
    ) async throws -> EmbeddedMetadataWritebackResult {
        guard AudioMetadataWritebackPolicy.embeddedFormats.contains(updated.fileFormat),
              !updated.isCueTrack,
              !updated.isStreamDescriptor else {
            throw EmbeddedMetadataCoordinatedWritebackError.unsupported
        }

        let sourceName = displayName(for: Adapter.self)
        try await run(source: sourceName, stage: .download) {
            try await adapter.prepareForMetadataWriteback(at: original.filePath)
        }
        let initialState = try await run(source: sourceName, stage: .inspect) {
            try await adapter.metadataWritebackState(for: original.filePath)
        }
        guard initialState.hasReliableConflictGuard else {
            throw EmbeddedMetadataCoordinatedWritebackError.invalidRemoteState
        }
        if !initialState.matchesScannedSong(original) {
            guard initialState.matchesScannedSong(
                original,
                revisionFoldsSidecarFingerprints: Adapter.revisionFoldsSidecarFingerprints
            ) else {
                plog("⚠️ Writeback conflict stage=scanned source=\(sourceName) \(initialState.mismatchSummary(againstScanned: original))")
                throw EmbeddedMetadataCoordinatedWritebackError.conflict
            }
            plog("Writeback: only the cover/lyrics files beside the audio changed since the scan source=\(sourceName); audio unchanged, continuing")
        }

        await adapter.invalidateMetadataWritebackCache(for: original.filePath)
        let sourceURL = try await run(source: sourceName, stage: .download) {
            try await adapter.localURL(for: original.filePath)
        }
        // SFBAudioEngine picks its file class by extension, and the working
        // copy is ours to name: an audiobook `.m4b` is written like the `.m4a`
        // it already is. Only this temporary copy is renamed — the edited bytes
        // still go back to the original path under its own name.
        let declaredExtension = sourceURL.pathExtension.isEmpty
            ? updated.fileFormat.rawValue
            : sourceURL.pathExtension
        let fileExtension = AudioFormat.from(fileExtension: declaredExtension)?.rawValue
            ?? declaredExtension
        let workingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-metadata-writeback-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        defer { try? FileManager.default.removeItem(at: workingURL) }

        try await run(source: sourceName, stage: .download) {
            try FileManager.default.copyItem(at: sourceURL, to: workingURL)
        }
        // 改的是工作副本。连接器为这次写回整首下载的原文件到这里就用完了,
        // 留着既不计入音频缓存上限也不参与淘汰, 批量写回能占掉几个 GB。
        await adapter.invalidateMetadataWritebackCache(for: original.filePath)

        // 刮削的写入先看文件里已有的：只补缺失时已有的不换，和要写的一样时不整首重写；
        // 文件里已有歌词又要换时，这次不整段写歌词，交回调用方按字段替换。
        var writtenCover = coverData
        var writtenLyrics = lyrics
        var assetLyrics = EmbeddedAssetLyricsHandling.notIncluded
        if assetPolicy != .replace, writtenCover != nil || writtenLyrics != .keep {
            let existing = await FileMetadataReader.read(from: workingURL)
            let kept = EmbeddedAssetWritePolicy.filtered(
                coverData: writtenCover, lyricsText: nil,
                existingCover: existing.coverArtData, existingLyrics: nil,
                policy: assetPolicy
            )
            if writtenCover != nil, kept.coverData == nil {
                plog("Writeback: cover left as the file has it source=\(sourceName) keepsExisting=\(assetPolicy.keepsExistingCover)")
            }
            writtenCover = kept.coverData
            if case .set(let lyricsText) = writtenLyrics {
                var rawLyricsFrameCount: Int?
                if workingURL.pathExtension.lowercased() == "mp3",
                   let data = try? Data(contentsOf: workingURL, options: .mappedIfSafe) {
                    rawLyricsFrameCount = ID3LyricsFramePreservation.lyricsFrameBodies(in: data)?.count
                }
                let fileHasLyrics = EmbeddedAssetWritePolicy.fileHasLyrics(
                    existing, rawLyricsFrameCount: rawLyricsFrameCount
                )
                var incoming = [lyricsText]
                if case .replace(let fieldText, _)? = assetPolicy.lyricsFieldReplacement?.operation {
                    incoming.append(fieldText)
                }
                let plan = ScrapedLyricsEmbedPlan.plan(
                    incoming: incoming,
                    fileChosen: existing.lyricsText,
                    fileHasLyrics: fileHasLyrics,
                    keepsExisting: assetPolicy.keepsExistingLyrics,
                    skipsUnchanged: assetPolicy.skipsUnchanged,
                    replacesByField: assetPolicy.lyricsFieldReplacement != nil
                )
                switch plan {
                case .setInTransaction:
                    assetLyrics = .written
                case .keepExisting, .unchanged:
                    assetLyrics = .kept
                    writtenLyrics = .keep
                case .replaceByField:
                    if writtenCover == nil, !writesTextTags, comment == .keep,
                       let request = assetPolicy.lyricsFieldReplacement {
                        // 这次只有歌词要写：就在这次事务里按字段改，不用整首再传一遍。
                        assetLyrics = .replacedByField
                        writtenLyrics = .field(request)
                    } else {
                        // 按字段改不能和封面放在同一次写入里：这次只换封面，歌词交回调用方随后单独写。
                        assetLyrics = .leftForFieldReplace
                        writtenLyrics = .keep
                    }
                }
                plog("Writeback: scraped lyrics plan=\(plan.rawValue) fileHasLyrics=\(fileHasLyrics) variants=\(existing.lyricsVariants.count) rawFrames=\(rawLyricsFrameCount.map { "\($0)" } ?? "-") source=\(sourceName)")
            }
            if writtenCover == nil, writtenLyrics == .keep, !writesTextTags, comment == .keep {
                // 没有要写的：不替换文件，交回文件此刻的身份。
                let currentTags = try? EmbeddedMetadataWriter.currentTags(at: workingURL)
                let digest = try await run(source: sourceName, stage: .edit) {
                    try SHA256FileDigest.hexDigest(at: workingURL)
                }
                let emptyTags = EmbeddedMetadataVerification(
                    title: nil, artist: nil, albumTitle: nil, genre: nil,
                    year: nil, trackNumber: nil, discNumber: nil, coverData: nil
                )
                return EmbeddedMetadataWritebackResult(
                    fileSize: initialState.fileSize,
                    modifiedDate: initialState.modifiedDate,
                    revision: initialState.revision,
                    fileSHA256: digest,
                    verification: currentTags ?? emptyTags,
                    filePath: original.filePath,
                    previousTags: currentTags,
                    assetsUnchanged: true,
                    assetLyrics: assetLyrics
                )
            }
        }

        let edits = EmbeddedMetadataEdits(
            tags: writesTextTags
                ? EmbeddedMetadataEdits.Tags(
                    title: updated.title,
                    artist: updated.artistName,
                    albumTitle: updated.albumTitle,
                    genre: updated.genre,
                    year: updated.year,
                    trackNumber: updated.trackNumber,
                    discNumber: updated.discNumber,
                    albumArtist: updated.albumArtistName
                )
                : nil,
            coverData: writtenCover,
            lyrics: writtenLyrics,
            changedFields: TagMetadataWritebackField.changedFields(
                from: original,
                to: updated,
                includesCover: false
            ),
            comment: comment
        )
        let previousTags = try? EmbeddedMetadataWriter.currentTags(at: workingURL)
        let verification = try await run(source: sourceName, stage: .edit) {
            try await Task.detached(priority: .userInitiated) {
                try await EmbeddedMetadataWriter.writeAndVerify(edits, to: workingURL)
            }.value
        }
        let editedSHA256 = try await run(source: sourceName, stage: .edit) {
            try SHA256FileDigest.hexDigest(at: workingURL)
        }

        // Close the download/edit race immediately before the provider starts
        // replacing bytes. Adapters with conditional APIs repeat this check at
        // the server (If-Match, Dropbox update rev, etc.).
        let currentState = try await run(source: sourceName, stage: .inspect) {
            try await adapter.metadataWritebackState(for: original.filePath)
        }
        guard initialState.matches(currentState) else {
            plog("⚠️ Writeback conflict stage=beforeReplace source=\(sourceName) \(initialState.mismatchSummary(against: currentState))")
            throw EmbeddedMetadataCoordinatedWritebackError.conflict
        }

        let replacementPath = try await run(source: sourceName, stage: .replace) {
            try await adapter.replaceMetadataFileReturningPath(
                at: original.filePath,
                with: workingURL,
                expected: initialState
            )
        }

        await adapter.invalidateMetadataWritebackCache(for: original.filePath)
        await adapter.invalidateMetadataWritebackCache(for: replacementPath)
        do {
            let finalState = try await run(source: sourceName, stage: .readback) {
                try await adapter.metadataWritebackState(for: replacementPath)
            }
            let readbackURL = try await run(source: sourceName, stage: .readback) {
                try await adapter.localURL(for: replacementPath)
            }
            let readbackSHA256 = try await run(source: sourceName, stage: .readback) {
                try SHA256FileDigest.hexDigest(at: readbackURL)
            }
            // 回读只为核对摘要, 下回来的这份同样不留。
            await adapter.invalidateMetadataWritebackCache(for: replacementPath)
            guard readbackSHA256 == editedSHA256 else {
                throw EmbeddedMetadataCoordinatedWritebackError.remoteVerificationFailed(
                    source: sourceName
                )
            }

            return EmbeddedMetadataWritebackResult(
                fileSize: finalState.fileSize,
                modifiedDate: finalState.modifiedDate,
                revision: finalState.revision,
                fileSHA256: readbackSHA256,
                verification: verification,
                filePath: replacementPath,
                previousTags: previousTags,
                assetLyrics: assetLyrics
            )
        } catch {
            guard replacementPath != original.filePath else { throw error }
            let size = try? workingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            throw EmbeddedMetadataReplacementReadbackError(
                filePath: replacementPath,
                fileSize: Int64(size ?? 0),
                detail: error.localizedDescription
            )
        }
    }

    /// 读一遍文件现在的身份和标签。远端源要把这一首整个下下来读,读完就删。
    static func snapshot<Adapter: EmbeddedMetadataWritebackAdapter>(
        adapter: Adapter,
        path: String
    ) async throws -> EmbeddedMetadataFileSnapshot {
        let sourceName = displayName(for: Adapter.self)
        await adapter.invalidateMetadataWritebackCache(for: path)
        try await run(source: sourceName, stage: .download) {
            try await adapter.prepareForMetadataWriteback(at: path)
        }
        let state = try await run(source: sourceName, stage: .inspect) {
            try await adapter.metadataWritebackState(for: path)
        }
        let url = try await run(source: sourceName, stage: .download) {
            try await adapter.localURL(for: path)
        }
        let tags: EmbeddedMetadataVerification
        do {
            tags = try await run(source: sourceName, stage: .inspect) {
                try await Task.detached(priority: .userInitiated) {
                    try EmbeddedMetadataWriter.currentTags(at: url)
                }.value
            }
        } catch {
            await adapter.invalidateMetadataWritebackCache(for: path)
            throw error
        }
        await adapter.invalidateMetadataWritebackCache(for: path)
        return EmbeddedMetadataFileSnapshot(state: state, tags: tags)
    }

    private static func run<Value>(
        source: String,
        stage: EmbeddedMetadataWritebackStage,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as EmbeddedMetadataReplacementReadbackError {
            throw error
        } catch let error as EmbeddedMetadataCoordinatedWritebackError {
            throw error
        } catch EmbeddedMetadataWritebackSourceError.conflict {
            throw EmbeddedMetadataCoordinatedWritebackError.conflict
        } catch {
            if let reason = MetadataWriteFailurePolicy.denial(error) {
                throw EmbeddedMetadataCoordinatedWritebackError.accessDenied(
                    source: source, stage: stage, reason: reason
                )
            }
            if MetadataWriteFailurePolicy.stopsSourceWrites(error) { throw error }
            throw EmbeddedMetadataCoordinatedWritebackError.operationFailed(
                source: source,
                stage: stage,
                detail: error.localizedDescription,
                isTransient: MetadataWriteFailurePolicy.isTransient(error)
            )
        }
    }

    private static func displayName<Adapter>(for type: Adapter.Type) -> String {
        switch String(describing: type) {
        case "LocalFileSource": return MusicSourceType.local.displayName
        case "SynologySource": return MusicSourceType.synology.displayName
        case "QnapSource": return MusicSourceType.qnap.displayName
        case "WebDAVSource": return MusicSourceType.webdav.displayName
        case "SMBSource": return MusicSourceType.smb.displayName
        case "FTPSource": return MusicSourceType.ftp.displayName
        case "SFTPSource": return MusicSourceType.sftp.displayName
        case "NFSSource": return MusicSourceType.nfs.displayName
        case "S3Source": return MusicSourceType.s3.displayName
        case "BaiduPanSource": return MusicSourceType.baiduPan.displayName
        case "U115Source": return MusicSourceType.pan115.displayName
        case "Pan123Source": return MusicSourceType.pan123.displayName
        case "DrimeSource": return MusicSourceType.drime.displayName
        case "AliyunDriveSource": return MusicSourceType.aliyunDrive.displayName
        case "GoogleDriveSource": return MusicSourceType.googleDrive.displayName
        case "OneDriveSource": return MusicSourceType.oneDrive.displayName
        case "DropboxSource": return MusicSourceType.dropbox.displayName
        case "PCloudSource": return MusicSourceType.pcloud.displayName
        default:
            let name = String(describing: type)
            return name.hasSuffix("Source") ? String(name.dropLast("Source".count)) : name
        }
    }
}

enum SHA256FileDigest {
    static func hexDigest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
