import Foundation

/// Adapts OpenSubsonic's independent lyric tracks to a single player document.
public enum OpenSubsonicLyricsConverter {
    public struct Track: Decodable, Sendable {
        public let kind: String?
        public let lang: String?
        public let synced: Bool?
        public let offset: Double?
        public let line: [Line]?
        public let cueLine: [CueLine]?
        public let agents: [Agent]?
    }

    public struct Agent: Decodable, Sendable {
        public let id: String
        public let role: String
        public let name: String?
    }

    public struct Line: Decodable, Sendable {
        public let start: Double?
        public let end: Double?
        public let value: String?
    }

    public struct CueLine: Decodable, Sendable {
        public let index: Int?
        public let agentId: String?
        public let start: Int?
        public let end: Int?
        public let value: String?
        public let cue: [Cue]?
    }

    public struct Cue: Decodable, Sendable {
        public let start: Int?
        public let end: Int?
        public let value: String?
        public let byteStart: Int?
        public let byteEnd: Int?
    }

    public static func text(from tracks: [Track]) -> String? {
        let mains = tracks.filter { normalizedKind($0.kind) == "main" && $0.line?.isEmpty == false }
        let main = mains.first(where: hasRenderableCues)
            ?? mains.first { track in
                track.synced != false && (track.cueLine ?? []).contains { layer in
                    guard let index = layer.index, track.line?.indices.contains(index) == true else { return false }
                    return lineValue(layer.value) != nil
                }
            }
            ?? mains.first { $0.line?.contains { lineValue($0.value) != nil } == true }
        guard let main, let lines = main.line else { return nil }

        let language = main.lang.flatMap(LyricLanguageCodePolicy.canonicalIdentifier)
        let companions = tracks.compactMap { Companion($0, originalLanguage: language) }
            .sorted { $0.priority < $1.priority }
        // Basic servers can carry bilingual or enhanced LRC inside line.value.
        // Keep that text on the usual LRC parsing path.
        if companions.isEmpty, main.cueLine?.isEmpty != false, !lines.contains(where: { $0.end != nil }) {
            let body = lines.compactMap { line -> String? in
                guard let value = lineValue(line.value) else { return nil }
                guard main.synced != false, let start = line.start else { return value }
                return lrcTimestamp(adjustedTimestamp(start, offset: main.offset ?? 0)) + value
            }.joined(separator: "\n")
            guard !body.isEmpty else { return nil }
            guard let language else { return body }
            if main.synced != false, lines.contains(where: { $0.start != nil }) {
                return "[la:\(language)]\n" + body
            }
            var parsed = LyricsContentParser.parseText(body)
            guard !parsed.isEmpty else { return nil }
            parsed[0].metadataLines = ["[la:\(language)]"] + (parsed[0].metadataLines ?? [])
            return LyricsContentParser.serializeTTML(parsed)
        }

        var originals = rows(in: main)
        guard !originals.isEmpty else { return nil }
        if !companions.isEmpty {
            let timeline = Timeline(originals)
            for companion in companions {
                let annotations = rows(in: companion.track)
                let matches = timeline.matches(annotations)
                for (target, indices) in matches {
                    let annotation = joinedAnnotation(indices.map { annotations[$0].line })
                    companion.kind.attach(annotation, language: companion.language, to: &originals[target].line)
                }
            }
        }
        var document = nestingBackingVocals(originals)
        if companions.isEmpty, main.agents?.isEmpty != false {
            document = LyricBilingualPairingPolicy.pair(document)
        }
        if let language { document[0].metadataLines = ["[la:\(language)]"] }
        return LyricsContentParser.serializeTTML(document)
    }

    private static func hasRenderableCues(_ track: Track) -> Bool {
        track.synced != false && (track.cueLine ?? []).contains { cueLine in
            guard let index = cueLine.index, track.line?.indices.contains(index) == true else { return false }
            return (cueLine.cue ?? []).contains { cue in
                cue.start.map { $0 >= 0 } == true && lineValue(cue.value) != nil
            }
        }
    }

    private struct Row {
        let parentIndex: Int
        let agent: Agent?
        var line: LyricLine
    }

