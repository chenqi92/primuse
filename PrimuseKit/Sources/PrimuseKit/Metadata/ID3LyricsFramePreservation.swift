import Foundation

/// Keeps a file's ID3 unsynchronised-lyrics frames intact across a tag edit.
///
/// The tagging library rewrites lyrics on every save: it drops all `USLT`
/// frames and recreates a single one from the first frame's text, without a
/// language or a descriptor. A file that carries the original and a
/// translation as two frames therefore loses one of them whenever any other
/// field is edited. The frame bodies read here are put back after the save.
///
/// Both directions are deliberately strict. Anything unusual — compression,
/// encryption, a frame that cannot be walked — yields `nil`, and the caller
/// leaves the saved file as the library wrote it.
public enum ID3LyricsFramePreservation {
    /// Bodies of every `USLT` (`ULT` in ID3v2.2) frame, in file order, with
    /// unsynchronisation reversed: encoding byte, language, descriptor, text.
    /// The layout is identical across ID3v2.2–2.4, so a body can be re-framed
    /// without being decoded. An empty array means the tag has no such frame.
    public static func lyricsFrameBodies(in data: Data) -> [Data]? {
        guard let tag = Tag(data) else { return nil }
        var bodies: [Data] = []
        for frame in tag.frames where frame.isLyrics {
            guard let body = frame.body else { return nil }
            bodies.append(body)
        }
        return bodies
    }

    /// Replaces the lyrics frames of a freshly saved tag with `bodies`.
    ///
    /// Only the shape the tagging library writes is accepted: ID3v2.3/2.4
    /// without tag-level unsynchronisation, extended header or footer. Every
    /// other frame is kept byte for byte and in order. The tag keeps its size
    /// when the padding can absorb the difference and grows otherwise.
    public static func replacingLyricsFrames(in data: Data, with bodies: [Data]) -> Data? {
        guard let tag = Tag(data),
              tag.version == 3 || tag.version == 4,
              tag.headerFlags & 0xD0 == 0,
              tag.frames.allSatisfy({ !$0.isLyrics || $0.body != nil }) else {
            return nil
        }
        for body in bodies {
            guard body.count >= 5,
                  tag.version == 4 || body[body.startIndex] <= 1,
                  body.count <= Tag.maximumFrameSize(version: tag.version) else {
                return nil
            }
        }

        var frames = Data()
        var insertedLyrics = false
        func appendLyrics() {
            guard !insertedLyrics else { return }
            insertedLyrics = true
            for body in bodies {
                frames.append(contentsOf: [0x55, 0x53, 0x4C, 0x54]) // "USLT"
                frames.append(Tag.encodedFrameSize(body.count, version: tag.version))
                frames.append(contentsOf: [0x00, 0x00])
                frames.append(body)
            }
        }
        for frame in tag.frames {
            if frame.isLyrics {
                appendLyrics()
            } else {
                frames.append(tag.body[frame.range])
            }
        }
        appendLyrics()

        let tagSize = frames.count <= tag.body.count
            ? tag.body.count
            : frames.count + 1024
        guard tagSize <= 0x0FFF_FFFF else { return nil }

        var result = Data(capacity: 10 + tagSize + (data.count - tag.end))
        result.append(data[data.startIndex..<(data.startIndex + 6)])
        result.append(Tag.synchsafe(tagSize))
        result.append(frames)
        result.append(Data(count: tagSize - frames.count))
        result.append(data[(data.startIndex + tag.end)...])
        return result
    }

    // MARK: - Tag walking

    private struct Frame {
        /// Header plus payload, relative to the tag body.
        let range: Range<Int>
        let isLyrics: Bool
        /// Lyrics frames only: the decoded body, or nil when it cannot be
        /// carried over (compressed, encrypted, grouped or malformed).
        let body: Data?
    }

    private struct Tag {
        let version: UInt8
        let headerFlags: UInt8
        /// Everything between the ten-byte header and the end of the tag,
        /// after tag-level unsynchronisation (ID3v2.2/2.3) has been reversed.
        let body: Data
        /// Offset of the first byte after the tag, relative to the file start.
        let end: Int
        let frames: [Frame]

        init?(_ data: Data) {
            let base = data.startIndex
            guard data.count >= 10,
                  data[base] == 0x49, data[base + 1] == 0x44, data[base + 2] == 0x33,
                  (2...4).contains(data[base + 3]),
                  data[base + 4] != 0xFF,
                  (6..<10).allSatisfy({ data[base + $0] < 0x80 }) else {
                return nil
            }
            version = data[base + 3]
            headerFlags = data[base + 5]
            let size = (Int(data[base + 6]) << 21) | (Int(data[base + 7]) << 14)
                | (Int(data[base + 8]) << 7) | Int(data[base + 9])
            guard size > 0, 10 + size <= data.count else { return nil }
            end = 10 + size

            // ID3v2.2 defines bit 6 as a compression scheme nobody implemented.
            if version == 2, headerFlags & 0x40 != 0 { return nil }
            var body = Data(data[(base + 10)..<(base + end)])
            if version < 4, headerFlags & 0x80 != 0 {
                body = Tag.removingUnsynchronisation(body)
            }
            self.body = body

            var cursor = 0
            if version >= 3, headerFlags & 0x40 != 0 {
                guard body.count >= 4 else { return nil }
                let declared = version == 4
                    ? Tag.synchsafeValue(body, at: 0)
                    : Tag.bigEndianValue(body, at: 0, length: 4).map { $0 + 4 }
                guard let declared, declared >= 6, declared <= body.count else { return nil }
                cursor = declared
            }

            guard let frames = Tag.walk(body, from: cursor, version: version) else { return nil }
            self.frames = frames
        }

