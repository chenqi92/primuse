import AVFoundation
import Foundation
import PrimuseKit

/// 给没有文稿的播客单集、有声书章节生成文稿(#314)。一次只做一个:取到音频,本机识别或分段交给
/// 云端识别,排成带时间的文稿写进歌词缓存;播放页、全屏文稿、锁屏和读到的文稿一样用它。
@MainActor
@Observable
final class SpokenTranscriptGenerator {
    static let shared = SpokenTranscriptGenerator()

    enum Phase: Equatable {
        /// 下载或取出这一集的音频;拿不到进度时为 nil。
        case fetchingAudio(Double?)
        /// 系统读不了原格式,先在本机转一份。
        case convertingAudio
        /// 下载这种语言的本机识别模型。
        case preparingModel
        /// 本机识别到了全长的几成。
        case transcribing(Double)
        /// 云端识别:第几段、一共几段(从 1 数)。
        case uploading(segment: Int, of: Int)
        case finishing
    }

    enum Failure: Error, Equatable {
        case audioUnavailable
        case unreadableAudio
        case onDeviceUnavailable
        case unsupportedLanguage
        case modelUnavailable
        case noSpeech
        case builtInUnavailable
        case builtInLimitReached
        case builtInMonthlyLimitReached
        case builtInNotInPlan
        case ownKeyUnavailable
        case failed
    }

    struct Job: Equatable {
        let song: Song
        let engine: SpokenTranscriptEngine
        let localeIdentifier: String?
        var phase: Phase
    }

    enum Outcome: Equatable {
        case finished(songID: String, lineCount: Int)
        case failed(songID: String, Failure)
    }

    /// 生成过的文稿记一笔:用的哪种识别、什么语言、什么时候,菜单据此写「重新生成」。
    struct Record: Codable, Equatable {
        var engine: SpokenTranscriptEngine
        var localeIdentifier: String?
        var generatedAt: Date
    }

    private(set) var activeJob: Job?
    private(set) var lastOutcome: Outcome? {
        didSet { lastOutcomeAt = lastOutcome == nil ? nil : Date() }
    }
    /// 上一次结果出来的时刻。播放页里的结果提示看它,几秒后自己收起。
    private(set) var lastOutcomeAt: Date?
    private(set) var records: [String: Record]

    @ObservationIgnored private var task: Task<Void, Never>?
    /// 云端识别做完的段,失败后重试从没做的那段接着来。只留最近一次的。
    @ObservationIgnored private var partial: (key: String, results: [Int: AIAudioTranscriptionResult])?
    @ObservationIgnored private let defaults: UserDefaults

    private static let recordsKey = "primuse.transcriptGeneration.records.v1"
    private static let uploadConsentKey = "primuse.transcriptGeneration.uploadConsent"
    private static let recordLimit = 1_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recordsKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    /// 上传音频去识别(内置智能、自己的密钥)之前用户点过头没有。
    var hasAudioUploadConsent: Bool {
        get { defaults.bool(forKey: Self.uploadConsentKey) }
        set { defaults.set(newValue, forKey: Self.uploadConsentKey) }
    }

    func isRunning(for songID: String) -> Bool { activeJob?.song.id == songID }

    /// 这首能生成文稿:播客单集或有声内容,不是电台、不是 CUE 分轨、不是 Apple Music。
    static func canGenerate(for song: Song) -> Bool {
        guard song.sourceID != AppleMusicLibraryIdentity.sourceID, song.cueSheetPath == nil else { return false }
        return PodcastPlaybackSong.isEpisode(song) || SpokenWordStore.shared.isSpokenWord(song)
    }

    /// 本机识别的语言候选:节目写的语言、标题里的文字、设备的首选语言。
    static func languageCandidates(for song: Song) -> [String] {
        let declared = PodcastPlaybackSong.isEpisode(song)
            ? PodcastStore.shared.episode(id: song.id)?.show.language
            : nil
        return SpokenTranscriptLanguagePolicy.candidates(
            declaredLanguage: declared,
            title: [song.title, song.albumTitle ?? ""].joined(separator: " "),
            preferredLanguages: Locale.preferredLanguages
        )
    }

