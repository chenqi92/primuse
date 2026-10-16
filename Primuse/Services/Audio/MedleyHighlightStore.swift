import AVFoundation
import Foundation
import PrimuseKit

/// Highlights ("高潮") found for songs, kept on this device so a later medley
/// starts every slice on its chorus without analysing the song again. The
/// file lives in Caches: losing it only means analysing again.
@MainActor
final class MedleyHighlightStore {
    static let shared = MedleyHighlightStore()

    private let fileURL: URL
    private var records: [String: MedleyHighlightRecord]?
    private var saveTask: Task<Void, Never>?

    /// `fileURL` is for tests.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("medley_highlights.json")
        }
    }

    func record(for songID: String) -> MedleyHighlightRecord? {
        loadedRecords()[songID]
    }

    /// The highlight found for `song`, while it still fits the song's file.
    func highlight(for song: Song) -> MedleyHighlight? {
        MedleyHighlightRecordPolicy.highlight(from: record(for: song.id), songDuration: song.duration)
    }

    func store(_ record: MedleyHighlightRecord, for songID: String) {
        var current = loadedRecords()
        current[songID] = record
        for id in MedleyHighlightRecordPolicy.evictedIDs(current) { current[id] = nil }
        records = current
        scheduleSave()
    }

    private func loadedRecords() -> [String: MedleyHighlightRecord] {
        if let records { return records }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode([String: MedleyHighlightRecord].self, from: $0)
        } ?? [:]
        records = loaded
        return loaded
    }

    /// Several slices are analysed in a row; one write covers them.
    private func scheduleSave() {
        saveTask?.cancel()
        let url = fileURL
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let snapshot = self?.records else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }
}

/// The parts of finding a highlight shared by the players: the lyrics they
/// read and how decoded audio reaches `MedleyAudioFeatureExtractor`.
enum MedleyHighlightAnalysis {
    /// Mono at the extractor's preferred rate; the decoders resample to it.
    static var analysisFormat: AVAudioFormat? {
        AVAudioFormat(
            standardFormatWithSampleRate: MedleyAudioFeatureExtractor.preferredSampleRate,
            channels: 1
        )
    }

    /// The timed lines of the lyrics Primuse has cached for the song; none
    /// when it has none or they are untimed. Only the cache is read: fetching
    /// lyrics just to cut a medley slice is not worth a network request.
    static func cachedLyricLines(songID: String) async -> [MedleyLyricLine] {
        guard let lines = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID) else { return [] }
        return lines.compactMap { line in
            line.isSynchronized ? MedleyLyricLine(time: line.timestamp, text: line.text) : nil
        }
    }

    static func append(_ buffer: AVAudioPCMBuffer, to extractor: MedleyAudioFeatureExtractor) {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
        extractor.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    static func record(
        songDuration: TimeInterval,
        lyrics: [MedleyLyricLine],
        features: MedleyAudioFeatures?,
        sectionStarts: [TimeInterval]
    ) -> MedleyHighlightRecord {
        MedleyHighlightRecord(
            songDuration: songDuration,
            highlight: MedleyHighlightDetector.highlight(
                duration: songDuration,
                lyrics: lyrics,
                audio: features,
                sectionStarts: sectionStarts
            ),
            includesAudio: features != nil,
            includesLyrics: !lyrics.isEmpty
        )
    }

    enum ReadError: Error {
        case unreadable
        case incomplete(TimeInterval)
    }

    /// Reads a complete local file through AVFoundation, for a player with no
    /// decoder of its own outside the playback graph (Apple TV). Formats
    /// AVFoundation cannot open throw; the slice then keeps the lyrics' or
    /// the guessed highlight.
    static func audioFeatures(readingFileAt url: URL, expectedDuration: TimeInterval) throws -> MedleyAudioFeatures {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = analysisFormat,
              source.sampleRate > 0,
              let converter = AVAudioConverter(from: source, to: target) else { throw ReadError.unreadable }
        if source.channelCount > 1 { converter.downmix = true }
        let extractor = MedleyAudioFeatureExtractor(sampleRate: target.sampleRate)
        let reader = FileChunkReader(file: file, format: source, chunk: 16_384)
        let outputCapacity = AVAudioFrameCount(Double(reader.chunk) * target.sampleRate / source.sampleRate) + 1024
        var reachedEnd = false
        while !reachedEnd, !extractor.isFull {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
                throw ReadError.unreadable
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                let next = reader.next()
                inputStatus.pointee = next == nil ? .endOfStream : .haveData
                return next
            }
            if let failure = reader.failure { throw failure }
            if let conversionError { throw conversionError }
            append(output, to: extractor)
            if status == .endOfStream || status == .error || output.frameLength == 0 { reachedEnd = true }
        }
        let needed = min(expectedDuration * 0.8, MedleyAudioFeatureExtractor.maximumDuration)
        guard extractor.analyzedDuration >= needed else { throw ReadError.incomplete(extractor.analyzedDuration) }
        return extractor.finish()
    }
}

/// Hands an `AVAudioConverter` the file one chunk at a time. The converter
/// calls back synchronously inside `convert`, on the reading thread.
private final class FileChunkReader: @unchecked Sendable {
    let chunk: AVAudioFrameCount
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private(set) var failure: Error?

    init(file: AVAudioFile, format: AVAudioFormat, chunk: AVAudioFrameCount) {
        self.file = file
        self.format = format
        self.chunk = chunk
    }

    /// The next chunk, or nil at the end of the file or on a read error.
    func next() -> AVAudioPCMBuffer? {
        guard failure == nil,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        do {
            try file.read(into: buffer, frameCount: chunk)
        } catch {
            failure = error
            return nil
        }
        return buffer.frameLength > 0 ? buffer : nil
    }
}
