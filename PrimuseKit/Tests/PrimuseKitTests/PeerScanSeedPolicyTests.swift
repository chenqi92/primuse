import Foundation
import Testing
@testable import PrimuseKit

struct PeerScanSeedPolicyTests {
    private let modified = Date(timeIntervalSinceReferenceDate: 800_000_000.789)

    private func readSong(
        id: String = "song-1",
        size: Int64 = 4_000_000,
        modified: Date? = nil,
        revision: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: "夜曲",
            albumTitle: "十一月的萧邦",
            artistName: "周杰伦",
            albumArtistName: "周杰伦",
            trackNumber: 1,
            duration: 226,
            fileFormat: .flac,
            filePath: "/music/夜曲.flac",
            sourceID: "nas",
            fileSize: size,
            bitRate: 900,
            sampleRate: 44_100,
            bitDepth: 16,
            year: 2005,
            lastModified: modified ?? self.modified,
            dateAdded: Date(timeIntervalSinceReferenceDate: 1),
            coverArtFileName: "0123456789abcdef0123456789abcdef.jpg",
            lyricsFileName: "fedcba9876543210fedcba9876543210.json",
            revision: revision
        )
    }

    private func bareSong(
        id: String = "song-1",
        size: Int64 = 4_000_000,
        modified: Date? = nil,
        revision: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: "夜曲",
            duration: 0,
            fileFormat: .flac,
            filePath: "/music/夜曲.flac",
            sourceID: "nas",
            fileSize: size,
            lastModified: modified ?? self.modified,
            dateAdded: Date(timeIntervalSinceReferenceDate: 99),
            revision: revision
        )
    }

    private let contentKey = String(repeating: "ab", count: 32)

    @Test("A row that was read from the file is a usable seed")
    func usableSeed() {
        #expect(PeerScanSeedPolicy.isUsableSeed(readSong()))
    }

    @Test("Bare rows, provisional DTS durations, edited and CUE rows are not seeds")
    func unusableSeeds() {
        #expect(!PeerScanSeedPolicy.isUsableSeed(bareSong()))

        var provisional = bareSong()
        provisional.duration = 300
        #expect(!PeerScanSeedPolicy.isUsableSeed(provisional))

        var edited = readSong()
        edited.userMetadataEditedAt = Date()
        #expect(!PeerScanSeedPolicy.isUsableSeed(edited))

        var cue = readSong()
        cue.cueSheetPath = "/music/album.cue"
        cue.cueStartTime = 0
        #expect(!PeerScanSeedPolicy.isUsableSeed(cue))

        var unsized = readSong()
        unsized.fileSize = 0
        #expect(!PeerScanSeedPolicy.isUsableSeed(unsized))

        var descriptor = readSong()
        descriptor.filePath = "/music/radio.strm"
        #expect(!PeerScanSeedPolicy.isUsableSeed(descriptor))
    }

    @Test("Modification times that lost their fractional seconds still match")
    func wholeSecondModificationTime() {
        let truncated = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let seed = readSong(modified: truncated)
        #expect(PeerScanSeedPolicy.fingerprintMatches(
            size: 4_000_000, modifiedDate: modified, revision: nil, seed: seed
        ))
        #expect(!PeerScanSeedPolicy.fingerprintMatches(
            size: 4_000_000, modifiedDate: modified.addingTimeInterval(2), revision: nil, seed: seed
        ))
    }

    @Test("Size and revision must agree")
    func sizeAndRevision() {
        let seed = readSong(revision: "r1")
        #expect(!PeerScanSeedPolicy.fingerprintMatches(
            size: 4_000_001, modifiedDate: modified, revision: "r1", seed: seed
        ))
        #expect(!PeerScanSeedPolicy.fingerprintMatches(
            size: 4_000_000, modifiedDate: modified, revision: "r2", seed: seed
        ))
        #expect(PeerScanSeedPolicy.fingerprintMatches(
            size: 4_000_000, modifiedDate: modified, revision: "r1", seed: seed
        ))
        #expect(PeerScanSeedPolicy.fingerprintMatches(
            size: 4_000_000, modifiedDate: nil, revision: nil, seed: seed
        ))
        #expect(!PeerScanSeedPolicy.fingerprintMatches(
            size: 0, modifiedDate: nil, revision: nil, seed: readSong(size: 0)
        ))
    }

    @Test("Row comparison also requires the same source and path")
    func rowFingerprint() {
        let seed = readSong()
        #expect(PeerScanSeedPolicy.fingerprintMatches(bareSong(), seed: seed))
        var moved = bareSong()
        moved.filePath = "/music/other.flac"
        #expect(!PeerScanSeedPolicy.fingerprintMatches(moved, seed: seed))
        var otherSource = bareSong()
        otherSource.sourceID = "webdav"
        #expect(!PeerScanSeedPolicy.fingerprintMatches(otherSource, seed: seed))
    }

    @Test("The most complete reading wins, ties go to the newer device")
    func mergePrefersCompleteness() {
        var sparse = readSong()
        sparse.albumArtistName = nil
        sparse.year = nil
        let newer = [PeerScanSeed(song: sparse)]
        let older = [PeerScanSeed(song: readSong(), coverContentKey: contentKey)]
        let merged = PeerScanSeedPolicy.merged([newer, older])
        #expect(merged["song-1"]?.coverContentKey == contentKey)

        var tieNewer = readSong()
        tieNewer.title = "新的"
        let tie = PeerScanSeedPolicy.merged([[PeerScanSeed(song: tieNewer)], [PeerScanSeed(song: readSong())]])
        #expect(tie["song-1"]?.song.title == "新的")
    }

    @Test("Unusable rows never enter the merged seeds")
    func mergeDropsUnusable() {
        let merged = PeerScanSeedPolicy.merged([[PeerScanSeed(song: bareSong())]])
        #expect(merged.isEmpty)
    }

    @Test("Adoption keeps this device's listing and leaves derived ids to the library")
    func adoption() {
        var base = bareSong(modified: modified, revision: "local-rev")
        base.coverArtFileName = "/music/cover.jpg"
        var seed = readSong(modified: Date(timeIntervalSinceReferenceDate: 800_000_000))
        seed.albumID = "peer-album"
        seed.artistID = "peer-artist"
        let adopted = PeerScanSeedPolicy.adopting(seed, onto: base)
        #expect(adopted.title == "夜曲")
        #expect(adopted.albumTitle == "十一月的萧邦")
        #expect(adopted.duration == 226)
        #expect(adopted.sampleRate == 44_100)
        #expect(adopted.lastModified == modified)
        #expect(adopted.revision == "local-rev")
        #expect(adopted.dateAdded == base.dateAdded)
        #expect(adopted.albumID == nil)
        #expect(adopted.artistID == nil)
        #expect(adopted.coverArtFileName == "/music/cover.jpg")
        // 歌词缓存名由歌曲 id 决定,留着表示文件里有歌词。
        #expect(adopted.lyricsFileName == seed.lyricsFileName)

        var sidecarLyrics = base
        sidecarLyrics.lyricsFileName = "/music/夜曲.lrc"
        #expect(PeerScanSeedPolicy.adopting(seed, onto: sidecarLyrics).lyricsFileName == "/music/夜曲.lrc")

        var pathLyricsSeed = seed
        pathLyricsSeed.lyricsFileName = "/elsewhere/夜曲.lrc"
        #expect(PeerScanSeedPolicy.adopting(pathLyricsSeed, onto: base).lyricsFileName == nil)
    }

    @Test("Cover disposition follows sidecar and content key; a missing cover stays unknown")
    func coverDisposition() {
        let base = bareSong()
        var sidecarBase = bareSong()
        sidecarBase.coverArtFileName = "/music/folder.jpg"
        let seed = PeerScanSeed(song: readSong(), coverContentKey: contentKey)
        #expect(PeerScanSeedPolicy.coverDisposition(seed: seed, base: sidecarBase) == .sidecar)
        #expect(PeerScanSeedPolicy.coverDisposition(seed: seed, base: base) == .content(contentKey))

        var noCover = readSong()
        noCover.coverArtFileName = nil
        #expect(PeerScanSeedPolicy.coverDisposition(seed: PeerScanSeed(song: noCover), base: base) == .unknown)
        #expect(PeerScanSeedPolicy.coverDisposition(seed: PeerScanSeed(song: readSong()), base: base) == .unknown)
        #expect(PeerScanSeedPolicy.coverDisposition(
            seed: PeerScanSeed(song: readSong(), coverContentKey: "../../etc"), base: base
        ) == .unknown)
    }

    @Test("Cached lyrics are told apart from sidecar lyric files")
    func cachedLyrics() {
        #expect(PeerScanSeedPolicy.hasCachedLyrics(readSong()))
        var sidecar = readSong()
        sidecar.lyricsFileName = "/music/夜曲.lrc"
        #expect(!PeerScanSeedPolicy.hasCachedLyrics(sidecar))
        var none = readSong()
        none.lyricsFileName = nil
        #expect(!PeerScanSeedPolicy.hasCachedLyrics(none))
    }

    @Test("Cover groups invert to a per-song lookup and reject malformed keys")
    func coverGroups() {
        let keys = PeerScanSeedPolicy.coverContentKeys(bySongIDFrom: [
            contentKey: ["a", "b"],
            "not-a-hash": ["c"],
        ])
        #expect(keys == ["a": contentKey, "b": contentKey])
        #expect(PeerScanSeedPolicy.coverContentKeys(bySongIDFrom: nil).isEmpty)
    }

    @Test("Seeds survive a JSON round trip with ISO-8601 dates")
    func codableRoundTrip() throws {
        let seed = PeerScanSeed(song: readSong(), coverContentKey: contentKey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PeerScanSeed.self, from: encoder.encode(seed))
        #expect(decoded.coverContentKey == contentKey)
        #expect(decoded.song.title == seed.song.title)
        #expect(PeerScanSeedPolicy.fingerprintMatches(readSong(), seed: decoded.song))
    }
}
