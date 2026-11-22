import Foundation

/// Fragment sample runs use the same track IDs, descriptions and timescales as an ordinary sample table.
/// Only the moof indices and selected text samples need to be transferred.
enum ISOBaseMediaLyricFragments {
    typealias Track = ISOBaseMediaChapterParser.LyricTrack
    private typealias Box = OrderedTagContainer.Box
    private typealias ISO = ISOBaseMediaFragmentDuration

    private struct Defaults {
        var duration: UInt32 = 0
        var size: UInt32 = 0
        var description: UInt32 = 1
    }

    static func samples(metadataFile: Data, tracks: [Track], fileSize: Int64, fetch: EmbeddedMediaLyricReader.RangeFetch) async throws -> [UInt32: [Track.Sample]] {
        var selected: [UInt32: Track] = [:]
        for track in tracks { if let id = track.id { selected[id] = track } }
        guard !selected.isEmpty, fileSize >= 8 else { return [:] }
        guard let ext = movieExtensions(in: metadataFile) else { return [:] }
        let defaults = movieDefaults(in: metadataFile, extensions: ext.box)
        var confirmedExtensions = ext.box.key == "mvex"
        var result: [UInt32: [Track.Sample]] = [:]
        var times: [UInt32: Double] = selected.mapValues { ($0.samples.last?.end ?? 0) * Double($0.timescale) }
        var cursor: Int64 = 0
        var byteBudget = 4 * LyricsRawDocumentPolicy.maximumByteCount
        var sampleBudget = 1_000_000
        for _ in 0..<8_192 {
            try Task.checkCancellation()
            if cursor == fileSize { return confirmedExtensions ? result : [:] }
            guard fileSize - cursor >= 8 else { return [:] }
            let headLength = min(16, fileSize - cursor)
            let header = Data(try await fetch(cursor, headLength))
            guard header.count == headLength else { throw ISOBaseMediaRangeReader.ReadError.incompleteRange }
            let size32 = OrderedTagContainer.value(header, 0, 4)
            let length: Int64
            let headerSize = size32 == 1 ? 16 : 8
            switch size32 {
            case 0: length = fileSize - cursor
            case 1:
                guard header.count >= 16, let n = ISO.uint64(header, 8, 16), n <= UInt64(Int64.max) else { return [:] }
                length = Int64(n)
            default: length = Int64(size32)
            }
            guard length >= headerSize, length <= fileSize - cursor else { return [:] }
            if !confirmedExtensions, header[4..<8].elementsEqual("moov".utf8) {
                let relativeType = Int64(ext.relativeTypeOffset)
                guard relativeType <= length - 4 else { return [:] }
                let type = try await fetch(cursor + relativeType, 4)
                guard type.elementsEqual("mvex".utf8) else { return [:] }
                confirmedExtensions = true
            }
            if header[4..<8].elementsEqual("moof".utf8) {
                guard length <= byteBudget, length <= 2 * 1024 * 1024 else { return [:] }
                let data = Data(try await fetch(cursor, length))
                guard data.count == length else { throw ISOBaseMediaRangeReader.ReadError.incompleteRange }
                byteBudget -= Int(length)
                guard append(data, payload: headerSize..<data.count, offset: cursor, fileSize: fileSize, tracks: selected, defaults: defaults,
                             times: &times, samples: &result, budget: &sampleBudget) else { return [:] }
            }
            cursor += length
        }
        return cursor == fileSize && confirmedExtensions ? result : [:]
    }

    /// RangeReader masks mvex as free in the metadata copy supplied to AVFoundation. Only candidate
    /// free boxes containing a complete trex are considered, then checked against the original file.
    static func movieExtensions(in data: Data) -> (box: OrderedTagContainer.Box, relativeTypeOffset: Int)? {
        guard let moov = (try? OrderedTagContainer.boxes(data, in: data.startIndex..<data.endIndex))?.first(where: { $0.key == "moov" }),
              let children = try? OrderedTagContainer.boxes(data, in: moov.body) else { return nil }
        let ext = children.first { $0.key == "mvex" } ?? children.first { candidate in
            guard candidate.key == "free", candidate.body.count >= 32 else { return false }
            return (try? OrderedTagContainer.boxes(data, in: candidate.body))?.contains { $0.key == "trex" && $0.body.count >= 24 } == true
        }
        return ext.map { ($0, $0.start + 4 - moov.start) }
    }

    private static func movieDefaults(in data: Data, extensions: Box) -> [UInt32: Defaults] {
        var result: [UInt32: Defaults] = [:]
        for trex in (try? OrderedTagContainer.boxes(data, in: extensions.body)) ?? [] where trex.key == "trex" && trex.body.count >= 24 {
            let start = trex.body.lowerBound
            let end = trex.body.upperBound
            guard let id = ISO.uint32(data, start + 4, end), let description = ISO.uint32(data, start + 8, end),
                  let duration = ISO.uint32(data, start + 12, end), let size = ISO.uint32(data, start + 16, end) else { continue }
            result[id] = Defaults(duration: duration, size: size, description: description)
        }
        return result
    }