    func start(song: Song, engine: SpokenTranscriptEngine, localeIdentifier: String?) {
        guard activeJob == nil else { return }
        lastOutcome = nil
        activeJob = Job(song: song, engine: engine, localeIdentifier: localeIdentifier, phase: .fetchingAudio(nil))
        task = Task { [weak self] in
            await self?.run(song: song, engine: engine, localeIdentifier: localeIdentifier)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func clearOutcome() {
        lastOutcome = nil
    }

    // MARK: - Pipeline

    private func run(song: Song, engine: SpokenTranscriptEngine, localeIdentifier: String?) async {
        var cleanups: [() -> Void] = []
        defer {
            for cleanup in cleanups.reversed() { cleanup() }
            activeJob = nil
            task = nil
        }
        do {
            let fetched = try await fetchAudio(for: song)
            cleanups.append(fetched.cleanup)
            try Task.checkCancellation()
            let readable = try await readableAudio(at: fetched.url, expectedDuration: song.duration)
            if let temporary = readable.temporaryURL {
                cleanups.append { try? FileManager.default.removeItem(at: temporary) }
            }
            try Task.checkCancellation()

            let result: AIAudioTranscriptionResult
            switch engine {
            case .onDevice:
                result = try await transcribeOnDevice(url: readable.url, localeIdentifier: localeIdentifier)
            case .builtIn, .ownKey:
                result = try await transcribeInSegments(
                    song: song,
                    engine: engine,
                    url: readable.url,
                    duration: readable.duration
                )
            }
            try Task.checkCancellation()
            setPhase(.finishing)
            let lines = SpokenTranscriptLayout.lines(from: result)
            guard !lines.isEmpty else { throw Failure.noSpeech }
            _ = await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: song.id, force: true)
            remember(Record(engine: engine, localeIdentifier: localeIdentifier, generatedAt: Date()), for: song.id)
            partial = nil
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
            lastOutcome = .finished(songID: song.id, lineCount: lines.count)
            plog("[transcript] generated \(lines.count) lines for '\(song.title)' via \(engine.rawValue)")
        } catch is CancellationError {
            plog("[transcript] cancelled for '\(song.title)'")
        } catch let failure as Failure {
            plog("[transcript] failed for '\(song.title)': \(failure)")
            lastOutcome = .failed(songID: song.id, failure)
        } catch {
            if Task.isCancelled { return }
            plog("[transcript] failed for '\(song.title)': \(error)")
            lastOutcome = .failed(songID: song.id, .failed)
        }
    }

    private func setPhase(_ phase: Phase) {
        guard activeJob != nil, activeJob?.phase != phase else { return }
        activeJob?.phase = phase
    }

    private func remember(_ record: Record, for songID: String) {
        records[songID] = record
        if records.count > Self.recordLimit {
            let overflow = records.sorted { $0.value.generatedAt < $1.value.generatedAt }
                .prefix(records.count - Self.recordLimit)
            for (stale, _) in overflow { records[stale] = nil }
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    // MARK: Audio

    private struct FetchedAudio {
        var url: URL
        var cleanup: () -> Void
    }

    /// 播客单集:已经下载的直接用;没下载的借单集下载先下到本机,用完删掉。
    /// 曲库里的有声书:和听歌识词一样经音乐源取一份完整文件。
    private func fetchAudio(for song: Song) async throws -> FetchedAudio {
        setPhase(.fetchingAudio(nil))
        if PodcastPlaybackSong.isEpisode(song) {
            return try await fetchPodcastEpisode(song)
        }
        let sourceManager = AppServices.shared.sourceManager
        let resolved: URL
        do {
            resolved = try await sourceManager.resolveFullDownloadSourceURL(for: song)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.audioUnavailable
        }
        if resolved.isFileURL {
            guard FileManager.default.isReadableFile(atPath: resolved.path) else { throw Failure.audioUnavailable }
            return FetchedAudio(url: resolved, cleanup: {})
        }
        let downloaded = try await Self.download(resolved, fallbackExtension: song.fileFormat.rawValue.lowercased())
        return FetchedAudio(url: downloaded, cleanup: { try? FileManager.default.removeItem(at: downloaded) })
    }

    private func fetchPodcastEpisode(_ song: Song) async throws -> FetchedAudio {
        let downloads = PodcastDownloadStore.shared
        if let local = downloads.localURL(for: song.id) {
            return FetchedAudio(url: local, cleanup: {})
        }
        guard let episode = PodcastStore.shared.episode(id: song.id)?.episode else {
            throw Failure.audioUnavailable
        }
        let startedHere = downloads.states[song.id] == nil
        downloads.download(episode)
        // 为生成文字稿才下的,用完删掉;这时正在听这一集就留着,省得再下。
        let removeIfStartedHere: () -> Void = {
            guard startedHere else { return }
            Task { @MainActor in
                guard AppServices.shared.playerService.currentSong?.id != song.id else { return }
                PodcastDownloadStore.shared.delete(song.id)
            }
        }
        do {
            while true {
                try Task.checkCancellation()
                if let local = downloads.localURL(for: song.id) {
                    return FetchedAudio(url: local, cleanup: removeIfStartedHere)
                }
                switch downloads.states[song.id] {
                case .downloading(let fraction):
                    setPhase(.fetchingAudio(fraction))
                case .queued:
                    setPhase(.fetchingAudio(nil))
                case .failed:
                    throw Failure.audioUnavailable
                case nil:
                    // 下载被别处取消了。
                    throw Failure.audioUnavailable
                }
                try await Task.sleep(for: .milliseconds(400))
            }
        } catch {
            if startedHere { downloads.cancel(song.id) }
            throw error
        }
    }

    private nonisolated static func download(_ url: URL, fallbackExtension: String) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Failure.audioUnavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.audioUnavailable
        }
        let fileExtension = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
        let destination = workDirectory()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private struct ReadableAudio {
        var url: URL
        var temporaryURL: URL?
        var duration: TimeInterval
    }

    /// 系统能直接读的(MP3、AAC、FLAC、WAV……)原样用;读不了的(Opus、WMA 等)先用播放那套解码器
    /// 转成一份 M4A。
    private func readableAudio(at url: URL, expectedDuration: TimeInterval) async throws -> ReadableAudio {
        // 打开文件可能要把整个 VBR 的 MP3 扫一遍,放到主线程外。
        if let duration = await Task.detached(priority: .userInitiated, operation: { Self.readableDuration(at: url) }).value {
            return ReadableAudio(url: url, temporaryURL: nil, duration: duration)
        }
        setPhase(.convertingAudio)
        let compact: OfflineAudioCompactor.Output
        do {
            compact = try await OfflineAudioCompactor.encodeForTranscription(
                original: url,
                expectedDuration: expectedDuration > 0 ? expectedDuration : nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreadableAudio
        }
        let compactURL = compact.url
        guard let duration = await Task.detached(priority: .userInitiated, operation: {
            Self.readableDuration(at: compactURL)
        }).value else {
            try? FileManager.default.removeItem(at: compact.url)
            throw Failure.unreadableAudio
        }
        return ReadableAudio(url: compact.url, temporaryURL: compact.url, duration: duration)
    }

    private nonisolated static func readableDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    // MARK: On-device

    private func transcribeOnDevice(url: URL, localeIdentifier: String?) async throws -> AIAudioTranscriptionResult {
        guard await OnDeviceSpeechTranscription.isAvailable() else { throw Failure.onDeviceUnavailable }
        guard let localeIdentifier else { throw Failure.unsupportedLanguage }
        do {
            return try await OnDeviceSpeechTranscription.transcribe(
                fileURL: url,
                localeIdentifier: localeIdentifier
            ) { phase in
                Task { @MainActor [weak self] in
                    switch phase {
                    case .preparingModel: self?.setPhase(.preparingModel)
                    case .transcribing(let fraction):
                        // 按 1% 一档更新,免得每个词都刷新界面。
                        self?.setPhase(.transcribing((fraction * 100).rounded(.down) / 100))
                    }
                }
            }
        } catch let failure as OnDeviceSpeechTranscription.Failure {
            switch failure {
            case .unavailable: throw Failure.onDeviceUnavailable
            case .unsupportedLanguage: throw Failure.unsupportedLanguage
            case .modelUnavailable: throw Failure.modelUnavailable
            case .unreadableAudio: throw Failure.unreadableAudio
            }
        }
    }

    // MARK: Cloud

    private func transcribeInSegments(
        song: Song,
        engine: SpokenTranscriptEngine,
        url: URL,
        duration: TimeInterval
    ) async throws -> AIAudioTranscriptionResult {
        let plan = SpokenTranscriptSegmentPlan(duration: duration)
        guard !plan.segments.isEmpty else { throw Failure.unreadableAudio }
        let intelligence = AppServices.shared.musicIntelligence
        let key = "\(song.id)\u{1F}\(engine.rawValue)\u{1F}\(plan.segments.count)"
        var results = partial?.key == key ? partial?.results ?? [:] : [:]
        let format: SegmentFormat = engine == .builtIn ? .mpeg4 : .adts
        for segment in plan.segments where results[segment.index] == nil {
            try Task.checkCancellation()
            setPhase(.uploading(segment: segment.index + 1, of: plan.segments.count))
            let written = try await Task.detached(priority: .userInitiated) {
                try Self.writeSegment(of: url, from: segment.audioStart, to: segment.audioEnd, format: format)
            }.value
            defer { try? FileManager.default.removeItem(at: written.url) }
            let outcome: AIAudioTranscriptionOutcome
            switch engine {
            case .builtIn:
                outcome = await intelligence.transcribeTranscriptSegmentWithBuiltIn(fileURL: written.url)
            case .ownKey, .onDevice:
                outcome = await intelligence.transcribeTranscriptSegmentWithOwnKey(
                    fileURL: written.url,
                    mimeType: written.mimeType,
                    displayName: "\(song.title) \(segment.index + 1)"
                )
            }
            try Task.checkCancellation()
            switch outcome {
            case .success(let execution):
                results[segment.index] = execution.result
                partial = (key, results)
            case .limitReached:
                throw engine == .builtIn ? Failure.builtInLimitReached : Failure.failed
            case .monthlyLimitReached:
                throw Failure.builtInMonthlyLimitReached
            case .notInPlan:
                throw Failure.builtInNotInPlan
            case .unavailable:
                throw engine == .builtIn ? Failure.builtInUnavailable : Failure.ownKeyUnavailable
            case .tooLong, .failed:
                throw Failure.failed
            }
        }
        return plan.stitch(results)
    }

    private enum SegmentFormat: Sendable {
        /// 内置智能:M4A,中转从里面读时长。
        case mpeg4
        /// 自己的 Google 密钥:ADTS 封装的 AAC,Google 写明支持;系统写不了时退回 WAV。
        case adts
    }

    private struct WrittenSegment: Sendable {
        var url: URL
        var mimeType: String
    }

    /// 从可读的音频里取出 [start, end] 这一段,降到 22.05 kHz 单声道写成一个小文件。
    private nonisolated static func writeSegment(
        of source: URL,
        from start: TimeInterval,
        to end: TimeInterval,
        format: SegmentFormat
    ) throws -> WrittenSegment {
        let input = try AVAudioFile(forReading: source)
        let sourceFormat = input.processingFormat
        let sampleRate = sourceFormat.sampleRate
        guard sampleRate > 0 else { throw Failure.unreadableAudio }
        let startFrame = AVAudioFramePosition((max(0, start) * sampleRate).rounded(.down))
        let endFrame = min(input.length, AVAudioFramePosition((end * sampleRate).rounded(.up)))
        guard endFrame > startFrame else { throw Failure.unreadableAudio }
        input.framePosition = startFrame

        let (output, url, mimeType) = try makeSegmentFile(format: format)
        var keepsFile = false
        defer { if !keepsFile { try? FileManager.default.removeItem(at: url) } }
        let target = output.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw Failure.unreadableAudio }
        if sourceFormat.channelCount > 1 { converter.downmix = true }
        let reader = SegmentChunkReader(file: input, format: sourceFormat, remaining: endFrame - startFrame)
        let capacity = AVAudioFrameCount(Double(SegmentChunkReader.chunk) * target.sampleRate / sampleRate) + 1_024
        while true {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw Failure.unreadableAudio
            }
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                let next = reader.next()
                inputStatus.pointee = next == nil ? .endOfStream : .haveData
                return next
            }
            if let failure = reader.failure { throw failure }
            if let conversionError { throw conversionError }
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            if status == .endOfStream || status == .error || buffer.frameLength == 0 { break }
        }
        keepsFile = true
        return WrittenSegment(url: url, mimeType: mimeType)
    }

