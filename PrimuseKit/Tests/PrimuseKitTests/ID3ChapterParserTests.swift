import Foundation
import Testing
@testable import PrimuseKit

@Test(arguments: [3, 4])
func readsPodcastChaptersFromCHAPFrames(version: Int) {
    let tag = chapterTag(version: version, frames: [
        chapFrame(version: version, id: "ch0", start: 0, title: "Вступление"),
        chapFrame(version: version, id: "ch1", start: 95_500, title: "Новости недели"),
        chapFrame(version: version, id: "ch2", start: 1_800_000, title: "Вопросы слушателей"),
    ])

    #expect(ID3ChapterParser.chapters(in: tag) == [
        MediaChapter(startTime: 0, title: "Вступление"),
        MediaChapter(startTime: 95.5, title: "Новости недели"),
        MediaChapter(startTime: 1800, title: "Вопросы слушателей"),
    ])
}

@Test func ordersChaptersByStartTimeWhenFramesAreOutOfOrder() {
    let tag = chapterTag(version: 3, frames: [
        chapFrame(version: 3, id: "b", start: 60_000, title: "Second"),
        chapFrame(version: 3, id: "a", start: 0, title: "First"),
    ])
    #expect(ID3ChapterParser.chapters(in: tag).map(\.title) == ["First", "Second"])
}

@Test func topLevelTableOfContentsHidesUnlistedChapters() {
    let tag = chapterTag(version: 4, frames: [
        ctocFrame(version: 4, id: "toc", topLevel: true, entries: ["ch0", "ch2"]),
        chapFrame(version: 4, id: "ch0", start: 0, title: "Intro"),
        chapFrame(version: 4, id: "ch1", start: 10_000, title: "Hidden ad marker"),
        chapFrame(version: 4, id: "ch2", start: 20_000, title: "Interview"),
    ])
    #expect(ID3ChapterParser.chapters(in: tag).map(\.title) == ["Intro", "Interview"])
}

@Test func nestedTablesOfContentsAreFollowed() {
    let tag = chapterTag(version: 3, frames: [
        ctocFrame(version: 3, id: "root", topLevel: true, entries: ["ch0", "part2"]),
        ctocFrame(version: 3, id: "part2", topLevel: false, entries: ["ch1", "ch2"]),
        chapFrame(version: 3, id: "ch0", start: 0, title: "Opening"),
        chapFrame(version: 3, id: "ch1", start: 30_000, title: "Part two A"),
        chapFrame(version: 3, id: "ch2", start: 60_000, title: "Part two B"),
    ])
    #expect(ID3ChapterParser.chapters(in: tag).count == 3)
}

@Test func chaptersWithoutTitlesFallBackToTIT3OrAreDropped() {
    let tag = chapterTag(version: 3, frames: [
        chapFrame(version: 3, id: "ch0", start: 0, title: nil, description: "Described only"),
        chapFrame(version: 3, id: "ch1", start: 5_000, title: nil),
        chapFrame(version: 3, id: "ch2", start: 9_000, title: "Titled"),
    ])
    #expect(ID3ChapterParser.chapters(in: tag).map(\.title) == ["Described only", "Titled"])
}

@Test func chapterImagesAndOtherFramesDoNotDisturbTheChapters() {
    let artwork = frame(version: 3, id: "APIC", payload: Data([0]) + Data("image/jpeg".utf8) + Data([0, 3, 0]) + Data(repeating: 0xFF, count: 4_096))
    let chapter = chapFrame(version: 3, id: "ch0", start: 1_000, title: "With picture", extraSubframes: [artwork])
    let tag = chapterTag(version: 3, frames: [
        frame(version: 3, id: "TIT2", payload: Data([3]) + Data("Episode".utf8)),
        artwork,
        chapter,
    ], padding: 512)
    #expect(ID3ChapterParser.chapters(in: tag) == [MediaChapter(startTime: 1, title: "With picture")])
}

@Test func truncatedTagKeepsTheCompleteChapters() {
    let tag = chapterTag(version: 4, frames: [
        chapFrame(version: 4, id: "ch0", start: 0, title: "Complete"),
        chapFrame(version: 4, id: "ch1", start: 50_000, title: "Cut off"),
    ])
    let cut = tag.prefix(tag.count - 6)
    #expect(ID3ChapterParser.chapters(in: cut).map(\.title) == ["Complete"])
}

@Test func filesWithoutChaptersYieldNothing() {
    #expect(ID3ChapterParser.chapters(in: Data()).isEmpty)
    #expect(ID3ChapterParser.chapters(in: Data("fLaC0000000000".utf8)).isEmpty)
    let textOnly = chapterTag(version: 3, frames: [frame(version: 3, id: "TIT2", payload: Data([3]) + Data("Song".utf8))])
    #expect(ID3ChapterParser.chapters(in: textOnly).isEmpty)
    // ID3v2.2 has no chapter frames.
    var legacy = chapterTag(version: 3, frames: [chapFrame(version: 3, id: "ch0", start: 0, title: "x")])
    legacy[3] = 2
    #expect(ID3ChapterParser.chapters(in: legacy).isEmpty)
}

