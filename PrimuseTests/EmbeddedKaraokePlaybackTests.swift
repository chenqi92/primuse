import AVFoundation
import XCTest
import PrimuseKit
@testable import Primuse

@MainActor
final class EmbeddedKaraokePlaybackTests: XCTestCase {
    private func song(_ tracks: [EmbeddedMediaTrackInventory.AudioTrack], path: String = "mix.stem.mp4") -> Song {
        var song = Song(id: "track", title: "Lantern Signals", fileFormat: .mp4, filePath: path, sourceID: "local")
        song.embeddedMediaTracks = .init(audioTracks: tracks, hasVideo: false)
        return song
    }

    func testBackingUsesLabelledStemsAndNeverIncludesTheMaster() {
        let vocal = EmbeddedMediaTrackInventory.AudioTrack(ordinal: 3, stemName: "Vocals")
        let song = song([.init(ordinal: 0, name: "Full Mix"), .init(ordinal: 1, stemName: "Drums"),
                         .init(ordinal: 2, stemName: "Bass"), vocal])
        let playback = EmbeddedKaraokePlayback()
        playback.load(for: song) { _ in XCTFail("Read persisted tracks twice"); return nil }
        XCTAssertEqual(playback.backingOrdinals, [1, 2])
        XCTAssertEqual(playback.togglingStem(vocal), [1, 2])
        XCTAssertNil(playback.selected)
        let unnamed = EmbeddedKaraokePlayback()
        unnamed.load(for: self.song([.init(ordinal: 0), .init(ordinal: 1)])) { _ in nil }
        XCTAssertNil(unnamed.backingOrdinals)

        let alternate = EmbeddedKaraokePlayback()
        alternate.load(for: self.song([.init(ordinal: 0, name: "Instrumental", isDefault: true),
                                       .init(ordinal: 1, name: "Original")])) { _ in nil }
        XCTAssertTrue(alternate.isBacking)
        XCTAssertEqual(alternate.originalOrdinals, [1])
    }

