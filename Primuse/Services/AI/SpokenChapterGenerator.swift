import CryptoKit
import Foundation
import Observation
import PrimuseKit

struct SpokenChapterServiceFailure: Error {
    let failure: AILibraryContentFailure
    let retryAt: Date?
}

@MainActor
@Observable
final class SpokenChapterGenerator {
    static let shared = SpokenChapterGenerator()
    struct Preview: Identifiable {
        var id: String { song.id }
        var song: Song
        var record: SpokenChapterRecord
        var previousRevision: String?
    }
    private(set) var isRunning = false
    private(set) var isApplying = false
    private(set) var currentTitle = ""
    private(set) var completedItems = 0
    private(set) var totalItems = 0
    private(set) var progress: Double = 0
    private(set) var failure: String?
    private(set) var retryAt: Date?
    private(set) var previews: [Preview] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var answers: [String: SpokenChapterGeneration.Answer] = [:]
    @ObservationIgnored private var transcriptLoader: (@MainActor (Song) async -> [LyricLine])?
    @ObservationIgnored private let checkpointURL: URL?

    init(checkpointURL: URL? = nil, usesDefaultStorage: Bool = true) {
        if usesDefaultStorage {
            #if os(tvOS)
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            #else
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            #endif
            self.checkpointURL = base.appendingPathComponent("Primuse/chapter-generation-resume.json")
        } else { self.checkpointURL = checkpointURL }
        if let url = self.checkpointURL, let data = try? Data(contentsOf: url), data.count <= 8 * 1_024 * 1_024,
           let saved = try? JSONDecoder().decode([String: SpokenChapterGeneration.Answer].self, from: data) {
            answers = saved
        }
    }

    func start(songs: [Song], library: MusicLibrary, intelligence: MusicIntelligenceService,
               loadTranscript: @escaping @MainActor (Song) async -> [LyricLine]) {
        start(songs: songs, library: library, loadTranscript: loadTranscript,
              request: { try await intelligence.spokenChapters($0) })
    }

