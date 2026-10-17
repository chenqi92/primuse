import AVFoundation
import CoreMedia
import Foundation
import PrimuseKit
import Speech

/// 本机的 Apple 语音识别(SpeechAnalyzer + SpeechTranscriber,iOS 26 / macOS 26 起),给文稿生成用
/// (#314)。识别全在设备上做,不上传音频,时长不限;每种语言的识别模型第一次用时由系统下载,
/// 之后各 App 共用。
enum OnDeviceSpeechTranscription {
    enum Failure: Error, Equatable {
        /// 系统低于 iOS 26 / macOS 26,或这台设备跑不了这套识别。
        case unavailable
        /// 选的语言本机识别不支持。
        case unsupportedLanguage
        /// 识别模型下载不下来(没网、空间不够)。
        case modelUnavailable
        /// 系统读不了这个音频文件。
        case unreadableAudio
    }

    enum Phase: Equatable, Sendable {
        /// 下载这种语言的识别模型;拿不到进度时为 nil。
        case preparingModel(Double?)
        /// 识别到了全长的几成。
        case transcribing(Double)
    }

    /// 这台设备能不能做本机识别。
    static func isAvailable() async -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        return await SpeechTranscriber.isAvailable
    }

    /// 本机识别支持(含要下载模型)的语言标识。
    static func supportedLocaleIdentifiers() async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, *) else { return [] }
        let locales = await SpeechTranscriber.supportedLocales
        return Array(Set(locales.map { $0.identifier(.bcp47) })).sorted()
    }

    /// 候选里第一个本机识别支持的语言,换成它认的那种写法。
    static func resolvedLocaleIdentifier(from candidates: [String]) async -> String? {
        guard #available(iOS 26.0, macOS 26.0, *) else { return nil }
        for candidate in candidates {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: candidate)) {
                return locale.identifier(.bcp47)
            }
        }
        return nil
    }

    /// 识别整个文件,返回带时间的词。`progress` 在任意线程上调用。
    static func transcribe(
        fileURL: URL,
        localeIdentifier: String,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws -> AIAudioTranscriptionResult {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw Failure.unavailable }
        guard await SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw Failure.unsupportedLanguage
        }
        return try await run(fileURL: fileURL, locale: locale, progress: progress)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func run(
        fileURL: URL,
        locale: Locale,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws -> AIAudioTranscriptionResult {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await installModel(for: transcriber, progress: progress)
        try Task.checkCancellation()

        // 文件在这里打开、交给分析器后不再碰它。
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw Failure.unreadableAudio
        }
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        progress(.transcribing(0))
        let collector = Task { () throws -> [AIAudioTranscriptionWord] in
            var words: [AIAudioTranscriptionWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: Self.words(in: result))
                let reached = result.range.end.seconds
                if duration > 0, reached.isFinite {
                    progress(.transcribing(min(1, max(0, reached / duration))))
                }
            }
            return words
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        let lastSample: CMTime?
        do {
            lastSample = try await analyzer.analyzeSequence(from: file)
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        guard !Task.isCancelled else {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw CancellationError()
        }
        if let lastSample {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await collector.value
        return AIAudioTranscriptionResult(
            transcript: words.map(\.text).joined(separator: " "),
            words: words
        )
    }

    /// 这种语言的识别模型不在本机时先下载;系统按需给 App 分配语言名额。
    @available(iOS 26.0, macOS 26.0, *)
    private static func installModel(
        for transcriber: SpeechTranscriber,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw Failure.modelUnavailable
        }
        guard let request else { return }
        progress(.preparingModel(nil))
        do {
            try await request.downloadAndInstall()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.modelUnavailable
        }
    }

    /// 一句识别结果里带时间的词。标点这类不带时间的片段接到前一个词后面。
    @available(iOS 26.0, macOS 26.0, *)
    private static func words(in result: SpeechTranscriber.Result) -> [AIAudioTranscriptionWord] {
        let text = result.text
        var words: [AIAudioTranscriptionWord] = []
        for textRun in text.runs {
            let piece = String(text[textRun.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let range = textRun[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                  range.start.seconds.isFinite else {
                if !words.isEmpty { words[words.count - 1].text += trimmed }
                continue
            }
            words.append(AIAudioTranscriptionWord(
                text: trimmed,
                startTime: range.start.seconds,
                endTime: range.end.seconds
            ))
        }
        if words.isEmpty {
            // 整句没有逐词时间:按这一句的区间放成一个词。
            let sentence = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty, result.range.start.seconds.isFinite {
                words.append(AIAudioTranscriptionWord(
                    text: sentence,
                    startTime: result.range.start.seconds,
                    endTime: result.range.end.seconds
                ))
            }
        }
        return words
    }
}
