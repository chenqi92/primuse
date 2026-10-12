import Foundation

/// Retags FLAC metadata blocks of the forbidden type 127 as PADDING.
///
/// The FLAC format reserves block type 127 as invalid, so it can never be
/// mistaken for a frame sync code, yet some taggers write it. libFLAC and
/// FFmpeg skip such a block, but Apple's FLAC parser (AVPlayer, AVAudioFile,
/// Core Audio) rejects the whole file with `'dta?'`. Rewriting the one type
/// byte to PADDING (1) keeps every length and offset and leaves the audio
/// frames untouched, and Apple's parser reads on past it.
///
/// Bytes are fed in the order they are handed to the decoder, from any number
/// of overlapping or repeated reads. Each block header is located from the
/// one before it and fixed before it is handed on. Anything that does not
/// look like a FLAC stream (no `fLaC` marker, a first block other than
/// STREAMINFO) stops the walk without touching a byte.
public final class FLACForbiddenBlockRepair: @unchecked Sendable {
    public static let forbiddenBlockType: UInt8 = 127
    public static let paddingBlockType: UInt8 = 1

    /// A FLAC file carries a handful of metadata blocks; a chain this long
    /// is not one the walk can trust.
    static let maximumBlockCount = 256

    private enum Expectation {
        /// `fLaC`, or an ID3v2 tag in front of it.
        case leadingStructure(at: Int64)
        /// `fLaC` after an ID3v2 tag.
        case marker(at: Int64)
        case blockHeader(at: Int64, index: Int)
        case finished

        var start: Int64? {
            switch self {
            case .leadingStructure(let offset), .marker(let offset), .blockHeader(let offset, _):
                offset
            case .finished:
                nil
            }
        }
    }

    private static let flacMarker: [UInt8] = Array("fLaC".utf8)
    private static let id3Marker: [UInt8] = Array("ID3".utf8)

    private let lock = NSLock()
    private var expectation = Expectation.leadingStructure(at: 0)
    private var collected: [UInt8] = []
    private var forbiddenHeaders: [Int64] = []
    private let onRepair: (@Sendable (Int64) -> Void)?

    /// `onRepair` is called once for each forbidden block header found, with
    /// its byte offset.
    public init(onRepair: (@Sendable (Int64) -> Void)? = nil) {
        self.onRepair = onRepair
    }

    /// Offsets of the forbidden block headers found so far.
    public var repairedHeaderOffsets: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return forbiddenHeaders
    }

    /// The next byte the walk needs, or nil once it has passed the last
    /// metadata block or given up.
    var pendingOffset: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return expectation.start.map { $0 + Int64(collected.count) }
    }

    /// `data` as it should reach the decoder, given that it starts at byte
    /// `offset` of the file.
    public func repairing(_ data: Data, at offset: Int64) -> Data {
        guard !data.isEmpty, offset >= 0 else { return data }
        let end = offset + Int64(data.count)
        lock.lock()
        let found = advance(through: data, offset: offset, end: end)
        let targets = forbiddenHeaders.filter { $0 >= offset && $0 < end }
        lock.unlock()
        for header in found { onRepair?(header) }
        guard !targets.isEmpty else { return data }

        var repaired = data
        for header in targets {
            let index = repaired.startIndex + Int(header - offset)
            let value = repaired[index]
            guard value & 0x7F == Self.forbiddenBlockType else { continue }
            repaired[index] = (value & 0x80) | Self.paddingBlockType
        }
        return repaired
    }

    /// Walks as far as `data` allows. Returns the forbidden headers it found.
    private func advance(through data: Data, offset: Int64, end: Int64) -> [Int64] {
        var found: [Int64] = []
        // Each pass either finishes an expectation or returns.
        for _ in 0...(Self.maximumBlockCount + 2) {
            guard let start = expectation.start else { return found }
            var next = start + Int64(collected.count)
            guard next >= offset, next < end else { return found }
            while collected.count < requiredCount(), next < end {
                collected.append(data[data.startIndex + Int(next - offset)])
                next += 1
                if case .blockHeader(_, let index) = expectation, index > 0, collected.count == 1,
                   collected[0] & 0x7F == Self.forbiddenBlockType {
                    forbiddenHeaders.append(start)
                    found.append(start)
                }
            }
            guard collected.count >= requiredCount() else { return found }
            resolve(start: start)
            collected.removeAll(keepingCapacity: true)
        }
        return found
    }

    private func requiredCount() -> Int {
        switch expectation {
        case .leadingStructure:
            collected.count >= 3 && Array(collected.prefix(3)) == Self.id3Marker ? 10 : 4
        case .marker, .blockHeader:
            4
        case .finished:
            0
        }
    }

    private func resolve(start: Int64) {
        switch expectation {
        case .leadingStructure:
            if Array(collected.prefix(4)) == Self.flacMarker {
                expectation = .blockHeader(at: start + 4, index: 0)
            } else if Array(collected.prefix(3)) == Self.id3Marker,
                      collected[6...9].allSatisfy({ $0 < 0x80 }) {
                let size = collected[6...9].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
                let footer: Int64 = collected[5] & 0x10 != 0 ? 10 : 0
                expectation = .marker(at: start + 10 + size + footer)
            } else {
                expectation = .finished
            }
        case .marker:
            expectation = collected == Self.flacMarker
                ? .blockHeader(at: start + 4, index: 0)
                : .finished
        case .blockHeader(_, let index):
            let type = collected[0] & 0x7F
            let isLast = collected[0] & 0x80 != 0
            let length = Int64(collected[1]) << 16 | Int64(collected[2]) << 8 | Int64(collected[3])
            if index == 0, type != 0 || length != 34 {
                expectation = .finished
            } else if isLast || index + 1 >= Self.maximumBlockCount {
                expectation = .finished
            } else {
                expectation = .blockHeader(at: start + 4 + length, index: index + 1)
            }
        case .finished:
            break
        }
    }

    // MARK: - Local files

    /// Offsets of the forbidden block headers in a local file; empty when it
    /// has none or is not a FLAC stream.
    public static func forbiddenHeaderOffsets(inFileAt url: URL) throws -> [Int64] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let walk = FLACForbiddenBlockRepair()
        for _ in 0...(maximumBlockCount + 2) {
            guard let offset = walk.pendingOffset else { break }
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: 16), !chunk.isEmpty else { break }
            _ = walk.repairing(chunk, at: offset)
        }
        return walk.repairedHeaderOffsets
    }

    /// Retags the file's forbidden block headers in place. Returns whether
    /// any were found.
    @discardableResult
    public static func repairFile(at url: URL) throws -> Bool {
        let headers = try forbiddenHeaderOffsets(inFileAt: url)
        guard !headers.isEmpty else { return false }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for header in headers {
            try handle.seek(toOffset: UInt64(header))
            guard let value = try handle.read(upToCount: 1)?.first,
                  value & 0x7F == forbiddenBlockType else { continue }
            try handle.seek(toOffset: UInt64(header))
            try handle.write(contentsOf: [(value & 0x80) | paddingBlockType])
        }
        return true
    }
}
