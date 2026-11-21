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
    /// 文件在编辑期间被别处改过,重读之后同一项两边都改了:没写,等用户选。
    var conflict: TagWriteConflict? = nil
    /// 文件在编辑期间被别处改过,单独重读这一首也没读成(文件没了、没权限、连不上)。
    var conflictRereadFailed = false
    /// 文件在编辑期间被别处改过,重读后不重叠,用新的文件身份写成了。
    var recoveredFromConflict = false

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

    /// 嵌入写回没写成,而且不是源明确拒绝:连不上、超时、回读校验没过。修改照样存在 Primuse
    /// (见 `TagWritebackKeepPolicy`),只是要说明文件没写成,之后自动再写一次。
    var embeddedWriteFailed: Bool {
        mode == .embedded && hasFailures
    }

    /// 这次没写到源的部分怎么留在 Primuse、之后要不要自动再写。
    var keepOutcome: TagWritebackKeepPolicy.Outcome {
        TagWritebackKeepPolicy.outcome(
            fields: fields.map { TagWritebackKeepPolicy.Field(isCover: $0.field == .cover, result: $0.disposition.keepResult) },
            sourceTakesWrites: mode != .localOnly,
            refusedThisTime: localSaveNotice != nil
        )
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
    /// `connector` 为 nil 时只做不必碰音乐源的那部分(只读源、旁路文件源只改文字),
    /// 见 `TagWritebackKeepPolicy.needsSource`。
    static func write(
        mode: TagMetadataPersistenceMode,
        connector: (any MusicSourceConnector)?,
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
            guard let connector else {
                report.setDisposition(.failed(String(localized: "metadata_writeback_error_invalid_state")), for: changed)
                return report
            }
            func record(_ result: EmbeddedMetadataWritebackResult) {
                report.updatedSong.fileSize = result.fileSize
                report.updatedSong.lastModified = result.modifiedDate
                report.updatedSong.revision = result.revision
                report.updatedSong.filePath = result.filePath ?? updated.filePath
                report.previousFileTags = result.previousTags
                report.setDisposition(.written, for: changed)
            }
            func recordFailure(_ error: any Error) {
                if let error = error as? EmbeddedMetadataReplacementReadbackError {
                    var relocated = original
                    relocated.filePath = error.filePath
                    relocated.fileSize = error.fileSize
                    relocated.revision = nil
                    relocated.lastModified = nil
                    report.replacementAfterFailedVerification = relocated
                    report.setDisposition(.failed(error.localizedDescription), for: changed)
                } else if MetadataWriteFailurePolicy.allowsLocalSave(error) {
                    report.setDisposition(.localOnly, for: changed)
                    report.localSaveNotice = MetadataWriteFailurePolicy.localSaveNotice
                } else {
                    report.setDisposition(.failed(error.localizedDescription), for: changed)
                }
            }
            do {
                record(try await writeEmbeddedRetryingOnce(
                    connector: connector,
                    original: original,
                    updated: updated,
                    coverData: sourceCover
                ))
            } catch EmbeddedMetadataCoordinatedWritebackError.conflict {
                // 页面手里的文件身份是旧的,原样再试永远失败:单独重读这一首,
                // 别处改的和这次改的不重叠就用新身份写一次,重叠就交给用户选。
                switch await recoverFromConflict(
                    connector: connector,
                    original: original,
                    updated: updated,
                    coverData: sourceCover
                ) {
                case .written(let result, let retried):
                    report.recoveredFromConflict = true
                    report.updatedSong = retried
                    record(result)
                case .needsChoice(let conflict):
                    report.conflict = conflict
                    report.setDisposition(.failed(conflictMessage(conflict.fields)), for: changed)
                case .rereadFailed(let message):
                    report.conflictRereadFailed = true
                    report.setDisposition(.failed(message), for: changed)
                case .failed(let error as EmbeddedMetadataCoordinatedWritebackError) where error == .conflict:
                    report.setDisposition(.failed(String(localized: "save_location_conflict_again")), for: changed)
                case .failed(let error):
                    recordFailure(error)
                }
            } catch {
                recordFailure(error)
            }

        case .serverAPI:
            guard let connector else {
                report.setDisposition(.failed(String(localized: "metadata_writeback_error_invalid_state")), for: changed)
                return report
            }
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
                if let fieldResult = result.fieldResults.last(where: { $0.field == field }) {
                    report.setDisposition(fieldResult.disposition, for: [field])
                    continue
                }
                if field == .albumArtist {
                    report.setDisposition(.unsupported(String(localized: "metadata_writeback_error_unsupported")), for: [field])
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
            guard let connector else {
                report.setDisposition(.failed(String(localized: "metadata_writeback_error_invalid_state")), for: [.cover])
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
            if !changed.isEmpty {
                report.localSaveNotice = String(localized: "save_location_tags_read_only_source")
            }
        }

        return report
    }

    private enum ConflictRecovery {
        /// 用新身份写成了;`updated` 是写的那一行(带上了别处改的字段)。
        case written(EmbeddedMetadataWritebackResult, updated: Song)
        case needsChoice(TagWriteConflict)
        case rereadFailed(String)
        /// 用新身份重写的那一次本身失败了。
        case failed(any Error)
    }

    /// 文件在编辑期间被别处改过:单独重读它现在的身份和标签。只看这次改了的字段 ——
    /// 写回只改这几项,别处改的其他字段原样留在文件里。
    private static func recoverFromConflict(
        connector: any MusicSourceConnector,
        original: Song,
        updated: Song,
        coverData: Data?
    ) async -> ConflictRecovery {
        let snapshot: EmbeddedMetadataFileSnapshot
        do {
            snapshot = try await connector.embeddedMetadataSnapshot(for: original.filePath)
        } catch {
            plog("Metadata writeback conflict reread failed songID=\(original.id): \(error.localizedDescription)")
            return .rereadFailed(String(
                format: String(localized: "save_location_conflict_reread_failed_format"),
                SourceErrorPresentation.userFacingDescription(error)
            ))
        }
        let changed = TagMetadataWritebackField.changedFields(from: original, to: updated, includesCover: false)
        let ordered = TagMetadataWritebackField.allCases.filter { changed.contains($0) }
        let states = ordered.map { field in
            TagWriteConflictPolicy.FieldState(
                field: field,
                baseline: field.value(in: original),
                fileNow: field.fileValue(in: snapshot.tags, for: original),
                edited: field.value(in: updated)
            )
        }
        var overlapping: [TagMetadataWritebackField]
        switch TagWriteConflictPolicy.resolve(states) {
        case .retry: overlapping = []
        case .askUser(let fields): overlapping = fields
        }
        let changesCover = coverData?.isEmpty == false
        if TagWriteConflictPolicy.coverOverlaps(
            userChangedCover: changesCover,
            fileCoverIsTheNewOne: changesCover && snapshot.tags.coverData == coverData
        ) {
            overlapping.append(.cover)
        }
        let refreshed = snapshot.applyingIdentity(to: original)
        guard overlapping.isEmpty else {
            plog("Metadata writeback conflict overlaps songID=\(original.id) "
                + "fields=\(overlapping.map(\.rawValue).joined(separator: ",")) "
                + "\(snapshot.state.mismatchSummary(againstScanned: original))")
            return .needsChoice(TagWriteConflict(
                refreshedOriginal: refreshed,
                edited: updated,
                fileTags: snapshot.tags,
                fields: overlapping,
                editedCover: changesCover ? coverData : nil
            ))
        }
        // 别处改的、这次没改的字段两行都换成文件里的值:资料库跟上文件,写回也不会把它改回旧值。
        var retryOriginal = refreshed
        var retryUpdated = updated
        retryUpdated.fileSize = refreshed.fileSize
        retryUpdated.lastModified = refreshed.lastModified
        retryUpdated.revision = refreshed.revision
        let adopted = TagMetadataWritebackField.adoptChangesElsewhere(
            from: snapshot.tags,
            original: &retryOriginal,
            updated: &retryUpdated,
            userChanged: changed
        )
        plog("Metadata writeback conflict reread songID=\(original.id) "
            + "changedElsewhere=\(adopted.map(\.rawValue).joined(separator: ",")) "
            + "edited=\(ordered.map(\.rawValue).joined(separator: ",")) retrying with the current file identity")
        do {
            let result = try await writeEmbeddedRetryingOnce(
                connector: connector,
                original: retryOriginal,
                updated: retryUpdated,
                coverData: coverData
            )
            return .written(result, updated: retryUpdated)
        } catch {
            return .failed(error)
        }
    }

    /// 批量编辑里冲突的说明:文字字段要用户去单曲标签编辑里选;封面没留下新图,要用新封面得再换一次。
    static func conflictMessage(_ fields: [TagMetadataWritebackField]) -> String {
        let textFields = fields.filter { $0 != .cover }
        var parts: [String] = []
        if !textFields.isEmpty {
            let names = textFields.map {
                String(format: String(localized: "save_location_field_quote_format"), $0.localizedName)
            }
            parts.append(String(
                format: String(localized: "save_location_conflict_fields_format"),
                ListFormatter.localizedString(byJoining: names)
            ))
        }
        if fields.contains(.cover) {
            parts.append(String(localized: "save_location_conflict_cover_kept"))
        }
        return LyricsWriteback.joinedSentences(parts)
    }

    /// 标签和封面这次落在哪里:开头先说落点,后面是原因。
    static func noticeText(for plan: SaveLocationPolicy.Plan) -> String {
        switch (plan.destination, plan.reason) {
        case (.audioFile, _):
            return String(localized: "save_location_tags_audio")
        case (.mediaServer, _):
            return String(localized: "save_location_tags_server")
        case (_, .formatCannotEmbed):
            return String(localized: "save_location_tags_cover_file")
        case (_, .noFolderAccess):
            return String(localized: "save_location_tags_cover_no_folder")
        case (_, .folderNotWritable):
            return String(localized: "save_location_tags_cover_folder_not_writable")
        case (_, .audioFileNotWritable):
            return String(localized: "save_location_tags_audio_not_writable")
        case (_, .readOnlyVolume):
            return String(localized: "save_location_read_only_volume")
        default:
            return String(localized: "save_location_tags_read_only_source")
        }
    }

    /// 连不上音乐源(连接失败、源找不到):要写到源的字段按写入失败报。修改照样存在 Primuse,
    /// 音乐源恢复连接后自动再写一次。
    static func sourceUnavailable(
        mode: TagMetadataPersistenceMode,
        original: Song,
        updated: Song,
        coverData: Data?,
        error: any Error
    ) -> TagMetadataWritebackReport {
        let changed = TagMetadataWritebackField.changedFields(
            from: original,
            to: updated,
            includesCover: coverData?.isEmpty == false
        )
        // 旁路文件源只写封面,文字标签本来就只在 Primuse。
        let attempted = mode == .sidecarOnly ? changed.intersection([.cover]) : changed
        let message = error.localizedDescription
        return TagMetadataWritebackReport(
            mode: mode,
            updatedSong: updated,
            fields: TagMetadataWritebackField.allCases.map { field in
                let disposition: TagMetadataFieldWritebackDisposition
                if attempted.contains(field) {
                    disposition = .failed(message)
                } else {
                    disposition = changed.contains(field) ? .localOnly : .unchanged
                }
                return TagMetadataFieldWritebackResult(field: field, disposition: disposition)
            }
        )
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

private extension TagMetadataFieldWritebackDisposition {
    var keepResult: TagWritebackKeepPolicy.FieldResult {
        switch self {
        case .unchanged: .unchanged
        case .written: .written
        case .localOnly: .keptLocal
        case .unsupported: .unsupported
        case .failed: .failed
        }
    }
}
