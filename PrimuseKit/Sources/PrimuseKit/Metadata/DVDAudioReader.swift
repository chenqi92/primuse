import Foundation

enum DVDAudioReader {
    typealias File = DiscImageFileSystem.File
    typealias Read = SACDISOReader.Read
    enum Failure: Error { case invalidTable, unsupportedAudio, encrypted, invalidPacket }
    struct Title {
        var file: File
        var times: [(start: Double, duration: Double)]
    }

    static func tracks(files: [File], read: Read) async throws -> [CueTrack] {
        var output: [CueTrack] = []
        for ifo in files where isTitleSet(ifo.path) {
            let titles = try await titles(ifo: ifo, files: files, read: read)
            for (titleIndex, title) in titles.enumerated() {
                let packet = try await firstPacket(title.file, read: read)
                let format: AudioFormat
                var rate: Int?, bits: Int?
                if packet[0] == 0xa1 { format = .mlp }
                else if packet[0] == 0xa0 {
                    let pcm = try PCMFormat(packet)
                    format = .wav; rate = pcm.rate; bits = pcm.bits.max()
                } else { throw Failure.unsupportedAudio }
                for (trackIndex, time) in title.times.enumerated() {
                    let selector = ISOAudioTrack(kind: .dvdAudio, path: ifo.path, title: titleIndex + 1,
                                                track: trackIndex + 1, format: format, byteCount: title.file.size,
                                                sampleRate: rate, bitDepth: bits, duration: time.duration)
                    output.append(CueTrack(number: output.count + 1, type: "AUDIO",
                                           startTime: time.start, endTime: time.start + time.duration, isoAudioTrack: selector))
                }
            }
        }
        return output
    }

    static func extract(track: ISOAudioTrack, files: [File], to url: URL, read: Read) async throws {
        guard let ifo = files.first(where: { $0.path == track.path }),
              let titleNumber = track.title, titleNumber > 0 else { throw Failure.invalidTable }
        let titles = try await titles(ifo: ifo, files: files, read: read)
        guard titleNumber <= titles.count else { throw Failure.invalidTable }
        let title = titles[titleNumber - 1]
        guard title.file.size == track.byteCount else { throw Failure.invalidTable }
        // Keep the title's continuous timeline. Track boundaries can fall inside
        // PES packets or MLP frames; the existing CUE playback range trims them.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at: url) } }
        var pcmFormat: PCMFormat?, written: UInt64 = 0, pending = Data()
        if track.format == .wav { try output.write(contentsOf: Data(repeating: 0, count: 104)) }
        var offset: Int64 = 0
        while offset < title.file.size {
            let data = try await DiscImageFileSystem.read(title.file, offset: offset, length: min(256 * 1024, title.file.size - offset), using: read)
            for sector in stride(from: 0, to: data.count, by: 2048) {
                guard sector + 2048 <= data.count else { throw Failure.invalidPacket }
                for packet in try packets(Data(data[sector..<(sector + 2048)])) {
                    guard packet.count >= 4 else { throw Failure.invalidPacket }
                    let header = 4 + Int(packet[3])
                    guard header <= packet.count else { throw Failure.invalidPacket }
                    if track.format == .mlp {
                        guard packet[0] == 0xa1 else { throw Failure.unsupportedAudio }
                        let audio = packet.dropFirst(header)
                        try output.write(contentsOf: audio); written += UInt64(audio.count)
                    } else {
                        let format = try PCMFormat(packet)
                        if let pcmFormat, pcmFormat != format { throw Failure.unsupportedAudio }
                        pcmFormat = format
                        pending.append(packet.dropFirst(header))
                        let length = pending.count / format.blockBytes * format.blockBytes
                        let audio = format.decode(Data(pending.prefix(length)))
                        try output.write(contentsOf: audio); written += UInt64(audio.count)
                        pending = Data(pending.dropFirst(length))
                    }
                }
            }
            offset += Int64(data.count)
        }
        guard written > 0, pending.isEmpty else { throw Failure.invalidPacket }
        if let pcmFormat {
            try output.seek(toOffset: 0)
            try output.write(contentsOf: pcmFormat.waveHeader(bytes: written))
        }
        try Task.checkCancellation()
        try output.synchronize()
        complete = true
    }

    private static func isTitleSet(_ path: String) -> Bool {
        let p = path.uppercased()
        let name = (p as NSString).lastPathComponent
        return (p as NSString).deletingLastPathComponent == "/AUDIO_TS"
            && name.count == 12 && name.hasPrefix("ATS_") && name.hasSuffix("_0.IFO")
            && Int(name.dropFirst(4).prefix(2)).map { $0 > 0 } == true
    }

