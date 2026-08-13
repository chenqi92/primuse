import Foundation
import PrimuseKit

/// 歌词的加载与写回。原本整套逻辑锁在 `TagEditorView` 的私有作用域里，
/// 独立的歌词编辑入口没法复用；抽出来之后标签编辑器和歌词编辑器共用同一条链路，
/// 写回目标(sidecar / 媒体服务器 / 仅本地)的判定也只有一份实现。
@MainActor
enum LyricsWriteback {
    /// 这首歌的歌词能写到哪。决定保存时走哪条路，也决定 UI 上那行状态提示。
    enum Mode: Equatable {
        /// 还在探测。
        case checking
        /// 写同目录的歌词 sidecar 文件（新文件默认 LRC，已有 TTML 保持 TTML）。
        case sidecar(fileName: String, replacesExistingFile: Bool)
        /// 走媒体服务器的写回接口(Jellyfin 等)。
        case mediaServer
        /// 源不可写，只更新 Primuse 自己的库记录。`reason` 非空时明确说明
        /// 服务端为什么没有被修改。
        case localOnly(reason: String?)
        /// 探测失败或源明确不支持，附带原因。
        case unavailable(String)
    }

    // MARK: - 加载

    static func loadEditableText(
        for song: Song,
        sourceManager: SourceManager
    ) async -> String {
        await LyricsLoader.loadEditableText(for: song, sourceManager: sourceManager)
    }

    /// 探测写回目标。sidecar 优先 —— 能写文件就写文件，跨设备和换播放器都还在。
    static func resolveMode(
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> Mode {
        if await sourceManager.supportsSidecarWriting(for: song) {
            do {
                let preflight = try await MusicScraperService.preflightLyricsWriteWithTimeout(
                    seconds: 10,
                    sourceManager: sourceManager,
                    for: song
                )
                return .sidecar(
                    fileName: preflight.fileName,
                    replacesExistingFile: preflight.replacesExistingFile
                )
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }

        let sourceType = sourcesStore.source(id: song.sourceID)?.type
        if sourceType == .jellyfin || sourceType == .emby || sourceType == .plex {
            do {
                let connector = try await sourceManager.connectorForSong(song)
                guard let server = connector as? any ServerLyricsConnector else {
                    return .unavailable(String(localized: "tag_editor_lyrics_server_unsupported"))
                }
                if server.serverLyricsCapabilities.canWrite,
                   connector is any MediaServerWritebackConnector {
                    return .mediaServer
                }
                if sourceType == .emby {
                    return .localOnly(
                        reason: String(localized: "tag_editor_lyrics_server_unsupported")
                    )
                }
                return .localOnly(reason: nil)
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }

        return .localOnly(reason: nil)
    }

    // MARK: - 保存

    /// 保存结果。`errorMessage` 非 nil 表示写回失败，调用方原样展示给用户。
    struct SaveOutcome {
        enum Persistence: Equatable {
            case sidecar
            case mediaServer
            case localOnly
        }

        var updatedSong: Song
        var errorMessage: String?
        var persistence: Persistence

        var succeeded: Bool { errorMessage == nil }

        init(
            updatedSong: Song,
            errorMessage: String?,
            persistence: Persistence = .localOnly
        ) {
            self.updatedSong = updatedSong
            self.errorMessage = errorMessage
            self.persistence = persistence
        }
    }

    /// 把编辑后的歌词文本落盘并更新库记录。
    ///
    /// `allowRemoval` 为 false 时，清空歌词会被拒绝 —— 删歌词是破坏性操作，
    /// 必须由调用方先向用户确认过。
    static func save(
        text: String,
        for song: Song,
        mode: Mode,
        allowRemoval: Bool,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> SaveOutcome {
        var updated = song
        let content = normalized(text)
        let persistence = persistence(for: mode)

        if content.isEmpty {
            guard allowRemoval else {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_empty_error"),
                    persistence: persistence
                )
            }
            if let error = await remove(for: updated, mode: mode, sourceManager: sourceManager) {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(
                        format: String(localized: "tag_editor_lyrics_write_failed"),
                        error
                    ),
                    persistence: persistence
                )
            }
            await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id)
            updated.lyricsFileName = nil
            updated.lyricsText = nil
        } else {
            let validation = LyricsContentParser.validateEditableText(content)
            guard validation.isValid else {
                let errorMessage: String
                if validation.lines.isEmpty {
                    errorMessage = String(localized: "tag_editor_lyrics_invalid_error")
                } else {
                    let lineNumbers = validation.issues
                        .map(\.lineNumber)
                        .reduce(into: [Int]()) { result, lineNumber in
                            if result.last != lineNumber { result.append(lineNumber) }
                        }
                        .map(String.init)
                        .joined(separator: ", ")
                    errorMessage = String(
                        format: String(localized: "tag_editor_lyrics_invalid_lines_format"),
                        lineNumbers
                    )
                }
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: errorMessage,
                    persistence: persistence
                )
            }
            if let error = await write(
                validation.lines,
                content: persistenceContent(
                    validation.normalizedContent,
                    lines: validation.lines,
                    mode: mode
                ),
                for: updated,
                mode: mode,
                sourceManager: sourceManager
            ) {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(
                        format: String(localized: "tag_editor_lyrics_write_failed"),
                        error
                    ),
                    persistence: persistence
                )
            }
            _ = await MetadataAssetStore.shared.cacheLyrics(
                validation.lines,
                forSongID: song.id,
                force: true
            )
            // LRC mirrors may intentionally yield to the richer local cache,
            // but an existing TTML document is itself word-level and must stay
            // addressable for later edits, deletion, and stale-cache refresh.
            updated.lyricsFileName = retainedTTMLReference(for: song, mode: mode)
                ?? MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
            updated.lyricsText = validation.lines.map(\.text).joined(separator: "\n")
        }