    func testReturningToDefaultCancelsPendingSourceAndCleansItsTemporaryFile() async throws {
        let session = EmbeddedKaraokePlayback()
        let song = song([.init(ordinal: 0), .init(ordinal: 1, name: "Instrumental")])
        session.load(for: song) { _ in nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var finishSource: CheckedContinuation<KaraokeAudioFile, Never>?
        session.select(session.backingOrdinals, for: song) {
            await withCheckedContinuation { finishSource = $0 }
        } apply: { _ in XCTFail("Switched to a superseded source"); return false }
        for _ in 0..<200 where finishSource == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(finishSource)
        session.select(nil, for: song) { throw CancellationError() } apply: { _ in true }
        finishSource?.resume(returning: KaraokeAudioFile(url: url, removeAfterDecoding: true))
        for _ in 0..<200 where FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(session.selected)
        XCTAssertFalse(session.isPreparing)
        XCTAssertFalse(session.failed)
    }

    func testChangingAStemWhileOpeningUsesOneOriginalFileRequest() async throws {
        let session = EmbeddedKaraokePlayback()
        let song = song([.init(ordinal: 0), .init(ordinal: 1, stemName: "Drums"), .init(ordinal: 2, stemName: "Bass")])
        session.load(for: song) { _ in nil }
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let source: @MainActor () async throws -> KaraokeAudioFile = {
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return KaraokeAudioFile(url: invalid)
        }
        session.select([1], for: song, source: source) { _ in XCTFail("Invalid source applied"); return false }
        for _ in 0..<200 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(release)
        session.select([2], for: song, source: source) { _ in XCTFail("Invalid source applied"); return false }
        await Task.yield()
        release?.resume()
        for _ in 0..<200 where session.isPreparing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(session.failed)
        XCTAssertNil(session.selected)
        session.reset()
    }

    func testAudioContainersWithEmbeddedVideoProduceActualFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The same two-second silent H.264/AAC movie in ISO BMFF and Matroska.
        let mp4 = """
            7VZfaBxFGJ+9S9KaKkaa0CARpjaFCL273b3cGQOLd4ZqRAsFMQ8irrO7c3fr7b/MzCV3LeihPij40CcffKh9LVh8UXxQMWIfFF9EEBoQUURRBPsimBd7frO3
            520uadAn+9AlM/PNfP/n+813QQjhmuhELg99hDJIrjB0smFrfrSoIXToCT8MNxBCnr/RcNCuL/sL8L9CCpJ/w0/ZLTW6r6ADvyzEcUkw0gT6WdGMfWb3WgO/
            6GA/+/rFyUBonjqCwzpHPS6GGtJuJdHNzPqOS6SG74zmLq1dQk9fjTe5huOxAWfDdWhacg324SoJHI9KGeUz3w1qQExv+LHRdJjzTp835zBaS6VxZ4t5uE8r
            r3BheUB/wgV3UjLvyqLd5Cpk0hitwro6kJh5EuTLel5fymuqij3XauvlxZTGbK8HcwmkVhQHTfZ+QLN1WN/Zftwbq8iayEnJXn2ddhU00fjtxy/v3/prZ0eq
            TkWER0kYckxbgiV3fOS9gXku4vsfhDuWFGYa0kqfy7FgD2Wz/bNKwu/GhUp0F0DXTuQyie7oKsc8yJ1LpQq+M5/Depe86mTMcWGHQ5+HziM0WYf4gc5+cwA+
            M/vgU1H++7s4AJ9jiW72zM3x+WEXKef3xScPW0Fa8inYO0N8ZnYSfE5xf5fRf4HNzEcJNl8cwWYAzYTsSTuDppJQ5Vem3ImLnO12uyeBOQbrscpMrPMHTHcc
            HYeT8XsurP2EJoBSMruglcjI60hBS8o8F19Z7Dmu1GIKJtkULAYwmU1oyXs0eXUXRiBjwjgGY+L2+F/GyPOcPAsDan7kbtjfy+uRIwvIQs8bPP24m81xqy4b
            04CjJJWUq9VyhMToMz4VA6weTz8ceGyMRJGXfjw5t/86T14WoQznPofEyjHIocPWoMNquuywsD9cYxR+GsYrPkhBWFcmxnu9y9+e/vXjn7dXP3jz1DW8feL3
            67IN4xy2Q0axVi5hVtR1HVvFUlktEWCs5kGgcObs6cdyi7i6tgKSDrWBsRJGHY/WBNZVtZjTVb0Ehw0houVCYXNzMy9/mEKPBPmQ1QvSS74hfA9kwki4YcCX
            sU0sYhsahgduFLFDLS+0m4a2rC6rmATE63BqqO3istrWtCL2qdGgbcxbFlAP4oh3QBVmkzmGlldBCSbsu23qmNKiBhomI0GdGloZ2w0W+sQEVQ0LRj3P5UAt
            tZccWwBhr/uGCiEQ51wYUEPXTmkarhEuzIg33UhK9A2sR2ZYq3EqjJyORYOBhjTkhWGTNGBjDs+459p0eKDigMU+bNcnQsbhBoIyj4AQnFtei5GOaYd+RATs
            bbgi6PtuACZAkBEpU2PEpxwuyzKjDtCuY0CtTOKQSGZhmZZLpCeADo3z2qRuvSEsoMKIBmY9jIDbP4xAtUk7YNvQS2pCmtCN4ZzbNKB2SxiLKo6dyxtllDdA
            m9nmP9lKPrMNm9WwD52RyqxgY+jFvIrXZS6Gmi8DGUm78UraRvkhILigkbGI3QhqBHiAEoItsg7ll8WMf2iP0tdeRTO9G39+cX3r7a+vhNdQ5WHZdKtvnfCq
            hRvvb32XQbv+rUCP4MOfzi5J7FcvVtsvv/QAOT419vwbc7fOLGNTLlovVAsL399qsd2e985/Aw==
            """
        let mkv = """
            rdZvbBNlGADwu+s/4IuimUGD8YQvoqy7u25zLjncdW22GbqRlc0YP5zX67U91/ZudzfY/OKuK2xjQ4YMTIBAWEmUMAiGICoxm1GTEdQPGDOWEOVPFBUFURNI
            jMzn3YA9GBO/2PTP8773vs/7e5/32vSx6LelUnizS4dvwus31xv+3V0ULgzkFMcy7A4l3A9dm1xmWbw3TVPkseSnpbE9zuRE8VHKQ8VODcUPF8uaDqXi4+6B
            +dYj6492QOtG7NQwtB5a/0k6Pl6gZ+aby+On4GJhyZc/z2ej4tT//yCeMxPFMWc09PT0u30PhOtivVvXKhtS1UKQhyfHvSjd37YPjkgNTaGXq04P/jJz6YOD
            Q+WxyOBA3f7RuXxkR3WXJop1OxqOH73jHpx2afuzgZeG1kyteie1ba9LrTixt68rn9y8rV2OrYs2VFY0xVsqpPb6Ppdeebmv+PgXGnVh9JjLfuiyu12m7dhA
            20mXbnsfwmsudbccDEWpY0foJLVk9iK1LA2f4zNNWW8dBcUmb7Tn00Gtl6b8mauXz6yY/OvWLequSJp2GRCl3pi217x5M4dEmyRZksDBXNy+32VODNRdMedm
            JJIuSxZXxzYtHWn/jiJnJbVNFMcPXKu27T/Vyd701M5oaSgmvdDSKodbpeZIpL+o20YuPbUrWtoaa2qG/vZoa7yppTnS31fFC+mpt6Ol7fUtsXXS+qbw2uj8
            rHikf4RMg5egbFD5nFnJp6d2R0v90eb6lki0NdL/j/Owb6mTQ+pCfdNT+6Kl4UbItTbaKjdLsWikf7hdT2pGo5JPZjUrPTWG0+2EdCqkE2pIOjarJ7qF6sr0
            1IFoaSDS1go4It7BcbXkKQQ5AYaRB2XbX80vfbeQ/7p03IDC3lv6v7M+Uf9eV8PoRLGw8+rZK25ZKfy5S1G9cN5H/L7Z2UPnoz9+9P1M48ldq8+xMyuvXSdY
            tpxVDUtj+eoq1goJgsAmQlXVXJUCFxqDMKCC3GbllSzcYzAyqalwod4we7JaymEFjguVC5xQBZ0ZxzFrKyo2btwY3EBKllXyQcNKV5BVghknl4UxhunoRt6u
            ZVUloagiz1paSgyxSS2RNdQOka+FDbFKXsn22JrIdYdquW6eD7E5Tcxo3azdlYDoWda0e2AqvMtWUuSDpArwxub0bi0pk4w8zJAtJZ/WRL6aVTOWkVNkmMqz
            jqVls7oNUU13TVJ1IFA7cyIHBCX5mpHXRIFfzfNsSrEd2bQ7dJOMmE/QacpGKmVrjlgusE7GghkkUdYwOpQMNOSFPjurq9pCB8fmrbk1VB1+8ohDzzualVVg
            EPQnsl2W0iOrRs5UHGirUCLHUvQ8pICBlkLGpCwlp9lQrIRs9kCsJ0U4K1lJKibZRUJO6ApZKalb2ty+Nmp6OuMkIDJMLS+nDROuzneaMLVD64HcolDF3Qnl
            nJ6HflvV8pra5YiVHDu3OKmopdkZmG2p8r3dkuuWKqpWis0loKxkV9AQhVCQYzvJXkQuWA2hSfLOfSrdYvVzENiOZoqVrG7CGcH9AEcIuZROOH5ymOSGpR7W
            BopU2eztm6evT+4/e8Q4R9U9X9ru+s6TX5TF0u6VWani9onJ0p7C7NXebxjqvi8iFWYXfbyspjTi0n+Q8YukfVJ34fVVSmlLAb4PTz7ofWV4OYnLUPwMiutQ
            3IbiDhT3ongnig+jeBLFX6P46kJMIw+NPDTy0MhDIw+NPDTy0MhDIw+NPDTy0Pc8I67nh7mK0fsSr0oVT12AqwwSMkjIICGDhAwSMkjIICGDhAwSMkjIICGD
            KuZBHg/yeJDHgzwe5PEgjwd5PMjjQR4P8niQx4M8XuTxIo8XebzI40UeL/J4kceLPF7k8SKPF3m8yONDHh/y+JDHhzw+5PEhjw95fMjjQx4f8viQx4c8fuTx
            I48fefzI40ceP/L4kcePPH7k8SOPH3n8yBNAngDyBJAngDwB5AkgTwB5AsgTQJ7AXQ/5R/oW/Ocp8KOnth13y05ugX/CNwqeyl/dxX8D
            """
        let source = MusicSource(id: UUID().uuidString, name: "Embedded video", type: .local)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in
            LocalFileSource(sourceID: source.id, basePath: directory)
        })
        for (format, data) in [(AudioFormat.m4a, mp4), (.mka, mkv)] {
            let path = directory.appendingPathComponent("Lantern").appendingPathExtension(format.rawValue)
            let bytes = try XCTUnwrap(Data(base64Encoded: data, options: .ignoreUnknownCharacters))
            try (bytes as NSData).decompressed(using: .zlib).write(to: path)
            var song = Song(id: UUID().uuidString, title: "Lantern", fileFormat: format,
                            filePath: path.lastPathComponent, sourceID: source.id)
            song.embeddedMediaTracks = await manager.embeddedTrackInventory(for: song)
            XCTAssertTrue(song.usesEmbeddedMusicVideo, format.rawValue)
            guard case .url(let url) = try await manager.resolveVideoAsset(for: song) else {
                return XCTFail("The local video should be playable")
            }
            defer { if url != path { try? FileManager.default.removeItem(at: url) } }
            if format == .mka {
                XCTAssertEqual(url.pathExtension, "mp4")
                guard case .url(let cached) = try await manager.resolveVideoAsset(for: song) else {
                    return XCTFail("The converted video should remain available")
                }
                XCTAssertEqual(cached, url)
            }
            let image = try await AVAssetImageGenerator(asset: AVURLAsset(url: url))
                .image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            XCTAssertEqual(image.width, 32)
            XCTAssertEqual(image.height, 32)
        }
    }

    func testPausedPlayerSwitchesTheDecoderAtItsExistingPositionAndKeepsTheSong() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        func writeAudio(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name).appendingPathExtension("caf")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
            return url
        }
        let original = try writeAudio("original")
        let mixed = try writeAudio("backing")
        let source = MusicSource(id: UUID().uuidString, name: "Mix", type: .local)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in
            LocalFileSource(sourceID: source.id, basePath: directory)
        })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let player = AudioPlayerService(sourceManager: manager, playbackSettings: PlaybackSettingsStore(defaults: defaults),
                                        playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        defer {
            player.setKaraokeSessionActive(false)
            player.stop()
        }
        let song = Song(id: UUID().uuidString, title: "Lantern", duration: 2, fileFormat: .caf,
                        filePath: original.lastPathComponent, sourceID: source.id)
        player.currentSong = song
        player.duration = 2
        player.currentTime = 0.75
        player.setKaraokeSessionActive(true)
        XCTAssertTrue(player.switchEmbeddedKaraokeAudio(EmbeddedKaraokeFile(songID: song.id, url: mixed), for: song))
        await player.seekTask?.value
        XCTAssertNil(player.lastPlaybackError)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.75, accuracy: 0.03)
        XCTAssertEqual(player.embeddedKaraokeFile?.url, mixed)
        XCTAssertEqual(player.currentSong?.id, song.id)
        XCTAssertTrue(player.switchEmbeddedKaraokeAudio(nil, for: song))
        await player.seekTask?.value
        XCTAssertNil(player.lastPlaybackError)
        XCTAssertNil(player.embeddedKaraokeFile)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.75, accuracy: 0.03)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixed.path))
    }

    func testEmbeddedVideoContainerUsesFileTypeWhenServerPathIsOpaque() {
        var song = Song(id: "video", title: "Snowline", fileFormat: .mka, filePath: "/songs/raw", sourceID: "server")
        song.embeddedMediaTracks = .init(audioTracks: [.init(ordinal: 0)], hasVideo: true)
        XCTAssertTrue(song.usesEmbeddedMusicVideo)
        XCTAssertEqual(MusicVideoCompatibilityPolicy.format(for: song, path: song.filePath), .mkv)
        XCTAssertTrue(MusicVideoCompatibilityPolicy.needsConversion(path: song.filePath, for: song))
        song.fileFormat = .m4a
        XCTAssertEqual(MusicVideoCompatibilityPolicy.format(for: song, path: song.filePath), .mp4)
        XCTAssertFalse(MusicVideoCompatibilityPolicy.needsConversion(path: song.filePath, for: song))
        song.mvPath = "clip.webm"
        XCTAssertEqual(MusicVideoCompatibilityPolicy.format(for: song, path: "clip.webm"), .webm)
        XCTAssertEqual(MusicVideoCompatibilityPolicy.format(for: song, path: "演出#2.mkv"), .mkv)
    }
}