        private static func walk(_ body: Data, from start: Int, version: UInt8) -> [Frame]? {
            let idLength = version == 2 ? 3 : 4
            let headerLength = version == 2 ? 6 : 10
            var frames: [Frame] = []
            var cursor = start
            while cursor < body.count {
                if body[cursor] == 0x00 { break } // padding
                guard cursor + headerLength <= body.count,
                      isFrameIdentifier(body, at: cursor, length: idLength) else {
                    return nil
                }
                guard let size = frameSize(
                    body, at: cursor, idLength: idLength,
                    headerLength: headerLength, version: version
                ) else { return nil }
                let payloadStart = cursor + headerLength
                let payloadEnd = payloadStart + size
                let identifier = body[cursor..<(cursor + idLength)]
                let isLyrics = identifier.elementsEqual(version == 2 ? [0x55, 0x4C, 0x54] : [0x55, 0x53, 0x4C, 0x54])
                var decoded: Data?
                if isLyrics {
                    let formatFlags: UInt8 = version == 2 ? 0 : body[cursor + 9]
                    decoded = lyricsBody(
                        Data(body[payloadStart..<payloadEnd]),
                        formatFlags: formatFlags,
                        version: version
                    )
                }
                frames.append(Frame(range: cursor..<payloadEnd, isLyrics: isLyrics, body: decoded))
                cursor = payloadEnd
            }
            // Whatever follows the last frame has to be padding, otherwise the
            // walk went wrong somewhere and nothing it found can be trusted.
            guard body[cursor...].allSatisfy({ $0 == 0x00 }) else { return nil }
            return frames
        }

        /// Resolves the frame size. Some writers store plain big-endian sizes in
        /// ID3v2.4 tags, so an ambiguous value is accepted only in the reading
        /// that lands on another frame, on padding, or on the end of the tag.
        private static func frameSize(
            _ body: Data,
            at cursor: Int,
            idLength: Int,
            headerLength: Int,
            version: UInt8
        ) -> Int? {
            let sizeOffset = cursor + idLength
            func lands(_ size: Int) -> Bool {
                guard size > 0 else { return false }
                let next = cursor + headerLength + size
                if next == body.count { return true }
                guard next < body.count else { return false }
                if body[next] == 0x00 {
                    // Padding runs to the end of the tag. A zero byte in the
                    // middle of a payload is just a misread size.
                    return body[next...].allSatisfy { $0 == 0x00 }
                }
                return next + headerLength <= body.count
                    && isFrameIdentifier(body, at: next, length: idLength)
            }
            if version == 2 {
                guard let size = bigEndianValue(body, at: sizeOffset, length: 3), lands(size) else {
                    return nil
                }
                return size
            }
            guard let plain = bigEndianValue(body, at: sizeOffset, length: 4) else { return nil }
            if version == 3 { return lands(plain) ? plain : nil }
            if let synchsafe = synchsafeValue(body, at: sizeOffset), lands(synchsafe) {
                return synchsafe
            }
            return lands(plain) ? plain : nil
        }

        private static func lyricsBody(_ payload: Data, formatFlags: UInt8, version: UInt8) -> Data? {
            var payload = payload
            if version == 4 {
                // Grouping, compression and encryption change what the payload
                // means; unsynchronisation and the length indicator do not.
                guard formatFlags & 0x4C == 0 else { return nil }
                if formatFlags & 0x01 != 0 {
                    guard payload.count >= 4 else { return nil }
                    payload = Data(payload.dropFirst(4))
                }
                if formatFlags & 0x02 != 0 {
                    payload = removingUnsynchronisation(payload)
                }
            } else if version == 3 {
                guard formatFlags & 0xE0 == 0 else { return nil }
            }
            // Encoding, three language bytes and at least a descriptor terminator.
            guard payload.count >= 5, payload[payload.startIndex] <= 3 else { return nil }
            return payload
        }

        private static func isFrameIdentifier(_ body: Data, at offset: Int, length: Int) -> Bool {
            guard offset + length <= body.count else { return false }
            return body[offset..<(offset + length)].allSatisfy {
                (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
            }
        }

        static func removingUnsynchronisation(_ data: Data) -> Data {
            var result = Data(capacity: data.count)
            var previousWasFF = false
            for byte in data {
                if previousWasFF, byte == 0x00 {
                    previousWasFF = false
                    continue
                }
                result.append(byte)
                previousWasFF = byte == 0xFF
            }
            return result
        }

        static func bigEndianValue(_ data: Data, at offset: Int, length: Int) -> Int? {
            guard offset >= 0, offset + length <= data.count else { return nil }
            var value = 0
            for index in 0..<length {
                value = (value << 8) | Int(data[data.startIndex + offset + index])
            }
            return value
        }

        static func synchsafeValue(_ data: Data, at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            var value = 0
            for index in 0..<4 {
                let byte = data[data.startIndex + offset + index]
                guard byte < 0x80 else { return nil }
                value = (value << 7) | Int(byte)
            }
            return value
        }

        static func synchsafe(_ value: Int) -> Data {
            Data([
                UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
                UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
            ])
        }

        static func encodedFrameSize(_ value: Int, version: UInt8) -> Data {
            if version == 4 { return synchsafe(value) }
            return Data([
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ])
        }

        static func maximumFrameSize(version: UInt8) -> Int {
            version == 4 ? 0x0FFF_FFFF : Int(Int32.max)
        }
    }
}
