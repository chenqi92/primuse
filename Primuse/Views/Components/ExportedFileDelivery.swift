import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers

/// 导出好的一个文件。iPhone / iPad 弹分享面板(存到「文件」、隔空投送、别的 App),
/// Mac 弹存储面板。
struct ExportedFileItem: Identifiable {
    let url: URL
    var id: URL { url }
}

enum ExportedFileDelivery {
    #if os(macOS)
    /// 存到用户挑的位置,返回存下的地址;取消返回 nil。给了几种格式时面板里能选格式,
    /// 选中的格式由存下的扩展名带回来。
    @MainActor
    static func save(_ url: URL, contentTypes: [UTType]) throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = contentTypes
        panel.showsContentTypes = contentTypes.count > 1
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
    #endif
}

#if os(iOS)
extension View {
    /// 有导出好的文件时弹分享面板。
    func exportedFileShareSheet(_ file: Binding<ExportedFileItem?>) -> some View {
        sheet(item: file) { exported in
            ShareSheet(items: [exported.url])
                .presentationDetents([.medium, .large])
        }
    }
}
#endif

extension UTType {
    static let primuseExportLRC = UTType(filenameExtension: "lrc", conformingTo: .plainText) ?? .plainText
    static let primuseExportSubRip = UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
}

extension LyricsExportFormat {
    var contentType: UTType {
        switch self {
        case .lrc: .primuseExportLRC
        case .srt: .primuseExportSubRip
        case .plainText: .plainText
        }
    }
}

// MARK: - Lyrics and transcripts

/// 播放页「更多」里点了某种格式后要导出的那一份(#362)。
struct LyricsExportRequest: Identifiable {
    let id = UUID()
    let song: Song
    let format: LyricsExportFormat
    let isTranscript: Bool
}

/// 「导出歌词」「导出文字稿」子菜单:一种格式一项。
struct LyricsExportMenu: View {
    let formats: [LyricsExportFormat]
    let isTranscript: Bool
    let onExport: (LyricsExportFormat) -> Void

    var body: some View {
        Menu {
            ForEach(formats) { format in
                Button {
                    onExport(format)
                } label: {
                    Text(verbatim: LyricsFileExporter.title(for: format))
                }
            }
        } label: {
            Label(
                isTranscript
                    ? String(localized: "transcript_export_menu")
                    : String(localized: "lyrics_export_menu"),
                systemImage: "doc.text"
            )
        }
    }
}

/// 收到导出请求就写文件,写好交给用户(分享面板 / 存储面板);读不到字时说原因。
struct LyricsExportPresenter: ViewModifier {
    @Binding var request: LyricsExportRequest?
    @State private var exported: ExportedFileItem?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .task(id: request?.id) { await run() }
            .alert(
                String(localized: "songs_export_failed"),
                isPresented: Binding(
                    get: { failure != nil },
                    set: { if !$0 { failure = nil } }
                )
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
            #if os(iOS)
            .exportedFileShareSheet($exported)
            #endif
    }

    @MainActor
    private func run() async {
        guard let pending = request else { return }
        defer { if request?.id == pending.id { request = nil } }
        do {
            let url = try await LyricsFileExporter.export(
                song: pending.song,
                format: pending.format,
                isTranscript: pending.isTranscript,
                sourceManager: AppServices.shared.sourceManager
            )
            guard !Task.isCancelled else { return }
            #if os(macOS)
            _ = try ExportedFileDelivery.save(url, contentTypes: [pending.format.contentType])
            #else
            exported = ExportedFileItem(url: url)
            #endif
        } catch is CancellationError {
            return
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
