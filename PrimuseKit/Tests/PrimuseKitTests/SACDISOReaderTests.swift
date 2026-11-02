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

    @Test
    func extractsOnlySelectedTrackWithoutChangingDSDBits() async throws {
        let image = fixture()
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
        #expect(await reader.audioReadOffsets.allSatisfy { $0 >= 546 * 2048 })
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
        let database = try IncrementalSongStore(path: ":memory:")
        try database.replaceAll(with: [song])
        let stored = try #require(database.loadSongs().first)
        #expect(stored.trackNumber == 99)
        #expect(stored.sacdTrackNumber == 2)
        let cache = SACDTrackCache()
        let url = try await cache.materialize(song: stored) { try await reader.read($0, $1) }
        #expect(try Data(contentsOf: url).suffix(9408) == Data(repeating: 0x96, count: 9408))
        let reused = try await cache.materialize(song: stored) { _, _ in throw CancellationError() }
        #expect(reused == url)
        song.lastModified = Date()
        #expect(SACDTrackCache.cachedURL(song: song) == nil)
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
    private func fixture(rawSectors: Bool = false, dst: Bool = false) -> Data {
        var image = Data(repeating: 0, count: 552 * 2048)
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
        text(&image, area, "TWOCHTOC")
        image[area + 8] = 1
        put(&image, area + 10, 4, bytes: 2)
        image[area + 20] = 4; image[area + 32] = 2; image[area + 69] = 2; image[area + 90] = 2
        put(&image, area + 72, 540, bytes: 4)
        put(&image, area + 76, 551, bytes: 4)
        text(&image, 521 * 2048, "SACDTRL1")
        text(&image, 522 * 2048, "SACDTRL2")
        text(&image, 523 * 2048, "SACDTTxt")
        for track in 0..<2 {
            put(&image, 521 * 2048 + 8 + track * 4, 540 + track * 6, bytes: 4)
            put(&image, 521 * 2048 + 1028 + track * 4, 6, bytes: 4)
            image[522 * 2048 + 8 + track * 4 + 2] = UInt8(track)
            image[522 * 2048 + 1028 + track * 4 + 2] = 1
            let nameOffset = 64 + track * 32
            put(&image, 523 * 2048 + 8 + track * 2, nameOffset, bytes: 2)
            image[523 * 2048 + nameOffset] = 1
            image[523 * 2048 + nameOffset + 4] = 1
            image[523 * 2048 + nameOffset + 5] = 0x20
            text(&image, 523 * 2048 + nameOffset + 6, track == 0 ? "One" : "Two")
            var remaining = dst ? 11 : 9408
            for sector in 0..<6 {
                let base = (540 + track * 6 + sector) * 2048
                guard remaining > 0 else { continue }
                let length = min(1800, remaining)
                image[base] = sector == 0 ? (dst ? 0x25 : 0x24) : (dst ? 0x21 : 0x20)
                image[base + 1] = UInt8((sector == 0 ? 0x90 : 0x10) | (length >> 8))
                image[base + 2] = UInt8(truncatingIfNeeded: length)
                let payload = base + 3 + (sector == 0 ? (dst ? 4 : 3) : 0)
                if sector == 0 { image[base + 5] = UInt8(track) }
                image.replaceSubrange(payload..<(payload + length), with: repeatElement(UInt8(track == 0 ? 0x69 : 0x96), count: length))
                remaining -= length
            }
        }
        guard rawSectors else { return image }
        var raw = Data()
        for sector in 0..<552 {
            raw += Data(repeating: 0, count: 12)
            raw += image.subdata(in: (sector * 2048)..<((sector + 1) * 2048))
            raw += Data(repeating: 0, count: 4)
        }
        return raw
    }
}
