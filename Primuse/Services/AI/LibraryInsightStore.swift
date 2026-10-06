import Foundation
import Observation
import PrimuseKit

/// AI 这次给的内容,以及用的服务和语言;编辑页保存时据此判断内容是不是 AI 原样给的。
typealias LibraryInsightDraft = (answer: LibraryInsightAIExchange.Answer, providerName: String, languageCode: String)

/// 专辑与艺人简介的读写入口,以及 AI 正在填写、最近一次失败这些界面状态。
/// 简介本身存在曲库快照里(`MusicLibrary.saveLibraryInsightRecord`),随曲库同步到别的设备。
@MainActor
@Observable
final class LibraryInsightStore {
    static let shared = LibraryInsightStore()

    private(set) var generatingIDs: Set<String> = []
    private(set) var failures: [String: AILibraryContentFailure] = [:]
    private(set) var retryDates: [String: Date] = [:]
    /// 最近一次写回音乐源的结果(写进了哪些、哪些没写成),只给界面看。
    private(set) var writebackNotes: [String: String] = [:]

    init() {
        // 上一版只在本机 Caches 里缓存过一份,现在改存曲库,旧文件清掉。
        let legacy = FileManager.default
            .primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("library-insights.json")
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// AI 用界面语言写。
    static var languageCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    func recordID(for subject: LibraryInsightSubject) -> String {
        subject.recordID(unknownArtistName: String(localized: "unknown_artist"))
    }

    func record(for subject: LibraryInsightSubject, in library: MusicLibrary) -> LibraryInsightRecord? {
        library.libraryInsightRecord(id: recordID(for: subject))
    }

    func isGenerating(_ subject: LibraryInsightSubject) -> Bool {
        generatingIDs.contains(recordID(for: subject))
    }

    func failure(for subject: LibraryInsightSubject) -> AILibraryContentFailure? {
        failures[recordID(for: subject)]
    }

    func retryDate(for subject: LibraryInsightSubject) -> Date? {
        guard let date = retryDates[recordID(for: subject)], date > Date() else { return nil }
        return date
    }

    func writebackNote(for subject: LibraryInsightSubject) -> String? {
        writebackNotes[recordID(for: subject)]
    }

    func setWritebackNote(written: [String], failed: [String], for subject: LibraryInsightSubject) {
        let separator = String(localized: "library_insight_list_separator")
        var parts: [String] = []
        if !written.isEmpty {
            parts.append(String(
                format: String(localized: "library_insight_writeback_written_format"),
                written.joined(separator: separator)
            ))
        }
        if !failed.isEmpty {
            parts.append(String(
                format: String(localized: "library_insight_writeback_failed_format"),
                failed.joined(separator: separator)
            ))
        }
        writebackNotes[recordID(for: subject)] = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 批量补简介开问前占上「正在生成」:详情页照样转圈,卡片上也不会对同一个再发一次。
    /// 已经有人在问就返回 false。
    func beginBatchGeneration(_ subject: LibraryInsightSubject) -> Bool {
        let id = recordID(for: subject)
        guard generatingIDs.insert(id).inserted else { return false }
        failures[id] = nil
        retryDates[id] = nil
        return true
    }

    func endBatchGeneration(_ subject: LibraryInsightSubject) {
        generatingIDs.remove(recordID(for: subject))
    }

    func clearFailure(for subject: LibraryInsightSubject) {
        let id = recordID(for: subject)
        failures[id] = nil
        retryDates[id] = nil
    }

    /// 让 AI 写一份并直接存下(卡片上的「生成简介」「重新生成」)。用户改过的内容会被换掉,
    /// 由调用方先确认。
    func generate(
        _ subject: LibraryInsightSubject,
        library: MusicLibrary,
        intelligence: MusicIntelligenceService
    ) async {
        let id = recordID(for: subject)
        guard let draft = await aiDraft(for: subject, intelligence: intelligence) else { return }
        plog("✨ Library insight kind=\(subject.kind.rawValue) known=\(draft.answer.known) tags=\(draft.answer.tags.count)"
             + " provider=\(draft.providerName) tracks=\(subject.tracks.count) albums=\(subject.albums.count)")
        library.saveLibraryInsightRecord(LibraryInsightEditing.recordAfterAIFill(
            draft.answer,
            subject: subject,
            id: id,
            providerName: draft.providerName,
            languageCode: draft.languageCode,
            previous: library.storedLibraryInsightRecord(id: id),
            now: Date()
        ))
    }

    /// 只问 AI 不保存(编辑页的「用 AI 填写」)。失败时记下原因并返回 nil;
    /// 同一张专辑/同一位艺人已经在问就不再重复发。
    func aiDraft(
        for subject: LibraryInsightSubject,
        intelligence: MusicIntelligenceService
    ) async -> LibraryInsightDraft? {
        let id = recordID(for: subject)
        guard !generatingIDs.contains(id) else { return nil }
        let languageCode = Self.languageCode
        guard let request = LibraryInsightAIExchange.request(for: subject, languageCode: languageCode) else {
            failures[id] = .noTasteProfile
            return nil
        }
        generatingIDs.insert(id)
        failures[id] = nil
        retryDates[id] = nil
        defer { generatingIDs.remove(id) }
        switch await intelligence.libraryInsight(request) {
        case .success(let answer, let providerName):
            return (answer, providerName, languageCode)
        case .failed(let failure, let retryAt):
            failures[id] = failure
            retryDates[id] = retryAt
            return nil
        }
    }

    /// 编辑页保存。两项都清空就删除;和这次 AI 草稿一字不差时仍记作 AI 写的。
    func saveEdit(
        _ subject: LibraryInsightSubject,
        summary: String,
        tags: [String],
        aiDraft: LibraryInsightDraft?,
        library: MusicLibrary
    ) {
        let id = recordID(for: subject)
        guard let record = LibraryInsightEditing.recordAfterUserEdit(
            summary: summary,
            tags: tags,
            subject: subject,
            id: id,
            previous: library.storedLibraryInsightRecord(id: id),
            aiDraft: aiDraft,
            now: Date()
        ) else { return }
        library.saveLibraryInsightRecord(record)
        failures[id] = nil
    }

    func remove(_ subject: LibraryInsightSubject, library: MusicLibrary) {
        guard let record = record(for: subject, in: library) else { return }
        library.saveLibraryInsightRecord(LibraryInsightEditing.tombstone(of: record, now: Date()))
        failures[recordID(for: subject)] = nil
    }

    /// 「未知专辑」「未知艺术家」这类占位名字没什么可介绍的。
    nonisolated static func isIntroducible(_ subject: LibraryInsightSubject) -> Bool {
        let unknownArtist = String(localized: "unknown_artist")
        func isPlaceholder(_ name: String) -> Bool {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == unknownArtist || TagCleanupPolicy.isPlaceholder(trimmed)
        }
        switch subject.kind {
        case .album: return !isPlaceholder(subject.albumTitle)
        case .artist: return !isPlaceholder(subject.artistName)
        }
    }

    /// 卡片底部的出处:自己写/改过的标「已编辑」,AI 原样给的标服务名和「可能有误」。
    nonisolated static func footer(for record: LibraryInsightRecord) -> String {
        if !record.isUserEdited, let source = record.importedFrom {
            return String(format: String(localized: "library_insight_footer_imported_format"), source)
        }
        guard !record.isUserEdited, let provider = record.aiProviderName else {
            return String(localized: "library_insight_footer_edited")
        }
        return String(format: String(localized: "library_insight_footer_format"), provider)
    }

    nonisolated static func message(for failure: AILibraryContentFailure) -> String {
        switch failure {
        case .notConfigured:
            return String(localized: "library_insight_not_configured")
        case .needsConsent:
            return String(localized: "library_insight_needs_consent")
        case .builtInNotOffered:
            return String(localized: "library_insight_builtin_not_offered")
        case .noTasteProfile:
            return String(localized: "ai_song_discovery_failed_generic")
        case .failed(let reason):
            switch reason {
            case .busy: return String(localized: "ai_song_discovery_failed_busy")
            case .minuteLimit: return String(localized: "ai_song_discovery_failed_minute_limit")
            case .dailyLimit: return String(localized: "library_insight_failed_daily_limit")
            case .monthlyLimit: return String(localized: "library_insight_failed_monthly_limit")
            case .regionRestricted: return String(localized: "ai_song_discovery_failed_region")
            case .network: return String(localized: "ai_song_discovery_failed_network")
            case .empty, .unavailable, .deviceRegistration, .authentication, .upstream:
                return String(localized: "ai_song_discovery_failed_generic")
            }
        }
    }
}
