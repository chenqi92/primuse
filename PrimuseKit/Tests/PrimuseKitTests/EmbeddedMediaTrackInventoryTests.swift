import Foundation
import Testing
@testable import PrimuseKit

@Suite("Embedded audio tracks and music videos")
struct EmbeddedMediaTrackInventoryTests {
    private func number(_ value: Int, bytes: Int = 4) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    private func box(_ type: String, _ body: Data) -> Data {
        number(body.count + 8) + Data(type.utf8) + body
    }

    private func track(_ id: Int, _ type: String, _ name: String, codec: String = "mp4a",
                       count: Int = 12, reference: (String, Int)? = nil) -> Data {
        let header = number(1) + Data(repeating: 0, count: 8) + number(id)
        let handler = Data(repeating: 0, count: 8) + Data(type.utf8) + Data(repeating: 0, count: 12)
            + Data(name.utf8) + Data([0])
        let description = box("stsd", number(0) + number(1) + box(codec, Data(repeating: 0, count: 32)))
        let samples = box("stsz", number(0) + number(32) + number(count))
        let media = box("mdia", box("hdlr", handler) + box("minf", box("stbl", description + samples)))
        let ref = reference.map { box("tref", box($0.0, number($0.1))) } ?? Data()
        return box("trak", box("tkhd", header) + ref + media)
    }

    @Test func isoAudioOrdinalsAndRealVideo() throws {
        let main = track(5, "soun", "Full Mix", reference: ("chap", 8))
        let instrumental = track(3, "soun", "伴奏")
        let art = [
            track(8, "vide", "Series", codec: "jpeg"),
            track(7, "vide", "Album Cover", codec: "avc1"),
            track(9, "vide", "VideoHandler", codec: "avc1", count: 1),
            track(2, "vide", "Preview", codec: "avc1", reference: ("thmb", 5)),
            track(10, "text", "Words", codec: "tx3g"),
        ].reduce(Data(), +)
        let audioMovie = box("moov", main + art + instrumental)
        let audio = try #require(EmbeddedMediaTrackInventory.isoBaseMedia(in: audioMovie))
        #expect(!audio.hasVideo)
        #expect(audio.audioTracks.map(\.ordinal) == [0, 1])
        #expect(audio.originalTrack?.ordinal == 0)
        #expect(audio.instrumentalTracks.map(\.name) == ["伴奏"])
        let video = box("moov", main + art + track(11, "vide", "Stage", codec: "avc1") + instrumental)
        #expect(ISOBaseMediaLyricsParser.contentMetadata(in: video)?.embeddedMediaTracks?.hasVideo == true)
    }

    @Test func nativeInstrumentsManifestDefinesStemOrderAndMix() throws {
        let streams = (1...5).map { track($0, "soun", "SoundHandler") }.reduce(Data(), +)
        func movie(_ values: [String]) throws -> Data {
            let json = try JSONSerialization.data(withJSONObject: ["stems": values.map { ["name": $0] }])
            return box("moov", streams + box("udta", box("stem", number(0) + json)))
        }
        let real = try #require(EmbeddedMediaTrackInventory.isoBaseMedia(in: movie(["Drums", "Vocals", "Bass", "Keys"])))
        #expect(real.originalTrack?.ordinal == 0)
        #expect(real.stemTracks.map(\.ordinal) == [1, 2, 3, 4])
        #expect(real.stemTracks.filter(\.isVocalStem).map(\.ordinal) == [2])
        #expect(real.instrumentalTracks.isEmpty)
        #expect(!real.hasVideo)
        #expect(EmbeddedMediaTrackInventory.isoBaseMedia(in: box("moov", streams))?.stemTracks == [])
        #expect(try EmbeddedMediaTrackInventory.isoBaseMedia(in: movie(["Vocal", "Drums"]))?.stemTracks == [])
    }

    @Test func distantMovieSkipsMediaPayload() async throws {
        let audio = track(1, "soun", "Original") + track(3, "soun", "Instrumental")
        let movie = box("moov", box("mvhd", Data(repeating: 0, count: 100)) + audio)
        let brand = box("ftyp", Data("M4A ".utf8) + number(0) + Data("isom".utf8))
        let mediaSize = 300_000_000
        let movieOffset = Int64(brand.count + mediaSize)
        let head = brand + number(mediaSize) + Data("mdat".utf8)
        var transferred = 0
        let inventory = try await EmbeddedMediaTrackInventory.inspect(head: head, fileSize: movieOffset + Int64(movie.count),
            fileExtension: "m4a") { offset, length in
            let start = Int(offset - movieOffset)
            #expect(start >= 0)
            guard start >= 0, start + Int(length) <= movie.count else { throw CocoaError(.fileReadCorruptFile) }
            transferred += Int(length)
            return movie.subdata(in: start..<(start + Int(length)))
        }
        #expect(inventory?.instrumentalTracks.map(\.ordinal) == [1])
        #expect(transferred <= movie.count + 32)
    }

    private func element(_ id: [UInt8], _ body: Data) -> Data {
        let size: Data = body.count < 127
            ? Data([0x80 | UInt8(body.count)])
            : number(0x4000 | body.count, bytes: 2)
        return Data(id) + size + body
    }

