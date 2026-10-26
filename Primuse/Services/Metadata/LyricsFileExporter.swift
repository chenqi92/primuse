import Foundation
import PrimuseKit

/// 把一首歌正在用的歌词、有声书或播客的文字稿写成文件(#362):LRC、SRT 或纯文本。
///
/// 读的是播放页显示的同一份(歌词缓存优先;听歌识词、生成文字稿的结果都存在这里),
/// 时间轴用原始的,不带文字稿的显示偏移。
enum LyricsFileExporter {
    enum Failure: LocalizedError {
        case noText
        /// 要带时间的格式,这份却一行时间都没有。
        case untimed

        var errorDescription: String? {
            switch self {
            case .noText: String(localized: "lyrics_export_error_empty")
            case .untimed: String(localized: "lyrics_export_error_untimed")
            }
        }
    }

    /// 菜单里各格式的叫法。
    static func title(for format: LyricsExportFormat) -> String {
        switch format {
        case .lrc: String(localized: "lyrics_export_format_lrc")
        case .srt: String(localized: "lyrics_export_format_srt")
        case .plainText: String(localized: "lyrics_export_format_text")
        }
    }

    /// 写出 `song` 的歌词或文字稿,返回临时目录里的文件。
    @MainActor
    static func export(
        song: Song,
        format: LyricsExportFormat,
        isTranscript: Bool,
        sourceManager: SourceManager
    ) async throws -> URL {
        let lines = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        try Task.checkCancellation()
        guard let text = LyricsExportPolicy.render(lines, as: format, readsAsProse: isTranscript) else {
            let formats = LyricsExportPolicy.formats(for: lines)
            throw formats.isEmpty ? Failure.noText : Failure.untimed
        }
        let fileName = LyricsExportPolicy.fileName(title: song.title, artist: song.artistName, format: format)
        return try await Task.detached(priority: .userInitiated) {
            try write(text, fileName: fileName)
        }.value
    }

    private static func write(_ text: String, fileName: String) throws -> URL {
        removeStaleExports()
        let directory = exportDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: destination, options: .atomic)
        plog("📝 Lyrics export: \(destination.pathExtension) \(text.count) chars")
        return destination
    }

    private static func exportDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Primuse-LyricsExport", isDirectory: true)
    }

    /// 上一次导出留下的文件。刚导出的可能还在分享面板里用着,留一小时。
    private static func removeStaleExports() {
        let directory = exportDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