    private static func titles(ifo: File, files: [File], read: Read) async throws -> [Title] {
        guard ifo.size >= 2048, ifo.size <= 4 * 1024 * 1024 else { throw Failure.invalidTable }
        let data = try await DiscImageFileSystem.read(ifo, offset: 0, length: ifo.size, using: read)
        guard data.prefix(12) == Data("DVDAUDIO-ATS".utf8) else { throw Failure.invalidTable }
        let table = Int(try ISOBytes.be(data, 204, 4)) * 2048
        let count = Int(try ISOBytes.be(data, table, 2))
        let tableEnd = table + Int(try ISOBytes.be(data, table + 4, 4)) + 1
        guard count > 0, count <= 99, tableEnd <= data.count, table + 8 + count * 8 <= tableEnd else { throw Failure.invalidTable }
        let prefix = String(ifo.path.dropLast(5)).uppercased()
        var extents: [DiscImageFileSystem.Extent] = []
        for index in 1...9 {
            if let aob = files.first(where: { $0.path.uppercased() == prefix + "\(index).AOB" }) {
                guard aob.size % 2048 == 0 else { throw Failure.invalidTable }
                extents.append(contentsOf: aob.extents)
            } else if index == 1 { throw Failure.invalidTable }
            else { break }
        }
        let aobs = File(path: ifo.path, extents: extents)
        var result: [Title] = []
        for index in 0..<count {
            let start = table + Int(try ISOBytes.be(data, table + 8 + index * 8 + 4, 4))
            guard start + 16 <= tableEnd else { throw Failure.invalidTable }
            let tracks = Int(data[start + 2]), cells = Int(data[start + 3])
            let pointers = start + Int(try ISOBytes.be(data, start + 14, 2))
            guard tracks > 0, cells > 0, start + 16 + tracks * 20 <= pointers,
                  pointers + cells * 12 <= tableEnd else { throw Failure.invalidTable }
            let firstSector = try ISOBytes.be(data, pointers + 4, 4)
            let lastSector = try ISOBytes.be(data, pointers + (cells - 1) * 12 + 8, 4)
            guard lastSector >= firstSector else { throw Failure.invalidTable }
            let file = try DiscImageFileSystem.slice(aobs, offset: firstSector * 2048, length: (lastSector - firstSector + 1) * 2048)
            var times: [(start: Double, duration: Double)] = []
            let origin = try ISOBytes.be(data, start + 16 + 6, 4)
            for track in 0..<tracks {
                let timestamp = start + 16 + track * 20
                let pts = try ISOBytes.be(data, timestamp + 6, 4), duration = try ISOBytes.be(data, timestamp + 10, 4)
                guard pts >= origin, duration > 0 else { throw Failure.invalidTable }
                times.append((Double(pts - origin) / 90_000, Double(duration) / 90_000))
            }
            result.append(Title(file: file, times: times))
        }
        return result
    }

    private static func firstPacket(_ file: File, read: Read) async throws -> Data {
        let head = try await DiscImageFileSystem.read(file, offset: 0, length: min(file.size, 32 * 2048), using: read)
        for offset in stride(from: 0, to: head.count, by: 2048) {
            guard offset + 2048 <= head.count else { break }
            if let packet = try packets(Data(head[offset..<(offset + 2048)])).first { return packet }
        }
        throw Failure.invalidPacket
    }

    private static func packets(_ sector: Data) throws -> [Data] {
        guard sector.count == 2048, sector.prefix(4) == Data([0, 0, 1, 0xba]), sector[4] & 0xc0 == 0x40 else { throw Failure.invalidPacket }
        var cursor = 14 + Int(sector[13] & 7), output: [Data] = []
        while cursor + 6 <= sector.count {
            guard sector[cursor..<(cursor + 3)] == Data([0, 0, 1]) else {
                if sector[cursor...].allSatisfy({ $0 == 0 || $0 == 0xff }) { break }
                throw Failure.invalidPacket
            }
            let id = sector[cursor + 3]
            if id == 0xb9 { break }
            let end = cursor + 6 + Int(try ISOBytes.be(sector, cursor + 4, 2))
            guard end <= sector.count, end > cursor + 6 else { throw Failure.invalidPacket }
            if id == 0xbd {
                guard cursor + 9 <= end, sector[cursor + 6] & 0xc0 == 0x80 else { throw Failure.invalidPacket }
                guard sector[cursor + 6] & 0x30 == 0 else { throw Failure.encrypted }
                let payload = cursor + 9 + Int(sector[cursor + 8])
                guard payload + 4 <= end else { throw Failure.invalidPacket }
                output.append(Data(sector[payload..<end]))
            }
            cursor = end
        }
        return output
    }

