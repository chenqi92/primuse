import CoreFoundation
import Foundation

/// Bounded sector reads; callers supply the same local or authenticated Range transport used by their source.
public enum SACDISOReader {
    public typealias Read = @Sendable (Int64, Int64) async throws -> Data

    public static func sheet(fileName: String, size: Int64, read: Read) async throws -> CueSheet? {
        do { return try await open(size: size, read: read).cueSheet(fileName: fileName) }
        catch Failure.notSACD { return nil }
    }

    public static func localSheet(url: URL) async throws -> CueSheet? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        return try await sheet(fileName: url.lastPathComponent, size: Int64(size)) { offset, length in
            try file.seek(toOffset: UInt64(offset))
            return try file.read(upToCount: Int(length)) ?? Data()
        }
    }

    public enum Failure: Error, Equatable {
        case notSACD, invalidTable, truncated, unsupportedAudio, invalidPacket, missingTrack
    }

    public struct Track: Sendable, Equatable {
        public let number: Int
        public let title: String?
        public let performer: String?
        public let firstSector: Int
        public let sectorCount: Int
        public let startFrame: Int
        public let frameCount: Int
        public var duration: Double { Double(frameCount) / 75 }
    }

    public struct Disc: Sendable, Equatable {
        public let title: String?
        public let performer: String?
        public let year: Int?
        public let channels: Int
        public let sectorSize: Int
        public let sectorOffset: Int
        public let tracks: [Track]

        /// Uses the existing virtual-track persistence and identity model. Each extracted track has its own timeline.
        public func cueSheet(fileName: String) -> CueSheet {
            CueSheet(title: title, performer: performer, year: year, files: [
                CueFile(name: fileName, type: "SACD", tracks: tracks.map {
                    CueTrack(number: $0.number, type: "AUDIO", title: $0.title,
                             performer: $0.performer, startTime: 0, endTime: $0.duration)
                })
            ])
        }
    }

    public static func open(size: Int64, read: Read) async throws -> Disc {
        var layout: (size: Int, offset: Int, master: Data)?
        for (stride, prefix) in [(2048, 0), (2064, 12)] {
            let offset = Int64(510 * stride + prefix)
            guard size <= 0 || offset + 2048 <= size else { continue }
            let master = try await exact(offset, 2048, read: read)
            if matches(master, 0, "SACDMTOC") {
                layout = (stride, prefix, master)
                break
            }
        }
        guard let layout else { throw Failure.notSACD }
        let master = layout.master
        guard master[8] == 1 else { throw Failure.invalidTable }
        var title: String?
        var performer: String?
        for language in 0..<min(Int(master[128]), 8) {
            let text = try await exact(Int64((511 + language) * layout.size + layout.offset), 2048, read: read)
            if matches(text, 0, "SACDText") {
                let charset = Int(master[138 + language * 4] & 7)
                title = title ?? string(text, at: be16(text, 16), charset: charset)
                    ?? string(text, at: be16(text, 32), charset: charset)
                performer = performer ?? string(text, at: be16(text, 18), charset: charset)
                    ?? string(text, at: be16(text, 34), charset: charset)
            }
            if title != nil, performer != nil { break }
        }
        // Prefer the stereo programme; use the multichannel programme only when no stereo area exists.
        let groups = [[be32(master, 64), be32(master, 68)], [be32(master, 72), be32(master, 76)]]
        var multichannel: Disc?
        for candidates in groups {
            for sector in candidates where sector > 0 {
                do {
                    guard size <= 0 || Int64(sector * layout.size + layout.offset + 2048) <= size else {
                        throw Failure.invalidTable
                    }
                    let header = try await exact(Int64(sector * layout.size + layout.offset), 2048, read: read)
                    guard matches(header, 0, "TWOCHTOC") || matches(header, 0, "MULCHTOC") else {
                        throw Failure.invalidTable
                    }
                    let count = be16(header, 10)
                    let channels = Int(header[32])
                    guard (1...255).contains(count), [2, 5, 6].contains(channels), header[20] == 4,
                          size <= 0 || Int64((sector + count) * layout.size) <= size else {
                        throw Failure.invalidTable
                    }
                    let raw = try await exact(Int64(sector * layout.size), Int64(count * layout.size), read: read)
                    var area = Data(capacity: count * 2048)
                    for index in 0..<count {
                        let offset = index * layout.size + layout.offset
                        area.append(raw.subdata(in: offset..<(offset + 2048)))
                    }
                    let tracks = try parseTracks(area, imageSize: size, stride: layout.size)
                    let year = be16(master, 120)
                    let disc = Disc(title: title, performer: performer, year: year > 0 ? year : nil,
                                    channels: channels, sectorSize: layout.size, sectorOffset: layout.offset, tracks: tracks)
                    if channels == 2 { return disc }
                    if multichannel == nil { multichannel = disc }
                    break
                } catch is CancellationError { throw CancellationError() }
                catch is Failure { continue }
                catch { throw error }
            }
        }
        if let multichannel { return multichannel }
        throw Failure.invalidTable
    }

    private static func parseTracks(_ area: Data, imageSize: Int64, stride: Int) throws -> [Track] {
        let count = Int(area[69])
        var offsets: Int?
        var times: Int?
        var texts: [Int] = []
        var boundaries: [Int] = []
        for position in Swift.stride(from: 2048, to: area.count, by: 2048) {
            if matches(area, position, "SACDTRL1") { offsets = position }
            if matches(area, position, "SACDTRL2") { times = position }
            if matches(area, position, "SACDTTxt") { texts.append(position) }
            if ["SACDTTxt", "SACDTRL1", "SACDTRL2", "SACD_IGL", "SACD_ACC", "SACD_Ind", "SACD_WLL", "SACDPLAY"]
                .contains(where: { matches(area, position, $0) }) { boundaries.append(position) }
        }
        guard count > 0, let offsets, let times else { throw Failure.invalidTable }
        let first = be32(area, 72), last = be32(area, 76)
        var result: [Track] = []
        for index in 0..<count {
            let start = be32(area, offsets + 8 + index * 4)
            let length = be32(area, offsets + 1028 + index * 4)
            let startFrame = try frameTime(area, times + 8 + index * 4)
            let duration = try frameTime(area, times + 1028 + index * 4)
            guard start >= first, length > 0, duration > 0, start + length - 1 <= last,
                  imageSize <= 0 || Int64((start + length) * stride) <= imageSize else {
                throw Failure.invalidTable
            }
            var title: String?, performer: String?
            for (language, text) in texts.prefix(10).enumerated() {
                let limit = boundaries.first(where: { $0 > text }) ?? area.count
                let values = trackText(area, at: text, limit: limit, index: index, count: count,
                                       charset: Int(area[90 + language * 4] & 7))
                title = title ?? values.title
                performer = performer ?? values.performer
                if title != nil, performer != nil { break }
            }
            result.append(Track(number: index + 1, title: title, performer: performer,
                                firstSector: start, sectorCount: length, startFrame: startFrame, frameCount: duration))
        }
        return result
    }

    private static func trackText(_ area: Data, at text: Int, limit: Int, index: Int, count: Int,
                                  charset: Int) -> (title: String?, performer: String?) {
        let positions = (0..<count).map { be16(area, text + 8 + $0 * 2) }
        let relative = positions[index]
        // Text offsets are relative to the text table, not restricted to its first sector.
        // Bound each record independently so a damaged field count cannot consume another track.
        let end = min(limit, text + (positions.filter { $0 > relative }.min() ?? (limit - text)))
        var cursor = text + relative
        guard relative >= 8 + count * 2, cursor + 4 <= end else { return (nil, nil) }
        let fields = Int(area[cursor])
        var title: String?, performer: String?
        cursor += 4
        for _ in 0..<fields {
            guard cursor + 2 < end else { break }
            let kind = area[cursor]
            cursor += 2
            guard let terminator = area[cursor..<end].firstIndex(of: 0) else { break }
            if let value = decode(area.subdata(in: cursor..<terminator), charset: charset) {
                if kind == 1 { title = title ?? value }
                if kind == 2 { performer = performer ?? value }
            }
            cursor = terminator + 1
            while cursor < end, area[cursor] == 0 { cursor += 1 }
        }
        return (title, performer)
    }

    /// Writes only the selected track, preserving DSD or DST bytes in a DSDIFF container.
    /// At most one input chunk and one audio frame are retained; no full-disc download or PCM conversion.
    public static func extract(disc: Disc, trackNumber: Int, to destination: URL, read: Read) async throws {
        guard let track = disc.tracks.first(where: { $0.number == trackNumber }) else { throw Failure.missingTrack }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        var frame = Data(), frameTime: Int?, compression: Bool?
        var chunkSizeOffset: UInt64 = 0, dataStart: UInt64 = 0, frameCountOffset: UInt64 = 0
        var writtenFrames = 0
        var remainingDSTPackets = 0
        func emit() throws {
            guard let time = frameTime, !frame.isEmpty else { return }
            guard time >= track.startFrame, time < track.startFrame + track.frameCount else { return }
            guard time == track.startFrame + writtenFrames else { throw Failure.invalidPacket }
            guard compression == true || frame.count == disc.channels * 4704 else { throw Failure.invalidPacket }
            if compression == true {
                guard remainingDSTPackets == 0 else { throw Failure.truncated }
                try output.write(contentsOf: chunk("DSTF", frame))
            } else {
                try output.write(contentsOf: frame)
            }
            writtenFrames += 1
        }
        var sector = track.firstSector
        let endSector = sector + track.sectorCount
        while sector < endSector {
            try Task.checkCancellation()
            let sectors = min(128, endSector - sector)
            let data = try await exact(Int64(sector * disc.sectorSize), Int64(sectors * disc.sectorSize), read: read)
            for index in 0..<sectors {
                let base = index * disc.sectorSize + disc.sectorOffset
                let flags = data[base]
                let packets = Int(flags >> 5), starts = Int((flags >> 2) & 7)
                let dst = flags & 1 != 0
                let infoSize = dst ? 4 : 3
                var payload = base + 1 + packets * 2 + starts * infoSize
                guard payload <= base + 2048 else { throw Failure.invalidPacket }
                var frameIndex = 0
                for packet in 0..<packets {
                    let descriptor = base + 1 + packet * 2
                    let high = data[descriptor]
                    let length = Int(high & 7) * 256 + Int(data[descriptor + 1])
                    guard payload + length <= base + 2048 else { throw Failure.invalidPacket }
                    defer { payload += length }
                    guard (high >> 3) & 7 == 2 else { continue }
                    if high & 0x80 != 0 {
                        try emit()
                        guard frameIndex < starts else { throw Failure.invalidPacket }
                        let info = base + 1 + packets * 2 + frameIndex * infoSize
                        frameTime = try Self.frameTime(data, info)
                        if dst {
                            let details = data[info + 3]
                            let channels = details & 3 == 1 ? 5 : details & 3 == 2 ? 6 : 2
                            guard details & 3 != 3, channels == disc.channels else { throw Failure.unsupportedAudio }
                            remainingDSTPackets = Int((details >> 2) & 31)
                            guard remainingDSTPackets > 0 else { throw Failure.invalidPacket }
                        }
                        frameIndex += 1
                        frame.removeAll(keepingCapacity: true)
                        if let compression {
                            guard compression == dst else { throw Failure.unsupportedAudio }
                        } else {
                            compression = dst
                            let header = dffHeader(channels: disc.channels, dst: dst)
                            chunkSizeOffset = UInt64(header.count - (dst ? 30 : 12) + 4)
                            dataStart = UInt64(header.count - (dst ? 18 : 0))
                            frameCountOffset = UInt64(header.count - 6)
                            try output.write(contentsOf: header)
                        }
                    }
                    if frameTime != nil {
                        guard compression == dst else { throw Failure.unsupportedAudio }
                        if dst {
                            guard remainingDSTPackets > 0 else { throw Failure.invalidPacket }
                            remainingDSTPackets -= 1
                        }
                        guard frame.count + length <= 65536 else { throw Failure.invalidPacket }
                        frame.append(data.subdata(in: payload..<(payload + length)))
                    }
                }
                guard frameIndex == starts else { throw Failure.invalidPacket }
            }
            sector += sectors
        }
        try emit()
        guard writtenFrames == track.frameCount, compression != nil else { throw Failure.truncated }
        let end = try output.offset()
        try output.seek(toOffset: chunkSizeOffset)
        try output.write(contentsOf: integer(end - dataStart, bytes: 8))
        if compression == true {
            try output.seek(toOffset: frameCountOffset)
            try output.write(contentsOf: integer(UInt64(writtenFrames), bytes: 4))
        }
        try output.seek(toOffset: 4)
        try output.write(contentsOf: integer(end - 12, bytes: 8))
        try output.synchronize()
        completed = true
    }

    private static func dffHeader(channels: Int, dst: Bool) -> Data {
        var header = Data("FRM8".utf8) + integer(0, bytes: 8) + Data("DSD ".utf8)
        header += chunk("FVER", integer(0x01050000, bytes: 4))
        let names = channels == 2 ? ["SLFT", "SRGT"] : (channels == 5
            ? ["MLFT", "MRGT", "C   ", "LS  ", "RS  "] : ["MLFT", "MRGT", "C   ", "LFE ", "LS  ", "RS  "])
        let channelData = integer(UInt64(channels), bytes: 2) + Data(names.joined().utf8)
        // SFB's DSDIFF reader requires a nonempty compression name even for raw DSD.
        let compressionName = Data((dst ? "DST Encoded" : "not compressed").utf8)
        let compression = Data((dst ? "DST " : "DSD ").utf8) + Data([UInt8(compressionName.count)]) + compressionName
        let properties = Data("SND ".utf8) + chunk("FS  ", integer(2_822_400, bytes: 4))
            + chunk("CHNL", channelData) + chunk("CMPR", compression)
        header += chunk("PROP", properties)
        header += Data((dst ? "DST " : "DSD ").utf8) + integer(0, bytes: 8)
        if dst { header += chunk("FRTE", integer(0, bytes: 4) + integer(75, bytes: 2)) }
        return header
    }

    private static func chunk(_ id: String, _ data: Data) -> Data {
        Data(id.utf8) + integer(UInt64(data.count), bytes: 8) + data + (data.count % 2 == 0 ? Data() : Data([0]))
    }
    private static func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func exact(_ offset: Int64, _ length: Int64, read: Read) async throws -> Data {
        try Task.checkCancellation()
        var data = Data()
        while Int64(data.count) < length {
            let remaining = length - Int64(data.count)
            let next = try await read(offset + Int64(data.count), remaining)
            try Task.checkCancellation()
            guard !next.isEmpty, Int64(next.count) <= remaining else { throw Failure.truncated }
            data.append(next)
        }
        return data
    }
    private static func matches(_ data: Data, _ offset: Int, _ text: String) -> Bool {
        offset >= 0 && offset + text.utf8.count <= data.count
            && data[offset..<(offset + text.utf8.count)].elementsEqual(text.utf8)
    }
    private static func be16(_ data: Data, _ offset: Int) -> Int { Int(data[offset]) * 256 + Int(data[offset + 1]) }
    private static func be32(_ data: Data, _ offset: Int) -> Int { be16(data, offset) * 65536 + be16(data, offset + 2) }
    private static func frameTime(_ data: Data, _ offset: Int) throws -> Int {
        guard data[offset + 1] < 60, data[offset + 2] < 75 else { throw Failure.invalidTable }
        return Int(data[offset]) * 4500 + Int(data[offset + 1]) * 75 + Int(data[offset + 2])
    }
    private static func string(_ data: Data, at offset: Int, charset: Int) -> String? {
        guard offset >= 48, offset < data.count, let end = data[offset...].firstIndex(of: 0) else { return nil }
        return decode(data.subdata(in: offset..<end), charset: charset)
    }
    private static func decode(_ data: Data, charset: Int) -> String? {
        // Foundation supports GB18030 (a superset of GB2312), but not the GB2312 NSString encoding.
        let encodings: [CFStringEncoding] = [0x0600, 0x0600, 0x0201, 0x0a01, 0x0940, 0x0632, 0x0a03, 0x0201]
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encodings[charset & 7]))
        let text = (String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
