import Foundation
import Testing
@testable import PrimuseKit

@Suite("ISO Base Media chapters")
struct ISOBaseMediaChapterParserTests {
    // MARK: - Nero chpl

    @Test("Reads a version 1 Nero chapter list")
    func neroVersionOne() {
        let file = mediaFile(moovChildren: udta(chpl(
            version: 1,
            entries: [(0, "Opening"), (90_000_000, "Middle"), (1_800_000_000, "Closing")]
        )))

        let chapters = ISOBaseMediaChapterParser.chapters(in: file)

        #expect(chapters.count == 3)
        #expect(chapters[0].title == "Opening")
        #expect(chapters[0].startTime == 0)
        #expect(chapters[1].title == "Middle")
        #expect(chapters[1].startTime == 9)
        #expect(chapters[2].startTime == 180)
    }

    @Test("Reads a version 0 Nero chapter list, which has no reserved field")
    func neroVersionZero() {
        let file = mediaFile(moovChildren: udta(chpl(
            version: 0,
            entries: [(0, "One"), (50_000_000, "Two")]
        )))

        let chapters = ISOBaseMediaChapterParser.chapters(in: file)

        #expect(chapters.map(\.title) == ["One", "Two"])
        #expect(chapters[1].startTime == 5)
    }

    @Test("Sorts marks and drops repeated start times")
    func neroSortsAndDeduplicates() {
        let file = mediaFile(moovChildren: udta(chpl(
            version: 1,
            entries: [(30_000_000, "Later"), (0, "First"), (0, "Duplicate start")]
        )))

        let chapters = ISOBaseMediaChapterParser.chapters(in: file)

        #expect(chapters.map(\.title) == ["First", "Later"])
    }

    @Test("An empty title is not a chapter")
    func neroSkipsEmptyTitles() {
        let file = mediaFile(moovChildren: udta(chpl(
            version: 1,
            entries: [(0, ""), (10_000_000, "Real")]
        )))

        #expect(ISOBaseMediaChapterParser.chapters(in: file).map(\.title) == ["Real"])
    }

    // MARK: - QuickTime chapter track

    @Test("Walks a chapter text track referenced through tref/chap")
    func quickTimeChapterTrack() {
        let file = quickTimeChapterFile(
            timescale: 1000,
            samples: [(durationUnits: 60_000, title: "Chapter One"),
                      (durationUnits: 30_000, title: "Chapter Two"),
                      (durationUnits: 30_000, title: "Chapter Three")]
        )

        let chapters = ISOBaseMediaChapterParser.chapters(in: file)

        #expect(chapters.count == 3)
        #expect(chapters.map(\.title) == ["Chapter One", "Chapter Two", "Chapter Three"])
        #expect(chapters[0].startTime == 0)
        #expect(chapters[1].startTime == 60)
        #expect(chapters[2].startTime == 90)
    }

    @Test("A chapter track with its own timescale still resolves to seconds")
    func quickTimeNonStandardTimescale() {
        let file = quickTimeChapterFile(
            timescale: 600,
            samples: [(durationUnits: 600, title: "A"), (durationUnits: 1200, title: "B")]
        )

        let chapters = ISOBaseMediaChapterParser.chapters(in: file)

        #expect(chapters.map(\.startTime) == [0, 1])
    }

    @Test("Nero chapters win when a file carries both layouts")
    func neroWinsOverChapterTrack() {
        var file = quickTimeChapterFile(
            timescale: 1000,
            samples: [(durationUnits: 1000, title: "Track layout")]
        )
        file = insertingNeroChapters(
            into: file,
            entries: [(0, "Nero layout")]
        )

        #expect(ISOBaseMediaChapterParser.chapters(in: file).map(\.title) == ["Nero layout"])
    }

    // MARK: - Malformed input

    @Test("Truncated and nonsense bytes yield no chapters instead of crashing")
    func malformedInput() {
        #expect(ISOBaseMediaChapterParser.chapters(in: Data()).isEmpty)
        #expect(ISOBaseMediaChapterParser.chapters(in: Data([0, 1, 2, 3, 4])).isEmpty)
        #expect(ISOBaseMediaChapterParser.chapters(in: Data(repeating: 0xFF, count: 512)).isEmpty)

        let complete = mediaFile(moovChildren: udta(chpl(
            version: 1,
            entries: [(0, "Opening"), (90_000_000, "Middle")]
        )))
        // Every prefix of a valid file must be survivable: a bounded remote
        // read hands the parser exactly this.
        for length in stride(from: 1, to: complete.count, by: 1) {
            _ = ISOBaseMediaChapterParser.chapters(in: complete.prefix(length))
        }
    }

