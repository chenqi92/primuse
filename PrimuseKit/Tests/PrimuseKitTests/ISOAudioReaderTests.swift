import Foundation
import Testing
@testable import PrimuseKit

struct ISOAudioReaderTests {
    @Test func dataISOListsMembersWithIndependentStableIdentityAndExtractsExactBytes() async throws {
        let wav = wave()
        let image = iso(["Album/Two.wav": wav, "Album/notes.txt": Data("not music".utf8)])
        let sheet = try #require(await ISOAudioReader.sheet(fileName: "Library.iso", size: Int64(image.count), read: reader(image)))
        #expect(try await ISOAudioReader.sheet(fileName: "Library.iso", size: 0, read: reader(image)) == sheet)
        let track = try #require(sheet.files.first?.tracks.first)
        let selector = try #require(track.isoAudioTrack)
        #expect(sheet.files[0].tracks.count == 1)
        #expect(track.title == "Two")
        #expect(selector.path == "/Album/Two.wav")
        #expect(selector.format == .wav)
        #expect(selector.sampleRate == 44_100)
        #expect(selector.bitDepth == 16)
        #expect(selector.duration == 2.0 / 44_100)
        let expanded = iso(["Album/One.wav": wav, "Album/Two.wav": wav])
        let rescanned = try #require(await ISOAudioReader.sheet(fileName: "Library.iso", size: Int64(expanded.count), read: reader(expanded)))
        let updated = try #require(rescanned.files[0].tracks.first { $0.title == "Two" })
        #expect(track.number != updated.number)
        #expect(track.identityKey == updated.identityKey)
        #expect(TVScanPipelinePolicy.cueSongID(sourceID: "s", path: "opaque", cuePath: "opaque", trackNumber: track.number, imageTrackKey: selector.key)
                == TVScanPipelinePolicy.cueSongID(sourceID: "s", path: "opaque", cuePath: "opaque", trackNumber: updated.number, imageTrackKey: updated.isoAudioTrack?.key))
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ISOAudioReader.extract(track: selector, size: Int64(image.count), to: url, read: reader(image))
        #expect(try Data(contentsOf: url) == wav)
    }

    @Test func jolietUnicodeAndUDFEmbeddedFilesUseTheirRealNames() async throws {
        let wav = wave()
        let image = iso(["音乐/晨光.wav": wav], joliet: true)
        #expect(try await DiscImageFileSystem.files(size: Int64(image.count), read: reader(image)).map(\.path) == ["/音乐/晨光.wav"])
        let udfImage = udf(wav)
        let files = try await DiscImageFileSystem.files(size: Int64(udfImage.count), read: reader(udfImage))
        #expect(files.map(\.path) == ["/晨光.wav"])
        #expect(try await DiscImageFileSystem.read(files[0], offset: 3, length: 8, using: reader(udfImage)) == wav.subdata(in: 3..<11))
    }

    @Test func dataISOPreservesIndividualAlbumsDuringMetadataRestoration() async throws {
        func flac(album: String) -> Data {
            var comments = Data(repeating: 0, count: 8)
            put(&comments, 4, 4, 4)
            for comment in ["TITLE=Morning", "ARTIST=Soloist", "ALBUM=\(album)", "ALBUMARTIST=Ensemble"] {
                let bytes = Data(comment.utf8)
                var length = Data(repeating: 0, count: 4)
                put(&length, 0, Int64(bytes.count), 4)
                comments.append(length); comments.append(bytes)
            }
            var data = Data("fLaC".utf8) + Data([0, 0, 0, 34]) + Data(repeating: 0, count: 34)
            var header = Data([0x84, 0, 0, 0])
            put(&header, 1, Int64(comments.count), 3, big: true)
            data.append(header); data.append(comments)
            return data
        }
        let image = iso(["One.flac": flac(album: "First Album"), "Two.flac": flac(album: "Second Album")])
        let sheet = try #require(await ISOAudioReader.sheet(fileName: "Collection.iso", size: Int64(image.count), read: reader(image)))
        let identities = sheet.files[0].tracks.map { CueTrackIdentity(sheet: sheet, track: $0) }
        #expect(identities.map(\.albumTitle) == ["First Album", "Second Album"])
        #expect(identities.allSatisfy { $0.title == "Morning" && $0.artist == "Soloist" && $0.albumArtist == "Ensemble" })
    }

    @Test func truncatedExtentsAndDirectoryCyclesFailWithoutPublishingTracks() async throws {
        var badExtent = iso(["Music.wav": wave()])
        both(&badExtent, 20 * 2048 + 68 + 2, 0xfffffff0, 4)
        await #expect(throws: DiscImageFileSystem.Failure.truncated) {
            try await DiscImageFileSystem.files(size: Int64(badExtent.count), read: reader(badExtent))
        }
        var cycle = iso(["Album/Music.wav": wave()])
        both(&cycle, 20 * 2048 + 68 + 2, 20, 4)
        await #expect(throws: DiscImageFileSystem.Failure.invalidDirectory) {
            try await DiscImageFileSystem.files(size: Int64(cycle.count), read: reader(cycle))
        }
        let unrelated = iso(["notes.txt": Data("notes".utf8)])
        #expect(try await ISOAudioReader.sheet(fileName: "Data.iso", size: Int64(unrelated.count), read: reader(unrelated)) == nil)
    }

    @Test func dvdAudioTracksShareContinuousTitleAcrossAOBBoundaries() async throws {
        let first = Data([0x12,0x34,0xfe,0xdc,0x01,0x23,0xff,0x00])
        let second = Data([0x00,0x02,0x00,0x03,0xff,0xfe,0xff,0xfd])
        let image = dvdImage(payloads: [first, second], bits: 16, assignment: 1)
        let sheet = try #require(await ISOAudioReader.sheet(fileName: "DVD.iso", size: Int64(image.count), read: reader(image)))
        let tracks = sheet.files[0].tracks
        #expect(tracks.count == 2)
        #expect(tracks[0].startTime == 0)
        #expect(tracks[1].startTime == 1)
        #expect(tracks[1].endTime == 2)
        let selector = try #require(tracks[1].isoAudioTrack)
        #expect(selector.kind == .dvdAudio)
        #expect(selector.sampleRate == 48_000)
        #expect(selector.bitDepth == 16)
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ISOAudioReader.extract(track: selector, size: Int64(image.count), to: url, read: reader(image))
        let pcm = try Data(contentsOf: url)
        #expect(pcm.prefix(4) == Data("RF64".utf8))
        #expect(pcm.count == 104 + 16)
        #expect(try ISOBytes.le(pcm, 20, 8) == Int64(pcm.count - 8))
        #expect(try ISOBytes.le(pcm, 28, 8) == 16)
        #expect(pcm[104..<112] == Data([0x34,0x12, 0xdc,0xfe, 0x23,0x01, 0,0xff]))
    }

    @Test func dvd24BitChannelGroupsAreReorderedToWaveSpeakerOrder() async throws {
        // Assignment 18: group 1 = L R Ls Rs; group 2 = LFE.
        // Storage holds both group-2 samples, then their low bytes, before group 1.
        let packet = Data([0,5, 0,15, 0x50,0xf0,
                           0,1,0,2,0,3,0,4, 0,11,0,12,0,13,0,14,
                           0x10,0x20,0x30,0x40, 0xb0,0xc0,0xd0,0xe0])
        let image = dvdImage(payloads: [packet, packet], bits: 24, assignment: 18)
        let sheet = try #require(await ISOAudioReader.sheet(fileName: "DVD.iso", size: Int64(image.count), read: reader(image)))
        let track = try #require(sheet.files[0].tracks[0].isoAudioTrack)
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ISOAudioReader.extract(track: track, size: Int64(image.count), to: url, read: reader(image))
        let data = try Data(contentsOf: url)
        #expect(try ISOBytes.le(data, 56, 2) == 0xfffe)
        #expect(try ISOBytes.le(data, 58, 2) == 5)
        #expect(try ISOBytes.le(data, 76, 4) == 0x3b)
        let firstFrame = try (0..<5).map { try ISOBytes.le(data, 104 + $0 * 3, 3) }
        #expect(firstFrame == [0x110, 0x220, 0x550, 0x330, 0x440])
    }

    @Test func mlpPayloadIsCopiedLosslesslyAndUnsupportedPCMIsRejected() async throws {
        let audio = Data([0,8,0,0,0xf8,0x72,0x6f,0xbb,1,2,3,4,5,6,7,8])
        let image = dvdImage(payloads: [audio, audio], bits: 0, assignment: 1)
        let sheet = try #require(await ISOAudioReader.sheet(fileName: "MLP.iso", size: Int64(image.count), read: reader(image)))
        let selector = try #require(sheet.files[0].tracks[0].isoAudioTrack)
        #expect(selector.format == .mlp)
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ISOAudioReader.extract(track: selector, size: Int64(image.count), to: url, read: reader(image))
        #expect(try Data(contentsOf: url) == audio + audio)
        let unsupported = dvdImage(payloads: [audio, audio], bits: 20, assignment: 1)
        await #expect(throws: (any Error).self) {
            try await ISOAudioReader.sheet(fileName: "20bit.iso", size: Int64(unsupported.count), read: reader(unsupported))
        }
    }

    @Test func selectorsPersistAndCachedTitlesDoNotCrossSourcesOrImageRevisions() async throws {
        let image = iso(["Music.wav": wave()])
        let sheet = try #require(await ISOAudioReader.sheet(fileName: "data.iso", size: Int64(image.count), read: reader(image)))
        let selector = try #require(sheet.files[0].tracks[0].isoAudioTrack)
        let sourceID = "iso-test-" + UUID().uuidString
        var song = Song(id: "song", title: "Edited", trackNumber: 99, fileFormat: .wav, filePath: "opaque", sourceID: sourceID,
                        fileSize: Int64(image.count), cueSheetPath: "opaque", cueStartTime: 0, isoAudioTrack: selector, revision: "first")
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        #expect(decoded.isoAudioTrack == selector)
        #expect(decoded.isDiscImageTrack && !decoded.isSACDTrack)
        #expect(sheet.track(audioFileName: "opaque", startTime: 0, number: 99, imageTrackKey: selector.key)?.title == "Music")
        let cache = ISOAudioTrackCache()
        let url = try await cache.materialize(song: song, scope: "account-a", read: reader(image))
        defer { try? FileManager.default.removeItem(at: CueSheetScanCache.directory(sourceID: sourceID).deletingLastPathComponent()) }
        #expect(ISOAudioTrackCache.cachedURL(song: song, scope: "account-a") == url)
        #expect(ISOAudioTrackCache.cachedURL(song: song, scope: "account-b") == nil)
        try Data([0]).write(to: url)
        #expect(ISOAudioTrackCache.cachedURL(song: song, scope: "account-a") == nil)
        let rebuilt = try await cache.materialize(song: song, scope: "account-a", read: reader(image))
        #expect(try Data(contentsOf: rebuilt) == wave())
        song.revision = "second"
        #expect(ISOAudioTrackCache.cachedURL(song: song, scope: "account-a") == nil)
        #expect(TVScanPipelinePolicy.sacdScanCandidates(parsedTracks: [], previousTracks: [song], readFailed: true) == [song])
    }

    @Test func televisionExtractsNativeMembersBeforeSelectingTheirDecoder() {
        for (format, decoder) in [(AudioFormat.flac, TVLocalDecoder.sfbAudioEngine), (.mod, .sfbAudioEngine), (.wav, .ffmpeg), (.mlp, .ffmpeg)] {
            #expect(TVPlaybackFormatRoutingPolicy.delivery(for: format, isVideo: false, serverTranscodesWMA: false, isDiscImageTrack: true)
                    == .decodedTemporaryFile(fileExtension: format.rawValue, decoder: decoder, inspectWAVAfterDownload: false))
        }
        #expect(TVPlaybackFormatRoutingPolicy.delivery(for: .mp4, isVideo: true, serverTranscodesWMA: false, isDiscImageTrack: true)
                == .avPlayer(fileExtension: "mp4"))
    }

    @Test func cancellationRemovesIncompleteOutput() async throws {
        let image = iso(["Music.wav": Data(repeating: 1, count: 300_000)])
        let track = ISOAudioTrack(path: "/Music.wav", format: .wav, byteCount: 300_000)
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: CancellationError.self) {
            try await ISOAudioReader.extract(track: track, size: Int64(image.count), to: url) { offset, length in
                if length == 256 * 1024 { throw CancellationError() }
                return image.subdata(in: Int(offset)..<Int(offset + length))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("iso-test-" + UUID().uuidString) }
    private func reader(_ data: Data) -> SACDISOReader.Read {
        { offset, length in
            guard offset >= 0, length >= 0, offset + length <= data.count else { throw DiscImageFileSystem.Failure.truncated }
            return data.subdata(in: Int(offset)..<Int(offset + length))
        }
    }
    private func put(_ data: inout Data, _ offset: Int, _ value: Int64, _ count: Int, big: Bool = false) {
        for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (big ? count - i - 1 : i))) }
    }
    private func both(_ data: inout Data, _ offset: Int, _ value: Int64, _ count: Int) {
        put(&data, offset, value, count); put(&data, offset + count, value, count, big: true)
    }
    private func wave() -> Data {
        var data = Data(repeating: 0, count: 52)
        data.replaceSubrange(0..<4, with: Data("RIFF".utf8)); put(&data, 4, 44, 4)
        data.replaceSubrange(8..<16, with: Data("WAVEfmt ".utf8)); put(&data, 16, 16, 4)
        put(&data, 20, 1, 2); put(&data, 22, 2, 2); put(&data, 24, 44_100, 4)
        put(&data, 28, 176_400, 4); put(&data, 32, 4, 2); put(&data, 34, 16, 2)
        data.replaceSubrange(36..<40, with: Data("data".utf8)); put(&data, 40, 8, 4)
        return data
    }
    private func iso(_ contents: [String: Data], joliet: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 512 * 2048)
        let folders = Set(contents.keys.map { ($0 as NSString).deletingLastPathComponent }).subtracting([""]).sorted()
        let directories = [""] + folders
        var sectors = Dictionary(uniqueKeysWithValues: directories.enumerated().map { ($0.element, 20 + $0.offset) })
        var next = 32
        for (path, bytes) in contents.sorted(by: { $0.key < $1.key }) {
            sectors[path] = next
            data.replaceSubrange((next * 2048)..<(next * 2048 + bytes.count), with: bytes)
            next += (bytes.count + 2047) / 2048
        }
        func record(_ name: Data, _ sector: Int, _ size: Int, _ directory: Bool) -> Data {
            var record = Data(repeating: 0, count: 33 + name.count + (name.count % 2 == 0 ? 1 : 0))
            record[0] = UInt8(record.count); both(&record, 2, Int64(sector), 4); both(&record, 10, Int64(size), 4)
            record[25] = directory ? 2 : 0; both(&record, 28, 1, 2); record[32] = UInt8(name.count)
            record.replaceSubrange(33..<(33 + name.count), with: name)
            return record
        }
        for directory in directories {
            let sector = sectors[directory]!
            var listing = record(Data([0]), sector, 2048, true) + record(Data([1]), 20, 2048, true)
            let children = directories.filter { !$0.isEmpty && ($0 as NSString).deletingLastPathComponent == directory }
                + contents.keys.filter { ($0 as NSString).deletingLastPathComponent == directory }.sorted()
            for child in children {
                let isDirectory = contents[child] == nil
                let name = (child as NSString).lastPathComponent + (isDirectory ? "" : ";1")
                listing += record(name.data(using: joliet ? .utf16BigEndian : .isoLatin1)!, sectors[child]!, contents[child]?.count ?? 2048, isDirectory)
            }
            data.replaceSubrange((sector * 2048)..<(sector * 2048 + listing.count), with: listing)
        }
        let p = 16 * 2048
        data[p] = joliet ? 2 : 1; data.replaceSubrange((p + 1)..<(p + 6), with: Data("CD001".utf8)); data[p + 6] = 1
        if joliet { data.replaceSubrange((p + 88)..<(p + 91), with: Data([0x25,0x2f,0x45])) }
        both(&data, p + 128, 2048, 2)
        data.replaceSubrange((p + 156)..<(p + 190), with: record(Data([0]), 20, 2048, true))
        data[17 * 2048] = 255; data.replaceSubrange((17 * 2048 + 1)..<(17 * 2048 + 6), with: Data("CD001".utf8))
        return data
    }
    private func udf(_ audio: Data) -> Data {
        var data = Data(repeating: 0, count: 512 * 2048)
        func descriptor(_ sector: Int, _ id: Int64, _ body: (inout Data) -> Void) {
            var block = Data(repeating: 0, count: 2048); put(&block, 0, id, 2); put(&block, 2, 2, 2)
            body(&block); block[4] = (0..<16).filter { $0 != 4 }.reduce(UInt8(0)) { $0 &+ block[$1] }
            data.replaceSubrange((sector * 2048)..<((sector + 1) * 2048), with: block)
        }
        for (index, name) in ["BEA01", "NSR02", "TEA01"].enumerated() {
            data.replaceSubrange(((16 + index) * 2048 + 1)..<((16 + index) * 2048 + 6), with: Data(name.utf8))
        }
        descriptor(256, 2) { put(&$0, 16, 3 * 2048, 4); put(&$0, 20, 260, 4) }
        descriptor(260, 5) { put(&$0, 22, 0, 2); put(&$0, 188, 300, 4); put(&$0, 192, 100, 4) }
        descriptor(261, 6) {
            put(&$0, 212, 2048, 4); put(&$0, 252, 0, 4); put(&$0, 256, 0, 2)
            put(&$0, 264, 6, 4); put(&$0, 268, 1, 4); $0[440] = 1; $0[441] = 6
        }
        descriptor(262, 8) { _ in }
        descriptor(300, 256) { put(&$0, 404, 1, 4) }
        let name = Data([16]) + "晨光.wav".data(using: .utf16BigEndian)!
        let length = (38 + name.count + 3) & ~3
        descriptor(301, 261) {
            $0[27] = 4; put(&$0, 34, 3, 2); put(&$0, 56, Int64(length), 8); put(&$0, 172, Int64(length), 4)
            put(&$0, 176, 257, 2); $0[176 + 19] = UInt8(name.count); put(&$0, 176 + 24, 2, 4)
            $0.replaceSubrange((176 + 38)..<(176 + 38 + name.count), with: name)
        }
        descriptor(302, 261) {
            $0[27] = 5; put(&$0, 34, 3, 2); put(&$0, 56, Int64(audio.count), 8); put(&$0, 172, Int64(audio.count), 4)
            $0.replaceSubrange(176..<(176 + audio.count), with: audio)
        }
        return data
    }
    private func dvdImage(payloads: [Data], bits: Int, assignment: Int) -> Data {
        var ifo = Data(repeating: 0, count: 4096)
        ifo.replaceSubrange(0..<12, with: Data("DVDAUDIO-ATS".utf8)); put(&ifo, 204, 1, 4, big: true)
        put(&ifo, 2048, 1, 2, big: true); put(&ifo, 2052, 2047, 4, big: true); put(&ifo, 2060, 16, 4, big: true)
        let title = 2064
        ifo[title + 2] = 2; ifo[title + 3] = 2; put(&ifo, title + 14, 56, 2, big: true)
        for i in 0..<2 {
            put(&ifo, title + 16 + i * 20 + 6, Int64(i * 90_000), 4, big: true)
            put(&ifo, title + 16 + i * 20 + 10, 90_000, 4, big: true)
            put(&ifo, title + 56 + i * 12 + 4, Int64(i), 4, big: true)
            put(&ifo, title + 56 + i * 12 + 8, Int64(i), 4, big: true)
        }
        func sector(_ audio: Data) -> Data {
            var packet = Data(repeating: 0, count: 12)
            packet[0] = bits == 0 ? 0xa1 : 0xa0; packet[3] = 8
            let group2 = assignment > 1
            packet[7] = UInt8((max(16, bits) - 16) / 4 * 16 + (group2 ? (max(16, bits) - 16) / 4 : 15))
            packet[8] = group2 ? 0 : 15; packet[10] = UInt8(assignment); packet += audio
            var sector = Data(repeating: 0, count: 2048)
            sector.replaceSubrange(0..<4, with: Data([0,0,1,0xba])); sector[4] = 0x44; sector[13] = 0xf8
            sector.replaceSubrange(14..<18, with: Data([0,0,1,0xbd])); put(&sector, 18, Int64(packet.count + 3), 2, big: true)
            sector[20] = 0x80; sector.replaceSubrange(23..<(23 + packet.count), with: packet)
            let end = 23 + packet.count
            sector.replaceSubrange(end..<(end + 4), with: Data([0,0,1,0xbe])); put(&sector, end + 4, Int64(2048 - end - 6), 2, big: true)
            return sector
        }
        return iso(["AUDIO_TS/ATS_01_0.IFO": ifo, "AUDIO_TS/ATS_01_1.AOB": sector(payloads[0]), "AUDIO_TS/ATS_01_2.AOB": sector(payloads[1])])
    }
}
