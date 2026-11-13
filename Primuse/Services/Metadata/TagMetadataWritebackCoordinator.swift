import Foundation
import PrimuseKit

struct TagMetadataWritebackReport: Sendable {
    let mode: TagMetadataPersistenceMode
    var updatedSong: Song
    var fields: [TagMetadataFieldWritebackResult]
    var replacementAfterFailedVerification: Song? = nil
    /// For embedded writes: what the file held before, so an undo can put
    /// back the file's own values.
    var previousFileTags: EmbeddedMetadataVerification? = nil
    var localSaveNotice: String?

    var failedFields: [TagMetadataFieldWritebackResult] {
        fields.filter {
            if case .failed = $0.disposition { return true }
            return false
        }
    }

    var unsupportedFields: [TagMetadataFieldWritebackResult] {
        fields.filter {
            if case .unsupported = $0.disposition { return true }
            return false
        }
    }

    var hasFailures: Bool { !failedFields.isEmpty }
    var hasNotices: Bool { localSaveNotice != nil || hasFailures || !unsupportedFields.isEmpty }
    var remoteMutationOccurred: Bool {
        fields.contains {
            if case .written = $0.disposition { return true }
            return false
        }
    }

    /// Embedded-file replacement is one guarded transaction. Only a definite
    /// write denial permits a disclosed local-only save. Media-server and
    /// sidecar APIs may partially succeed, so their local row must still be
    /// brought in line with the requested values while the per-field report is
    /// shown to the user.
    var shouldAbortLocalSave: Bool {
        mode == .embedded && hasFailures
    }