    private struct Companion {
        let track: Track
        let kind: LyricAnnotationKind
        let language: String?
        let priority: Int

        init?(_ track: Track, originalLanguage: String?) {
            guard track.line?.isEmpty == false else { return nil }
            self.track = track
            language = track.lang.flatMap(LyricLanguageCodePolicy.canonicalIdentifier)
            switch normalizedKind(track.kind) {
            case "translation":
                kind = .translation
                priority = 0
            case "pronunciation":
                kind = .romanization
                // The player presents one reading per sung line. Prefer a
                // transcription of the selected original, then an untagged one.
                if let language, let originalLanguage,
                   language.split(separator: "-").first == originalLanguage.split(separator: "-").first {
                    priority = 1
                } else {
                    priority = language == nil ? 2 : 3
                }
            default:
                return nil
            }
        }
    }

    private static func rows(in track: Track) -> [Row] {
        let lines = track.line ?? []
        let offset = track.offset ?? 0
        let agents = Dictionary((track.agents ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byIndex = Dictionary(grouping: track.synced == false ? [] : track.cueLine ?? [], by: \.index)
        var result: [Row] = []
        for (index, parent) in lines.enumerated() {
            let parentStart = track.synced == false ? nil : parent.start.map { adjustedTimestamp($0, offset: offset) }
            let parentEnd = track.synced == false ? nil : parent.end.map { adjustedTimestamp($0, offset: offset) }
            let nextStart = lines.indices.contains(index + 1)
                ? lines[index + 1].start.map { adjustedTimestamp($0, offset: offset) } : nil
            let priorCount = result.count
            for layer in byIndex[index] ?? [] {
                let start = layer.start.map { adjustedTimestamp($0, offset: offset) } ?? parentStart
                let end = layer.end.map { adjustedTimestamp($0, offset: offset) } ?? parentEnd
                let syllables = syllables(in: layer, end: end, nextStart: nextStart, offset: offset)
                guard let value = lyricText(syllables?.map(\.text).joined()) ?? lyricText(layer.value) else { continue }
                let lineStart = start.map { Double($0) / 1000 }
                let onset = [lineStart, syllables?.first?.start].compactMap { $0 }.min()
                let agent = layer.agentId.flatMap { agents[$0] }
                let line = LyricLine(
                    timestamp: onset ?? 0, text: value, isSynchronized: onset != nil, syllables: syllables,
                    endTimestamp: end.map { Double($0) / 1000 } ?? syllables?.last?.end,
                    voice: agent?.role == "voice" || agent?.role == "bg" ? .secondary : .primary,
                    isBackingVocal: agent?.role == "bg"
                )
                result.append(Row(parentIndex: index, agent: agent, line: LyricTextEntityPolicy.decoded(line)))
            }
            if result.count == priorCount, let value = lyricText(parent.value) {
                let line = LyricLine(
                    timestamp: Double(parentStart ?? 0) / 1000, text: value,
                    isSynchronized: parentStart != nil, endTimestamp: parentEnd.map { Double($0) / 1000 }
                )
                result.append(Row(parentIndex: index, agent: nil, line: LyricTextEntityPolicy.decoded(line)))
            }
        }
        return result
    }

    private static func syllables(in layer: CueLine, end: Int?, nextStart: Int?, offset: Double) -> [LyricSyllable]? {
        let cues = (layer.cue ?? []).enumerated().compactMap { order, cue -> TimedCue? in
            guard let start = cue.start, start >= 0,
                  let value = cue.value, !value.isEmpty else { return nil }
            return TimedCue(
                order: order,
                start: adjustedTimestamp(start, offset: offset),
                end: cue.end.map { adjustedTimestamp($0, offset: offset) },
                value: value,
                byteStart: cue.byteStart,
                byteEnd: cue.byteEnd
            )
        }.sorted {
            $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start
        }
        guard !cues.isEmpty,
              cues.contains(where: { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }

        let values = resolvedValues(for: cues, canonicalLine: layer.value)
        return cues.enumerated().map { index, cue in
            let cueEnd = cue.end
                ?? (cues.indices.contains(index + 1) ? cues[index + 1].start : nil)
                ?? end ?? nextStart
                ?? addingMilliseconds(400, to: cue.start)
            return LyricSyllable(text: values[index], start: Double(cue.start) / 1000,
                                 end: Double(max(cue.start, cueEnd)) / 1000,
                                 endTiming: cue.end == nil ? .inferred : .explicit)
        }
    }

    private static func nestingBackingVocals(_ rows: [Row]) -> [LyricLine] {
        var document: [LyricLine] = []
        var remaining = rows[...]
        while let first = remaining.first {
            let group = remaining.prefix { $0.parentIndex == first.parentIndex }
            remaining = remaining[group.endIndex...]
            let vocals = group.filter { !$0.line.isBackingVocal }
            let backing = group.filter { $0.line.isBackingVocal }.map(\.line)
            guard !vocals.isEmpty else {
                document += backing
                continue
            }
            var lines = vocals.map(\.line)
            if !backing.isEmpty {
                let lead = vocals.firstIndex { $0.agent?.role == "main" } ?? 0
                lines[lead].background = backing
            }
            document += lines
        }
        return document.sorted { $0.timestamp < $1.timestamp }
    }

    /// A track's indices and agent IDs only address its own rows. Look up other
    /// tracks on the playback clock and narrow simultaneous vocals by role/name.
    private struct Timeline {
        struct Target {
            let index: Int
            let start: TimeInterval
            let end: TimeInterval
            let agent: Agent?
        }

        let timed: [Target]
        let plainParents: [Int]

        init(_ originals: [Row]) {
            let ordered = originals.indices.filter { originals[$0].line.isSynchronized }
                .sorted { originals[$0].line.timestamp < originals[$1].line.timestamp }
            plainParents = ordered.isEmpty ? originals.map(\.parentIndex) : []
            var nextStart: TimeInterval?
            var previousStart: TimeInterval?
            var targets: [Target] = []
            for index in ordered.reversed() {
                let row = originals[index]
                let start = row.line.timestamp
                if previousStart != start {
                    nextStart = previousStart
                    previousStart = start
                }
                targets.append(Target(index: index, start: start, end: row.line.endTime ?? nextStart ?? start, agent: row.agent))
            }
            timed = targets.reversed()
        }

        func matches(_ annotations: [Row]) -> [Int: [Int]] {
            if timed.isEmpty {
                guard !plainParents.isEmpty, annotations.allSatisfy({ !$0.line.isSynchronized }),
                      annotations.map(\.parentIndex) == plainParents else { return [:] }
                return Dictionary(uniqueKeysWithValues: annotations.indices.map { ($0, [$0]) })
            }
            let ordered = annotations.indices.filter { annotations[$0].line.isSynchronized }
                .sorted { annotations[$0].line.timestamp < annotations[$1].line.timestamp }
            var matches: [Int: [Int]] = [:]
            var active: [Target] = []
            var cursor = timed.startIndex
            for index in ordered {
                let row = annotations[index]
                let time = row.line.timestamp
                // Some servers round the parent LRC row to centiseconds.
                let tolerance = 0.010_001
                while cursor < timed.endIndex, timed[cursor].start <= time + tolerance {
                    active.append(timed[cursor])
                    cursor += 1
                }
                active.removeAll { $0.end <= time && abs($0.start - time) > tolerance }
                var best: (Int, Int, Double, Int)?
                var owner: Int?
                func consider(_ target: Target) {
                    guard let rank = Self.agentRank(row.agent, target.agent) else { return }
                    let distance = abs(time - target.start)
                    let score = (rank < 0 ? 0 : 1, distance <= tolerance ? 1 : 0, -distance, rank)
                    if let best {
                        if score == best { owner = nil }
                        guard score > best else { return }
                    }
                    best = score
                    owner = target.index
                }
                for target in active { consider(target) }
                // A translated phrase can begin before the singer. Only its
                // own end can establish an overlap with a later original.
                if best == nil, let end = row.line.endTime {
                    for target in timed[cursor...].prefix(while: { $0.start < end }) {
                        consider(target)
                    }
                }
                if let owner { matches[owner, default: []].append(index) }
            }
            return matches
        }

        private static func agentRank(_ annotation: Agent?, _ original: Agent?) -> Int? {
            // A passage can be sung entirely by a backing singer. An
            // unattributed annotation goes there only if no foreground vocal fits.
            if annotation == nil, original?.role == "bg" { return -1 }
            guard (annotation?.role == "bg") == (original?.role == "bg") else { return nil }
            if let name = annotation?.name, !name.isEmpty, let other = original?.name, !other.isEmpty {
                return name.caseInsensitiveCompare(other) == .orderedSame ? 3 : nil
            }
            if let role = annotation?.role, role != "main", let other = original?.role, role != other { return nil }
            if annotation?.role == original?.role { return 2 }
            return original == nil || original?.role == "main" ? 1 : 0
        }
    }

    private static func joinedAnnotation(_ lines: [LyricLine]) -> LyricLine {
        var annotation = lines[0]
        guard lines.count > 1 else { return annotation }
        annotation.text = lines.map(\.text).joined(separator: "\n")
        if lines.contains(where: \.isWordLevel) {
            annotation.syllables = lines.enumerated().flatMap { index, line in
                var words = line.syllables ?? [LyricSyllable(
                    text: line.text, start: line.timestamp, end: line.endTime ?? line.timestamp,
                    endTiming: line.endTime == nil ? .inferred : .explicit
                )]
                if index + 1 < lines.count { words[words.count - 1].text += "\n" }
                return words
            }
        }
        return annotation
    }

    /// byteStart/byteEnd point into cueLine.value's final UTF-8 bytes. Taking
    /// each segment up to the next cue retains spaces and any untimed text.
    private static func resolvedValues(
        for cues: [TimedCue],
        canonicalLine: String?
    ) -> [String] {
        let fallback = cues.map(\.value)
        guard let canonicalLine, !canonicalLine.isEmpty else { return fallback }
        let bytes = Array(canonicalLine.utf8)
        var result: [String] = []
        for index in cues.indices {
            guard let start = cues[index].byteStart,
                  let end = cues[index].byteEnd,
                  start >= 0, end >= start, end < bytes.count else {
                return fallback
            }
            let lower = index == cues.startIndex ? 0 : start
            let upper: Int
            if cues.indices.contains(index + 1) {
                guard let nextStart = cues[index + 1].byteStart,
                      nextStart > end, nextStart <= bytes.count else { return fallback }
                upper = nextStart
            } else {
                upper = bytes.count
            }
            guard lower < upper,
                  let value = String(bytes: bytes[lower..<upper], encoding: .utf8) else {
                return fallback
            }
            result.append(value)
        }
        return result
    }

    private static func normalizedKind(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "main" : normalized.lowercased()
    }

    private static func lineValue(_ value: String?) -> String? {
        lyricText(value).map(oneLine)
    }

    private static func lyricText(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func lrcTimestamp(_ milliseconds: Int) -> String {
        let fraction = milliseconds % 1000
        let suffix = fraction.isMultiple(of: 10)
            ? String(format: "%02d", fraction / 10) : String(format: "%03d", fraction)
        return String(format: "[%02lld:%02d.", Int64(milliseconds / 60_000), milliseconds / 1000 % 60) + suffix + "]"
    }

    /// OpenSubsonic defines a positive track offset as displaying lyrics
    /// earlier, and a negative offset as displaying them later.
    private static func adjustedTimestamp(_ timestamp: Int, offset: Double) -> Int {
        adjustedTimestamp(Double(timestamp), offset: offset)
    }

    /// The API permits fractional line starts and offsets, while Primuse's
    /// playback timeline has millisecond precision.
    private static func adjustedTimestamp(_ timestamp: Double, offset: Double) -> Int {
        guard timestamp.isFinite, offset.isFinite else { return 0 }
        let adjusted = max(0, timestamp) - offset
        if adjusted <= 0 { return 0 }
        if adjusted >= Double(Int.max) { return .max }
        return Int(adjusted.rounded())
    }

    private static func addingMilliseconds(_ milliseconds: Int, to timestamp: Int) -> Int {
        let (result, overflow) = timestamp.addingReportingOverflow(milliseconds)
        return overflow ? .max : result
    }

    private struct TimedCue {
        let order: Int
        let start: Int
        let end: Int?
        let value: String
        let byteStart: Int?
        let byteEnd: Int?
    }
}