    func start(songs: [Song], library: MusicLibrary,
               loadTranscript: @escaping @MainActor (Song) async -> [LyricLine],
               request: @escaping @MainActor (SpokenChapterGeneration.Request) async throws -> SpokenChapterGeneration.Answer) {
        guard !isRunning, !isApplying, !songs.isEmpty else { return }
        transcriptLoader = loadTranscript
        isRunning = true; failure = nil; retryAt = nil; previews = []; completedItems = 0
        totalItems = songs.count; progress = 0
        let requestProvider = request
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil }
            do {
                for song in songs {
                    try Task.checkCancellation()
                    self.currentTitle = song.title
                    let previousRevision = library.generatedChapterRecord(id: song.id)?.revision
                    let transcript = await loadTranscript(song)
                    try Task.checkCancellation()
                    let lines = try SpokenChapterGeneration.lines(from: transcript, duration: song.duration)
                    let fingerprint = try Self.fingerprint(lines)
                    let chapters = try await SpokenChapterGeneration.generate(
                        title: song.title, language: Bundle.main.preferredLocalizations.first ?? "en", lines: lines,
                        ask: { [self] request in try await self.ask(request, provider: requestProvider) },
                        progress: { [self] done, total in
                            await self.setProgress(Double(done) / Double(max(1, total)))
                        }
                    )
                    try Task.checkCancellation()
                    self.previews.append(Preview(
                        song: song,
                        record: SpokenChapterRecord(id: song.id, chapters: chapters,
                                                    transcriptFingerprint: fingerprint, providerName: "AI"),
                        previousRevision: previousRevision
                    ))
                    self.completedItems += 1
                    self.progress = 0
                }
            } catch is CancellationError {
                // Completed requests remain reusable; no chapter record has been replaced.
            } catch let error as SpokenChapterServiceFailure {
                self.failure = Self.message(error.failure)
                self.retryAt = error.retryAt
            } catch let error as SpokenChapterGeneration.Failure {
                self.failure = Self.message(error)
            } catch {
                self.failure = String(localized: "chapter_generation_failed")
            }
        }
    }

    private func setProgress(_ value: Double) { progress = value }

    private func ask(_ request: SpokenChapterGeneration.Request, provider: @MainActor (SpokenChapterGeneration.Request) async throws -> SpokenChapterGeneration.Answer) async throws -> SpokenChapterGeneration.Answer {
        try Task.checkCancellation()
        let key = "v1:" + (try Self.fingerprint(request))
        if let answer = answers[key] { return try SpokenChapterGeneration.validate(answer, for: request) }
        let answer = try SpokenChapterGeneration.validate(try await provider(request), for: request)
        try Task.checkCancellation()
        answers[key] = answer
        if answers.count > 1_000 { answers = [key: answer] }
        if let checkpointURL, let data = try? JSONEncoder().encode(answers) {
            try? FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: checkpointURL, options: .atomic)
        }
        return answer
    }

    func cancel() { task?.cancel() }

    func waitForCompletion() async { await task?.value }

    func rename(songID: String, index: Int, title: String) {
        guard let item = previews.firstIndex(where: { $0.id == songID }),
              previews[item].record.chapters.indices.contains(index) else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        previews[item].record.chapters[index].title = String(value.prefix(100))
    }

    func remove(songID: String, index: Int) {
        guard let item = previews.firstIndex(where: { $0.id == songID }),
              previews[item].record.chapters.indices.contains(index), previews[item].record.chapters.count > 1 else { return }
        previews[item].record.chapters.remove(at: index)
    }

    func apply(to library: MusicLibrary) async throws {
        guard !isRunning, !isApplying, completedItems == totalItems, !previews.isEmpty,
              let transcriptLoader else { return }
        isApplying = true
        defer { isApplying = false }
        for preview in previews {
            let transcript = await transcriptLoader(preview.song)
            try Task.checkCancellation()
            let lines = try SpokenChapterGeneration.lines(from: transcript, duration: preview.song.duration)
            guard try Self.fingerprint(lines) == preview.record.transcriptFingerprint else {
                throw SpokenChapterGeneration.Failure.changedDuringGeneration
            }
        }
        guard previews.allSatisfy({ library.generatedChapterRecord(id: $0.id)?.revision == $0.previousRevision }) else {
            throw SpokenChapterGeneration.Failure.changedDuringGeneration
        }
        for preview in previews {
            var record = preview.record
            record.updatedAt = Date(); record.revision = UUID().uuidString
            library.saveGeneratedChapterRecord(record)
        }
        previews = []
        answers = [:]
        if let checkpointURL { try? FileManager.default.removeItem(at: checkpointURL) }
    }

    static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func message(_ failure: AILibraryContentFailure) -> String {
        switch failure {
        case .notConfigured: String(localized: "library_insight_not_configured")
        case .needsConsent: String(localized: "ai_primuse_relay_consent_required")
        case .builtInNotOffered, .noTasteProfile: String(localized: "ai_song_discovery_failed_generic")
        case .failed(let reason):
            switch reason {
            case .dailyLimit: String(localized: "chapter_generation_daily_limit")
            case .monthlyLimit: String(localized: "chapter_generation_monthly_limit")
            case .busy: String(localized: "ai_song_discovery_failed_busy")
            case .minuteLimit: String(localized: "ai_song_discovery_failed_minute_limit")
            case .regionRestricted: String(localized: "ai_song_discovery_failed_region")
            case .network: String(localized: "ai_song_discovery_failed_network")
            case .empty, .unavailable, .deviceRegistration, .authentication, .upstream:
                String(localized: "chapter_generation_failed")
            }
        }
    }

    static func message(_ error: SpokenChapterGeneration.Failure) -> String {
        switch error {
        case .missingTimedTranscript, .invalidTranscript: String(localized: "chapter_generation_needs_timed_text")
        case .invalidResponse: String(localized: "chapter_generation_failed")
        case .changedDuringGeneration: String(localized: "chapter_generation_changed")
        }
    }
}