    var issueMessage: String? {
        if let localSaveNotice { return localSaveNotice }
        if mode == .embedded {
            let failureMessages = failedFields.compactMap { result -> String? in
                if case .failed(let message) = result.disposition { return message }
                return nil
            }
            if let first = failureMessages.first,
               failureMessages.allSatisfy({ $0 == first }) {
                return first
            }
        }
        let lines = fields.compactMap { result -> String? in
            let detail: String
            switch result.disposition {
            case .failed(let message), .unsupported(let message):
                detail = message
            case .unchanged, .written, .localOnly:
                return nil
            }
            return "\(result.field.localizedName): \(detail)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

enum TagMetadataWritebackCoordinator {
    static func write(
        mode: TagMetadataPersistenceMode,
        connector: any MusicSourceConnector,
        original: Song,
        updated: Song,
        coverData: Data?
    ) async -> TagMetadataWritebackReport {
        let changed = TagMetadataWritebackField.changedFields(
            from: original,
            to: updated,
            includesCover: coverData?.isEmpty == false
        )
        var report = TagMetadataWritebackReport(
            mode: mode,
            updatedSong: updated,
            fields: TagMetadataWritebackField.allCases.map {
                TagMetadataFieldWritebackResult(
                    field: $0,
                    disposition: changed.contains($0) ? .localOnly : .unchanged
                )
            }
        )

        // Music containers and server cover APIs receive a compatible still;
        // the editor persists the original animation as the selected artwork.
        let sourceCover = await Task.detached(priority: .utility) {
            coverData.flatMap { data in
                LibraryArtworkImageProcessor.isAnimatedUpload(data)
                    ? SidecarWriteService.embeddableCoverData(data) : data
            }
        }.value
        switch mode {
        case .embedded:
            do {
                let result = try await writeEmbeddedRetryingOnce(
                    connector: connector,
                    original: original,
                    updated: updated,
                    coverData: sourceCover
                )
                report.updatedSong.fileSize = result.fileSize
                report.updatedSong.lastModified = result.modifiedDate
                report.updatedSong.revision = result.revision
                report.updatedSong.filePath = result.filePath ?? updated.filePath
                report.previousFileTags = result.previousTags
                report.setDisposition(.written, for: changed)
            } catch let error as EmbeddedMetadataReplacementReadbackError {
                var relocated = original
                relocated.filePath = error.filePath
                relocated.fileSize = error.fileSize
                relocated.revision = nil
                relocated.lastModified = nil
                report.replacementAfterFailedVerification = relocated
                report.setDisposition(.failed(error.localizedDescription), for: changed)
            } catch {
                if MetadataWriteFailurePolicy.allowsLocalSave(error) {
                    report.setDisposition(.localOnly, for: changed)
                    report.localSaveNotice = MetadataWriteFailurePolicy.localSaveNotice
                } else {
                    report.setDisposition(.failed(error.localizedDescription), for: changed)
                }
            }

        case .serverAPI:
            guard let writer = connector as? any MediaServerWritebackConnector else {
                report.setDisposition(
                    .failed(String(localized: "metadata_writeback_error_unsupported")),
                    for: changed
                )
                return report
            }
            let result = await writer.writeScrapedMetadata(
                original: original,
                updated: updated,
                coverData: sourceCover,
                lyricsLines: nil,
                lyricsContent: nil
            )
            for field in changed {
                if field == .albumArtist {
                    report.setDisposition(.unsupported(String(localized: "metadata_writeback_error_unsupported")), for: [field])
                    continue
                }
                if let fieldResult = result.fieldResults.last(where: { $0.field == field }) {
                    report.setDisposition(fieldResult.disposition, for: [field])
                    continue
                }

                if field == .cover, result.coverWritten {
                    report.setDisposition(.written, for: [field])
                } else if TagMetadataWritebackField.metadataFields.contains(field),
                          result.metadataWritten {
                    report.setDisposition(.written, for: [field])
                } else if let error = result.errors.first {
                    report.setDisposition(.failed(error), for: [field])
                } else if let reason = result.unsupported.first {
                    report.setDisposition(.unsupported(reason), for: [field])
                } else {
                    report.setDisposition(
                        .failed(String(localized: "metadata_writeback_error_invalid_state")),
                        for: [field]
                    )
                }
            }

        case .sidecarOnly:
            guard changed.contains(.cover), let coverData, !coverData.isEmpty else {
                return report
            }
            let result = await SidecarWriteService.shared.writeSidecars(
                for: updated,
                using: connector,
                coverData: sourceCover,
                lyricsLines: nil
            )
            if result.coverWritten {
                report.setDisposition(.written, for: [.cover])
            } else if result.coverWriteDenied {
                report.setDisposition(.localOnly, for: [.cover])
                report.localSaveNotice = MetadataWriteFailurePolicy.localSaveNotice
            } else {
                let detail = result.coverError
                    ?? result.errors.first
                    ?? String(localized: "metadata_writeback_error_invalid_state")
                report.setDisposition(.failed(detail), for: [.cover])
            }

        case .localOnly:
            break
        }

        return report
    }

    /// The embedded rewrite, tried a second time after a timeout or a
    /// dropped connection. Only failures before the replacement, or in it,
    /// qualify: the second try starts by checking that the file is still the
    /// one the library knows, so a replacement that did land is reported,
    /// never written twice.
    private static func writeEmbeddedRetryingOnce(
        connector: any MusicSourceConnector,
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> EmbeddedMetadataWritebackResult {
        do {
            return try await connector.writeEmbeddedMetadata(
                original: original, updated: updated, coverData: coverData,
                lyrics: .keep, writesTextTags: true
            )
        } catch {
            guard EmbeddedMetadataWritebackRetryPolicy.retriesOnce(after: error) else { throw error }
            plog("Metadata writeback retrying once songID=\(original.id) after: \(error.localizedDescription)")
            try? await Task.sleep(for: EmbeddedMetadataWritebackRetryPolicy.delay)
            guard !Task.isCancelled else { throw error }
            do {
                return try await connector.writeEmbeddedMetadata(
                    original: original, updated: updated, coverData: coverData,
                    lyrics: .keep, writesTextTags: true
                )
            } catch EmbeddedMetadataCoordinatedWritebackError.conflict {
                // The first try may have replaced the file before it failed.
                // The listener caused no conflict; say what went wrong first.
                throw error
            }
        }
    }
}

/// Which failed embedded writes are tried once more on their own.
enum EmbeddedMetadataWritebackRetryPolicy {
    static let delay: Duration = .seconds(2)

    static func retriesOnce(after error: any Error) -> Bool {
        guard case EmbeddedMetadataCoordinatedWritebackError.operationFailed(_, let stage, _, true) = error else {
            return false
        }
        switch stage {
        case .inspect, .download, .replace: return true
        // A local edit fails the same way twice; after the readback the file
        // has already changed.
        case .edit, .readback: return false
        }
    }
}

private extension TagMetadataWritebackReport {
    mutating func setDisposition(
        _ disposition: TagMetadataFieldWritebackDisposition,
        for targetFields: Set<TagMetadataWritebackField>
    ) {
        fields = fields.map { result in
            guard targetFields.contains(result.field) else { return result }
            return TagMetadataFieldWritebackResult(
                field: result.field,
                disposition: disposition
            )
        }
    }
}
