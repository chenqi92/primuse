import Foundation

/// Reads text streams using container offsets. Audio/video packets are never decoded.
public enum EmbeddedMediaLyricReader {
    public typealias RangeFetch = (Int64, Int64) async throws -> Data

    public static func local(at url: URL, fileExtension: String, metadataFile: Data? = nil) async -> [EmbeddedLyricField] {
        let ext = fileExtension.lowercased()
        let matroska = ["mka", "mkv", "webm", "weba"].contains(ext)
        guard url.isFileURL, matroska || ["m4a", "alac", "m4b", "mp4", "m4v", "mov", "3gp", "3g2"].contains(ext),
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            let size = Int64(clamping: try handle.seekToEnd())
            let fetch: RangeFetch = { offset, count in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: Int(count)) ?? Data()
            }
            if !matroska, let metadataFile {
                return try await isoTracks(metadataFile: metadataFile, fileSize: size, fetch: fetch)
            }
            let head = try await fetch(0, min(size, 8_192))
            if matroska { return try await MatroskaLyricReader(head: head, fileSize: size, local: true, fetch: fetch).read() }
            guard let movie = try await ISOBaseMediaRangeReader.read(head: head, fileSize: size, fetch: fetch) else { return [] }
            return try await isoTracks(metadataFile: movie, fileSize: size, fetch: fetch)
        } catch { return [] }
    }

    public static func isoTracks(metadataFile: Data, fileSize: Int64, fetch: RangeFetch) async throws -> [EmbeddedLyricField] {
        var fields: [EmbeddedLyricField] = []
        var budget = 4 * LyricsRawDocumentPolicy.maximumByteCount
        var tracks = ISOBaseMediaChapterParser.lyricTracks(in: metadataFile)
        if tracks.contains(where: \.hasFragments) {
            let fragments = try await ISOBaseMediaLyricFragments.samples(metadataFile: metadataFile, tracks: tracks, fileSize: fileSize, fetch: fetch)
            for i in tracks.indices {
                if let id = tracks[i].id, let extra = fragments[id] { tracks[i].samples += extra }
            }
        }
        for track in tracks {
            var samples: [Sample] = []
            var bytes = 0
            var complete = true
            for sample in track.samples {
                try Task.checkCancellation()
                guard sample.offset >= 0, sample.offset <= fileSize,
                      sample.size <= fileSize - sample.offset,
                      sample.size <= LyricsRawDocumentPolicy.maximumByteCount - bytes,
                      sample.size <= budget else { complete = false; break }
                if sample.size == 0 || (track.codec == .timedText && sample.size <= 2) { continue }
                let data = try await fetch(sample.offset, Int64(sample.size))
                guard data.count == sample.size else { throw ISOBaseMediaRangeReader.ReadError.incompleteRange }
                budget -= sample.size
                bytes += sample.size
                samples.append(Sample(start: sample.start, end: sample.end, data: Data(data)))
            }
            if complete, let value = document(codec: track.codec, samples: samples, offset: track.offset, timescale: track.timescale) {
                fields.append(field(name: track.name, language: track.language, text: value))
            }
        }
        return fields
    }

    public static func matroska(head: Data, fileSize: Int64, fetch: @escaping RangeFetch) async throws -> [EmbeddedLyricField] {
        try await MatroskaLyricReader(head: head, fileSize: fileSize, fetch: fetch).read()
    }

    struct Sample {
        var start: Double
        var end: Double?
        let data: Data
    }

    enum Codec: String {
        case timedText, webVTTBoxes, xml, utf8, webVTT, webVTTWithHeader, ass, usf
    }

    static func isLyricName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["lyric", "karaoke", "sing-along", "sing along", "歌词", "歌詞", "逐字", "卡拉ok"].contains { lower.contains($0) }
    }

    static func acceptsTrack(name: String, audioOnly: Bool) -> Bool {
        let lower = name.lowercased()
        guard !["chapter", "章节", "章節", "commentary", "audio description", "transcript", "closed caption"].contains(where: lower.contains)
        else { return false }
        return audioOnly || isLyricName(name)
    }

    static func field(name: String, language: String?, text: String, descriptor: String? = nil) -> EmbeddedLyricField {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (PrimuseConstants.readableLyricsExtensions.contains(ext) || ext == "krc")
            ? (name as NSString).deletingPathExtension : name
        let role = descriptor.flatMap(ISOBaseMediaLyricsParser.lyricFieldRole)
            ?? ISOBaseMediaLyricsParser.lyricFieldRole(stem)
            ?? ISOBaseMediaLyricsParser.lyricFieldRole(name)
        var result = (role ?? .original(languageCode: nil)).field(name: name, text: text)
        if let language = language.flatMap(LyricLanguageCodePolicy.canonicalIdentifier) { result.languageCode = language }
        return result
    }

    static func document(codec: Codec, samples: [Sample], offset: Double = 0, timescale: UInt32 = 1_000) -> String? {
        guard !samples.isEmpty else { return nil }
        if codec == .usf {
            let lines = samples.flatMap(MatroskaLyricReader.usf)
            return lines.isEmpty ? nil : LyricsContentParser.serializeTTML(lines)
        }
        if codec == .timedText { return timedText(samples, offset: offset, timescale: timescale) }
        if codec == .webVTTBoxes { return webVTTBoxes(samples, offset: offset) }
        if codec == .xml {
            var lines: [LyricLine] = []
            var seen = Set<LyricLine>()
            for sample in samples {
                guard let xml = TextEncodingRepair.decodeTextFile(sample.data)?.text,
                      LyricsContentParser.isTTML(xml) else { continue }
                let parsed = LyricsContentParser.parseText(xml)
                guard !parsed.isEmpty else { continue }
                if samples.count == 1, offset == 0, parsed.allSatisfy(\.isSynchronized) { return xml }
                var keys: [LyricLine] = []
                for var line in parsed {
                    if !line.isSynchronized {
                        line.timestamp = sample.start
                        line.endTimestamp = sample.end
                        line.isSynchronized = true
                    }
                    let key = xmlIdentity(line)
                    if !seen.contains(key) { lines.append(line) }
                    keys.append(key)
                }
                seen.formUnion(keys)
            }
            guard !lines.isEmpty else { return nil }
            lines.sort { $0.timestamp < $1.timestamp }
            return LyricsContentParser.serializeTTML(LyricDocumentOffsetPolicy.applying(offset: -offset, to: lines))
        }

        var cues: [String] = []
        for (index, sample) in samples.enumerated() {
            let start = max(0, sample.start + offset)
            let end = max(start, (sample.end ?? samples.dropFirst(index + 1).first?.start ?? sample.start) + offset)
            if codec == .ass {
                guard let packet = String(data: sample.data, encoding: .utf8) else { continue }
                let values = packet.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                guard values.count == 9 else { continue }
                cues.append("Dialogue: " + [String(values[1]), clock(start, ass: true), clock(end, ass: true),
                                            values[2...].joined(separator: ",")].joined(separator: ","))
                continue
            }
            let payloads: [String]
            switch codec {
            case .utf8, .webVTT, .webVTTWithHeader:
                guard let value = String(data: sample.data, encoding: .utf8) else { continue }
                if codec == .webVTTWithHeader {
                    // WebM D_WEBVTT stores the cue identifier and settings on the first two lines.
                    let parts = value.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3 else { continue }
                    payloads = [String(parts[2])]
                } else if codec == .webVTT {
                    let timestamp = /<(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})>/
                    payloads = [value.replacing(timestamp) { mark in
                        let hours = mark.1.flatMap { Double($0) } ?? 0
                        let seconds = hours * 3600 + (Double(mark.2) ?? 0) * 60 + (Double(mark.3) ?? 0)
                        return "<" + clock(start + seconds + (Double(mark.4) ?? 0) / 1_000) + ">"
                    }]
                } else { payloads = [value] }
            default: continue
            }
            for payload in payloads where !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cues.append(clock(start) + " --> " + clock(end) + "\n" + payload)
            }
        }
        guard !cues.isEmpty else { return nil }
        return codec == .ass ? "[Events]\n" + cues.joined(separator: "\n")
                             : "WEBVTT\n\n" + cues.joined(separator: "\n\n")
    }

    private static func xmlIdentity(_ line: LyricLine) -> LyricLine {
        var copy = line
        copy.id = ""
        copy.metadataLines = nil
        copy.background = line.background?.map(xmlIdentity)
        return copy
    }

    /// ISO/IEC 14496-30 splits overlapping cues into repeated vttc boxes in consecutive samples.
    private static func webVTTBoxes(_ samples: [Sample], offset: Double) -> String? {
        struct CueKey: Hashable { let id: String?; let originalTime: String?; let payload: String }
        struct Cue { var start: Double; var end: Double; var key: CueKey }
        var cues: [Cue] = []
        var active: [CueKey: Int] = [:]
        for sample in samples {
            let bytes = sample.data
            let boxes = (try? OrderedTagContainer.boxes(bytes, in: 0..<bytes.count)) ?? []
            let start = max(0, sample.start + offset)
            let end = max(start, (sample.end ?? sample.start) + offset)
            var next: [CueKey: Int] = [:]
            for box in boxes where box.key == "vttc" {
                guard let children = try? OrderedTagContainer.boxes(bytes, in: box.body) else { continue }
                func value(_ name: String) -> String? {
                    children.first { $0.key == name }.flatMap { String(data: bytes[$0.body], encoding: .utf8) }
                }
                guard let payload = value("payl"), !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let key = CueKey(id: value("iden"), originalTime: value("ctim"), payload: payload)
                if let i = active[key], cues[i].end == start {
                    cues[i].end = end
                    next[key] = i
                } else {
                    next[key] = cues.count
                    cues.append(Cue(start: start, end: end, key: key))
                }
            }
            active = next
        }
        guard !cues.isEmpty else { return nil }
        return "WEBVTT\n\n" + cues.map { clock($0.start) + " --> " + clock($0.end) + "\n" + $0.key.payload }.joined(separator: "\n\n")
    }

    private static func timedText(_ samples: [Sample], offset: Double, timescale: UInt32) -> String? {
        var lines: [LyricLine] = []
        var cues: [String] = []
        for sample in samples {
            let bytes = sample.data
            guard bytes.count >= 2 else { continue }
            let size = OrderedTagContainer.value(bytes, 0, 2)
            guard size > 0, size <= bytes.count - 2,
                  let text = TextEncodingRepair.decodeTextFile(bytes.subdata(in: 2..<(2 + size)))?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = max(0, sample.start + offset)
            let end = max(start, (sample.end ?? sample.start) + offset)
            let karaoke = (try? OrderedTagContainer.boxes(bytes, in: (2 + size)..<bytes.count))?.first { $0.key == "krok" }
            let syllables = karaoke.flatMap { highlights(text, bytes: bytes, box: $0, start: start, end: end, scale: Double(timescale)) }
            lines.append(.init(timestamp: start, text: text, isSynchronized: true, syllables: syllables, endTimestamp: end))
            // tx3g is plain text; literal angle brackets do not introduce WebVTT tags.
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            cues.append(clock(start) + " --> " + clock(end) + "\n" + escaped)
        }
        guard !lines.isEmpty else { return nil }
        return lines.contains(where: \.isWordLevel) ? LyricsContentParser.serializeTTML(lines)
                                                    : "WEBVTT\n\n" + cues.joined(separator: "\n\n")
    }

    /// 3GPP TS 26.245 §5.17.1.3. Character offsets exclude the BOM and count characters, not encoded bytes.
    private static func highlights(_ text: String, bytes: Data, box: OrderedTagContainer.Box, start: Double, end: Double, scale: Double) -> [LyricSyllable]? {
        let base = box.body.lowerBound
        guard box.body.count >= 6, scale > 0 else { return nil }
        let count = OrderedTagContainer.value(bytes, base + 4, 2)
        guard count > 0, count <= (box.body.count - 6) / 8 else { return nil }
        let letters = Array(text.unicodeScalars)
        func slice(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(letters[from..<to])) }
        var elapsed = OrderedTagContainer.value(bytes, base, 4)
        var consumed = 0
        var parts: [LyricSyllable] = []
        for i in 0..<count {
            let at = base + 6 + 8 * i
            let next = OrderedTagContainer.value(bytes, at, 4)
            let first = OrderedTagContainer.value(bytes, at + 4, 2)
            let last = OrderedTagContainer.value(bytes, at + 6, 2)
            guard first >= consumed, last >= first, last <= letters.count, next >= elapsed,
                  Double(next) / scale <= end - start + 0.001 else { return nil }
            let from = start + Double(elapsed) / scale
            if first > consumed { parts.append(.init(text: slice(consumed, first), start: parts.last?.end ?? start, end: from)) }
            if last > first { parts.append(.init(text: slice(first, last), start: from, end: start + Double(next) / scale)) }
            consumed = last
            elapsed = next
        }
        guard !parts.isEmpty else { return nil }
        if consumed < letters.count { parts.append(.init(text: slice(consumed, letters.count), start: parts.last?.end ?? start, end: end)) }
        return parts
    }

    private static func clock(_ seconds: Double, ass: Bool = false) -> String {
        // The precision of the file is bounded; a corrupt timestamp must never trap an Int conversion.
        let units = ass ? 100 : 1_000
        let ticks = Int((min(max(seconds, 0), 1e12) * Double(units)).rounded())
        let s = ticks / units
        return String(format: ass ? "%lld:%02lld:%02lld.%02lld" : "%02lld:%02lld:%02lld.%03lld",
                      s / 3600, s / 60 % 60, s % 60, ticks % units)
    }
}