    private nonisolated static func makeSegmentFile(format: SegmentFormat) throws -> (AVAudioFile, URL, String) {
        let directory = workDirectory()
        let sampleRate = AIAudioTranscriptionPolicy.builtInUploadSampleRate
        let aacExtension = format == .mpeg4 ? "m4a" : "aac"
        let aacMIME = format == .mpeg4 ? "audio/m4a" : "audio/aac"
        // 单声道 AAC 在这个采样率下接受的码率因系统而异,从高往低试。
        for bitRate in [48_000, 32_000, 24_000] {
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(aacExtension)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
            if let file = try? AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            ) {
                return (file, url, aacMIME)
            }
            try? FileManager.default.removeItem(at: url)
        }
        guard format == .adts else { throw Failure.unreadableAudio }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        return (file, url, "audio/wav")
    }

    private nonisolated static func workDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Primuse-TranscriptGeneration", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// 给 `AVAudioConverter` 一块一块读这一段;转换器在 `convert` 里同步回调,都在同一个线程上。
private final class SegmentChunkReader: @unchecked Sendable {
    static let chunk: AVAudioFrameCount = 16_384

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var remaining: AVAudioFramePosition
    private(set) var failure: Error?

    init(file: AVAudioFile, format: AVAudioFormat, remaining: AVAudioFramePosition) {
        self.file = file
        self.format = format
        self.remaining = remaining
    }

    func next() -> AVAudioPCMBuffer? {
        guard failure == nil, remaining > 0 else { return nil }
        let count = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunk), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        do {
            try file.read(into: buffer, frameCount: count)
        } catch {
            failure = error
            return nil
        }
        remaining -= AVAudioFramePosition(buffer.frameLength)
        return buffer.frameLength > 0 ? buffer : nil
    }
}
