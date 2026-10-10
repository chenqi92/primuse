import Foundation

/// Where a file's encoded audio begins, read from its first bytes.
///
/// A queue prefetch seed should let the decoder open the file and play its
/// first seconds without the network. Tags and cover art in front of the audio
/// (an ID3v2 tag carrying a large picture, FLAC PICTURE blocks, an MP4 `moov`
/// with `covr`) can fill a seed sized from the top of the file before the
/// first audio frame, and an MP4 whose `moov` follows the audio cannot be
/// opened from a short tail.
public enum AudioPayloadStart: Sendable, Equatable {
    /// The audio begins at this byte offset.
    case at(Int64)
    /// The leading metadata runs at least to this offset. Read up to it and
    /// locate again.
    case beyond(Int64)
    /// No leading structure this parser knows; the audio is taken to start
    /// at the top of the file.
    case unrecognized
}

public struct AudioPayloadLayout: Sendable, Equatable {
    public var audioStart: AudioPayloadStart
    /// An MP4 whose index follows its audio: everything from this offset to
    /// the end of the file is read before the first sample can be decoded.
    public var trailingIndexStart: Int64?

    public init(audioStart: AudioPayloadStart, trailingIndexStart: Int64? = nil) {
        self.audioStart = audioStart
        self.trailingIndexStart = trailingIndexStart
    }

    private static let maximumStructureCount = 512

    public static func locate(head: Data, fileSize: Int64) -> AudioPayloadLayout {
        // Only a few header bytes are read; index the data in place instead
        // of copying a head that can run to several megabytes.
        let bytes = ByteView(head)
        let available = Int64(bytes.count)
        let limit = fileSize > 0 ? fileSize : Int64.max
        var offset: Int64 = 0

        // ID3v2 tags, possibly more than one, in front of MP3, AAC and some FLAC.
        for _ in 0..<maximumStructureCount {
            guard offset + 3 <= available else {
                return AudioPayloadLayout(audioStart: offset > 0 ? .beyond(offset + 4) : .unrecognized)
            }
            guard bytes[Int(offset)] == 0x49, bytes[Int(offset) + 1] == 0x44, bytes[Int(offset) + 2] == 0x33 else {
                break
            }
            guard offset + 10 <= available else {
                return AudioPayloadLayout(audioStart: .beyond(offset + 10))
            }
            let base = Int(offset)
            let flags = bytes[base + 5]
            let sizeBytes = (6...9).map { bytes[base + $0] }
            guard bytes[base + 3] != 0xFF, bytes[base + 4] != 0xFF,
                  sizeBytes.allSatisfy({ $0 < 0x80 }) else {
                return AudioPayloadLayout(audioStart: offset > 0 ? .at(offset) : .unrecognized)
            }
            let size = sizeBytes.reduce(Int64(0)) { ($0 << 7) | Int64($1) }
            let footer: Int64 = flags & 0x10 != 0 ? 10 : 0
            let next = offset + 10 + size + footer
            guard next <= limit else { return AudioPayloadLayout(audioStart: .unrecognized) }
            offset = next
        }

        if let flac = locateFLAC(bytes: bytes, at: offset, limit: limit) {
            return AudioPayloadLayout(audioStart: flac)
        }
        if offset == 0, let mp4 = locateMP4(bytes: bytes, limit: limit) {
            return mp4
        }
        if offset >= available, offset > 0 {
            return AudioPayloadLayout(audioStart: .beyond(offset + 4))
        }
        return AudioPayloadLayout(audioStart: offset > 0 ? .at(offset) : .unrecognized)
    }

    private static func locateFLAC(bytes: ByteView, at start: Int64, limit: Int64) -> AudioPayloadStart? {
        let available = Int64(bytes.count)
        guard start + 4 <= available else { return nil }
        let base = Int(start)
        guard bytes[base] == 0x66, bytes[base + 1] == 0x4C,
              bytes[base + 2] == 0x61, bytes[base + 3] == 0x43 else { return nil }
        var blockStart = start + 4
        for _ in 0..<maximumStructureCount {
            guard blockStart + 4 <= available else { return .beyond(blockStart + 4) }
            let header = Int(blockStart)
            let isLast = bytes[header] & 0x80 != 0
            let length = Int64(bytes[header + 1]) << 16 | Int64(bytes[header + 2]) << 8 | Int64(bytes[header + 3])
            let next = blockStart + 4 + length
            guard next <= limit else { return .unrecognized }
            if isLast { return .at(next) }
            blockStart = next
        }
        return .unrecognized
    }

    private static func locateMP4(bytes: ByteView, limit: Int64) -> AudioPayloadLayout? {
        let available = Int64(bytes.count)
        guard available >= 8,
              bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 else { return nil }
        var boxStart: Int64 = 0
        for _ in 0..<maximumStructureCount {
            guard boxStart + 8 <= available else {
                return AudioPayloadLayout(audioStart: .beyond(boxStart + 16))
            }
            let base = Int(boxStart)
            var size = (0..<4).reduce(Int64(0)) { ($0 << 8) | Int64(bytes[base + $1]) }
            let isMediaData = bytes[base + 4] == 0x6D && bytes[base + 5] == 0x64
                && bytes[base + 6] == 0x61 && bytes[base + 7] == 0x74
            var headerSize: Int64 = 8
            if size == 1 {
                guard boxStart + 16 <= available else {
                    return AudioPayloadLayout(audioStart: .beyond(boxStart + 16))
                }
                size = (8..<16).reduce(Int64(0)) { ($0 << 8) | Int64(bytes[base + $1]) }
                headerSize = 16
            } else if size == 0 {
                size = limit == .max ? 0 : limit - boxStart
            }
            guard size >= headerSize, boxStart + size <= limit else {
                return AudioPayloadLayout(audioStart: .unrecognized)
            }
            if isMediaData {
                let end = boxStart + size
                return AudioPayloadLayout(
                    audioStart: .at(boxStart + headerSize),
                    trailingIndexStart: limit != .max && end < limit ? end : nil
                )
            }
            boxStart += size
        }
        return AudioPayloadLayout(audioStart: .unrecognized)
    }
}

/// Zero-based reads into a `Data` that may be a slice.
private struct ByteView {
    let data: Data
    init(_ data: Data) { self.data = data }
    var count: Int { data.count }
    subscript(index: Int) -> UInt8 { data[data.startIndex + index] }
}
