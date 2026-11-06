import Foundation
import Testing
@testable import PrimuseKit

@Suite("SACD ISO bounded reads and track extraction")
struct SACDISOReaderTests {
    @Test(arguments: [false, true])
    func readsDiscAndTracks(rawSectors: Bool) async throws {
        let image = fixture(rawSectors: rawSectors)
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count), read: { try await reader.read($0, $1) })
        #expect(disc.title == "Album")
        #expect(disc.performer == "Artist")
        #expect(disc.channels == 2)
        #expect(disc.year == 2020)
        #expect(disc.tracks.map(\.title) == ["One", "Two"])
        #expect(disc.tracks.map(\.firstSector) == [540, 546])
        #expect(disc.tracks.map(\.frameCount) == [1, 1])
        #expect(await reader.largestRead < 64 * 1024)
        let cue = disc.cueSheet(fileName: "Album.iso")
        #expect(cue.files[0].tracks.map(\.startTime) == [0, 0])
        #expect(cue.files[0].tracks[1].endTime == 1.0 / 75)
    }

    @Test(arguments: [false, true])
    func extractsOnlySelectedTrackWithoutChangingDSDBits(rawSectors: Bool) async throws {
        let image = fixture(rawSectors: rawSectors)
        let reader = Reads(image, shortReads: true)
        let disc = try await SACDISOReader.open(size: Int64(image.count), read: { try await reader.read($0, $1) })
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SACDISOReader.extract(disc: disc, trackNumber: 2, to: url, read: { try await reader.read($0, $1) })
        let dff = try Data(contentsOf: url)
        #expect(dff.prefix(4) == Data("FRM8".utf8))
        #expect(bigEndian(dff, 4, 8) == dff.count - 12)
        let compression = try #require(dff.range(of: Data("CMPR".utf8))?.lowerBound)
        #expect(dff[compression + 16] > 0)
        #expect(Int(dff[compression + 16]) + 5 == bigEndian(dff, compression + 4, 8))
        #expect(dff.suffix(9408) == Data(repeating: 0x96, count: 9408))
        #expect(await reader.audioReadOffsets.allSatisfy { $0 >= 546 * (rawSectors ? 2064 : 2048) })
    }

    @Test
    func retainsDSTFramesAndWritesFrameCount() async throws {
        let image = fixture(dst: true)
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count), read: { try await reader.read($0, $1) })
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url, read: { try await reader.read($0, $1) })
        let dff = try Data(contentsOf: url)
        let frameCount = try #require(dff.range(of: Data("FRTE".utf8))?.lowerBound)
        #expect(bigEndian(dff, frameCount + 12, 4) == 1)
        let packet = try #require(dff.range(of: Data("DSTF".utf8))?.lowerBound)
        #expect(bigEndian(dff, packet + 4, 8) == 11)
        #expect(dff.subdata(in: (packet + 12)..<(packet + 23)) == Data(repeating: 0x69, count: 11))
        #expect(bigEndian(dff, 4, 8) == dff.count - 12)
    }

    @Test
    func rejectsOtherImagesAndOutOfBoundsTables() async throws {
        let ordinary = Reads(Data(repeating: 0, count: 2 * 1024 * 1024))
        await #expect(throws: SACDISOReader.Failure.notSACD) {
            try await SACDISOReader.open(size: 2 * 1024 * 1024, read: { try await ordinary.read($0, $1) })
        }
        var corrupt = fixture()
        put(&corrupt, 521 * 2048 + 8, 0xffffffff, bytes: 4)
        let reader = Reads(corrupt)
        await #expect(throws: SACDISOReader.Failure.invalidTable) {
            try await SACDISOReader.open(size: Int64(corrupt.count), read: { try await reader.read($0, $1) })
        }
    }

    @Test
    func removesPartialOutputAfterTruncatedFrame() async throws {
        var image = fixture()
        image[540 * 2048 + 1] = 0x97
        image[540 * 2048 + 2] = 0xff
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count), read: { try await reader.read($0, $1) })
        let url = temporaryURL()
        await #expect(throws: SACDISOReader.Failure.invalidPacket) {
            try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url, read: { try await reader.read($0, $1) })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func cancellationAndMissingTracksDoNotProduceFiles() async throws {
        let image = fixture()
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count), read: { try await reader.read($0, $1) })
        let url = temporaryURL()
        await #expect(throws: SACDISOReader.Failure.missingTrack) {
            try await SACDISOReader.extract(disc: disc, trackNumber: 9, to: url, read: { try await reader.read($0, $1) })
        }
        await #expect(throws: CancellationError.self) {
            try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url) { _, _ in throw CancellationError() }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func modelPersistsIndependentTracks() throws {
        let song = Song(id: "track2", title: "Two", trackNumber: 2, duration: 1, fileFormat: .sacdISO,
                        filePath: "Album.iso", sourceID: "local", fileSize: 1_500_000,
                        cueSheetPath: "Album.iso", cueStartTime: 0, cueEndTime: 1, sacdTrackNumber: 2)
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        #expect(restored.sacdTrackNumber == 2)
        #expect(restored.isSACDTrack)
        #expect(restored.isCueTrack)
        #expect(restored.audioQuality == .dsd)
        #expect(AudioFormat.from(fileExtension: "ISO") == .sacdISO)
        #expect(restored.fileFormat.requiresFFmpeg)
        #expect(TVPlaybackFormatRoutingPolicy.delivery(for: .sacdISO, isVideo: false, serverTranscodesWMA: false)
            == .decodedTemporaryFile(fileExtension: "iso", decoder: .sfbAudioEngine, inspectWAVAfterDownload: false))
        #expect(!PreparedPlaybackStartPolicy.allowsPreparation(
            streamsByRange: true, startsMidFile: false, format: .sacdISO, requiresCompleteLocalFile: false,
            isEpisodeOrStreamDescriptor: false, hasMusicVideo: false, queuePrefetchEnabled: true, audioCacheEnabled: true
        ))
    }

    @Test
    func editedTrackTagsPreservePlaybackSelectionAndCache() async throws {
        let image = fixture()
        let reader = Reads(image)
        let sourceID = "sacd-test-" + UUID().uuidString
        var song = Song(id: "two", title: "Two", trackNumber: 2, fileFormat: .sacdISO,
                        filePath: "Album.iso", sourceID: sourceID, fileSize: Int64(image.count),
                        cueSheetPath: "Album.iso", cueStartTime: 0, cueEndTime: 1.0 / 75, sacdTrackNumber: 2)
        let directory = CueSheetScanCache.directory(sourceID: sourceID).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        song.trackNumber = 99
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try IncrementalSongStore(path: directory.appendingPathComponent("songs.sqlite").path)
        try database.replaceAll(with: [song])
        let stored = try #require(database.loadSongs().first)
        #expect(stored.trackNumber == 99)
        #expect(stored.sacdTrackNumber == 2)
        let cache = SACDTrackCache()
        let url = try await cache.materialize(song: stored, scope: "source-a") { try await reader.read($0, $1) }
        #expect(try Data(contentsOf: url).suffix(9408) == Data(repeating: 0x96, count: 9408))
        let reused = try await cache.materialize(song: stored, scope: "source-a") { _, _ in throw CancellationError() }
        #expect(reused == url)
        song.lastModified = Date()
        #expect(SACDTrackCache.cachedURL(song: song, scope: "source-a") == nil)
    }

    @Test
    func backupTablesAndMultichannelFallback() async throws {
        var image = fixture()
        put(&image, 510 * 2048 + 64, 519, bytes: 4)
        put(&image, 510 * 2048 + 68, 520, bytes: 4)
        var reader = Reads(image)
        let backup = try await SACDISOReader.open(size: Int64(image.count), read: { [reader] in try await reader.read($0, $1) })
        #expect(backup.channels == 2)
        put(&image, 510 * 2048 + 64, 0, bytes: 4)
        put(&image, 510 * 2048 + 68, 0, bytes: 4)
        put(&image, 510 * 2048 + 72, 520, bytes: 4)
        text(&image, 520 * 2048, "MULCHTOC")
        image[520 * 2048 + 32] = 6
        reader = Reads(image)
        let multichannel = try await SACDISOReader.open(size: Int64(image.count), read: { [reader] in try await reader.read($0, $1) })
        #expect(multichannel.channels == 6)
        image.replaceSubrange((524 * 2048)..<(528 * 2048), with: image.subdata(in: (520 * 2048)..<(524 * 2048)))
        put(&image, 510 * 2048 + 64, 520, bytes: 4)
        put(&image, 510 * 2048 + 72, 524, bytes: 4)
        text(&image, 524 * 2048, "TWOCHTOC")
        image[524 * 2048 + 32] = 2
        reader = Reads(image)
        let preferred = try await SACDISOReader.open(size: Int64(image.count), read: { [reader] in try await reader.read($0, $1) })
        #expect(preferred.channels == 2)
    }

    @Test
    func transportErrorsRemainRetryable() async throws {
        let image = fixture()
        let reader = Reads(image)
        await #expect(throws: URLError.self) {
            try await SACDISOReader.open(size: Int64(image.count)) { offset, length in
                if offset == 520 * 2048 { throw URLError(.timedOut) }
                return try await reader.read(offset, length)
            }
        }
    }

    @Test
    func outOfBoundsPrimaryTOCUsesBackupWithoutReadingOutsideImage() async throws {
        var image = fixture()
        put(&image, 510 * 2048 + 64, 0xffffffff, bytes: 4)
        put(&image, 510 * 2048 + 68, 520, bytes: 4)
        let reader = Reads(image)
        let size = Int64(image.count)
        let disc = try await SACDISOReader.open(size: size) { offset, length in
            guard offset >= 0, offset + length <= size else { throw URLError(.badServerResponse) }
            return try await reader.read(offset, length)
        }
        #expect(disc.tracks.count == 2)
    }

    @Test
    func fillsMissingMetadataFromOtherTextLanguages() async throws {
        var image = fixture()
        image.replaceSubrange((512 * 2048)..<(513 * 2048), with: image.subdata(in: (511 * 2048)..<(512 * 2048)))
        image.replaceSubrange((511 * 2048 + 16)..<(511 * 2048 + 48), with: repeatElement(0, count: 32))
        image[510 * 2048 + 128] = 2
        image[510 * 2048 + 142] = 2
        image.replaceSubrange((524 * 2048)..<(525 * 2048), with: image.subdata(in: (523 * 2048)..<(524 * 2048)))
        put(&image, 523 * 2048 + 8, 0, bytes: 4)
        put(&image, 520 * 2048 + 10, 5, bytes: 2)
        image[520 * 2048 + 80] = 2
        image[520 * 2048 + 94] = 2
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        #expect(disc.title == "Album")
        #expect(disc.performer == "Artist")
        #expect(disc.tracks.map(\.title) == ["One", "Two"])
    }

    @Test
    func boundsTrackTextByNextTrackAndNextTable() async throws {
        var image = fixture()
        // A damaged field count must not consume the following track's metadata.
        image[523 * 2048 + 64] = 3
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        #expect(disc.tracks.map(\.title) == ["One", "Two"])
    }

    @Test
    func readsTextOffsetsAcrossSectors() async throws {
        var image = fixture()
        put(&image, 520 * 2048 + 10, 5, bytes: 2)
        let original = image.subdata(in: (523 * 2048 + 64)..<(523 * 2048 + 128))
        image.replaceSubrange((524 * 2048 + 64)..<(524 * 2048 + 128), with: original)
        put(&image, 523 * 2048 + 8, 2048 + 64, bytes: 2)
        put(&image, 523 * 2048 + 10, 2048 + 96, bytes: 2)
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        #expect(disc.tracks.map(\.title) == ["One", "Two"])
    }

    @Test(arguments: [3, 4, 5, 6])
    func readsAsianTextCharsets(charset: Int) async throws {
        var image = fixture()
        let bytes: [Int: [UInt8]] = [3: [137, 185], 4: [235, 229], 5: [210, 244], 6: [173, 181]]
        image[510 * 2048 + 138] = UInt8(charset)
        image[520 * 2048 + 90] = UInt8(charset)
        for position in [511 * 2048 + 64, 523 * 2048 + 64 + 6] {
            image.replaceSubrange(position..<(position + 3), with: bytes[charset]! + [0])
        }
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        #expect(disc.title == "音")
        #expect(disc.tracks[0].title == "音")
    }

    @Test
    func rejectsIncompleteDSTFrameAndRemovesOutput() async throws {
        var image = fixture(dst: true)
        image[540 * 2048 + 6] = 2 << 2
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: SACDISOReader.Failure.truncated) {
            try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url) { try await reader.read($0, $1) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func rejectsCompressionChangesInsideFrame() async throws {
        var image = fixture()
        image[541 * 2048] |= 1
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: SACDISOReader.Failure.unsupportedAudio) {
            try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url) { try await reader.read($0, $1) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [5, 6])
    func extractsMultichannelDSD(channels: Int) async throws {
        let image = fixture(channels: channels)
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SACDISOReader.extract(disc: disc, trackNumber: 2, to: url) { try await reader.read($0, $1) }
        let dff = try Data(contentsOf: url)
        let channelChunk = try #require(dff.range(of: Data("CHNL".utf8))?.lowerBound)
        #expect(bigEndian(dff, channelChunk + 12, 2) == channels)
        #expect(dff.suffix(channels * 4704) == Data(repeating: 0x96, count: channels * 4704))
    }

    @Test(arguments: [5, 6])
    func validatesMultichannelDSTFrameHeaders(channels: Int) async throws {
        var image = fixture(dst: true, channels: channels)
        var reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { [reader] in try await reader.read($0, $1) }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url) { [reader] in try await reader.read($0, $1) }
        image[540 * 2048 + 6] = 4 // A stereo frame cannot be labelled as multichannel audio.
        reader = Reads(image)
        await #expect(throws: SACDISOReader.Failure.unsupportedAudio) {
            try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url) { [reader] in try await reader.read($0, $1) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func extractsMultipleDSTFramesWithPaddingInOneSector() async throws {
        var image = fixture(dst: true)
        let base = 540 * 2048
        image.replaceSubrange(base..<(base + 2048), with: repeatElement(0, count: 2048))
        image[base] = 0x69 // Three packets, two audio frame starts, DST.
        let bytes: [UInt8] = [0x38, 3, 0x90, 11, 0x90, 13, 0, 0, 0, 4, 0, 0, 1, 4]
        image.replaceSubrange((base + 1)..<(base + 15), with: bytes)
        image.replaceSubrange((base + 18)..<(base + 29), with: repeatElement(0x69, count: 11))
        image.replaceSubrange((base + 29)..<(base + 42), with: repeatElement(0x96, count: 13))
        image[522 * 2048 + 1028 + 2] = 2
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SACDISOReader.extract(disc: disc, trackNumber: 1, to: url) { try await reader.read($0, $1) }
        let dff = try Data(contentsOf: url)
        let frte = try #require(dff.range(of: Data("FRTE".utf8))?.lowerBound)
        let first = frte + 18
        #expect(bigEndian(dff, frte + 12, 4) == 2)
        #expect(bigEndian(dff, first + 4, 8) == 11)
        #expect(dff.subdata(in: (first + 12)..<(first + 23)) == Data(repeating: 0x69, count: 11))
        let second = first + 24
        #expect(dff.subdata(in: second..<(second + 4)) == Data("DSTF".utf8))
        #expect(bigEndian(dff, second + 4, 8) == 13)
        #expect(dff.subdata(in: (second + 12)..<(second + 25)) == Data(repeating: 0x96, count: 13))
    }

    @Test
    func changedSourceScopeCannotReuseExtractedAudio() async throws {
        let image = fixture()
        let reader = Reads(image)
        let sourceID = "sacd-test-" + UUID().uuidString
        let song = Song(id: "one", title: "One", fileFormat: .sacdISO, filePath: "Album.iso", sourceID: sourceID,
                        fileSize: Int64(image.count), cueSheetPath: "Album.iso", cueStartTime: 0,
                        cueEndTime: 1.0 / 75, sacdTrackNumber: 1)
        let directory = CueSheetScanCache.directory(sourceID: sourceID).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SACDTrackCache()
        let old = try await cache.materialize(song: song, scope: "old-server") { try await reader.read($0, $1) }
        #expect(SACDTrackCache.cachedURL(song: song, scope: "old-server") == old)
        #expect(SACDTrackCache.cachedURL(song: song, scope: "new-server") == nil)
        await #expect(throws: URLError.self) {
            try await cache.materialize(song: song, scope: "new-server") { _, _ in throw URLError(.notConnectedToInternet) }
        }
        #expect(SACDTrackCache.cachedURL(song: song, scope: "new-server") == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: old.deletingLastPathComponent(),
                                                          includingPropertiesForKeys: nil).count == 1)
    }

    @Test
    func truncatedCacheIsRebuiltAndCancelledExtractionLeavesNoPartialFile() async throws {
        let image = fixture()
        let reader = Reads(image)
        let sourceID = "sacd-test-" + UUID().uuidString
        let song = Song(id: "two", title: "Two", fileFormat: .sacdISO, filePath: "Album.iso", sourceID: sourceID,
                        fileSize: Int64(image.count), cueSheetPath: "Album.iso", cueStartTime: 0,
                        cueEndTime: 1.0 / 75, sacdTrackNumber: 2)
        let directory = CueSheetScanCache.directory(sourceID: sourceID).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SACDTrackCache()
        let url = try await cache.materialize(song: song, scope: "source") { try await reader.read($0, $1) }
        let complete = try Data(contentsOf: url)
        try complete.prefix(complete.count - 7).write(to: url)
        #expect(SACDTrackCache.cachedURL(song: song, scope: "source") == nil)
        await #expect(throws: CancellationError.self) {
            try await cache.materialize(song: song, scope: "source") { offset, length in
                if offset >= 546 * 2048 { throw CancellationError() }
                return try await reader.read(offset, length)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                          includingPropertiesForKeys: nil).count == 1)
        let rebuilt = try await cache.materialize(song: song, scope: "source") { try await reader.read($0, $1) }
        #expect(rebuilt == url)
        #expect(try Data(contentsOf: rebuilt) == complete)
        #expect(SACDTrackCache.cachedURL(song: song, scope: "source") == url)
    }

    @Test
    func externalCUEDoesNotDuplicateISOTracksOrApplyWholeDiscOffsets() async throws {
        let image = fixture()
        let reader = Reads(image)
        let disc = try await SACDISOReader.open(size: Int64(image.count)) { try await reader.read($0, $1) }
        let embedded = disc.cueSheet(fileName: "Album.ISO")
        let external = try #require(CueSheetParser.parse(data: Data("""
        FILE "Album.ISO" WAVE
          TRACK 01 AUDIO
            TITLE "External One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "External Two"
            INDEX 01 03:20:00
        """.utf8)))
        for reverseOrder in [false, true] {
            var sheets = [("Album.cue", external), ("Album.ISO", embedded)]
            if reverseOrder { sheets.reverse() }
            let tracks = sheets.flatMap { name, sheet in
                sheet.filesForScanning(sheetFileName: name).flatMap(\.tracks)
            }
            #expect(tracks.map(\.number) == [1, 2])
            #expect(tracks.map(\.title) == ["One", "Two"])
            #expect(tracks.map(\.startTime) == [0, 0])
            #expect(tracks.map(\.endTime) == [1.0 / 75, 1.0 / 75])
        }
    }

    @Test
    func mixedCUEKeepsOrdinaryAudioImagesButCannotAdmitUnrecognizedISO() throws {
        let sheet = try #require(CueSheetParser.parse(data: Data(#"""
        FILE "disc\Other.ISO" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "Music.flac" WAVE
          TRACK 02 AUDIO
            INDEX 01 01:30:00
        """#.utf8)))
        let files = sheet.filesForScanning(sheetFileName: "Album.CUE")
        #expect(files.map(\.name) == ["Music.flac"])
        #expect(files.flatMap(\.tracks).map(\.startTime) == [90])
        #expect(sheet.files.count == 2)
    }

    private actor Reads {
        let image: Data
        let shortReads: Bool
        var largestRead = 0
        var audioReadOffsets: [Int64] = []
        init(_ image: Data, shortReads: Bool = false) { self.image = image; self.shortReads = shortReads }
        func read(_ offset: Int64, _ length: Int64) throws -> Data {
            largestRead = max(largestRead, Int(length))
            if offset >= 540 * 2048 { audioReadOffsets.append(offset) }
            guard offset >= 0, offset < image.count else { return Data() }
            let count = min(Int(length), image.count - Int(offset), shortReads ? 997 : Int.max)
            return image.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }

    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dff") }
    private func put(_ data: inout Data, _ offset: Int, _ value: Int, bytes: Int) {
        for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((bytes - index - 1) * 8)) }
    }
    private func text(_ data: inout Data, _ offset: Int, _ value: String) {
        data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
    }
    private func bigEndian(_ data: Data, _ offset: Int, _ bytes: Int) -> Int {
        data[offset..<(offset + bytes)].reduce(0) { $0 * 256 + Int($1) }
    }
    private func fixture(rawSectors: Bool = false, dst: Bool = false, channels: Int = 2) -> Data {
        let sectorsPerTrack = max(6, (channels * 4704 + 1799) / 1800)
        let sectorCount = 540 + 2 * sectorsPerTrack
        var image = Data(repeating: 0, count: sectorCount * 2048)
        let master = 510 * 2048, area = 520 * 2048
        text(&image, master, "SACDMTOC")
        image[master + 8] = 1
        put(&image, master + 64, 520, bytes: 4)
        put(&image, master + 120, 2020, bytes: 2)
        image[master + 128] = 1; image[master + 138] = 2
        text(&image, 511 * 2048, "SACDText")
        put(&image, 511 * 2048 + 16, 64, bytes: 2)
        put(&image, 511 * 2048 + 18, 80, bytes: 2)
        text(&image, 511 * 2048 + 64, "Album")
        text(&image, 511 * 2048 + 80, "Artist")
        text(&image, area, channels == 2 ? "TWOCHTOC" : "MULCHTOC")
        image[area + 8] = 1
        put(&image, area + 10, 4, bytes: 2)
        image[area + 20] = 4; image[area + 32] = UInt8(channels); image[area + 69] = 2; image[area + 90] = 2
        image[area + 21] = dst ? 0 : 2
        put(&image, area + 72, 540, bytes: 4)
        put(&image, area + 76, sectorCount - 1, bytes: 4)
        text(&image, 521 * 2048, "SACDTRL1")
        text(&image, 522 * 2048, "SACDTRL2")
        text(&image, 523 * 2048, "SACDTTxt")
        for track in 0..<2 {
            put(&image, 521 * 2048 + 8 + track * 4, 540 + track * sectorsPerTrack, bytes: 4)
            put(&image, 521 * 2048 + 1028 + track * 4, sectorsPerTrack, bytes: 4)
            image[522 * 2048 + 8 + track * 4 + 2] = UInt8(track)
            image[522 * 2048 + 1028 + track * 4 + 2] = 1
            let nameOffset = 64 + track * 32
            put(&image, 523 * 2048 + 8 + track * 2, nameOffset, bytes: 2)
            image[523 * 2048 + nameOffset] = 1
            image[523 * 2048 + nameOffset + 4] = 1
            image[523 * 2048 + nameOffset + 5] = 0x20
            text(&image, 523 * 2048 + nameOffset + 6, track == 0 ? "One" : "Two")
            var remaining = dst ? 11 : channels * 4704
            for sector in 0..<sectorsPerTrack {
                let base = (540 + track * sectorsPerTrack + sector) * 2048
                guard remaining > 0 else { continue }
                let length = min(1800, remaining)
                image[base] = sector == 0 ? (dst ? 0x25 : 0x24) : (dst ? 0x21 : 0x20)
                image[base + 1] = UInt8((sector == 0 ? 0x90 : 0x10) | (length >> 8))
                image[base + 2] = UInt8(truncatingIfNeeded: length)
                let payload = base + 3 + (sector == 0 ? (dst ? 4 : 3) : 0)
                if sector == 0 { image[base + 5] = UInt8(track) }
                if sector == 0, dst { image[base + 6] = 4 | (channels == 6 ? 2 : channels == 5 ? 1 : 0) }
                image.replaceSubrange(payload..<(payload + length), with: repeatElement(UInt8(track == 0 ? 0x69 : 0x96), count: length))
                remaining -= length
            }
        }
        guard rawSectors else { return image }
        var raw = Data()
        for sector in 0..<sectorCount {
            raw += Data(repeating: 0, count: 12)
            raw += image.subdata(in: (sector * 2048)..<((sector + 1) * 2048))
            raw += Data(repeating: 0, count: 4)
        }
        return raw
    }
}
