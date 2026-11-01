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
    struct SavedInput: Codable {
        var fingerprint: String
        var previousRevision: String?
    }

    struct SavedJob: Codable, Identifiable {
        enum Status: String, Codable { case running, paused, waitingForQuota, failed, ready }
        var id: String
        var songIDs: [String]
        var sourceIDs: [String]
        var title: String
        var namespace: String
        var language: String
        var limits: SpokenChapterGeneration.Limits
        var inputs: [String: SavedInput] = [:]
        var results: [String: SpokenChapterRecord] = [:]
        var completedRequests = 0
        var progress: Double = 0
        var status: Status = .paused
        var retryAt: Date?
        var updatedAt = Date()
    }

    private struct Archive: Codable {
        var version = 1
        var jobs: [SavedJob]
    }

    private struct Identity: Encodable {
        var songIDs: [String]
        var sourceIDs: [String]
        var namespace: String
        var language: String
        var limits: SpokenChapterGeneration.Limits
    }

    enum CheckpointFailure: Error { case storage, settingsChanged, missingSongs }

    private(set) var isRunning = false
    private(set) var isApplying = false
    private(set) var currentTitle = ""
    private(set) var completedItems = 0
    private(set) var totalItems = 0
    private(set) var progress: Double = 0
    private(set) var failure: String?
    private(set) var retryAt: Date?
    private(set) var previews: [Preview] = []
    private(set) var savedJobs: [SavedJob] = []
    private(set) var activeJobID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var memoryAnswers: [String: SpokenChapterGeneration.Answer] = [:]
    @ObservationIgnored private var legacyAnswers: [String: SpokenChapterGeneration.Answer] = [:]
    @ObservationIgnored private var transcriptLoader: (@MainActor (Song) async -> [LyricLine])?
    @ObservationIgnored private let checkpointURL: URL?
    @ObservationIgnored private var storageLoadFailed = false

    private var chunksURL: URL? { checkpointURL?.deletingPathExtension().appendingPathExtension("chunks") }
    private var legacyURL: URL? { checkpointURL?.appendingPathExtension("legacy") }

    init(checkpointURL: URL? = nil, usesDefaultStorage: Bool = true) {
        if usesDefaultStorage {
            #if os(tvOS)
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            #else
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            #endif
            self.checkpointURL = base.appendingPathComponent("Primuse/chapter-generation-resume.json")
        } else { self.checkpointURL = checkpointURL }
        do {
            if let url = self.checkpointURL, FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                if let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 {
                    guard Set(archive.jobs.map(\.id)).count == archive.jobs.count,
                          archive.jobs.allSatisfy({ job in
                              job.id.count == 64 && job.id.allSatisfy { "0123456789abcdef".contains($0) }
                                  && !job.songIDs.isEmpty && job.songIDs.count == job.sourceIDs.count
                          }) else { throw CheckpointFailure.storage }
                    savedJobs = archive.jobs.map { job in
                        var job = job
                        if job.status == .running { job.status = .paused }
                        return job
                    }
                } else {
                    legacyAnswers = try JSONDecoder().decode([String: SpokenChapterGeneration.Answer].self, from: data)
                }
            }
            if let url = legacyURL, FileManager.default.fileExists(atPath: url.path) {
                legacyAnswers.merge(try JSONDecoder().decode([String: SpokenChapterGeneration.Answer].self,
                    from: Data(contentsOf: url)), uniquingKeysWith: { current, _ in current })
            }
        } catch {
            storageLoadFailed = true
            failure = String(localized: "chapter_generation_save_failed")
        }
    }

    func jobs(for songID: String) -> [SavedJob] {
        savedJobs.filter { $0.songIDs.contains(songID) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func start(songs: [Song], library: MusicLibrary, intelligence: MusicIntelligenceService,
               loadTranscript: @escaping @MainActor (Song) async -> [LyricLine], resuming jobID: String? = nil) {
        let namespace = intelligence.spokenChapterCheckpointNamespace
        start(songs: songs, library: library, loadTranscript: loadTranscript,
              limits: intelligence.spokenChapterLimits, checkpointNamespace: namespace,
              resuming: jobID, request: {
                  guard intelligence.spokenChapterCheckpointNamespace == namespace else { throw CheckpointFailure.settingsChanged }
                  return try await intelligence.spokenChapters($0)
              })
    }

    func start(songs: [Song], library: MusicLibrary,
               loadTranscript: @escaping @MainActor (Song) async -> [LyricLine],
               limits: SpokenChapterGeneration.Limits = .standard,
               checkpointNamespace: String = "default", resuming requestedID: String? = nil,
               request: @escaping @MainActor (SpokenChapterGeneration.Request) async throws -> SpokenChapterGeneration.Answer) {
        guard !isRunning, !isApplying, !songs.isEmpty else { return }
        guard !storageLoadFailed else { failure = String(localized: "chapter_generation_save_failed"); return }
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let id: String
        do {
            id = try Self.fingerprint(Identity(songIDs: songs.map(\.id), sourceIDs: songs.map(\.sourceID),
                namespace: checkpointNamespace, language: language, limits: limits))
            if let requestedID {
                guard requestedID == id else { throw CheckpointFailure.settingsChanged }
                guard savedJobs.contains(where: { $0.id == requestedID }) else { throw CheckpointFailure.missingSongs }
            }
            var job = savedJobs.first { $0.id == id } ?? SavedJob(id: id, songIDs: songs.map(\.id),
                sourceIDs: songs.map(\.sourceID), title: songs[0].title, namespace: checkpointNamespace,
                language: language, limits: limits)
            job.status = .running; job.retryAt = nil
            try store(job)
        } catch {
            failure = Self.checkpointMessage(error)
            return
        }
        activeJobID = id
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
                    let transcript = await loadTranscript(song)
                    try Task.checkCancellation()
                    let lines = try SpokenChapterGeneration.lines(from: transcript, duration: song.duration)
                    let fingerprint = try Self.fingerprint(lines)
                    var job = try self.job(id)
                    let input: SavedInput
                    if let saved = job.inputs[song.id] {
                        guard saved.fingerprint == fingerprint else { throw SpokenChapterGeneration.Failure.changedDuringGeneration }
                        input = saved
                    } else {
                        input = SavedInput(fingerprint: fingerprint, previousRevision: library.generatedChapterRecord(id: song.id)?.revision)
                        job.inputs[song.id] = input
                        try self.store(job)
                    }
                    let record: SpokenChapterRecord
                    if let saved = job.results[song.id] {
                        record = saved
                    } else {
                        let chapters = try await SpokenChapterGeneration.generate(
                            title: song.title, language: language, lines: lines, limits: limits,
                            ask: { [self] request in try await self.ask(request, jobID: id, provider: requestProvider) },
                            progress: { [self] done, total in
                                await self.setProgress(Double(done) / Double(max(1, total)))
                            }
                        )
                        record = SpokenChapterRecord(id: song.id, chapters: chapters,
                            transcriptFingerprint: fingerprint, providerName: "AI")
                        job = try self.job(id)
                        job.results[song.id] = record
                        try self.store(job)
                    }
                    try Task.checkCancellation()
                    self.previews.append(Preview(song: song, record: record, previousRevision: input.previousRevision))
                    self.completedItems += 1; self.progress = 0
                }
                try self.finish(id, status: .ready)
            } catch is CancellationError {
                self.finishSafely(id, status: .paused)
            } catch let error as SpokenChapterServiceFailure {
                self.failure = Self.message(error.failure); self.retryAt = error.retryAt
                let quota = error.failure == .failed(.dailyLimit) || error.failure == .failed(.monthlyLimit)
                self.finishSafely(id, status: quota ? .waitingForQuota : .failed, retryAt: error.retryAt)
            } catch let error as SpokenChapterGeneration.Failure {
                self.failure = Self.message(error)
                self.finishSafely(id, status: .failed)
            } catch {
                self.failure = Self.checkpointMessage(error)
                self.finishSafely(id, status: .failed)
            }
        }
    }

    private func setProgress(_ value: Double) { progress = value }

    private func job(_ id: String) throws -> SavedJob {
        guard let job = savedJobs.first(where: { $0.id == id }) else { throw CheckpointFailure.storage }
        return job
    }

    private func store(_ job: SavedJob) throws {
        var job = job; job.updatedAt = Date()
        var updated = savedJobs.filter { $0.id != job.id }; updated.append(job)
        try persist(updated)
        savedJobs = updated
    }

    private func persist(_ jobs: [SavedJob]) throws {
        guard let checkpointURL else { return }
        do {
            try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !legacyAnswers.isEmpty, let legacyURL {
                try JSONEncoder().encode(legacyAnswers).write(to: legacyURL, options: .atomic)
            }
            try JSONEncoder().encode(Archive(jobs: jobs)).write(to: checkpointURL, options: .atomic)
        } catch { throw CheckpointFailure.storage }
    }

    private func finish(_ id: String, status: SavedJob.Status, retryAt: Date? = nil) throws {
        var job = try job(id)
        job.status = status; job.retryAt = retryAt
        job.progress = status == .ready ? 1 : (Double(completedItems) + progress) / Double(max(1, totalItems))
        try store(job)
    }

    private func finishSafely(_ id: String, status: SavedJob.Status, retryAt: Date? = nil) {
        do { try finish(id, status: status, retryAt: retryAt) }
        catch { failure = String(localized: "chapter_generation_save_failed") }
    }

    private func ask(_ request: SpokenChapterGeneration.Request, jobID: String,
                     provider: @MainActor (SpokenChapterGeneration.Request) async throws -> SpokenChapterGeneration.Answer) async throws -> SpokenChapterGeneration.Answer {
        try Task.checkCancellation()
        let key = try Self.fingerprint(request)
        let memoryKey = jobID + ":" + key
        let legacyKey = "v2:" + (try job(jobID).namespace) + ":" + key
        let url = chunksURL?.appendingPathComponent(jobID).appendingPathComponent(key + ".json")
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let answer: SpokenChapterGeneration.Answer
            do { answer = try JSONDecoder().decode(SpokenChapterGeneration.Answer.self, from: Data(contentsOf: url)) }
            catch { throw CheckpointFailure.storage }
            let validated = try SpokenChapterGeneration.validate(answer, for: request)
            try consumeLegacyAnswer(legacyKey)
            return validated
        }
        if let answer = memoryAnswers[memoryKey] { return try SpokenChapterGeneration.validate(answer, for: request) }
        let answer: SpokenChapterGeneration.Answer
        if let legacy = legacyAnswers[legacyKey] { answer = try SpokenChapterGeneration.validate(legacy, for: request) }
        else { answer = try SpokenChapterGeneration.validate(try await provider(request), for: request) }
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(answer).write(to: url, options: .atomic)
            } catch { throw CheckpointFailure.storage }
        } else { memoryAnswers[memoryKey] = answer }
        try consumeLegacyAnswer(legacyKey)
        var job = try job(jobID)
        job.completedRequests += 1
        job.progress = (Double(completedItems) + progress) / Double(max(1, totalItems))
        try store(job)
        // Save a completed response even when Pause arrived while that response was in flight.
        try Task.checkCancellation()
        return answer
    }

    private func consumeLegacyAnswer(_ key: String) throws {
        guard legacyAnswers[key] != nil else { return }
        var remaining = legacyAnswers; remaining.removeValue(forKey: key)
        if let legacyURL {
            do { try JSONEncoder().encode(remaining).write(to: legacyURL, options: .atomic) }
            catch { throw CheckpointFailure.storage }
        }
        legacyAnswers = remaining
    }

    func cancel() { task?.cancel() }
    func waitForCompletion() async { await task?.value }

    func discard(_ id: String) throws {
        guard !isRunning, !isApplying, savedJobs.contains(where: { $0.id == id }) else { return }
        let remaining = savedJobs.filter { $0.id != id }
        try persist(remaining)
        savedJobs = remaining
        if let directory = chunksURL?.appendingPathComponent(id) { try? FileManager.default.removeItem(at: directory) }
        memoryAnswers = memoryAnswers.filter { !$0.key.hasPrefix(id + ":") }
        if activeJobID == id { activeJobID = nil; previews = []; failure = nil; retryAt = nil }
        if remaining.isEmpty, legacyAnswers.isEmpty, let checkpointURL { try? FileManager.default.removeItem(at: checkpointURL) }
    }

    private func savePreview(_ item: Preview) {
        guard let activeJobID else { return }
        do {
            var job = try job(activeJobID); job.results[item.id] = item.record
            try store(job)
        } catch { failure = String(localized: "chapter_generation_save_failed") }
    }

    func rename(songID: String, index: Int, title: String) {
        guard let item = previews.firstIndex(where: { $0.id == songID }),
              previews[item].record.chapters.indices.contains(index) else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        previews[item].record.chapters[index].title = String(value.prefix(100))
        savePreview(previews[item])
    }

    func remove(songID: String, index: Int) {
        guard let item = previews.firstIndex(where: { $0.id == songID }),
              previews[item].record.chapters.indices.contains(index), previews[item].record.chapters.count > 1 else { return }
        previews[item].record.chapters.remove(at: index)
        savePreview(previews[item])
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
        guard case .success = await library.persistNowAndWait() else { throw CheckpointFailure.storage }
        isApplying = false
        if let activeJobID { try discard(activeJobID) }
        previews = []
    }

    private static func checkpointMessage(_ error: Error) -> String {
        switch error {
        case CheckpointFailure.storage: String(localized: "chapter_generation_save_failed")
        case CheckpointFailure.settingsChanged: String(localized: "chapter_generation_settings_changed")
        case CheckpointFailure.missingSongs: String(localized: "chapter_generation_missing_items")
        default: String(localized: "chapter_generation_failed")
        }
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