    private struct PCMFormat: Equatable {
        let rate: Int
        let bits: [Int]
        let groups: [[Int]]
        let speakers: [Int]
        var channels: Int { speakers.count }
        var outputBits: Int { bits.max() ?? 24 }
        var outputSampleBytes: Int { outputBits / 8 }
        var blockBytes: Int { zip(groups, bits).reduce(0) { $0 + $1.0.count * $1.1 / 4 } }
        init(_ packet: Data) throws {
            guard packet.count >= 12, packet[0] == 0xa0, packet[3] >= 8, packet[9] & 15 == 0 else { throw Failure.unsupportedAudio }
            // Speaker masks follow WAVEFORMATEXTENSIBLE; the disc order follows
            // DVD-Audio channel assignment, with group 2 stored before group 1.
            let layouts = [[2], [0,1], [0,1,8], [0,1,4,5], [0,1,3], [0,1,3,8], [0,1,3,4,5],
                           [0,1,2], [0,1,2,8], [0,1,2,4,5], [0,1,2,3], [0,1,2,3,8], [0,1,2,3,4,5],
                           [0,1,2,8], [0,1,2,4,5], [0,1,2,3], [0,1,2,3,8], [0,1,2,3,4,5],
                           [0,1,4,5,3], [0,1,4,5,2], [0,1,4,5,2,3]]
            let assignment = Int(packet[10])
            guard assignment < layouts.count else { throw Failure.unsupportedAudio }
            let sortedSpeakers = layouts[assignment].sorted()
            speakers = sortedSpeakers
            let group1 = assignment == 0 ? 1 : assignment < 13 ? 2 : assignment < 18 ? 3 : 4
            let ordered = layouts[assignment].map { sortedSpeakers.firstIndex(of: $0)! }
            groups = [Array(ordered.prefix(group1)), Array(ordered.dropFirst(group1))]
            let rates = [0:48_000, 1:96_000, 2:192_000, 8:44_100, 9:88_200, 10:176_400]
            guard let sampleRate = rates[Int(packet[8] >> 4)] else { throw Failure.unsupportedAudio }
            rate = sampleRate
            let b1 = Int(packet[7] >> 4), b2 = Int(packet[7] & 15)
            guard [0,2].contains(b1), groups[1].isEmpty || ([0,2].contains(b2) && rates[Int(packet[8] & 15)] == rate) else {
                throw Failure.unsupportedAudio
            }
            bits = [16 + b1 * 4, groups[1].isEmpty ? 0 : 16 + b2 * 4]
        }
        func decode(_ data: Data) -> Data {
            var output = Data(capacity: data.count * 2), cursor = 0
            while cursor < data.count {
                var values = [UInt32](repeating: 0, count: channels * 2)
                for group in [1, 0] where !groups[group].isEmpty {
                    for frame in 0..<2 { for channel in groups[group] {
                        values[frame * channels + channel] = (UInt32(data[cursor]) << 24) | (UInt32(data[cursor + 1]) << 16)
                        cursor += 2
                    } }
                    if bits[group] == 24 {
                        for frame in 0..<2 { for channel in groups[group] {
                            values[frame * channels + channel] |= UInt32(data[cursor]) << 8; cursor += 1
                        } }
                    }
                }
                for value in values { for shift in stride(from: 32 - outputBits, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: value >> shift)) } }
            }
            return output
        }
        func waveHeader(bytes: UInt64) -> Data {
            var data = Data("RF64".utf8)
            func put(_ value: UInt64, _ count: Int) { for i in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
            put(0xffffffff, 4); data.append(Data("WAVEds64".utf8)); put(28, 4)
            put(bytes + 96, 8); put(bytes, 8); put(bytes / UInt64(channels * outputSampleBytes), 8); put(0, 4)
            data.append(Data("fmt ".utf8)); put(40, 4); put(0xfffe, 2); put(UInt64(channels), 2)
            put(UInt64(rate), 4); put(UInt64(rate * channels * outputSampleBytes), 4); put(UInt64(channels * outputSampleBytes), 2); put(UInt64(outputBits), 2)
            put(22, 2); put(UInt64(bits.max() ?? 24), 2); put(speakers.reduce(0) { $0 | (1 << $1) }, 4)
            data.append(Data([1,0,0,0,0,0,0x10,0,0x80,0,0,0xaa,0,0x38,0x9b,0x71]))
            data.append(Data("data".utf8)); put(0xffffffff, 4)
            return data
        }
    }
}
