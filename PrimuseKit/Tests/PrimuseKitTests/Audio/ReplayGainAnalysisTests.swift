import Foundation
import GRDB
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

    @Test func preparationPrioritizesQueueAndSkipsTaggedAndDuplicateSongs() {
        let current = song("current"), next = song("next"), rest = song("rest")
        var tagged = song("tagged")
        tagged.replayGainTrackGain = -4
        let planned = ReplayGainPolicy.analysisPlan(current: current, upcoming: [next, tagged, next],
                                                   album: [current, next, rest], mode: .album)
        #expect(planned.map(\.id) == ["next", "current", "rest"])
        #expect(ReplayGainPolicy.analysisPlan(current: current, upcoming: [], album: [rest], mode: .track).map(\.id) == ["current"])
    }

    @Test func nonMusicNeverEntersAnalysisAndExplicitMusicClassificationIsRespected() {
        let music = song("music")
        var book = song("book"), podcast = song("podcast"), radio = song("radio")
        book.filePath = "book.m4b"
        book.replayGainTrackGain = -6
        podcast.genre = "Podcast"
        radio.sourceID = RadioStation.playbackSourceID
        #expect(!ReplayGainPolicy.supports(book))
        #expect(!ReplayGainPolicy.supports(podcast))
        #expect(!ReplayGainPolicy.supports(radio, contentKind: .music))
        #expect(ReplayGainPolicy.analysisPlan(current: book, upcoming: [music], album: [], mode: .track).isEmpty)
        #expect(ReplayGainPolicy.analysisPlan(current: music, upcoming: [book, podcast, radio], album: [], mode: .track) == [music])
        #expect(ReplayGainPolicy.supports(book, contentKind: .music))
        #expect(!ReplayGainPolicy.supports(music, contentKind: .spokenWord))
        var concert = music
        concert.duration = 7200
        #expect(ReplayGainPolicy.supports(concert))
    }

    @Test func preparationKeepsSeparateCUETracksAndDoesNotFetchStreamDescriptors() {
        var a = song("a"), b = song("b"), stream = song("stream")
        a.filePath = "disc.flac"; b.filePath = a.filePath
        a.cueStartTime = 0; a.cueEndTime = 10
        b.cueStartTime = 10; b.cueEndTime = 20
        stream.filePath = "station.strm"
        #expect(ReplayGainPolicy.analysisPlan(current: a, upcoming: [b, stream], album: [], mode: .track).map(\.id) == ["b", "a"])
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

    @Test func cacheMigratesLegacyMeasurementsAndOnlyWritesChangedTrack() async throws {
        struct LegacyEntry: Encodable {
            let measurement: ReplayGainLoudnessMeasurement
            let savedAt: Date
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = song("a"), b = song("b"), c = song("c")
        let value = ReplayGainLoudnessMeasurement(blockEnergies: [0.01], peak: 0.8, duration: 3)
        let legacy = root.appendingPathComponent("v1.json")
        try JSONEncoder().encode([ReplayGainAnalysisCache.key(for: a): LegacyEntry(measurement: value, savedAt: Date())]).write(to: legacy)
        let cache = ReplayGainAnalysisCache(directory: root)
        #expect(await cache.measurement(for: a) == value)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let db = try DatabaseQueue(path: root.appendingPathComponent("v2.sqlite").path)
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE changedKeys (cacheKey TEXT);
                CREATE TRIGGER recordInsert AFTER INSERT ON measurements BEGIN
                    INSERT INTO changedKeys VALUES (NEW.cacheKey);
                END;
                CREATE TRIGGER recordUpdate AFTER UPDATE ON measurements BEGIN
                    INSERT INTO changedKeys VALUES (NEW.cacheKey);
                END;
                """)
        }
        let file = root.appendingPathComponent("audio")
        try Data([1]).write(to: file)
        await cache.store(value, for: b, fileURL: file)
        await cache.store(value, for: b, fileURL: file)
        await cache.store(value, for: c, fileURL: file)
        let changed = try await db.read { try String.fetchAll($0, sql: "SELECT cacheKey FROM changedKeys") }
        #expect(changed == [ReplayGainAnalysisCache.key(for: b), ReplayGainAnalysisCache.key(for: c)])
        let restarted = ReplayGainAnalysisCache(directory: root)
        for track in [a, b, c] { #expect(await restarted.measurement(for: track) == value) }
    }

    @Test func failedMigrationKeepsLegacyCacheReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v2.sqlite"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = song("a")
        let value = ReplayGainLoudnessMeasurement(blockEnergies: [0.01], peak: 0.8, duration: 3)
        let payload: [String: Any] = [ReplayGainAnalysisCache.key(for: track): [
            "measurement": ["blockEnergies": [0.01], "peak": 0.8, "duration": 3.0], "savedAt": 0.0
        ]]
        let legacy = root.appendingPathComponent("v1.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: legacy)
        #expect(await ReplayGainAnalysisCache(directory: root).measurement(for: track) == value)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
