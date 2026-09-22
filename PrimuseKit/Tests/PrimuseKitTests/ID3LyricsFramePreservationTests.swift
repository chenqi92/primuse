import Foundation
import Testing
@testable import PrimuseKit

@Suite("ID3 lyrics frame preservation")
struct ID3LyricsFramePreservationTests {
    private let audio = Data([0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02, 0x03, 0x04])

    // MARK: Reading

    @Test("Reads every lyrics frame of an ID3v2.3 tag in file order")
    func readsMultipleFramesInOrder() {
        let original = lyricsBody(language: "jpn", descriptor: "", text: "[00:01.00]原文")
        let translation = lyricsBody(language: "eng", descriptor: "translation", text: "[00:01.00]Translation")
        let file = tag(version: 3, frames: [
            frame("TIT2", body: textBody("Title"), version: 3),
            frame("USLT", body: original, version: 3),
            frame("USLT", body: translation, version: 3),
        ], padding: 64) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [original, translation])
    }

    @Test("Reads the three-character ULT frame of ID3v2.2")
    func readsVersion22() {
        let body = lyricsBody(language: "eng", descriptor: "", text: "Old tag")
        let file = tag(version: 2, frames: [
            frame("TT2", body: textBody("Title"), version: 2),
            frame("ULT", body: body, version: 2),
        ], padding: 10) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [body])
    }

    @Test("Accepts ID3v2.4 frames whose size was stored as a plain integer")
    func readsPlainSizesInVersion24() {
        let long = lyricsBody(language: "eng", descriptor: "", text: String(repeating: "la ", count: 100))
        #expect(long.count > 127)
        var plain = Data("USLT".utf8)
        plain.append(bigEndian(long.count))
        plain.append(contentsOf: [0, 0])
        plain.append(long)
        let file = tag(version: 4, frames: [
            plain,
            frame("TIT2", body: textBody("Title"), version: 4),
        ], padding: 32) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [long])
    }

    @Test("A zero byte inside a payload is not mistaken for padding")
    func plainSizeLandingOnZeroByte() {
        // Read as synchsafe, 0x0000_0101 is 129 and lands on the zero planted at
        // payload offset 129; the frame is really 257 bytes long.
        var text = Data(repeating: 0x61, count: 252)
        text[124] = 0x00
        let body = Data([0x00]) + Data("eng".utf8) + Data([0x00]) + text
        #expect(body.count == 257)
        var plain = Data("USLT".utf8)
        plain.append(bigEndian(body.count))
        plain.append(contentsOf: [0, 0])
        plain.append(body)
        let file = tag(version: 4, frames: [
            plain,
            frame("TIT2", body: textBody("Title"), version: 4),
        ], padding: 16) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [body])
    }

    @Test("Reverses frame-level unsynchronisation in ID3v2.4")
    func reversesFrameUnsynchronisation() {
        let body = Data([0x00]) + Data("eng".utf8) + Data([0x00, 0xFF, 0xE0, 0x41])
        let stored = Data([0x00]) + Data("eng".utf8) + Data([0x00, 0xFF, 0x00, 0xE0, 0x41])
        let file = tag(version: 4, frames: [
            frame("USLT", body: stored, version: 4, formatFlags: 0x02),
        ], padding: 16) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [body])
    }

    @Test("Reverses tag-level unsynchronisation in ID3v2.3")
    func reversesTagUnsynchronisation() {
        let body = Data([0x00]) + Data("eng".utf8) + Data([0x00, 0xFF, 0xE0, 0x41])
        let plainFrames = frame("USLT", body: body, version: 3)
        var unsynchronised = Data()
        for byte in plainFrames {
            unsynchronised.append(byte)
            if byte == 0xFF { unsynchronised.append(0x00) }
        }
        let file = rawTag(version: 3, flags: 0x80, body: unsynchronised + Data(count: 8)) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [body])
    }

    @Test("Skips an ID3v2.3 extended header")
    func skipsExtendedHeader() {
        let body = lyricsBody(language: "eng", descriptor: "", text: "Extended")
        let extendedHeader = bigEndian(6) + Data(count: 6)
        let file = rawTag(
            version: 3,
            flags: 0x40,
            body: extendedHeader + frame("USLT", body: body, version: 3) + Data(count: 4)
        ) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [body])
    }

    @Test("A tag without lyrics frames reports none")
    func reportsNoLyrics() {
        let file = tag(version: 4, frames: [
            frame("TIT2", body: textBody("Title"), version: 4),
        ], padding: 12) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: file) == [])
    }

    @Test("Refuses compressed or encrypted lyrics frames")
    func refusesTransformedFrames() {
        let body = lyricsBody(language: "eng", descriptor: "", text: "Secret")
        let compressed24 = tag(version: 4, frames: [
            frame("USLT", body: body, version: 4, formatFlags: 0x08),
        ], padding: 8) + audio
        let encrypted23 = tag(version: 3, frames: [
            frame("USLT", body: body, version: 3, formatFlags: 0x40),
        ], padding: 8) + audio

        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: compressed24) == nil)
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: encrypted23) == nil)
    }

    @Test("Refuses data that is not a walkable ID3v2 tag")
    func refusesUnreadableTags() {
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: Data()) == nil)
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: audio) == nil)

        let truncated = tag(version: 3, frames: [
            frame("TIT2", body: textBody("Title"), version: 3),
        ], padding: 0).dropLast(3)
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: Data(truncated)) == nil)

        var overrun = frame("TIT2", body: textBody("Title"), version: 3)
        overrun.replaceSubrange(4..<8, with: bigEndian(4_000))
        #expect(
            ID3LyricsFramePreservation.lyricsFrameBodies(
                in: rawTag(version: 3, flags: 0, body: overrun) + audio
            ) == nil
        )

        let junkAfterFrames = rawTag(
            version: 3,
            flags: 0,
            body: frame("TIT2", body: textBody("Title"), version: 3) + Data([0x00, 0x00, 0x7F, 0x00])
        ) + audio
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: junkAfterFrames) == nil)
    }

    // MARK: Replacing

    @Test("Puts the original frames back where the saved one was, inside the padding")
    func replacesWithinPadding() throws {
        let original = lyricsBody(language: "jpn", descriptor: "", text: "[00:01.00]原文")
        let translation = lyricsBody(language: "eng", descriptor: "tr", text: "[00:01.00]Translation")
        let title = frame("TIT2", body: textBody("New title"), version: 4)
        let picture = frame("APIC", body: Data([0x00]) + Data("image/png".utf8) + Data([0x00, 0x03, 0x00, 0x89, 0x50]), version: 4)
        let collapsed = frame(
            "USLT",
            body: lyricsBody(language: "XXX", descriptor: "", text: "[00:01.00]原文", encoding: 3),
            version: 4
        )
        let saved = tag(version: 4, frames: [title, collapsed, picture], padding: 1024) + audio

        let restored = try #require(
            ID3LyricsFramePreservation.replacingLyricsFrames(in: saved, with: [original, translation])
        )

        #expect(restored.count == saved.count)
        #expect(restored.prefix(10) == saved.prefix(10))
        #expect(restored.suffix(audio.count) == audio)
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: restored) == [original, translation])
        let expectedFrames = title
            + frame("USLT", body: original, version: 4)
            + frame("USLT", body: translation, version: 4)
            + picture
        #expect(restored.dropFirst(10).prefix(expectedFrames.count) == expectedFrames)
        #expect(
            restored.dropFirst(10 + expectedFrames.count).dropLast(audio.count).allSatisfy { $0 == 0 }
        )
    }

    @Test("Grows the tag when the padding cannot absorb the frames")
    func growsTag() throws {
        let long = lyricsBody(language: "eng", descriptor: "", text: String(repeating: "line\n", count: 80))
        let title = frame("TIT2", body: textBody("Title"), version: 4)
        let saved = tag(version: 4, frames: [
            title,
            frame("USLT", body: lyricsBody(language: "XXX", descriptor: "", text: "x"), version: 4),
        ], padding: 4) + audio

        let restored = try #require(
            ID3LyricsFramePreservation.replacingLyricsFrames(in: saved, with: [long, long])
        )

        #expect(restored.count > saved.count)
        #expect(restored.suffix(audio.count) == audio)
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: restored) == [long, long])
        let declaredSize = restored[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        #expect(restored.count == 10 + declaredSize + audio.count)
        #expect(restored.dropFirst(10).prefix(title.count) == title)
    }

    @Test("Appends the frames when the saved tag has none")
    func appendsWhenSavedTagHasNoLyrics() throws {
        let body = lyricsBody(language: "eng", descriptor: "", text: "Kept")
        let title = frame("TIT2", body: textBody("Title"), version: 3)
        let saved = tag(version: 3, frames: [title], padding: 128) + audio

        let restored = try #require(
            ID3LyricsFramePreservation.replacingLyricsFrames(in: saved, with: [body])
        )

        #expect(restored.count == saved.count)
        #expect(ID3LyricsFramePreservation.lyricsFrameBodies(in: restored) == [body])
        #expect(restored.dropFirst(10).prefix(title.count) == title)
    }

    @Test("Replacing with the frames already present changes nothing")
    func replacementIsIdempotent() throws {
        let body = lyricsBody(language: "eng", descriptor: "", text: "Same")
        let saved = tag(version: 4, frames: [
            frame("TIT2", body: textBody("Title"), version: 4),
            frame("USLT", body: body, version: 4),
        ], padding: 40) + audio

        #expect(ID3LyricsFramePreservation.replacingLyricsFrames(in: saved, with: [body]) == saved)
    }

    @Test("Refuses tags it would have to restructure")
    func refusesUnexpectedSavedTags() {
        let body = lyricsBody(language: "eng", descriptor: "", text: "Text")
        let frames = frame("USLT", body: body, version: 4)
        let unsynchronised = rawTag(version: 4, flags: 0x80, body: frames + Data(count: 8)) + audio
        let footer = rawTag(version: 4, flags: 0x10, body: frames + Data(count: 8)) + audio
        let version22 = tag(version: 2, frames: [frame("ULT", body: body, version: 2)], padding: 8) + audio

        #expect(ID3LyricsFramePreservation.replacingLyricsFrames(in: unsynchronised, with: [body]) == nil)
        #expect(ID3LyricsFramePreservation.replacingLyricsFrames(in: footer, with: [body]) == nil)
        #expect(ID3LyricsFramePreservation.replacingLyricsFrames(in: version22, with: [body]) == nil)

        // UTF-8 (encoding 3) does not exist in ID3v2.3.
        let utf8Body = lyricsBody(language: "eng", descriptor: "", text: "Text", encoding: 3)
        let version23 = tag(version: 3, frames: [frame("USLT", body: body, version: 3)], padding: 8) + audio
        #expect(ID3LyricsFramePreservation.replacingLyricsFrames(in: version23, with: [utf8Body]) == nil)
        #expect(ID3LyricsFramePreservation.replacingLyricsFrames(in: version23, with: [Data([0x00, 0x65])]) == nil)
    }

    // MARK: Fixtures

    private func lyricsBody(
        language: String,
        descriptor: String,
        text: String,
        encoding: UInt8 = 0
    ) -> Data {
        var body = Data([encoding])
        body.append(Data(language.utf8))
        body.append(Data(descriptor.utf8))
        body.append(0x00)
        body.append(Data(text.utf8))
        return body
    }

    private func textBody(_ text: String) -> Data {
        Data([0x00]) + Data(text.utf8)
    }

    private func frame(
        _ identifier: String,
        body: Data,
        version: UInt8,
        formatFlags: UInt8 = 0
    ) -> Data {
        var result = Data(identifier.utf8)
        switch version {
        case 2:
            result.append(contentsOf: [
                UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF),
            ])
        case 3:
            result.append(bigEndian(body.count))
            result.append(contentsOf: [0x00, formatFlags])
        default:
            result.append(synchsafe(body.count))
            result.append(contentsOf: [0x00, formatFlags])
        }
        result.append(body)
        return result
    }

    private func tag(version: UInt8, frames: [Data], padding: Int) -> Data {
        rawTag(version: version, flags: 0, body: frames.reduce(Data(), +) + Data(count: padding))
    }

    private func rawTag(version: UInt8, flags: UInt8, body: Data) -> Data {
        var result = Data("ID3".utf8)
        result.append(contentsOf: [version, 0x00, flags])
        result.append(synchsafe(body.count))
        result.append(body)
        return result
    }

    private func synchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
        ])
    }

    private func bigEndian(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}