        library.replaceSong(updated)
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: updated.id)
        return SaveOutcome(
            updatedSong: updated,
            errorMessage: nil,
            persistence: persistence
        )
    }

    // MARK: - 写 / 删

    /// 返回 nil 表示成功，否则是给用户看的错误原因。
    private static func write(
        _ lines: [LyricLine],
        content: String,
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return String(localized: "tag_editor_lyrics_writeback_checking")
        case .unavailable(let reason):
            return reason
        case .sidecar:
            do {
                let result = try await MusicScraperService.writeSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sourceManager,
                    for: song,
                    coverData: nil,
                    lyricsLines: lines,
                    lyricsContent: content
                )
                guard result.lyricsWritten else {
                    return result.errors.joined(separator: "\n")
                }
                // 写完读回来比一次 —— 网盘/NAS 偶尔会吞掉写入还返回成功。
                guard await verifySidecarWrite(
                    content: content,
                    song: song,
                    sourceManager: sourceManager
                ) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        case .mediaServer:
            let result = await sourceManager.writeScrapedMetadataToMediaServer(
                original: song,
                updated: song,
                coverData: nil,
                lyricsLines: lines,
                lyricsContent: content
            )
            guard result.lyricsWritten else {
                return (result.errors + result.unsupported).joined(separator: "\n")
            }
            guard await verifyMediaServerWrite(
                expectedLines: lines,
                song: song,
                sourceManager: sourceManager
            ) else {
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
            return nil
        }
    }

    private static func remove(
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return String(localized: "tag_editor_lyrics_writeback_checking")
        case .unavailable(let reason):
            return reason
        case .sidecar:
            do {
                let result = try await MusicScraperService.removeLyricsSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sourceManager,
                    for: song
                )
                guard result.lyricsRemoved else {
                    return result.errors.joined(separator: "\n")
                }
                guard await verifySidecarRemoval(song: song, sourceManager: sourceManager) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        case .mediaServer:
            let result = await sourceManager.removeLyricsFromMediaServer(for: song)
            guard result.lyricsRemoved else {
                return (result.errors + result.unsupported).joined(separator: "\n")
            }
            guard await verifyMediaServerRemoval(song: song, sourceManager: sourceManager) else {
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
            return nil
        }
    }

    // MARK: - 回读校验

    private static func verifySidecarWrite(
        content: String,
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let readback = await LyricsLoader.loadSourceText(
            for: song,
            sourceManager: sourceManager
        ) else { return false }
        return normalized(readback) == normalized(content)
    }

    private static func verifyMediaServerWrite(
        expectedLines: [LyricLine],
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let connector = try? await sourceManager.connectorForSong(song),
              let server = connector as? any ServerLyricsConnector,
              let readback = await server.fetchServerLyrics(for: song.filePath) else {
            return false
        }
        return LyricsContentParser.areSemanticallyEquivalent(
            expectedLines,
            LyricsContentParser.parseText(readback)
        )
    }

    private static func verifySidecarRemoval(
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let preflight = try? await MusicScraperService.preflightLyricsWriteWithTimeout(
            seconds: 10,
            sourceManager: sourceManager,
            for: song
        ) else { return false }
        return !preflight.replacesExistingFile
    }

    private static func verifyMediaServerRemoval(
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let connector = try? await sourceManager.connectorForSong(song),
              let server = connector as? any ServerLyricsConnector else {
            return false
        }
        return await server.fetchServerLyrics(for: song.filePath) == nil
    }

    // MARK: - 工具

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func persistenceContent(
        _ editableContent: String,
        lines: [LyricLine],
        mode: Mode
    ) -> String {
        guard case .sidecar(let fileName, _) = mode,
              (fileName as NSString).pathExtension.caseInsensitiveCompare("ttml") == .orderedSame else {
            return editableContent
        }
        return LyricsContentParser.serializeTTML(lines)
    }

    private static func retainedTTMLReference(for song: Song, mode: Mode) -> String? {
        guard case .sidecar(let fileName, _) = mode,
              (fileName as NSString).pathExtension.caseInsensitiveCompare("ttml") == .orderedSame,
              let reference = song.lyricsFileName,
              (reference as NSString).pathExtension.caseInsensitiveCompare("ttml") == .orderedSame else {
            return nil
        }
        return reference
    }

    private static func persistence(for mode: Mode) -> SaveOutcome.Persistence {
        switch mode {
        case .sidecar:
            return .sidecar
        case .mediaServer:
            return .mediaServer
        case .checking, .localOnly, .unavailable:
            return .localOnly
        }
    }
}
