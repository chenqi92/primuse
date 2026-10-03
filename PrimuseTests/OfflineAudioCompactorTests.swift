import AVFoundation
import XCTest
import PrimuseKit
@testable import Primuse

final class OfflineAudioCompactorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineAudioCompactorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLosslessSourceBecomesSmallerAACWithTheSameLength() async throws {
        let wav = try OfflineAudioFixture.writeWAV(
            to: directory.appendingPathComponent("hires.wav"),
            seconds: 12,
            sampleRate: 96_000,
            channels: 2
        )
        let originalSize = try OfflineAudioFixture.byteCount(of: wav)

        let output = try await OfflineAudioCompactor.encode(
            original: wav,
            originalByteCount: originalSize,
            targetKbps: 192,
            expectedDuration: 12
        )
        defer { try? FileManager.default.removeItem(at: output.url) }

        XCTAssertEqual(output.url.pathExtension, "m4a")
        XCTAssertLessThan(output.byteCount, originalSize / 4)
        XCTAssertEqual(output.encodedBitRate, 192_000)
        XCTAssertEqual(output.record, OfflineCompactArtifactRecord(originalByteCount: originalSize, bitRateKbps: 192))
        let encoded = try AVAudioFile(forReading: output.url)
        XCTAssertEqual(encoded.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(encoded.fileFormat.channelCount, 2)
        XCTAssertEqual(Double(encoded.length) / encoded.fileFormat.sampleRate, 12, accuracy: 0.05)
    }

    func testMonoSourceFallsBackToABitRateTheEncoderAccepts() async throws {
        let wav = try OfflineAudioFixture.writeWAV(
            to: directory.appendingPathComponent("mono.wav"),
            seconds: 6,
            sampleRate: 44_100,
            channels: 1
        )
        let output = try await OfflineAudioCompactor.encode(
            original: wav,
            originalByteCount: try OfflineAudioFixture.byteCount(of: wav),
            targetKbps: 320,
            expectedDuration: 6
        )
        defer { try? FileManager.default.removeItem(at: output.url) }

        XCTAssertEqual(output.encodedBitRate, 160_000)
        let encoded = try AVAudioFile(forReading: output.url)
        XCTAssertEqual(encoded.fileFormat.channelCount, 1)
        XCTAssertEqual(encoded.fileFormat.sampleRate, 44_100)
    }

    func testInstalledCopyCarriesItsRecordAndIsRejectedOnceTheSourceChanges() throws {
        let staging = directory.appendingPathComponent("staging.m4a")
        try Data(repeating: 3, count: 4_096).write(to: staging)
        let destination = directory.appendingPathComponent("song.flac.compact.m4a")
        let record = OfflineCompactArtifactRecord(originalByteCount: 40_000_000, bitRateKbps: 128)

        try OfflineCompactArtifact.install(staging: staging, at: destination, record: record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(OfflineCompactArtifact.readRecord(at: destination), record)
        XCTAssertTrue(OfflineCompactArtifact.isCompactURL(destination))
        XCTAssertTrue(OfflineCompactArtifact.isUsable(
            at: destination,
            expectedOriginalByteCount: 40_000_000,
            preservesExisting: false
        ))
        XCTAssertFalse(OfflineCompactArtifact.isUsable(
            at: destination,
            expectedOriginalByteCount: 60_000_000,
            preservesExisting: false
        ))
        XCTAssertTrue(OfflineCompactArtifact.isUsable(
            at: destination,
            expectedOriginalByteCount: 60_000_000,
            preservesExisting: true
        ))
    }

    func testCopyWithoutRecordIsNeverUsable() throws {
        let destination = directory.appendingPathComponent("orphan.flac.compact.m4a")
        try Data(repeating: 3, count: 4_096).write(to: destination)
        XCTAssertNil(OfflineCompactArtifact.readRecord(at: destination))
        XCTAssertFalse(OfflineCompactArtifact.isUsable(
            at: destination,
            expectedOriginalByteCount: 0,
            preservesExisting: false
        ))
    }
}

/// 走真实的离线下载链路: 原文件已在缓存里, 再点一次缓存时按设置转成副本。
@MainActor
final class OfflineDownloadQualityIntegrationTests: XCTestCase {
    func testCachingAgainConvertsPinnedOriginalIntoCompactCopy() async throws {
        let restore = setOfflineQuality(.kbps128)
        defer { restore() }
        let fixture = try await makeFixture(seconds: 8)
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }

        let result = await fixture.manager.downloadForOfflineBatch(songs: [fixture.song])