@Test func malformedChapterFramesDoNotCrash() {
    let shortChap = frame(version: 3, id: "CHAP", payload: Data("ch0".utf8) + Data([0, 0, 0]))
    let noTerminator = frame(version: 3, id: "CHAP", payload: Data(repeating: 0x41, count: 40))
    let badTOC = frame(version: 3, id: "CTOC", payload: Data("toc".utf8) + Data([0, 0x03, 200]) + Data("ch0".utf8))
    let tag = chapterTag(version: 3, frames: [shortChap, noTerminator, badTOC, chapFrame(version: 3, id: "ch0", start: 2_000, title: "Survivor")])
    #expect(ID3ChapterParser.chapters(in: tag).map(\.title) == ["Survivor"])

    var oversized = tag
    oversized.replaceSubrange(14..<18, with: [0x7F, 0x7F, 0x7F, 0x7F])
    _ = ID3ChapterParser.chapters(in: oversized)
}

@Test func tagLengthComesFromTheHeaderAlone() {
    let tag = chapterTag(version: 4, frames: [chapFrame(version: 4, id: "ch0", start: 0, title: "One")], padding: 100)
    #expect(ID3ChapterParser.tagLength(header: tag.prefix(ID3ChapterParser.headerLength)) == tag.count)
    #expect(ID3ChapterParser.tagLength(header: Data("ID3".utf8)) == nil)
    #expect(ID3ChapterParser.tagLength(header: Data(repeating: 0, count: 10)) == nil)
    // A slice that does not start at index 0 reads the same.
    let shifted = (Data([0xAA]) + tag).dropFirst()
    #expect(ID3ChapterParser.tagLength(header: shifted.prefix(10)) == tag.count)
    #expect(ID3ChapterParser.chapters(in: shifted).map(\.title) == ["One"])
}

@Test func readsChaptersFromTheHeadOfALocalFile() throws {
    let tag = chapterTag(version: 3, frames: [
        chapFrame(version: 3, id: "ch0", start: 0, title: "Start"),
        chapFrame(version: 3, id: "ch1", start: 120_000, title: "Middle"),
    ])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("id3-chapters-\(UUID().uuidString).mp3")
    try (tag + Data(repeating: 0xFF, count: 64 * 1024)).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(ID3ChapterParser.chapters(fileURL: url).map(\.title) == ["Start", "Middle"])
    #expect(ID3ChapterParser.chapters(fileURL: url.appendingPathExtension("missing")).isEmpty)
}

@Test func unsynchronisedVersion23TagIsRestoredBeforeParsing() {
    // The start time and the unused byte offsets carry 0xFF bytes, which
    // unsynchronisation follows with a zero that has to come out again.
    let plain = chapterTag(version: 3, frames: [chapFrame(version: 3, id: "ch0", start: 0x00FF_0000, title: "Late")])
    var body = Data()
    for byte in plain.dropFirst(10) {
        body.append(byte)
        if byte == 0xFF { body.append(0) }
    }
    var header = Data(plain.prefix(10))
    header[5] |= 0x80
    header.replaceSubrange(6..<10, with: id3SyncSafe(body.count))
    #expect(ID3ChapterParser.chapters(in: header + body) == [MediaChapter(startTime: 16_711.68, title: "Late")])
}

// MARK: - Builders

private func chapterTag(version: Int, frames: [Data], padding: Int = 0) -> Data {
    let body = frames.reduce(Data(), +) + Data(repeating: 0, count: padding)
    return Data("ID3".utf8) + Data([UInt8(version), 0, 0]) + id3SyncSafe(body.count) + body
}

private func chapFrame(
    version: Int,
    id: String,
    start: UInt32,
    title: String?,
    description: String? = nil,
    extraSubframes: [Data] = []
) -> Data {
    var payload = Data(id.utf8) + Data([0])
    payload += id3UInt32(Int(start)) + id3UInt32(Int(start) + 1_000)
    payload += Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    if let title {
        payload += frame(version: version, id: "TIT2", payload: Data([3]) + Data(title.utf8))
    }
    if let description {
        payload += frame(version: version, id: "TIT3", payload: Data([3]) + Data(description.utf8))
    }
    payload += extraSubframes.reduce(Data(), +)
    return frame(version: version, id: "CHAP", payload: payload)
}

private func ctocFrame(version: Int, id: String, topLevel: Bool, entries: [String]) -> Data {
    var payload = Data(id.utf8) + Data([0, topLevel ? 0x03 : 0x01, UInt8(entries.count)])
    for entry in entries { payload += Data(entry.utf8) + Data([0]) }
    return frame(version: version, id: "CTOC", payload: payload)
}

private func frame(version: Int, id: String, payload: Data) -> Data {
    Data(id.utf8)
        + (version == 4 ? id3SyncSafe(payload.count) : id3UInt32(payload.count))
        + Data([0, 0])
        + payload
}

private func id3UInt32(_ value: Int) -> Data {
    Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}

private func id3SyncSafe(_ value: Int) -> Data {
    Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
}
