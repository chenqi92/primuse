import Foundation
import GRDB
import Testing
@testable import PrimuseKit

@Suite("Library catalog row codec", .serialized)
struct LibraryCatalogRowCodecTests {
    /// 与 `IncrementalSongStore` 存负载时同一套编码设置。
    private static func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static func exactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan"
        )
        return encoder
    }

    /// 两首歌逐位相同:`==` 之外再比一遍所有浮点数的位模式(NaN 不等于自己)。
    private static func bitExact(_ lhs: Song, _ rhs: Song) -> Bool {
        func bits(_ value: Double?) -> UInt64? { value?.bitPattern }
        func dateBits(_ value: Date?) -> UInt64? { value?.timeIntervalSinceReferenceDate.bitPattern }
        let numericEqual = bits(lhs.duration) == bits(rhs.duration)
            && dateBits(lhs.dateAdded) == dateBits(rhs.dateAdded)
            && dateBits(lhs.lastModified) == dateBits(rhs.lastModified)
            && dateBits(lhs.serverDateAdded) == dateBits(rhs.serverDateAdded)
            && dateBits(lhs.serverAlbumDateAdded) == dateBits(rhs.serverAlbumDateAdded)
            && dateBits(lhs.userMetadataEditedAt) == dateBits(rhs.userMetadataEditedAt)
            && bits(lhs.replayGainTrackGain) == bits(rhs.replayGainTrackGain)
            && bits(lhs.replayGainTrackPeak) == bits(rhs.replayGainTrackPeak)
            && bits(lhs.replayGainAlbumGain) == bits(rhs.replayGainAlbumGain)
            && bits(lhs.replayGainAlbumPeak) == bits(rhs.replayGainAlbumPeak)
            && bits(lhs.cueStartTime) == bits(rhs.cueStartTime)
            && bits(lhs.cueEndTime) == bits(rhs.cueEndTime)
        guard numericEqual else { return false }
        // NaN 让 `==` 失败;把位模式相同的 NaN 字段换成同一个普通值后再比其余字段。
        func scrub(_ song: Song) -> Song {
            var copy = song
            if copy.duration.isNaN { copy.duration = 1 }
            if copy.dateAdded.timeIntervalSinceReferenceDate.isNaN { copy.dateAdded = .distantPast }
            if copy.lastModified?.timeIntervalSinceReferenceDate.isNaN == true { copy.lastModified = .distantPast }
            if copy.serverDateAdded?.timeIntervalSinceReferenceDate.isNaN == true { copy.serverDateAdded = .distantPast }
            if copy.serverAlbumDateAdded?.timeIntervalSinceReferenceDate.isNaN == true { copy.serverAlbumDateAdded = .distantPast }
            if copy.userMetadataEditedAt?.timeIntervalSinceReferenceDate.isNaN == true { copy.userMetadataEditedAt = .distantPast }
            if copy.replayGainTrackGain?.isNaN == true { copy.replayGainTrackGain = 1 }
            if copy.replayGainTrackPeak?.isNaN == true { copy.replayGainTrackPeak = 1 }
            if copy.replayGainAlbumGain?.isNaN == true { copy.replayGainAlbumGain = 1 }
            if copy.replayGainAlbumPeak?.isNaN == true { copy.replayGainAlbumPeak = 1 }
            if copy.cueStartTime?.isNaN == true { copy.cueStartTime = 1 }
            if copy.cueEndTime?.isNaN == true { copy.cueEndTime = 1 }
            return copy
        }
        return scrub(lhs) == scrub(rhs)
    }

    @Test("Randomized songs round-trip losslessly through catalog rows", arguments: [UInt64(1), 7, 42, 2026, 90210])
    func randomizedRoundTrip(seed: UInt64) throws {
        let temporary = try TemporaryCatalog()
        var rng = CatalogTestRandom(seed: seed)
        var originals: [Song] = []
        for index in 0..<400 {
            originals.append(CatalogSongFactory.randomSong(&rng, index: index, exotic: index % 3 == 0))
        }
        // id 必须唯一:随机 id 里带了下标。
        let summary = try temporary.catalog.apply(upserts: originals)
        #expect(summary.insertedRowids.count == originals.count, "seed \(seed)")
        let restored = try temporary.catalog.songs(ids: originals.map(\.id))
        #expect(restored.count == originals.count, "seed \(seed)")
        for (original, back) in zip(originals, restored) {
            let expected = original.withoutAppliedPlaybackRange
            #expect(Self.bitExact(expected, back), "seed \(seed) id \(original.id)")
            #expect(try Self.exactEncoder().encode(expected) == Self.exactEncoder().encode(back), "seed \(seed) id \(original.id)")
        }
        // 再写一遍同样的歌:逐首判为未变,行号不变。
        let again = try temporary.catalog.apply(upserts: originals)
        #expect(again.unchangedCount == originals.count, "seed \(seed)")
        #expect(again.isEmpty, "seed \(seed)")
    }

    @Test("Catalog rows reproduce the store's JSON payload byte for byte")
    func jsonPayloadEquality() throws {
        let temporary = try TemporaryCatalog()
        var rng = CatalogTestRandom(seed: 314)
        let originals = (0..<600).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false) }
        try temporary.catalog.apply(upserts: originals)
        let restored = try temporary.catalog.songs(ids: originals.map(\.id))
        let encoder = Self.storeEncoder()
        for (original, back) in zip(originals, restored) {
            #expect(try encoder.encode(original) == encoder.encode(back), "id \(original.id)")
            let exact = JSONEncoder()
            exact.outputFormatting = .sortedKeys
            #expect(try exact.encode(original) == exact.encode(back), "id \(original.id)")
        }
    }

    @Test("Updates keep rowids stable; new rows append in input order; deletes free nothing for reuse")
    func rowidStability() throws {
        let temporary = try TemporaryCatalog()
        var rng = CatalogTestRandom(seed: 5)
        var songs = (0..<50).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false) }
        let first = try temporary.catalog.apply(upserts: songs)
        let rowidsBefore = try temporary.catalog.rowids(forIDs: songs.map(\.id))
        songs[3].title = "edited"
        songs[7].filePath = "moved/elsewhere.flac"
        let second = try temporary.catalog.apply(upserts: [songs[3], songs[7]])
        #expect(second.updatedRowids.sorted() == [rowidsBefore[3]!, rowidsBefore[7]!].sorted())
        #expect(try temporary.catalog.rowids(forIDs: songs.map(\.id)) == rowidsBefore)
        let deleted = try temporary.catalog.apply(upserts: [], deletingIDs: [songs[49].id])
        #expect(deleted.deletedRowids == [rowidsBefore[49]!])
        let extra = CatalogSongFactory.randomSong(&rng, index: 999, exotic: false)
        let third = try temporary.catalog.apply(upserts: [extra])
        // AUTOINCREMENT:被删的最大行号不会给新歌。
        #expect(third.insertedRowids.first! > first.insertedRowids.max()!)
        let order = try temporary.catalog.rowList(.everything)
        #expect(order.count == 50)
        #expect(order.rowids.last == third.insertedRowids.first)
        #expect(Array(order.rowids.prefix(49)) == rowidsBefore.prefix(49).map { $0! })
    }

    @Test("Identifiers with NUL are rejected instead of colliding")
    func nulIdentifiers() throws {
        let temporary = try TemporaryCatalog()
        let song = Song(id: "a\0b", title: "t", fileFormat: .mp3, filePath: "x.mp3", sourceID: "s")
        #expect(throws: LibraryCatalogError.invalidIdentifier("a\0b")) {
            try temporary.catalog.apply(upserts: [song])
        }
    }

    @Test("Materialization above the hard limit reports and truncates")
    func materializationGuard() throws {
        let temporary = try TemporaryCatalog()
        let messages = LockedMessages()
        LibraryScaleGuard.setViolationHandlerForTesting { messages.append($0) }
        defer { LibraryScaleGuard.setViolationHandlerForTesting(nil) }
        let ids = (0..<(LibraryScale.maxMaterializedRows + 10)).map { "missing-\($0)" }
        let result = try temporary.catalog.songs(ids: ids)
        #expect(result.isEmpty)
        #expect(messages.count == 1)
        #expect(LibraryScaleGuard.admitMaterialization(count: 10) == 10)
    }
}

final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}
