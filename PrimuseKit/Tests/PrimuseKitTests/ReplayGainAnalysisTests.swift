import Foundation
import Testing
@testable import PrimuseKit

@Suite("ReplayGain analysis")
struct ReplayGainAnalysisTests {
    private func song(_ id: String, album: String = "album", source: String = "source") -> Song {
        Song(id: id, title: id, albumID: album, albumTitle: album, duration: 3,
             fileFormat: .flac, filePath: id + ".flac", sourceID: source)
    }

    @Test func automaticModeRespectsShuffleAndMixedSources() {
        let a = song("a"), b = song("b")
        #expect(ReplayGainPolicy.effectiveMode(.automatic, song: a, queue: [a, b], shuffled: false) == .album)
        #expect(ReplayGainPolicy.effectiveMode(.automatic, song: a, queue: [a, b], shuffled: true) == .track)
        #expect(ReplayGainPolicy.effectiveMode(.automatic, song: a, queue: [a, song("b", album: "other")], shuffled: false) == .track)
        #expect(ReplayGainPolicy.effectiveMode(.automatic, song: a, queue: [a, song("b", source: "other")], shuffled: false) == .track)
        #expect(ReplayGainPolicy.effectiveMode(.automatic, song: a, queue: [a], shuffled: false) == .track)
        #expect(ReplayGainPolicy.effectiveMode(.album, song: a, queue: [a, b], shuffled: true) == .album)
    }

    @Test func preampRetainsPeakProtectionAndNeverAmplifiesUnknownAudio() {
        #expect(abs(ReplayGainPolicy.linearGain(gainDB: -6, peak: 0.9, preampDB: 6) - 1) < 0.001)
        #expect(abs(ReplayGainPolicy.linearGain(gainDB: 6, peak: 0.9, preampDB: 12) - Float(1 / 0.9)) < 0.001)
        #expect(ReplayGainPolicy.linearGain(gainDB: nil, peak: nil, preampDB: 12) == 1)
        #expect(ReplayGainPolicy.sanitizedPreamp(.nan) == 0)
        #expect(ReplayGainPolicy.sanitizedPreamp(100) == 12)
    }

    @Test func albumFallbackKeepsGainAndPeakPaired() {
        var track = song("a")
        track.replayGainAlbumPeak = 0.9
        track.replayGainTrackGain = 3
        track.replayGainTrackPeak = 0.5
        #expect(ReplayGainPolicy.adjustment(for: track, mode: .album) == .init(gain: 3, peak: 0.5))
        track.replayGainAlbumGain = -2
        track.replayGainAlbumPeak = nil
        #expect(ReplayGainPolicy.adjustment(for: track, mode: .album) == .init(gain: -2, peak: 0.5))
    }

    // These are numerical fixtures only; no audio device is opened or played.
    @Test(arguments: [44100.0, 48000.0, 96000.0])
    func calibratedStereoSineMatchesBS1770(sampleRate: Double) throws {
        let samples = (0..<Int(sampleRate * 2)).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / sampleRate)) }
        var analyzer = try #require(ReplayGainLoudnessAnalyzer(sampleRate: sampleRate, channelWeights: [1, 1]))
        analyzer.append(planarSamples: [samples, samples])
        let measurement = try #require(analyzer.measurement)
        #expect(abs(try #require(measurement.integratedLUFS) - (-20.0)) < 0.1)
        #expect(abs(measurement.peak - 0.1) < 0.001)
    }

    @Test func chunkBoundariesDoNotChangeMeasurement() throws {
        let samples = (0..<96000).map { Float(0.12 * sin(2 * .pi * 440 * Double($0) / 48000)) }
        var whole = try #require(ReplayGainLoudnessAnalyzer(sampleRate: 48000, channelWeights: [1]))
        var chunked = whole
        whole.append(planarSamples: [samples])
        for offset in stride(from: 0, to: samples.count, by: 997) {
            chunked.append(planarSamples: [Array(samples[offset..<min(offset + 997, samples.count)])])
        }
        #expect(whole.measurement == chunked.measurement)
    }

    @Test func gatesExcludeSilenceAndLFE() throws {
        var analyzer = try #require(ReplayGainLoudnessAnalyzer(sampleRate: 48000, channelWeights: [0]))
        let samples = Array(repeating: Float(0.5), count: 48000)
        analyzer.append(planarSamples: [samples])
        #expect(analyzer.measurement?.integratedLUFS == nil)
        #expect(analyzer.measurement?.peak == 0.5)
        let measurement = ReplayGainLoudnessMeasurement(blockEnergies: [0, 1e-12, 0.01, 0.01, 0.00001], peak: 0.5, duration: 2)
        #expect(abs(try #require(measurement.integratedLUFS) - (-20.691)) < 0.00001)
    }

    @Test func albumGatesCombinedEnergyInsteadOfAveragingDecibels() throws {
        let loud = ReplayGainLoudnessMeasurement(blockEnergies: [0.1, 0.1, 0.1], peak: 0.9, duration: 3)
        let soft = ReplayGainLoudnessMeasurement(blockEnergies: [0.01], peak: 0.2, duration: 1)
        let album = try #require(ReplayGainLoudnessMeasurement.album([loud, soft]))
        #expect(abs(try #require(album.integratedLUFS) - (-0.691 + 10 * log10(0.0775))) < 0.00001)
        #expect(album.peak == 0.9)
    }

    @Test func cacheSurvivesRestartInvalidatesChangesAndRequiresWholeAlbum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio")
        try Data([1]).write(to: file)
        let track = song("a"), other = song("b")
        let value = ReplayGainLoudnessMeasurement(blockEnergies: [0.01], peak: 0.8, duration: 3)
        let cache = ReplayGainAnalysisCache(directory: root)
        await cache.store(value, for: track, fileURL: file)
        #expect(await cache.albumMeasurement(for: [track, other]) == nil)
        let restored = ReplayGainAnalysisCache(directory: root)
        #expect(await restored.measurement(for: track, fileURL: file) == value)
        try Data([1, 2]).write(to: file)
        #expect(await restored.measurement(for: track, fileURL: file) == nil)
        var changed = track
        changed.revision = "new"
        #expect(await restored.measurement(for: changed) == nil)
        changed = track
        changed.cueStartTime = 1
        #expect(ReplayGainAnalysisCache.key(for: changed) != ReplayGainAnalysisCache.key(for: track))
    }
}