        XCTAssertEqual(result.completedCount, 1)
        let compact = OfflineCompactArtifact.url(forCanonical: fixture.canonical)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compact.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.canonical.path))
        XCTAssertNil(fixture.manager.cachedURL(for: fixture.song))
        XCTAssertEqual(
            fixture.manager.cachedPlaybackURL(for: fixture.song)?.standardizedFileURL,
            compact.standardizedFileURL
        )
        XCTAssertTrue(fixture.manager.hasUsableCachedAudioForPlayback(fixture.song))
        XCTAssertEqual(fixture.manager.offlineAudioSnapshot(for: fixture.song).state, .pinned)
        let pinned = await AudioCacheManager.shared.isPinned(path: fixture.path)
        XCTAssertTrue(pinned)
        let downloaded = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertEqual(downloaded, [fixture.song.id])

        // 服务器上换成了另一个文件: 副本不再代表这首歌。
        var replaced = fixture.song
        replaced.fileSize = fixture.song.fileSize * 2
        XCTAssertNil(fixture.manager.cachedPlaybackURL(for: replaced))
        XCTAssertFalse(FileManager.default.fileExists(atPath: compact.path))
    }

    func testOriginalQualityKeepsTheDownloadedFile() async throws {
        let restore = setOfflineQuality(.original)
        defer { restore() }
        let fixture = try await makeFixture(seconds: 4)
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }

        let result = await fixture.manager.downloadForOfflineBatch(songs: [fixture.song])

        XCTAssertEqual(result.completedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.canonical.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: OfflineCompactArtifact.url(forCanonical: fixture.canonical).path
        ))
    }

    func testRemovingTheDownloadDeletesTheCompactCopy() async throws {
        let restore = setOfflineQuality(.kbps192)
        defer { restore() }
        let fixture = try await makeFixture(seconds: 4)
        _ = await fixture.manager.downloadForOfflineBatch(songs: [fixture.song])
        let compact = OfflineCompactArtifact.url(forCanonical: fixture.canonical)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compact.path))

        fixture.manager.removeOfflineDownload(song: fixture.song)

        XCTAssertFalse(FileManager.default.fileExists(atPath: compact.path))
        XCTAssertNil(fixture.manager.cachedPlaybackURL(for: fixture.song))
        XCTAssertFalse(fixture.manager.offlineAudioSnapshot(for: fixture.song).isDownloaded)
    }

    func testConvertingCachedSongsShrinksPinnedOriginalsInPlace() async throws {
        let restore = setOfflineQuality(.kbps128)
        defer { restore() }
        let fixture = try await makeFixture(seconds: 6)
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }

        fixture.manager.startOfflineCompactionSweep()
        XCTAssertNotNil(fixture.manager.offlineCompactionSweepProgress)
        let deadline = Date().addingTimeInterval(30)
        while fixture.manager.offlineCompactionSweepProgress != nil {
            guard Date() < deadline else { return XCTFail("conversion did not finish") }
            try await Task.sleep(for: .milliseconds(50))
        }

        let result = try XCTUnwrap(fixture.manager.lastOfflineCompactionSweepResult)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(result.convertedCount, 1)
        XCTAssertGreaterThan(result.savedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.canonical.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: OfflineCompactArtifact.url(forCanonical: fixture.canonical).path
        ))
    }

    /// 改宿主 App 的偏好, 返回还原用的闭包。
    private func setOfflineQuality(_ quality: StreamQualityPreference) -> () -> Void {
        let saved = UserDefaults.standard.data(forKey: PlaybackSettings.defaultsKey)
        var settings = PlaybackSettings.load()
        settings.offlineDownloadQuality = quality
        settings.save()
        return {
            if let saved {
                UserDefaults.standard.set(saved, forKey: PlaybackSettings.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PlaybackSettings.defaultsKey)
            }
        }
    }

    private func makeFixture(seconds: Double) async throws -> (
        manager: SourceManager,
        song: Song,
        canonical: URL,
        path: String
    ) {
        let source = MusicSource(id: UUID().uuidString, name: "Compact fixture", type: .navidrome)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        try OfflineAudioFixture.writeWAV(to: staging, seconds: seconds, sampleRate: 44_100, channels: 2)
        let size = try OfflineAudioFixture.byteCount(of: staging)
        let song = Song(
            id: UUID().uuidString,
            title: "Compact fixture",
            duration: seconds,
            fileFormat: .wav,
            filePath: "/songs/fixture.wav",
            sourceID: source.id,
            fileSize: size
        )
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: { [song] })
        let deadline = Date().addingTimeInterval(3)
        while !(await manager.prepareAutomaticOfflineDownload(song: song, forceRedownload: false)) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let canonical = manager.cacheURL(for: song)
        try FileManager.default.copyItem(at: staging, to: canonical)
        let path = source.id + "/" + canonical.lastPathComponent
        await AudioCacheManager.shared.markDownloaded(path: path, byteCount: size, pinned: true)
        return (manager, song, canonical, path)
    }
}

enum OfflineAudioFixture {
    /// 16 bit PCM WAV, 两个声道各是一段正弦加一点噪声, 编码器压不到零。
    @discardableResult
    static func writeWAV(
        to url: URL,
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        defer { file.close() }
        let format = file.processingFormat
        let total = Int(seconds * sampleRate)
        var written = 0
        var generator = SystemRandomNumberGenerator()
        while written < total {
            let count = min(8_192, total - written)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let data = buffer.floatChannelData else {
                throw URLError(.cannotCreateFile)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(format.channelCount) {
                let frequency = Float(440 + 110 * channel)
                for frame in 0..<count {
                    let t = Float(written + frame) / Float(sampleRate)
                    let noise = Float.random(in: -0.05...0.05, using: &generator)
                    data[channel][frame] = 0.4 * sinf(2 * .pi * frequency * t) + noise
                }
            }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    static func byteCount(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