    private static func append(_ data: Data, payload: Range<Int>, offset: Int64, fileSize: Int64, tracks: [UInt32: Track], defaults: [UInt32: Defaults],
                               times: inout [UInt32: Double], samples: inout [UInt32: [Track.Sample]], budget: inout Int) -> Bool {
        guard let children = try? OrderedTagContainer.boxes(data, in: payload) else { return false }
        var previousTrafEnd = offset
        for traf in children where traf.key == "traf" {
            guard let boxes = try? OrderedTagContainer.boxes(data, in: traf.body),
                  let tfhd = boxes.first(where: { $0.key == "tfhd" }), tfhd.body.count >= 8 else { return false }
            let base = tfhd.body.lowerBound
            let id = UInt32(OrderedTagContainer.value(data, base + 4, 4))
            let flags = OrderedTagContainer.value(data, base + 1, 3)
            var config = defaults[id] ?? Defaults()
            var cursor = base + 8
            var dataOffset = flags & 0x020000 != 0 ? offset : previousTrafEnd
            if flags & 1 != 0 {
                guard let n = ISO.uint64(data, cursor, tfhd.body.upperBound), n <= UInt64(fileSize) else { return false }
                dataOffset = Int64(n)
                cursor += 8
            }
            for flag in [2, 8, 16, 32] where flags & flag != 0 {
                guard let value = ISO.uint32(data, cursor, tfhd.body.upperBound) else { return false }
                switch flag {
                case 2: config.description = value
                case 8: config.duration = value
                case 16: config.size = value
                default: break
                }
                cursor += 4
            }
            var decodeTime = times[id] ?? 0
            if let tfdt = boxes.first(where: { $0.key == "tfdt" }) {
                let b = tfdt.body
                guard b.count >= 8 else { return false }
                let value = data[b.lowerBound] == 1 ? ISO.uint64(data, b.lowerBound + 4, b.upperBound)
                                                    : ISO.uint32(data, b.lowerBound + 4, b.upperBound).map(UInt64.init)
                guard let value else { return false }
                decodeTime = Double(value)
            }
            var next = dataOffset
            var found: [Track.Sample] = []
            for trun in boxes where trun.key == "trun" {
                let body = trun.body
                guard body.count >= 8 else { return false }
                let version = data[body.lowerBound]
                let flags = OrderedTagContainer.value(data, body.lowerBound + 1, 3)
                let count = OrderedTagContainer.value(data, body.lowerBound + 4, 4)
                guard count <= budget else { return false }
                budget -= count
                cursor = body.lowerBound + 8
                if flags & 1 != 0 {
                    guard let v = ISO.uint32(data, cursor, body.upperBound) else { return false }
                    let (value, overflow) = dataOffset.addingReportingOverflow(Int64(Int32(bitPattern: v)))
                    guard !overflow, value >= 0, value <= fileSize else { return false }
                    next = value
                    cursor += 4
                }
                if flags & 4 != 0 { cursor += 4 }
                let stride = [0x100, 0x200, 0x400, 0x800].filter { flags & $0 != 0 }.count * 4
                guard cursor <= body.upperBound, count * stride <= body.upperBound - cursor else { return false }
                let track = config.description == 1 ? tracks[id] : nil
                for _ in 0..<count {
                    let duration = flags & 0x100 != 0 ? OrderedTagContainer.value(data, cursor, 4) : Int(config.duration)
                    if flags & 0x100 != 0 { cursor += 4 }
                    let size = flags & 0x200 != 0 ? OrderedTagContainer.value(data, cursor, 4) : Int(config.size)
                    if flags & 0x200 != 0 { cursor += 4 }
                    if flags & 0x400 != 0 { cursor += 4 }
                    var presentation = decodeTime
                    if flags & 0x800 != 0 {
                        let value = UInt32(OrderedTagContainer.value(data, cursor, 4))
                        presentation += version == 1 ? Double(Int32(bitPattern: value)) : Double(value)
                        cursor += 4
                    }
                    guard next >= 0, Int64(size) <= fileSize - next else { return false }
                    if let track {
                        let scale = Double(track.timescale)
                        found.append(.init(offset: next, size: size, start: presentation / scale, end: (presentation + Double(duration)) / scale))
                    }
                    next += Int64(size)
                    decodeTime += Double(duration)
                }
            }
            if !found.isEmpty {
                if tracks[id]?.codec == .xml, let subs = boxes.first(where: { $0.key == "subs" }) {
                    for (index, size) in ISOBaseMediaChapterParser.xmlSubsampleSizes(subs.body, data: data, count: found.count) {
                        found[index].size = min(size, found[index].size)
                    }
                }
                guard found.count <= 100_000 - (samples[id]?.count ?? 0) else { return false }
                samples[id, default: []] += found
            }
            times[id] = decodeTime
            previousTrafEnd = next
        }
        return true
    }
}
