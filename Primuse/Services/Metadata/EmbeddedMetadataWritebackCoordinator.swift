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

    init(
        fileSize: Int64,
        modifiedDate: Date?,
        revision: String?,
        replacementToken: String? = nil
    ) {
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
        self.revision = revision
        self.replacementToken = replacementToken
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
        if let songRevision = song.revision {
            guard let revision else { return false }
            return songRevision == revision
        }
        guard song.fileSize > 0, fileSize > 0, fileSize == song.fileSize else {
            return false
        }
        guard let songDate = song.lastModified, let modifiedDate else { return false }
        return abs(songDate.timeIntervalSince(modifiedDate)) < 1
    }

    var hasReliableConflictGuard: Bool {
        revision?.isEmpty == false || (fileSize > 0 && modifiedDate != nil)
    }
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
    case operationFailed(
        source: String,
        stage: EmbeddedMetadataWritebackStage,
        detail: String
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
        case .operationFailed(let source, let stage, let detail):
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
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState
    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws
    func invalidateMetadataWritebackCache(for path: String) async
}

extension EmbeddedMetadataWritebackAdapter {
    func invalidateMetadataWritebackCache(for path: String) async {}

    func writeEmbeddedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> EmbeddedMetadataWritebackResult {
        try await EmbeddedMetadataWritebackCoordinator.write(
            adapter: self,
            original: original,
            updated: updated,
            coverData: coverData
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
        coverData: Data?
    ) async throws -> EmbeddedMetadataWritebackResult {
        guard AudioMetadataWritebackPolicy.embeddedFormats.contains(updated.fileFormat),
              !updated.isCueTrack,
              !updated.isStreamDescriptor else {
            throw EmbeddedMetadataCoordinatedWritebackError.unsupported
        }

        let sourceName = displayName(for: Adapter.self)
        let initialState = try await run(source: sourceName, stage: .inspect) {
            try await adapter.metadataWritebackState(for: original.filePath)
        }
        guard initialState.hasReliableConflictGuard else {
            throw EmbeddedMetadataCoordinatedWritebackError.invalidRemoteState
        }
        guard initialState.matchesScannedSong(original) else {
            throw EmbeddedMetadataCoordinatedWritebackError.conflict
        }

        await adapter.invalidateMetadataWritebackCache(for: original.filePath)
        let sourceURL = try await run(source: sourceName, stage: .download) {
            try await adapter.localURL(for: original.filePath)
        }
        let fileExtension = sourceURL.pathExtension.isEmpty
            ? updated.fileFormat.rawValue
            : sourceURL.pathExtension
        let workingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-metadata-writeback-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        defer { try? FileManager.default.removeItem(at: workingURL) }

        try await run(source: sourceName, stage: .download) {
            try FileManager.default.copyItem(at: sourceURL, to: workingURL)
        }

        let edits = EmbeddedMetadataEdits(
            title: updated.title,
            artist: updated.artistName,
            albumTitle: updated.albumTitle,
            genre: updated.genre,
            year: updated.year,
            trackNumber: updated.trackNumber,
            discNumber: updated.discNumber,
            coverData: coverData
        )
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
            throw EmbeddedMetadataCoordinatedWritebackError.conflict
        }

        try await run(source: sourceName, stage: .replace) {
            try await adapter.replaceMetadataFile(
                at: original.filePath,
                with: workingURL,
                expected: initialState
            )
        }

        await adapter.invalidateMetadataWritebackCache(for: original.filePath)
        let finalState = try await run(source: sourceName, stage: .readback) {
            try await adapter.metadataWritebackState(for: original.filePath)
        }
        let readbackURL = try await run(source: sourceName, stage: .readback) {
            try await adapter.localURL(for: original.filePath)
        }
        let readbackSHA256 = try await run(source: sourceName, stage: .readback) {
            try SHA256FileDigest.hexDigest(at: readbackURL)
        }
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
            verification: verification
        )
    }

    private static func run<Value>(
        source: String,
        stage: EmbeddedMetadataWritebackStage,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as EmbeddedMetadataCoordinatedWritebackError {
            throw error
        } catch EmbeddedMetadataWritebackSourceError.conflict {
            throw EmbeddedMetadataCoordinatedWritebackError.conflict
        } catch {
            throw EmbeddedMetadataCoordinatedWritebackError.operationFailed(
                source: source,
                stage: stage,
                detail: error.localizedDescription
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
        case "AliyunDriveSource": return MusicSourceType.aliyunDrive.displayName
        case "GoogleDriveSource": return MusicSourceType.googleDrive.displayName
        case "OneDriveSource": return MusicSourceType.oneDrive.displayName
        case "DropboxSource": return MusicSourceType.dropbox.displayName
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