    private func mkvTrack(_ id: UInt8, _ type: UInt8, _ name: String, _ codec: String) -> Data {
        let identity = element([0xD7], Data([id])) + element([0x73, 0xC5], Data([id]))
        let info = element([0x83], Data([type])) + element([0x86], Data(codec.utf8))
        return element([0xAE], identity + info + element([0x53, 0x6E], Data(name.utf8)))
    }

    @Test func matroskaKeepsNamedAudioAndIgnoresAttachedArt() async throws {
        let voice = mkvTrack(12, 2, "原唱", "A_OPUS")
        let artwork = mkvTrack(11, 1, "Thumbnail", "V_MJPEG") + mkvTrack(10, 16, "Logo", "V_MPEG4/ISO/AVC")
        let subtitles = mkvTrack(1, 17, "", "S_TEXT/UTF8")
        let backing = mkvTrack(8, 2, "Karaoke", "A_OPUS")
        let image = element([0x46, 0x6E], Data("cover.jpg".utf8)) + element([0x46, 0x5C], Data([0xFF, 0xD8, 0xFF]))
        let attachment = element([0x19, 0x41, 0xA4, 0x69], element([0x61, 0xA7], image))
        for withVideo in [false, true] {
            let movie = withVideo ? mkvTrack(2, 1, "Stage", "V_VP9") : Data()
            let tracks = element([0x16, 0x54, 0xAE, 0x6B], voice + subtitles + artwork + movie + backing)
            let bytes = element([0x1A, 0x45, 0xDF, 0xA3], Data()) + element([0x18, 0x53, 0x80, 0x67], attachment + tracks)
            let inventory = try #require(try await EmbeddedMediaTrackInventory.inspect(head: bytes, fileSize: Int64(bytes.count), fileExtension: "mka") { _, _ in
                Issue.record("All track headers are present in the prefix")
                return Data()
            })
            #expect(inventory.hasVideo == withVideo)
            #expect(inventory.audioTracks.map(\.ordinal) == [0, 1])
            #expect(inventory.audioTracks.map(\.name) == ["原唱", "Karaoke"])
            #expect(inventory.instrumentalTracks.map(\.ordinal) == [1])
        }
    }

    @Test func matroskaTrackTagsAndJPEGBlockCounts() async throws {
        let headers = mkvTrack(1, 2, "", "A_OPUS") + mkvTrack(3, 1, "", "V_MJPEG")
        let target = element([0x63, 0xC0], element([0x63, 0xC5], Data([1])))
        let title = element([0x67, 0xC8], element([0x45, 0xA3], Data("TITLE".utf8)) + element([0x44, 0x87], Data("Backing Track".utf8)))
        let tags = element([0x12, 0x54, 0xC3, 0x67], element([0x73, 0x73], target + title))
        let block = element([0xA3], Data([0x83, 0, 0, 0x80, 0xFF, 0xD8, 0xFF]))
        for count in [1, 2] {
            let cluster = element([0x1F, 0x43, 0xB6, 0x75], (0..<count).reduce(into: Data()) { value, _ in value.append(block) })
            let segment = element([0x16, 0x54, 0xAE, 0x6B], headers) + cluster + tags
            let bytes = element([0x1A, 0x45, 0xDF, 0xA3], Data()) + element([0x18, 0x53, 0x80, 0x67], segment)
            let inventory = try await EmbeddedMediaTrackInventory.inspect(head: bytes, fileSize: Int64(bytes.count), fileExtension: "mkv") { _, _ in Data() }
            #expect(inventory?.instrumentalTracks.map(\.ordinal) == [0])
            #expect(inventory?.hasVideo == (count == 2))
        }
    }

    @Test func legacySongsKeepSeparateSidecarsAndEmbeddedFilesFollowRenames() throws {
        let audio = EmbeddedMediaTrackInventory(audioTracks: [.init(ordinal: 0)], hasVideo: false)
        let video = EmbeddedMediaTrackInventory(audioTracks: audio.audioTracks, hasVideo: true)
        var song = Song(id: "track", title: "Tide", fileFormat: .m4a, filePath: "/Tide.m4a", sourceID: "source")
        song.contentMetadata = .init(isFileInspectionComplete: true)
        #expect(SongContentMetadata.needsInspection(song))
        song.embeddedMediaTracks = video
        #expect(!SongContentMetadata.needsInspection(song))
        #expect(song.usesEmbeddedMusicVideo && !song.isStandaloneMusicVideo && song.mvPath == song.filePath)
        song = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        song.filePath = "/New.m4a"
        #expect(song.mvPath == "/New.m4a")
        song.mvPath = "/Sibling.mkv"
        #expect(song.mvPath == "/Sibling.mkv" && !song.usesEmbeddedMusicVideo)
        song.embeddedMediaTracks = audio
        #expect(song.hasMusicVideo)
        song.mvPath = nil
        #expect(!song.hasMusicVideo)
        var standalone = Song(id: "video", title: "Tide", fileFormat: .mka, filePath: "/Tide.mkv", sourceID: "source", mvPath: "/Tide.mkv")
        standalone.embeddedMediaTracks = video
        #expect(standalone.isStandaloneMusicVideo)
        var stem = Song(id: "stem", title: "Tide", fileFormat: .mp4, filePath: "/Tide.stem.mp4", sourceID: "source", mvPath: "/Tide.stem.mp4")
        #expect(!stem.isStandaloneMusicVideo && !stem.hasMusicVideo)
        stem.embeddedMediaTracks = audio
        #expect(!stem.hasMusicVideo)
    }
}
