import Foundation
import PrimuseKit

/// 「重新读取服务器文字稿」(#461):有声内容的文字稿从音乐源服务器上重读一遍。
/// Audiobookshelf 先确认服务端登记着音频旁边的文字稿,没登记就请它扫描这一本;
/// 手上这份是用户自己编辑或导入的,先问过再换(`SpokenTranscriptPrecedencePolicy`);
/// 读不到、连不上都留着手上这份。
@MainActor
enum ServerTranscriptReload {
    enum Outcome: Equatable {
        case updated([LyricLine])
        case unchanged
        /// 手上这份是用户自己编辑或导入的:问过再换。
        case needsReplaceConfirmation
        /// 服务端没有登记这首的文字稿。
        case missing(ServerTranscriptRescan)
        /// 服务端登记着,却读不出能用的内容。
        case unreadable
        case failedPreservingCache
        case unsupported

        /// 读完告诉用户的话;要先确认的那一种没有。
        var message: String? {
            switch self {
            case .updated: String(localized: "transcript_server_reload_success")
            case .unchanged: String(localized: "transcript_server_reload_unchanged")
            case .needsReplaceConfirmation: nil
            case .missing(.rescanned): String(localized: "transcript_server_reload_missing_rescanned")
            case .missing(.notPermitted): String(localized: "transcript_server_reload_missing_not_permitted")
            case .missing(.failed): String(localized: "transcript_server_reload_missing_failed")
            case .missing(.singleFileItem): String(localized: "transcript_server_reload_missing_single_file")
            case .unreadable: String(localized: "transcript_server_reload_unreadable")
            case .failedPreservingCache: String(localized: "transcript_server_reload_failed_kept")
            case .unsupported: String(localized: "transcript_server_reload_unsupported")
            }
        }
    }

    static func run(
        for song: Song,
        sourceType: MusicSourceType?,
        sourceManager: SourceManager,
        cachedDocument: [LyricLine]?,
        replacingUserTranscript: Bool
    ) async -> Outcome {
        guard LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) else { return .unsupported }
        let connector: any MusicSourceConnector
        do {
            connector = try await sourceManager.auxiliaryConnector(for: song)
        } catch {
            return .failedPreservingCache
        }
        if let files = connector as? any ServerTranscriptFileConnector {
            switch await files.prepareServerTranscriptReload(for: song.filePath) {
            case .registered: break
            case .missing(let rescan): return .missing(rescan)
            case .unavailable: return .failedPreservingCache
            }
        }
        let current: [LyricLine]?
        if let cachedDocument {
            current = cachedDocument
        } else {
            current = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        }
        if !replacingUserTranscript,
           SpokenTranscriptPrecedencePolicy.explicitReloadNeedsConfirmation(current: current) {
            return .needsReplaceConfirmation
        }
        switch await LyricsLoader.refreshFromSource(
            for: song,
            sourceType: sourceType,
            sourceManager: sourceManager,
            cachedDocument: current,
            trigger: .explicit,
            replacingUserTranscript: replacingUserTranscript
        ) {
        case .updated(let lines): return .updated(lines)
        case .unchanged, .throttled: return .unchanged
        case .emptyPreservingCache: return .unreadable
        case .failedPreservingCache: return .failedPreservingCache
        case .unsupported: return .unsupported
        }
    }
}
