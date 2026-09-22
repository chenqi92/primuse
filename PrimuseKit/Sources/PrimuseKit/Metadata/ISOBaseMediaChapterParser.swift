import Foundation

/// One chapter mark recovered from a media file.
public struct MediaChapter: Equatable, Sendable, Codable, Identifiable {
    /// Start of the chapter on the decoded timeline, in seconds.
    public var startTime: TimeInterval
    public var title: String

    public var id: String { "\(startTime)-\(title)" }

    public init(startTime: TimeInterval, title: String) {
        self.startTime = startTime
        self.title = title
    }
}

public extension Array where Element == MediaChapter {
    /// Index of the chapter covering `position`, or nil when the marks start
    /// after it. Chapters are expected sorted; playback asks this on every
    /// tick, so it walks backwards from the end rather than scanning.
    func chapterIndex(at position: TimeInterval) -> Int? {
        guard !isEmpty else { return nil }
        var low = 0
        var high = count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if self[mid].startTime <= position + 0.001 {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// Reads chapter marks out of an ISO base-media file (`.m4b` audiobooks and
/// the `.m4a`/`.mp4` releases that carry the same structures).
///
/// Two layouts exist in the wild and both are handled:
/// - **Nero `chpl`**, a flat list inside `moov/udta`. Titles are stored inline,
///   so nothing outside `moov` has to be read.
/// - **QuickTime chapter track**, a text track that another track points at
///   through `tref/chap`. Its titles live in the media data, so the sample
///   table has to be walked to find them. This is what Apple's own tools and
///   most audiobook converters write.
///
/// Every field is bounds-checked against untrusted bytes: a malformed or
/// truncated file yields no chapters rather than a crash.
public enum ISOBaseMediaChapterParser {
    /// Parses `data`, which must cover the whole file. Callers should map the
    /// file (`Data(contentsOf:options:.mappedIfSafe)`) instead of reading it:
    /// a QuickTime chapter track's titles sit in `mdat`, but only the pages
    /// holding them are ever touched.
    public static func chapters(in data: Data) -> [MediaChapter] {
        guard let moov = atoms(in: data, range: data.startIndex..<data.endIndex)
            .first(where: { $0.type == "moov" }) else { return [] }
        // `chpl` is preferred when present: it is self-contained, while the
        // chapter track needs the sample table to agree with the media data.
        let nero = neroChapters(in: data, moov: moov)
        if !nero.isEmpty { return sanitized(nero) }
        return sanitized(quickTimeChapters(in: data, moov: moov))
    }

    /// Drops marks that carry no title, orders them, and removes the duplicate
    /// start times some converters emit for a leading "chapter 0".
    private static func sanitized(_ chapters: [MediaChapter]) -> [MediaChapter] {
        var seenStarts = Set<Int64>()
        return chapters
            .filter { $0.startTime.isFinite && $0.startTime >= 0 && !$0.title.isEmpty }
            .sorted { $0.startTime < $1.startTime }
            .filter { seenStarts.insert(Int64(($0.startTime * 1000).rounded())).inserted }
    }

    // MARK: - Nero chpl

    private static func neroChapters(in data: Data, moov: Atom) -> [MediaChapter] {
        guard let udta = atoms(in: data, range: moov.payload)
                .first(where: { $0.type == "udta" }),
              let chpl = atoms(in: data, range: udta.payload)
                .first(where: { $0.type == "chpl" }) else { return [] }

        let end = chpl.payload.upperBound
        var cursor = chpl.payload.lowerBound
        guard cursor + 4 <= end else { return [] }
        let version = data[cursor]
        cursor += 4 // version + flags
        if version > 0 {
            // Version 1 writes a further 32-bit field before the count. Its
            // meaning is undocumented and no reader interprets it.
            guard cursor + 4 <= end else { return [] }
            cursor += 4
        }
        guard cursor < end else { return [] }
        let count = Int(data[cursor])
        cursor += 1

        var result: [MediaChapter] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 9 <= end,
                  let start = readUInt64BE(data, at: cursor) else { break }
            cursor += 8
            let length = Int(data[cursor])
            cursor += 1
            guard cursor + length <= end else { break }
            let title = decodeText(data[cursor..<(cursor + length)])
            cursor += length
            // chpl timestamps count 100-nanosecond units.
            result.append(MediaChapter(
                startTime: TimeInterval(start) / 10_000_000,
                title: title
            ))
        }
        return result
    }

    // MARK: - QuickTime chapter track

    private static func quickTimeChapters(in data: Data, moov: Atom) -> [MediaChapter] {
        let tracks = atoms(in: data, range: moov.payload).filter { $0.type == "trak" }
        var referencedIDs: Set<UInt32> = []
        for track in tracks {
            guard let tref = atoms(in: data, range: track.payload)
                    .first(where: { $0.type == "tref" }),
                  let chap = atoms(in: data, range: tref.payload)
                    .first(where: { $0.type == "chap" }) else { continue }
            var cursor = chap.payload.lowerBound
            while cursor + 4 <= chap.payload.upperBound {
                if let id = readUInt32BE(data, at: cursor) { referencedIDs.insert(id) }
                cursor += 4
            }
        }
        guard !referencedIDs.isEmpty else { return [] }

        for track in tracks {
            guard let id = trackID(of: track, in: data), referencedIDs.contains(id) else {
                continue
            }
            let chapters = textTrackChapters(track: track, in: data)
            if !chapters.isEmpty { return chapters }
        }
        return []
    }

    private static func trackID(of track: Atom, in data: Data) -> UInt32? {
        guard let tkhd = atoms(in: data, range: track.payload)
            .first(where: { $0.type == "tkhd" }) else { return nil }
        let base = tkhd.payload.lowerBound
        guard base < tkhd.payload.upperBound else { return nil }
        // FullBox: version/flags, then creation/modification time (32 or 64
        // bit by version) and the track ID.
        let version = data[base]
        let offset = version == 1 ? 20 : 12
        guard base + offset + 4 <= tkhd.payload.upperBound else { return nil }
        return readUInt32BE(data, at: base + offset)
    }

    private static func textTrackChapters(track: Atom, in data: Data) -> [MediaChapter] {
        guard let mdia = atoms(in: data, range: track.payload)
                .first(where: { $0.type == "mdia" }),
              let timescale = mediaTimescale(mdia: mdia, in: data),
              timescale > 0,
              let minf = atoms(in: data, range: mdia.payload)
                .first(where: { $0.type == "minf" }),
              let stbl = atoms(in: data, range: minf.payload)
                .first(where: { $0.type == "stbl" }) else { return [] }

        let locations = sampleLocations(stbl: stbl, in: data)
        guard !locations.isEmpty else { return [] }
        let startTimes = sampleStartTimes(stbl: stbl, in: data, timescale: timescale)
        guard !startTimes.isEmpty else { return [] }

        var result: [MediaChapter] = []
        for (index, location) in locations.enumerated() {
            guard index < startTimes.count else { break }
            guard let title = sampleTitle(at: location, in: data), !title.isEmpty else { continue }
            result.append(MediaChapter(startTime: startTimes[index], title: title))
        }
        return result
    }

    private static func mediaTimescale(mdia: Atom, in data: Data) -> UInt32? {
        guard let mdhd = atoms(in: data, range: mdia.payload)
            .first(where: { $0.type == "mdhd" }) else { return nil }
        let base = mdhd.payload.lowerBound
        guard base < mdhd.payload.upperBound else { return nil }
        let version = data[base]
        let offset = version == 1 ? 20 : 12
        guard base + offset + 4 <= mdhd.payload.upperBound else { return nil }
        return readUInt32BE(data, at: base + offset)
    }

    /// A text sample is a 16-bit byte count followed by the title. Trailing
    /// atoms (`encd`, style records) may follow and are ignored.
    private static func sampleTitle(at location: SampleLocation, in data: Data) -> String? {
        let start = data.startIndex + location.offset
        guard location.offset >= 0,
              location.size >= 2,
              start >= data.startIndex,
              start + location.size <= data.endIndex,
              let declared = readUInt16BE(data, at: start) else { return nil }
        let textStart = start + 2
        let available = min(Int(declared), start + location.size - textStart)
        guard available > 0 else { return nil }
        return decodeText(data[textStart..<(textStart + available)])
    }

    // MARK: - Sample table

    private struct SampleLocation {
        let offset: Int
        let size: Int
    }

    private static func sampleLocations(stbl: Atom, in data: Data) -> [SampleLocation] {
        let children = atoms(in: data, range: stbl.payload)
        guard let stsz = children.first(where: { $0.type == "stsz" }),
              let stsc = children.first(where: { $0.type == "stsc" }) else { return [] }
        let chunkOffsets = chunkOffsets(children: children, in: data)
        guard !chunkOffsets.isEmpty else { return [] }
        let sizes = sampleSizes(stsz: stsz, in: data)
        guard !sizes.isEmpty else { return [] }
        let runs = sampleToChunkRuns(stsc: stsc, in: data)
        guard !runs.isEmpty else { return [] }

        var result: [SampleLocation] = []
        result.reserveCapacity(sizes.count)
        var sampleIndex = 0
        for (runIndex, run) in runs.enumerated() {
            let firstChunk = max(1, Int(run.firstChunk))
            let lastChunk = runIndex + 1 < runs.count
                ? max(firstChunk, Int(runs[runIndex + 1].firstChunk) - 1)
                : chunkOffsets.count
            guard run.samplesPerChunk > 0 else { continue }
            for chunk in firstChunk...max(firstChunk, lastChunk) {
                guard chunk >= 1, chunk <= chunkOffsets.count else { break }
                var offset = chunkOffsets[chunk - 1]
                for _ in 0..<Int(run.samplesPerChunk) {
                    guard sampleIndex < sizes.count else { return result }
                    let size = Int(sizes[sampleIndex])
                    // An offset past the file cannot be trusted to be a sample.
                    guard offset >= 0, offset <= Int64(Int.max) else { return result }
                    result.append(SampleLocation(offset: Int(offset), size: size))
                    offset += Int64(size)
                    sampleIndex += 1
                }
            }
        }
        return result
    }

    private static func chunkOffsets(children: [Atom], in data: Data) -> [Int64] {
        if let stco = children.first(where: { $0.type == "stco" }) {
            return entries(of: stco, in: data, entryWidth: 4) { offset in
                readUInt32BE(data, at: offset).map(Int64.init)
            }
        }
        if let co64 = children.first(where: { $0.type == "co64" }) {
            return entries(of: co64, in: data, entryWidth: 8) { offset in
                readUInt64BE(data, at: offset).flatMap {
                    $0 <= UInt64(Int64.max) ? Int64($0) : nil
                }
            }
        }
        return []
    }

    private static func sampleSizes(stsz: Atom, in data: Data) -> [UInt32] {
        let base = stsz.payload.lowerBound
        guard base + 12 <= stsz.payload.upperBound,
              let uniformSize = readUInt32BE(data, at: base + 4),
              let count = readUInt32BE(data, at: base + 8) else { return [] }
        let sampleCount = Int(min(count, UInt32(maximumTableEntries)))
        if uniformSize > 0 {
            return Array(repeating: uniformSize, count: sampleCount)
        }
        var result: [UInt32] = []
        result.reserveCapacity(sampleCount)
        var cursor = base + 12
        for _ in 0..<sampleCount {
            guard cursor + 4 <= stsz.payload.upperBound,
                  let size = readUInt32BE(data, at: cursor) else { break }
            result.append(size)
            cursor += 4
        }
        return result
    }

    private struct SampleToChunkRun {
        let firstChunk: UInt32
        let samplesPerChunk: UInt32
    }

    private static func sampleToChunkRuns(stsc: Atom, in data: Data) -> [SampleToChunkRun] {
        let base = stsc.payload.lowerBound
        guard base + 8 <= stsc.payload.upperBound,
              let count = readUInt32BE(data, at: base + 4) else { return [] }
        let entryCount = Int(min(count, UInt32(maximumTableEntries)))
        var result: [SampleToChunkRun] = []
        result.reserveCapacity(entryCount)
        var cursor = base + 8
        for _ in 0..<entryCount {
            guard cursor + 12 <= stsc.payload.upperBound,
                  let firstChunk = readUInt32BE(data, at: cursor),
                  let samplesPerChunk = readUInt32BE(data, at: cursor + 4) else { break }
            result.append(SampleToChunkRun(
                firstChunk: firstChunk,
                samplesPerChunk: samplesPerChunk
            ))
            cursor += 12
        }
        return result
    }

    /// Start time of every sample, from the `stts` delta runs.
    private static func sampleStartTimes(
        stbl: Atom,
        in data: Data,
        timescale: UInt32
    ) -> [TimeInterval] {
        guard let stts = atoms(in: data, range: stbl.payload)
            .first(where: { $0.type == "stts" }) else { return [] }
        let base = stts.payload.lowerBound
        guard base + 8 <= stts.payload.upperBound,
              let count = readUInt32BE(data, at: base + 4) else { return [] }
        let entryCount = Int(min(count, UInt32(maximumTableEntries)))
        var result: [TimeInterval] = []
        var elapsed: UInt64 = 0
        var cursor = base + 8
        for _ in 0..<entryCount {
            guard cursor + 8 <= stts.payload.upperBound,
                  let sampleCount = readUInt32BE(data, at: cursor),
                  let delta = readUInt32BE(data, at: cursor + 4) else { break }
            cursor += 8
            for _ in 0..<min(Int(sampleCount), maximumTableEntries) {
                result.append(TimeInterval(elapsed) / TimeInterval(timescale))
                elapsed += UInt64(delta)
                if result.count >= maximumTableEntries { return result }
            }
        }
        return result
    }

    /// A chapter list this long is a corrupt table rather than a book, and the
    /// cap keeps a bad `entry_count` from allocating without bound.
    private static let maximumTableEntries = 100_000

    private static func entries<Value>(
        of atom: Atom,
        in data: Data,
        entryWidth: Int,
        read: (Int) -> Value?
    ) -> [Value] {
        let base = atom.payload.lowerBound
        guard base + 8 <= atom.payload.upperBound,
              let count = readUInt32BE(data, at: base + 4) else { return [] }
        let entryCount = Int(min(count, UInt32(maximumTableEntries)))
        var result: [Value] = []
        result.reserveCapacity(entryCount)
        var cursor = base + 8
        for _ in 0..<entryCount {
            guard cursor + entryWidth <= atom.payload.upperBound,
                  let value = read(cursor) else { break }
            result.append(value)
            cursor += entryWidth
        }
        return result
    }

    // MARK: - Text

    /// Chapter titles are UTF-8 unless a byte-order mark says otherwise. The
    /// shared encoding repair recovers the mislabeled GB18030/Big5/Shift_JIS
    /// text that older converters produce for non-Latin books.
    private static func decodeText(_ slice: Data) -> String {
        let bytes = Data(slice)
        guard !bytes.isEmpty else { return "" }
        let decoded: String?
        if hasUTF16ByteOrderMark(bytes) {
            decoded = TextEncodingRepair.bestDecoding(
                of: bytes,
                encodings: [.utf16, .utf16BigEndian, .utf16LittleEndian]
            )
        } else {
            decoded = TextEncodingRepair.bestDecoding(
                of: bytes,
                encodings: TextEncodingRepair.legacyTextEncodings
            )
        }
        guard let decoded else { return "" }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\0\u{FEFF}")
        )
        let normalized = decoded.trimmingCharacters(in: trimSet)
        guard !normalized.isEmpty else { return "" }
        return TextEncodingRepair.repaired(normalized) ?? normalized
    }

    private static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF)
            || (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE)
    }

    // MARK: - Atom reading

    private struct Atom {
        let type: String
        let full: Range<Int>
        let payload: Range<Int>
    }

    private static func atoms(in data: Data, range: Range<Int>) -> [Atom] {
        guard range.lowerBound >= data.startIndex,
              range.upperBound <= data.endIndex,
              range.lowerBound <= range.upperBound else { return [] }
        var result: [Atom] = []
        var cursor = range.lowerBound
        while cursor <= range.upperBound - 8,
              let child = atom(in: data, startingAt: cursor, limit: range.upperBound),
              child.full.upperBound <= range.upperBound,
              child.full.upperBound > cursor {
            result.append(child)
            cursor = child.full.upperBound
        }
        return result
    }

    private static func atom(in data: Data, startingAt offset: Int, limit: Int) -> Atom? {
        guard offset >= data.startIndex, offset + 8 <= limit,
              let size32 = readUInt32BE(data, at: offset),
              let type = fourCC(in: data, at: offset + 4) else { return nil }

        let headerLength: Int
        let totalLength: UInt64
        switch size32 {
        case 0:
            headerLength = 8
            totalLength = UInt64(limit - offset)
        case 1:
            guard offset + 16 <= limit,
                  let extended = readUInt64BE(data, at: offset + 8) else { return nil }
            headerLength = 16
            totalLength = extended
        default:
            headerLength = 8
            totalLength = UInt64(size32)
        }
        guard totalLength >= UInt64(headerLength),
              totalLength <= UInt64(limit - offset) else { return nil }
        let end = offset + Int(totalLength)
        return Atom(
            type: type,
            full: offset..<end,
            payload: (offset + headerLength)..<end
        )
    }

    private static func fourCC(in data: Data, at offset: Int) -> String? {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else { return nil }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= data.startIndex, offset + 2 <= data.endIndex else { return nil }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= data.startIndex, offset + 8 <= data.endIndex else { return nil }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}
