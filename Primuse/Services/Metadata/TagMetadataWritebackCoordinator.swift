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
    var hasNotices: Bool { hasFailures || !unsupportedFields.isEmpty }
    var remoteMutationOccurred: Bool {
        fields.contains {
            if case .written = $0.disposition { return true }
            return false
        }
    }

    /// Embedded-file replacement is one guarded transaction. A failed result
    /// must not be silently converted into a local-only edit. Media-server and
    /// sidecar APIs may partially succeed, so their local row must still be
    /// brought in line with the requested values while the per-field report is
    /// shown to the user.
    var shouldAbortLocalSave: Bool {
        mode == .embedded && hasFailures
    }

    var issueMessage: String? {
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

        switch mode {
        case .embedded:
            do {
                let result = try await connector.writeEmbeddedMetadata(
                    original: original,
                    updated: updated,
                    coverData: coverData,
                    lyrics: .keep,
                    writesTextTags: true
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
                report.setDisposition(.failed(error.localizedDescription), for: changed)
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
                coverData: coverData,
                lyricsLines: nil,
                lyricsContent: nil
            )
            for field in changed {
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
                coverData: coverData,
                lyricsLines: nil
            )
            if result.coverWritten {
                report.setDisposition(.written, for: [.cover])
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
