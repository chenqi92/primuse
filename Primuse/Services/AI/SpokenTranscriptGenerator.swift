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
        /// 阿里云百炼:整集上传到临时存储,传了几成;拿不到进度时为 nil。
        case uploadingAudio(Double?)
        /// 阿里云百炼:文件交上去了,等它识别完。
        case recognizingRemotely
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
        case aliyunNotConfigured
        /// 连不上阿里云百炼。
        case aliyunNetwork
        /// 密钥不对,或者和选的地区对不上。
        case aliyunKeyRejected
        /// 账号没开通百炼或 Fun-ASR。
        case aliyunAccessDenied
        /// 欠费,或者只用免费额度且额度用完了。
        case aliyunBilling
        case aliyunThrottled
        case aliyunContentBlocked
        /// 文件取不到、格式或内容不对。
        case aliyunFileRejected
        /// 超过 Fun-ASR 一次能收的时长或大小。
        case aliyunTooLong
        /// 等太久还没出结果;任务还在服务端,重试接着等。
        case aliyunTimedOut
        case aliyunFailed
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
    /// 交给阿里云百炼、还没拿到结果的任务。超时、停下或断网后重试时接着等它,不再上传、不再计费;
    /// 服务端说任务失败了才丢掉。
    @ObservationIgnored private var aliyunPendingTask: (key: String, taskID: String, submittedAt: Date)?
    @ObservationIgnored private let defaults: UserDefaults

    private static let recordsKey = "primuse.transcriptGeneration.records.v1"
    private static let uploadConsentKey = "primuse.transcriptGeneration.uploadConsent"
    /// 阿里云百炼是另一家第三方,第一次用它要另外点一次头;老的总开关只管内置智能与 Google。
    private static let aliyunUploadConsentKey = "primuse.transcriptGeneration.uploadConsent.aliyun"
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

    /// 这种识别方式要上传音频时,用户对它点过头没有。
    func hasUploadConsent(for engine: SpokenTranscriptEngine) -> Bool {
        switch engine {
        case .onDevice: true
        case .builtIn, .ownKey: hasAudioUploadConsent
        case .aliyun: defaults.bool(forKey: Self.aliyunUploadConsentKey)
        }
    }

    func grantUploadConsent(for engine: SpokenTranscriptEngine) {
        switch engine {
        case .onDevice: break
        case .builtIn, .ownKey: hasAudioUploadConsent = true
        case .aliyun: defaults.set(true, forKey: Self.aliyunUploadConsentKey)
        }
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
            case .aliyun:
                result = try await transcribeWithAliyun(
                    song: song,
                    url: readable.url,
                    duration: readable.duration,
                    isCompactCopy: readable.temporaryURL != nil
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
            case .ownKey, .onDevice, .aliyun:
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

    // MARK: Aliyun

    /// 阿里云百炼:整集一个文件传上去(Fun-ASR 一次收得下 12 小时),提交任务后等结果。
    private func transcribeWithAliyun(
        song: Song,
        url: URL,
        duration: TimeInterval,
        isCompactCopy: Bool
    ) async throws -> AIAudioTranscriptionResult {
        guard let credentials = AliyunSpeechCredentialStore.load() else { throw Failure.aliyunNotConfigured }
        guard duration <= AliyunFunASR.maximumDuration else { throw Failure.aliyunTooLong }
        let client = AliyunSpeechTranscriptionClient.shared
        let key = "\(song.id)\u{1F}\(credentials.region.rawValue)\u{1F}\(credentials.maskedAPIKey)"
        do {
            let taskID: String
            if let pending = aliyunPendingTask, pending.key == key,
               Date().timeIntervalSince(pending.submittedAt) < AliyunFunASR.taskRetention {
                taskID = pending.taskID
            } else {
                aliyunPendingTask = nil
                // 本机转过一份的已经是 22 kHz 单声道 M4A;原样的文件先压成这样再传,省流量也省上传时间。
                let upload: URL
                var removesUpload = false
                if isCompactCopy {
                    upload = url
                } else {
                    setPhase(.convertingAudio)
                    upload = try await Task.detached(priority: .userInitiated) {
                        try Self.writeSegment(of: url, from: 0, to: duration, format: .mpeg4)
                    }.value.url
                    removesUpload = true
                }
                defer { if removesUpload { try? FileManager.default.removeItem(at: upload) } }
                try Task.checkCancellation()
                setPhase(.uploadingAudio(nil))
                let ossURL = try await client.upload(fileURL: upload, credentials: credentials) { fraction in
                    Task { @MainActor [weak self] in
                        // 进度回调晚到时,已经进了下一步就别再拨回「上传中」。
                        guard let self, case .uploadingAudio? = self.activeJob?.phase else { return }
                        self.setPhase(.uploadingAudio((fraction * 100).rounded(.down) / 100))
                    }
                }
                try Task.checkCancellation()
                let declared = PodcastPlaybackSong.isEpisode(song)
                    ? PodcastStore.shared.episode(id: song.id)?.show.language
                    : nil
                taskID = try await client.submit(
                    ossURL: ossURL,
                    languageHint: AliyunFunASR.languageHint(declaredLanguage: declared),
                    credentials: credentials
                )
                aliyunPendingTask = (key, taskID, Date())
            }
            setPhase(.recognizingRemotely)
            let result = try await client.result(
                taskID: taskID,
                credentials: credentials,
                timeout: AliyunFunASR.resultTimeout(forDuration: duration)
            )
            aliyunPendingTask = nil
            AliyunSpeechTranscriptionAccount.shared.recordSuccess()
            return result
        } catch let error as AliyunSpeechTranscriptionError {
            if case .taskFailed = error { aliyunPendingTask = nil }
            AliyunSpeechTranscriptionAccount.shared.recordFailure(error)
            throw Self.failure(for: error)
        }
    }

    private static func failure(for error: AliyunSpeechTranscriptionError) -> Failure {
        switch error {
        case .notConfigured: return .aliyunNotConfigured
        case .network: return .aliyunNetwork
        case .invalidResponse: return .aliyunFailed
        case .fileTooLarge: return .aliyunTooLong
        case .timedOut: return .aliyunTimedOut
        case .uploadRejected(let code, _): return code == "EntityTooLarge" ? .aliyunTooLong : .aliyunFailed
        case .service(let service), .taskFailed(let service):
            switch service.kind {
            case .invalidAPIKey: return .aliyunKeyRejected
            case .accessDenied: return .aliyunAccessDenied
            case .billing: return .aliyunBilling
            case .throttled: return .aliyunThrottled
            case .contentBlocked: return .aliyunContentBlocked
            case .fileRejected: return .aliyunFileRejected
            case .server, .other: return .aliyunFailed
            }
        }
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
