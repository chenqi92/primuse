import Foundation
import zlib
#if canImport(FoundationXML)
import FoundationXML
#endif

/// EBML element sizes let us skip cover attachments, audio packets and video frames by offset.
final class MatroskaLyricReader {
    private struct Element {
        var id: UInt64
        var body: Range<Int64>
        var unknown: Bool
    }

    private enum FrameDecoding {
        case zlib
        case restoreHeader(Data)
    }

    private struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0
        var name = ""
        var codecID = ""
        var language: String?
        var ietfLanguage: String?
        var defaultDuration: Double?
        var decoders: [FrameDecoding]? = []

        var codec: EmbeddedMediaLyricReader.Codec? {
            switch codecID {
            case "S_TEXT/UTF8": .utf8
            case "S_TEXT/USF": .usf
            case "S_TEXT/SSA", "S_TEXT/ASS", "S_SSA", "S_ASS": .ass
            case "S_TEXT/WEBVTT": .webVTT
            case "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS": .webVTTWithHeader
            default: nil
            }
        }
    }

    private enum Limit: Error { case reached }
    private let fileSize: Int64
    private let head: Data
    private let local: Bool
    private var pinnedMetadata: (start: Int64, bytes: Data)?
    private let fetch: EmbeddedMediaLyricReader.RangeFetch
    private var cache = Data()
    private var cacheStart: Int64 = 0
    private var remainingReads = 4_096
    private var remainingBytes = 4 * LyricsRawDocumentPolicy.maximumByteCount
    private var remainingElements = 250_000
    private var remainingFrameBytes = 4 * LyricsRawDocumentPolicy.maximumByteCount
    private var sampleBytes: [UInt64: Int] = [:]
    private var samples: [UInt64: [EmbeddedMediaLyricReader.Sample]] = [:]
    private var timestampScale = 0.001
    private static let segmentChildren: Set<UInt64> = [
        0x114D9B74, 0x1549A966, 0x1654AE6B, 0x1C53BB6B, 0x1941A469, 0x1043A770, 0x1254C367, 0x1F43B675,
    ]

    init(head: Data, fileSize: Int64, local: Bool = false, fetch: @escaping EmbeddedMediaLyricReader.RangeFetch) {
        self.head = head
        self.local = local
        if local { remainingReads = 250_000 }
        self.fileSize = fileSize
        self.fetch = fetch
    }

    func read() async throws -> [EmbeddedLyricField] {
        guard head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]), fileSize > 4 else { return [] }
        var output: [EmbeddedLyricField] = []
        do {
            guard let header = try await element(at: 0, limit: fileSize) else { return [] }
            var cursor = header.body.upperBound
            while let top = try await element(at: cursor, limit: fileSize) {
                if top.id == 0x18538067 { try await readSegment(top, output: &output); break }
                cursor = top.body.upperBound
            }
        } catch Limit.reached { /* Valid attachments obtained before hitting a traversal budget remain available. */ }
        return output
    }

    private func readSegment(_ segment: Element, output: inout [EmbeddedLyricField]) async throws {
        var tracks: [Track] = []
        var attachments: [Element] = []
        var tagGroups: [Element] = []
        var clusters: [Element] = []
        var cueTable: Element?
        let index = try await metadataIndex(segment)
        let top: [Element]
        if let index { top = index } else { top = try await topLevel(segment) }
        for child in top {
            switch child.id {
            case 0x1549A966:
                for field in try await children(child) where field.id == 0x2AD7B1 {
                    if let scale = try await number(field), scale > 0 { timestampScale = Double(scale) / 1e9 }
                }
            case 0x1654AE6B:
                for entry in try await children(child) where entry.id == 0xAE { tracks.append(try await track(entry)) }
            case 0x1941A469:
                attachments += try await children(child).filter { $0.id == 0x61A7 }
            case 0x1254C367:
                tagGroups += try await children(child).filter { $0.id == 0x7373 }
            case 0x1C53BB6B: cueTable = child
            case 0x1F43B675: clusters.append(child)
            default: break
            }
        }
        let audioOnly = tracks.contains { $0.type == 2 } && !tracks.contains { $0.type == 1 }
        for group in tagGroups { try await appendTags(group, to: &output) }
        for entry in attachments {
            if let field = try await attachment(entry, audioOnly: audioOnly) { output.append(field) }
        }
        let selected = tracks.filter { track in
            track.type == 17 && track.number != 0 && track.codec != nil && track.decoders != nil &&
                EmbeddedMediaLyricReader.acceptsTrack(name: track.name, audioOnly: audioOnly && track.codecID != "D_WEBVTT/CAPTIONS")
        }
        guard !selected.isEmpty else { return }
        var byNumber: [UInt64: Track] = [:]
        for t in selected where byNumber[t.number] == nil { byNumber[t.number] = t }
        // Matroska writers should index every subtitle frame. Keep indexed samples available even if a
        // very large file exceeds the budget for checking unindexed blocks. Never expose a half-scanned fallback.
        var indexed: [UInt64: [EmbeddedMediaLyricReader.Sample]] = [:]
        var indexedPositions: Set<Int64> = []
        if let cueTable {
            if cueTable.body.count <= 2 * 1024 * 1024 {
                pinnedMetadata = try await (cueTable.body.lowerBound, read(cueTable.body.lowerBound, count: cueTable.body.count))
            }
            try await readCueTable(cueTable, segment: segment, selected: byNumber, seen: &indexedPositions)
            pinnedMetadata = nil
            indexed = samples
        }
        do {
            // Check unindexed frames without turning a remote tag read into thousands of round trips.
            if !local, !indexed.isEmpty { remainingReads = min(remainingReads, 64) }
            if index != nil { clusters = try await topLevel(segment).filter { $0.id == 0x1F43B675 } }
            for cluster in clusters { try await scan(cluster: cluster, selected: byNumber, indexedPositions: indexedPositions) }
        } catch Limit.reached { samples = indexed }
        for track in selected {
            guard let codec = track.codec, let items = samples[track.number], sampleBytes[track.number] != Int.max else { continue }
            let ordered = items.sorted { $0.start < $1.start }
            if let document = EmbeddedMediaLyricReader.document(codec: codec, samples: ordered) {
                output.append(EmbeddedMediaLyricReader.field(name: track.name.isEmpty ? track.codecID : track.name,
                                                            language: track.ietfLanguage ?? track.language, text: document))
            }
        }
    }

    private func metadataIndex(_ segment: Element) async throws -> [Element]? {
        var cursor = segment.body.lowerBound
        while let child = try await element(at: cursor, limit: segment.body.upperBound) {
            cursor = child.body.upperBound
            if child.id == 0xBF || child.id == 0xEC { continue }
            guard child.id == 0x114D9B74 else { return nil }
            var result: [Element] = []
            var seen = Set<Int64>()
            for seek in try await children(child) where seek.id == 0x4DBB {
                let fields = try await children(seek)
                guard let idField = fields.first(where: { $0.id == 0x53AB }), let id = try await number(idField),
                      [0x1549A966, 0x1654AE6B, 0x1941A469, 0x1254C367, 0x1C53BB6B].contains(id),
                      let offsetField = fields.first(where: { $0.id == 0x53AC }), let relative = try await number(offsetField),
                      relative < UInt64(segment.body.count) else { continue }
                let pos = segment.body.lowerBound + Int64(relative)
                guard seen.insert(pos).inserted else { continue }
                guard let indexed = try await element(at: pos, limit: segment.body.upperBound), indexed.id == id else { return nil }
                result.append(indexed)
            }
            return result.contains(where: { $0.id == 0x1654AE6B }) ? result.sorted { $0.body.lowerBound < $1.body.lowerBound } : nil
        }
        return nil
    }

    private func topLevel(_ segment: Element) async throws -> [Element] {
        var result: [Element] = []
        var cursor = segment.body.lowerBound
        while var child = try await element(at: cursor, limit: segment.body.upperBound) {
            if child.id == 0x1F43B675, child.unknown {
                var end = child.body.lowerBound
                while let next = try await element(at: end, limit: child.body.upperBound), !Self.segmentChildren.contains(next.id) {
                    end = next.body.upperBound
                }
                child.body = child.body.lowerBound..<end
            }
            if Self.segmentChildren.contains(child.id) { result.append(child) }
            cursor = child.body.upperBound
        }
        return result
    }

    private func track(_ element: Element) async throws -> Track {
        var result = Track()
        var encodings: Element?
        for child in try await children(element) {
            switch child.id {
            case 0xD7: result.number = try await number(child) ?? 0
            case 0x83: result.type = try await number(child) ?? 0
            case 0x86: result.codecID = try await string(child) ?? ""
            case 0x536E: result.name = try await string(child) ?? ""
            case 0x22B59C: result.language = try await string(child)
            case 0x22B59D: result.ietfLanguage = try await string(child)
            case 0x23E383: result.defaultDuration = try await number(child).map { Double($0) / 1e9 }
            case 0x6D80: encodings = child
            default: break
            }
        }
        if let encodings, result.type == 17, result.codec != nil {
            result.decoders = try await frameDecoders(encodings)
        }
        return result
    }

    /// RFC 9559 §5.1.4.1.31. Only frame-scope transforms apply to Block data.
    private func frameDecoders(_ encodings: Element) async throws -> [FrameDecoding]? {
        func value(_ fields: [Element], _ id: UInt64, fallback: UInt64) async throws -> UInt64? {
            guard let field = fields.first(where: { $0.id == id }) else { return fallback }
            return try await number(field)
        }
        var decoders: [(order: UInt64, decoder: FrameDecoding)] = []
        var orders = Set<UInt64>()
        var headerBudget = LyricsRawDocumentPolicy.maximumByteCount
        for entry in try await children(encodings) where entry.id == 0x6240 {
            let fields = try await children(entry)
            guard orders.count < 32, let order = try await value(fields, 0x5031, fallback: 0), orders.insert(order).inserted,
                  let scope = try await value(fields, 0x5032, fallback: 1), scope != 0, scope & ~3 == 0 else { return nil }
            // CodecPrivate can have its own transform, including encryption, while the frames remain clear.
            guard scope & 1 != 0 else { continue }
            guard try await value(fields, 0x5033, fallback: 0) == 0, !fields.contains(where: { $0.id == 0x5035 }),
                  let compression = fields.first(where: { $0.id == 0x5034 }) else { return nil }
            let settings = try await children(compression)
            switch try await value(settings, 0x4254, fallback: 0) {
            case 0: decoders.append((order, .zlib))
            case 3:
                var prefix = Data()
                if let header = settings.first(where: { $0.id == 0x4255 }) {
                    guard header.body.count <= headerBudget else { return nil }
                    headerBudget -= header.body.count
                    prefix = try await read(header.body.lowerBound, count: header.body.count)
                }
                decoders.append((order, .restoreHeader(prefix)))
            default: return nil
            }
        }
        return decoders.sorted { $0.order > $1.order }.map(\.decoder)
    }

    private static func decode(_ data: Data, using decoders: [FrameDecoding], maximum: Int) -> Data? {
        var result = data
        for (index, decoder) in decoders.enumerated() {
            let limit = index == decoders.count - 1 ? maximum : LyricsRawDocumentPolicy.maximumByteCount
            switch decoder {
            case .restoreHeader(let prefix):
                guard result.count <= limit - prefix.count else { return nil }
                if !prefix.isEmpty { result = prefix + result }
            case .zlib:
                guard let inflated = inflateFrame(result, maximum: limit) else { return nil }
                result = inflated
            }
        }
        return result.count <= maximum ? result : nil
    }

    private static func inflateFrame(_ input: Data, maximum: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        let limit = max(1, maximum)
        var capacity = min(limit, max(256, input.count))
        while true {
            var result = Data(count: capacity)
            var outputLength = uLongf(capacity)
            var inputLength = uLong(input.count)
            let status = result.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    uncompress2(destination.bindMemory(to: Bytef.self).baseAddress, &outputLength,
                                source.bindMemory(to: Bytef.self).baseAddress, &inputLength)
                }
            }
            if status == Z_OK, inputLength == input.count, outputLength <= maximum {
                result.removeSubrange(Int(outputLength)..<result.count)
                return result
            }
            guard status == Z_BUF_ERROR, capacity < limit else { return nil }
            capacity = min(limit, capacity * 2)
        }
    }

    private func attachment(_ element: Element, audioOnly: Bool) async throws -> EmbeddedLyricField? {
        var filename = ""
        var description = ""
        var mime = ""
        var body: Range<Int64>?
        for child in try await children(element) {
            switch child.id {
            case 0x466E: filename = try await string(child) ?? ""
            case 0x467E: description = try await string(child) ?? ""
            case 0x4660: mime = (try await string(child) ?? "").lowercased().split(separator: ";").first.map(String.init) ?? ""
            case 0x465C: body = child.body
            default: break
            }
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        let named = EmbeddedMediaLyricReader.isLyricName(filename) || EmbeddedMediaLyricReader.isLyricName(description)
        let lyricFormat = ["lrc", "elrc", "lys", "yrc", "qrc", "krc", "lyl"].contains(ext)
        let subtitle = LyricsDocumentFormat(fileName: filename) != nil || ["application/ttml+xml", "application/x-subrip", "text/vtt"].contains(mime)
        let text = mime.hasPrefix("text/") || ["", "application/octet-stream", "application/xml"].contains(mime)
        guard lyricFormat || mime == "text/lrc" || (subtitle && (audioOnly || named)) || (named && text),
              let body, body.count <= LyricsRawDocumentPolicy.maximumByteCount, !body.isEmpty else { return nil }
        let bytes = try await read(body.lowerBound, count: body.count)
        guard let value = TextEncodingRepair.decodeTextFile(bytes)?.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              !LyricsContentParser.parseText(value, options: .literal).isEmpty else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        let language = (stem as NSString).pathExtension
        return EmbeddedMediaLyricReader.field(name: filename.isEmpty ? description : filename, language: language,
                                              text: value, descriptor: description)
    }

    private func appendTags(_ group: Element, to fields: inout [EmbeddedLyricField]) async throws {
        let elements = try await children(group)
        if let targets = elements.first(where: { $0.id == 0x63C0 }) {
            // Chapter, edition and attachment annotations belong to a different document.
            for target in try await children(targets) where [0x63C4, 0x63C6, 0x63C9].contains(target.id) {
                if let uid = try await number(target), uid != 0 { return }
            }
        }
        for tag in elements where tag.id == 0x67C8 {
            try await appendSimpleTag(tag, parents: [], language: nil, to: &fields)
        }
    }

    private func appendSimpleTag(_ tag: Element, parents: [String], language: String?, to fields: inout [EmbeddedLyricField]) async throws {
        guard parents.count < 32 else { return }
        let elements = try await children(tag)
        guard let key = elements.first(where: { $0.id == 0x45A3 }), let name = try await string(key), !name.isEmpty else { return }
        let path = parents + [name]
        var code = language
        if let lang = elements.first(where: { $0.id == 0x447B }) ?? elements.first(where: { $0.id == 0x447A }),
           let explicit = try await string(lang) { code = LyricLanguageCodePolicy.canonicalIdentifier(explicit) }
        let label = path.joined(separator: "/")
        let declared = ISOBaseMediaLyricsParser.lyricFieldRole(label) ?? ISOBaseMediaLyricsParser.lyricFieldRole(name)
        for value in elements where value.id == 0x4487 || value.id == 0x4485 {
            guard value.body.count > 0, value.body.count <= LyricsRawDocumentPolicy.maximumByteCount,
                  declared != nil || value.id == 0x4487 else { continue }
            let data = try await read(value.body.lowerBound, count: value.body.count)
            guard let text = TextEncodingRepair.decodeTextFile(data)?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
                  let role = declared ?? ISOBaseMediaLyricsParser.lyricFieldRole(label, text: text) else { continue }
            var field = role.field(name: label, text: text)
            if let code { field.languageCode = code }
            fields.append(field)
        }
        for nested in elements where nested.id == 0x67C8 {
            try await appendSimpleTag(nested, parents: path, language: code, to: &fields)
        }
    }

    static func usf(_ sample: EmbeddedMediaLyricReader.Sample) -> [LyricLine] {
        guard let fragment = String(data: sample.data, encoding: .utf8) else { return [] }
        let delegate = USFDelegate(start: sample.start, end: sample.end)
        let parser = XMLParser(data: Data(("<subtitle>" + fragment + "</subtitle>").utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() ? delegate.lines : []
    }

    private final class USFDelegate: NSObject, XMLParserDelegate {
        let start: Double
        let end: Double?
        var lines: [LyricLine] = []
        var depth = 0
        var visible = false
        var text = ""
        var token = ""
        var syllables: [LyricSyllable] = []
        var next: Double
        var duration: Double?

        init(start: Double, end: Double?) { self.start = start; self.end = end; self.next = start }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 2 { visible = name == "text" || name == "karaoke" }
            guard visible else { return }
            if name == "br" { append("\n") }
            if name == "k", let t = attributes["t"].flatMap(Double.init), t.isFinite, t >= 0, t <= 1e10 {
                flush()
                duration = t / 1_000
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if visible, depth == 2 {
                flush()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(.init(timestamp: start, text: text, isSynchronized: true,
                                       syllables: syllables.isEmpty ? nil : syllables, endTimestamp: end))
                }
                visible = false
                next = start
                duration = nil
                text = ""
                token = ""
                syllables.removeAll(keepingCapacity: true)
            }
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if visible { append(string) } }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { if visible { append(String(decoding: data, as: UTF8.self)) } }

        private func append(_ value: String) { text += value; token += value }
        private func flush() {
            if let duration {
                let until = min(end ?? (next + duration), next + duration)
                if !token.isEmpty { syllables.append(.init(text: token, start: next, end: until)) }
                next = until
            } else if !token.isEmpty, token != text || depth > 2 {
                syllables.append(.init(text: token, start: start, end: next))
            }
            token = ""
        }
    }

    private func readCueTable(_ cues: Element, segment: Element, selected: [UInt64: Track], seen: inout Set<Int64>) async throws {
        // CueTime is the block timestamp on the segment timeline. CueRelativePosition refers to the
        // SimpleBlock or BlockGroup relative to the Cluster's *payload*, after its EBML header.
        for point in try await children(cues) where point.id == 0xBB {
            let fields = try await children(point)
            guard let time = fields.first(where: { $0.id == 0xB3 }), let ticks = try await number(time) else { continue }
            for positions in fields where positions.id == 0xB7 {
                let values = try await children(positions)
                guard let track = values.first(where: { $0.id == 0xF7 }), let n = try await number(track), selected[n] != nil,
                      let clusterPos = values.first(where: { $0.id == 0xF1 }), let delta = try await number(clusterPos),
                      delta < UInt64(segment.body.count),
                      let relPos = values.first(where: { $0.id == 0xF0 }), let relative = try await number(relPos),
                      let cluster = try await element(at: segment.body.lowerBound + Int64(delta), limit: segment.body.upperBound),
                      cluster.id == 0x1F43B675, relative < UInt64(cluster.body.count) else { continue }
                let pos = cluster.body.lowerBound + Int64(relative)
                guard !seen.contains(pos), let block = try await element(at: pos, limit: cluster.body.upperBound),
                      try await readBlock(block, trackTime: Double(ticks) * timestampScale, clusterTime: nil, selected: selected, requiredTrack: n)
                else { continue }
                seen.insert(pos)
            }
        }
    }

    private func scan(cluster: Element, selected: [UInt64: Track], indexedPositions: Set<Int64>) async throws {
        var time: Double?
        var cursor = cluster.body.lowerBound
        while let child = try await element(at: cursor, limit: cluster.body.upperBound) {
            if child.id == 0xE7 { time = try await number(child).map { Double($0) * timestampScale } }
            else if let time, !indexedPositions.contains(cursor), child.id == 0xA3 || child.id == 0xA0 {
                _ = try await readBlock(child, trackTime: nil, clusterTime: time, selected: selected, requiredTrack: nil)
            }
            cursor = child.body.upperBound
        }
    }

    private func readBlock(_ element: Element, trackTime: Double?, clusterTime: Double?, selected: [UInt64: Track], requiredTrack: UInt64?) async throws -> Bool {
        var block = element
        var duration: Double?
        if element.id == 0xA0 {
            let fields = try await children(element)
            guard let value = fields.first(where: { $0.id == 0xA1 }) else { return false }
            block = value
            if let field = fields.first(where: { $0.id == 0x9B }) { duration = try await number(field).map { Double($0) * timestampScale } }
        } else if element.id != 0xA3 { return false }
        guard block.body.count >= 4 else { return false }
        let prefix = try await read(block.body.lowerBound, count: min(11, block.body.count), readAhead: true)
        guard let (number, width) = vint(prefix, at: 0, id: false), width + 3 <= prefix.count,
              requiredTrack == nil || requiredTrack == number, let track = selected[number], let decoders = track.decoders,
              prefix[width + 2] & 0x06 == 0 else { return false }
        let relative = Int16(bitPattern: UInt16(prefix[width]) << 8 | UInt16(prefix[width + 1]))
        let start = trackTime ?? ((clusterTime ?? 0) + Double(relative) * timestampScale)
        let count = block.body.count - width - 3
        let prior = sampleBytes[number] ?? 0
        guard prior != Int.max, count > 0 || !decoders.isEmpty else { return false }
        guard count <= LyricsRawDocumentPolicy.maximumByteCount, (samples[number]?.count ?? 0) < 100_000 else {
            return discardTrack(number, bytes: prior)
        }
        let stored = try await read(block.body.lowerBound + Int64(width + 3), count: count)
        let room = min(remainingFrameBytes, LyricsRawDocumentPolicy.maximumByteCount - prior)
        guard let data = Self.decode(stored, using: decoders, maximum: room) else {
            // A damaged stream must not become a partial lyric or discard another track's valid cues.
            return discardTrack(number, bytes: prior)
        }
        guard !data.isEmpty else { return false }
        samples[number, default: []].append(.init(start: max(0, start), end: (duration ?? track.defaultDuration).map { max(0, start + $0) }, data: data))
        sampleBytes[number] = prior + data.count
        remainingFrameBytes -= data.count
        return true
    }

    private func discardTrack(_ number: UInt64, bytes: Int) -> Bool {
        remainingFrameBytes += bytes
        sampleBytes[number] = Int.max
        samples.removeValue(forKey: number)
        return false
    }

    private func children(_ parent: Element) async throws -> [Element] {
        var result: [Element] = []
        var pos = parent.body.lowerBound
        while let value = try await element(at: pos, limit: parent.body.upperBound) {
            result.append(value)
            pos = value.body.upperBound
        }
        return result
    }

    private func element(at pos: Int64, limit: Int64) async throws -> Element? {
        guard pos >= 0, pos < limit else { return nil }
        guard remainingElements > 0 else { throw Limit.reached }
        remainingElements -= 1
        let b = try await read(pos, count: Int(min(12, limit - pos)), readAhead: true)
        guard let (id, idWidth) = vint(b, at: 0, id: true), let (size, width) = vint(b, at: idWidth, id: false) else { return nil }
        let start = pos + Int64(idWidth + width)
        let unknown = size == (UInt64(1) << (7 * width)) - 1
        guard start <= limit, unknown || size <= UInt64(limit - start) else { return nil }
        return Element(id: id, body: start..<(unknown ? limit : start + Int64(size)), unknown: unknown)
    }

    private func vint(_ bytes: Data, at pos: Int, id: Bool) -> (UInt64, Int)? {
        guard pos < bytes.count, bytes[pos] != 0 else { return nil }
        let width = bytes[pos].leadingZeroBitCount + 1
        guard width <= (id ? 4 : 8), width <= bytes.count - pos else { return nil }
        var value = UInt64(id ? bytes[pos] : bytes[pos] & (0xFF >> width))
        for byte in bytes[(pos + 1)..<(pos + width)] { value = value << 8 | UInt64(byte) }
        return (value, width)
    }

    private func string(_ value: Element) async throws -> String? {
        guard value.body.count <= 8192 else { return nil }
        return try await String(data: read(value.body.lowerBound, count: value.body.count), encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }

    private func number(_ value: Element) async throws -> UInt64? {
        guard (1...8).contains(value.body.count) else { return nil }
        return try await read(value.body.lowerBound, count: value.body.count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private func read(_ offset: Int64, count: Int, readAhead: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= fileSize, count >= 0, Int64(count) <= fileSize - offset else { throw Limit.reached }
        if count == 0 { return Data() }
        if offset <= head.count, count <= head.count - Int(offset) {
            let i = head.startIndex + Int(offset)
            return Data(head[i..<(i + count)])
        }
        if let pinnedMetadata {
            let delta = offset - pinnedMetadata.start
            if delta >= 0, delta <= pinnedMetadata.bytes.count, count <= pinnedMetadata.bytes.count - Int(delta) {
                return pinnedMetadata.bytes.subdata(in: Int(delta)..<(Int(delta) + count))
            }
        }
        let delta = offset - cacheStart
        if delta >= 0, delta <= cache.count, count <= cache.count - Int(delta) {
            let i = cache.startIndex + Int(delta)
            return Data(cache[i..<(i + count)])
        }
        let size = readAhead ? max(count, Int(min(256, fileSize - offset))) : count
        guard size <= remainingBytes, remainingReads > 0 else { throw Limit.reached }
        remainingBytes -= size
        remainingReads -= 1
        cache = try await fetch(offset, Int64(size))
        cacheStart = offset
        guard cache.count == size else { throw ISOBaseMediaRangeReader.ReadError.incompleteRange }
        return Data(cache.prefix(count))
    }
}