    @Test("A chapter count larger than the payload stops at the last full entry")
    func neroOverstatedCount() {
        var payload = Data([1, 0, 0, 0, 0, 0, 0, 0])
        payload.append(200) // claims 200 entries
        payload.append(contentsOf: bigEndian(UInt64(0)))
        payload.append(5)
        payload.append(contentsOf: Array("Alpha".utf8))
        let file = mediaFile(moovChildren: udta(atom("chpl", payload)))

        #expect(ISOBaseMediaChapterParser.chapters(in: file).map(\.title) == ["Alpha"])
    }

    // MARK: - Lookup

    @Test("Finds the chapter covering a playback position")
    func chapterLookup() {
        let chapters = [
            MediaChapter(startTime: 0, title: "A"),
            MediaChapter(startTime: 60, title: "B"),
            MediaChapter(startTime: 120, title: "C"),
        ]

        #expect(chapters.chapterIndex(at: 0) == 0)
        #expect(chapters.chapterIndex(at: 59.9) == 0)
        #expect(chapters.chapterIndex(at: 60) == 1)
        #expect(chapters.chapterIndex(at: 119) == 1)
        #expect(chapters.chapterIndex(at: 5000) == 2)
        #expect([MediaChapter]().chapterIndex(at: 10) == nil)
    }

    @Test("A position before the first mark belongs to no chapter")
    func chapterLookupBeforeFirstMark() {
        let chapters = [MediaChapter(startTime: 30, title: "Late start")]

        #expect(chapters.chapterIndex(at: 10) == nil)
        #expect(chapters.chapterIndex(at: 30) == 0)
    }
}

// MARK: - Builders

private func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24),
     UInt8(truncatingIfNeeded: value >> 16),
     UInt8(truncatingIfNeeded: value >> 8),
     UInt8(truncatingIfNeeded: value)]
}

private func bigEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
}

private func bigEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func atom(_ type: String, _ payload: Data) -> Data {
    var result = Data(bigEndian(UInt32(payload.count + 8)))
    result.append(contentsOf: Array(type.utf8))
    result.append(payload)
    return result
}

private func atom(_ type: String, _ children: [Data]) -> Data {
    atom(type, children.reduce(into: Data()) { $0.append($1) })
}

private func chpl(version: UInt8, entries: [(UInt64, String)]) -> Data {
    var payload = Data([version, 0, 0, 0])
    if version > 0 { payload.append(contentsOf: [0, 0, 0, 0]) }
    payload.append(UInt8(entries.count))
    for (start, title) in entries {
        payload.append(contentsOf: bigEndian(start))
        let bytes = Array(title.utf8)
        payload.append(UInt8(bytes.count))
        payload.append(contentsOf: bytes)
    }
    return atom("chpl", payload)
}

private func udta(_ child: Data) -> [Data] {
    [atom("udta", [child])]
}

private func mediaFile(moovChildren: [Data]) -> Data {
    var file = atom("ftyp", Data(Array("M4A mp42".utf8)))
    file.append(atom("moov", moovChildren))
    return file
}

/// Builds `ftyp` + `mdat` + `moov` with an audio track pointing at a chapter
/// text track. `mdat` comes first so the sample offsets are known up front,
/// which is how most converters lay an audiobook out.
private func quickTimeChapterFile(
    timescale: UInt32,
    samples: [(durationUnits: UInt32, title: String)]
) -> Data {
    let ftyp = atom("ftyp", Data(Array("M4A mp42".utf8)))

    var sampleBytes = Data()
    var sizes: [UInt32] = []
    for sample in samples {
        let titleBytes = Array(sample.title.utf8)
        var encoded = Data(bigEndian(UInt16(titleBytes.count)))
        encoded.append(contentsOf: titleBytes)
        sizes.append(UInt32(encoded.count))
        sampleBytes.append(encoded)
    }
    let mdat = atom("mdat", sampleBytes)
    let firstSampleOffset = UInt32(ftyp.count + 8)

    var sttsPayload = Data([0, 0, 0, 0])
    sttsPayload.append(contentsOf: bigEndian(UInt32(samples.count)))
    for sample in samples {
        sttsPayload.append(contentsOf: bigEndian(UInt32(1)))
        sttsPayload.append(contentsOf: bigEndian(sample.durationUnits))
    }

    var stscPayload = Data([0, 0, 0, 0])
    stscPayload.append(contentsOf: bigEndian(UInt32(1)))
    stscPayload.append(contentsOf: bigEndian(UInt32(1)))                  // first chunk
    stscPayload.append(contentsOf: bigEndian(UInt32(samples.count)))      // samples per chunk
    stscPayload.append(contentsOf: bigEndian(UInt32(1)))                  // description index

    var stszPayload = Data([0, 0, 0, 0])
    stszPayload.append(contentsOf: bigEndian(UInt32(0)))                  // non-uniform
    stszPayload.append(contentsOf: bigEndian(UInt32(sizes.count)))
    for size in sizes { stszPayload.append(contentsOf: bigEndian(size)) }

    var stcoPayload = Data([0, 0, 0, 0])
    stcoPayload.append(contentsOf: bigEndian(UInt32(1)))
    stcoPayload.append(contentsOf: bigEndian(firstSampleOffset))

    let stbl = atom("stbl", [
        atom("stts", sttsPayload),
        atom("stsc", stscPayload),
        atom("stsz", stszPayload),
        atom("stco", stcoPayload),
    ])

    var mdhdPayload = Data([0, 0, 0, 0])
    mdhdPayload.append(contentsOf: bigEndian(UInt32(0)))                  // creation
    mdhdPayload.append(contentsOf: bigEndian(UInt32(0)))                  // modification
    mdhdPayload.append(contentsOf: bigEndian(timescale))
    mdhdPayload.append(contentsOf: bigEndian(UInt32(0)))                  // duration

    let chapterTrack = atom("trak", [
        trackHeader(id: 2),
        atom("mdia", [
            atom("mdhd", mdhdPayload),
            atom("hdlr", Data([0, 0, 0, 0]) + Data(Array("mhlrtext".utf8))),
            atom("minf", [stbl]),
        ]),
    ])

    let audioTrack = atom("trak", [
        trackHeader(id: 1),
        atom("tref", [atom("chap", Data(bigEndian(UInt32(2))))]),
    ])

    var file = ftyp
    file.append(mdat)
    file.append(atom("moov", [audioTrack, chapterTrack]))
    return file
}

private func trackHeader(id: UInt32) -> Data {
    var payload = Data([0, 0, 0, 0])                                      // version/flags
    payload.append(contentsOf: bigEndian(UInt32(0)))                      // creation
    payload.append(contentsOf: bigEndian(UInt32(0)))                      // modification
    payload.append(contentsOf: bigEndian(id))
    payload.append(contentsOf: bigEndian(UInt32(0)))                      // reserved
    payload.append(contentsOf: bigEndian(UInt32(0)))                      // duration
    return atom("tkhd", payload)
}

/// Rebuilds a chapter-track file with a Nero list added to `moov/udta`, so a
/// file that carries both layouts can be exercised.
private func insertingNeroChapters(
    into file: Data,
    entries: [(UInt64, String)]
) -> Data {
    // The generated file ends with its moov; rebuild that atom with one more
    // child rather than parsing offsets back out.
    var cursor = 0
    var prefix = Data()
    var moovPayload = Data()
    while cursor + 8 <= file.count {
        let size = Int(file[cursor]) << 24 | Int(file[cursor + 1]) << 16
            | Int(file[cursor + 2]) << 8 | Int(file[cursor + 3])
        let type = String(bytes: file[(cursor + 4)..<(cursor + 8)], encoding: .ascii)
        guard size >= 8, cursor + size <= file.count else { break }
        if type == "moov" {
            moovPayload = file[(cursor + 8)..<(cursor + size)]
        } else {
            prefix.append(file[cursor..<(cursor + size)])
        }
        cursor += size
    }
    moovPayload.append(atom("udta", [chpl(version: 1, entries: entries)]))
    var result = prefix
    result.append(atom("moov", moovPayload))
    return result
}
