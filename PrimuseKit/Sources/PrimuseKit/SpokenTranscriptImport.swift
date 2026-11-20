import Foundation

/// 批量导入的文字稿(#461)。
public enum SpokenTranscriptImportPolicy {
    /// 导入的这份记下来自哪个文件,并算作用户提供的:服务器稿、生成稿都不会自动换掉它。
    public static func importedDocument(_ lines: [LyricLine], fileName: String) -> [LyricLine] {
        var stamped = LyricsDocumentSource.file(fileName).stamped(lines)
        guard !stamped.isEmpty else { return stamped }
        stamped[0].documentIsLocalOverride = true
        return stamped
    }
}

/// 一批文字稿文件按文件名对到一本书的各章。规则一条条试,前一条对上的章节后面的不再要:
/// 1. 文件名(不算扩展名)和章节的音频文件名一样;
/// 2. `<名>.<语言>.vtt` 这类带语言后缀的,去掉语言后一样;
/// 3. 文件名和章节标题一样;
/// 4. 文件名里最后一个数字和章节音频文件名里的(没有就用曲目号)一样。
/// 比较时不分大小写、全角半角,下划线当空格。一份文件对上不止一章的不算对上;几份对上
/// 同一章时留时间轴最细的那份。
public enum SpokenTranscriptImportMatcher {
    public struct Track: Equatable, Sendable {
        public let id: String
        /// 音频文件名(带不带扩展名都行);不知道时为 nil。
        public let fileName: String?
        public let title: String
        public let trackNumber: Int?

        public init(id: String, fileName: String?, title: String, trackNumber: Int? = nil) {
            self.id = id
            self.fileName = fileName
            self.title = title
            self.trackNumber = trackNumber
        }
    }

    public struct File: Equatable, Sendable {
        public let name: String
        /// 读出来的文字稿时间轴精度;读不出能用的内容时为 nil。
        public let level: LyricsTimingLevel?

        public init(name: String, level: LyricsTimingLevel?) {
            self.name = name
            self.level = level
        }
    }

    public enum Rule: Equatable, Sendable {
        case fileName
        case languageTagged
        case title
        case number
    }

    public struct Match: Equatable, Sendable {
        public let fileIndex: Int
        public let trackID: String
        public let rule: Rule
    }

    public enum SkipReason: Equatable, Sendable {
        /// 读不出文字稿。
        case unreadable
        /// 没有哪一章对得上。
        case noTrack
        /// 对上的那一章已经有更合适的一份。
        case duplicate
    }

    public struct Skip: Equatable, Sendable {
        public let fileIndex: Int
        public let reason: SkipReason
    }

    public struct Result: Equatable, Sendable {
        /// 按章节顺序。
        public let matches: [Match]
        /// 按文件顺序。
        public let skipped: [Skip]
    }

    public static func match(files: [File], tracks: [Track]) -> Result {
        var assigned: [Int: (track: Int, rule: Rule)] = [:]
        var skipped: [Int: SkipReason] = [:]
        for (index, file) in files.enumerated() where file.level == nil {
            skipped[index] = .unreadable
        }
        var claimed: Set<Int> = []

        for rule in [Rule.fileName, .languageTagged, .title, .number] {
            var claims: [Int: [Int]] = [:]
            for fileIndex in files.indices where assigned[fileIndex] == nil && skipped[fileIndex] == nil {
                guard let key = fileKey(files[fileIndex].name, rule: rule) else { continue }
                let candidates = tracks.indices.filter { trackKeys(tracks[$0], rule: rule).contains(key) }
                guard candidates.count == 1, let trackIndex = candidates.first else { continue }
                if claimed.contains(trackIndex) {
                    skipped[fileIndex] = .duplicate
                } else {
                    claims[trackIndex, default: []].append(fileIndex)
                }
            }
            for (trackIndex, fileIndices) in claims {
                guard let best = bestFile(among: fileIndices, files: files) else { continue }
                assigned[best] = (trackIndex, rule)
                claimed.insert(trackIndex)
                for other in fileIndices where other != best { skipped[other] = .duplicate }
            }
        }
        for index in files.indices where assigned[index] == nil && skipped[index] == nil {
            skipped[index] = .noTrack
        }
        let matches = assigned
            .sorted { $0.value.track < $1.value.track }
            .map { Match(fileIndex: $0.key, trackID: tracks[$0.value.track].id, rule: $0.value.rule) }
        let skips = skipped.keys.sorted().map { Skip(fileIndex: $0, reason: skipped[$0] ?? .noTrack) }
        return Result(matches: matches, skipped: skips)
    }

    // MARK: - Keys

    static func normalizedKey(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func stem(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        let ext = (last as NSString).pathExtension.lowercased()
        guard !ext.isEmpty,
              PrimuseConstants.readableLyricsExtensions.contains(ext)
                || PrimuseConstants.supportedAudioExtensions.contains(ext)
                || ext == "txt" else { return last }
        return (last as NSString).deletingPathExtension
    }

    /// 最后一段数字的值:`第03章` → 3,`Lesson 12 Part 2` → 2。
    static func lastNumber(in value: String) -> String? {
        var digits: [Character] = []
        var current: [Character] = []
        for character in value {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                digits = current
                current = []
            }
        }
        if !current.isEmpty { digits = current }
        guard !digits.isEmpty, let number = Int(String(digits.suffix(9))) else { return nil }
        return String(number)
    }

    private static func fileKey(_ name: String, rule: Rule) -> String? {
        switch rule {
        case .fileName, .title:
            let key = normalizedKey(stem(name))
            return key.isEmpty ? nil : key
        case .languageTagged:
            guard let base = LyricsSidecarSelectionPolicy.languageTaggedComponents(ofSidecarNamed: name)?.baseName else {
                return nil
            }
            let key = normalizedKey(base)
            return key.isEmpty ? nil : key
        case .number:
            return lastNumber(in: normalizedKey(stem(name)))
        }
    }

    private static func trackKeys(_ track: Track, rule: Rule) -> [String] {
        switch rule {
        case .fileName, .languageTagged:
            guard let fileName = track.fileName else { return [] }
            let key = normalizedKey(stem(fileName))
            return key.isEmpty ? [] : [key]
        case .title:
            let key = normalizedKey(track.title)
            return key.isEmpty ? [] : [key]
        case .number:
            if let fileName = track.fileName, let number = lastNumber(in: normalizedKey(stem(fileName))) {
                return [number]
            }
            return track.trackNumber.map { [String($0)] } ?? []
        }
    }

    /// 几份对上同一章时留哪份:时间轴细的、格式排得靠前的(`readableLyricsExtensions` 的顺序)、文件名靠前的。
    private static func bestFile(among indices: [Int], files: [File]) -> Int? {
        let order = PrimuseConstants.readableLyricsExtensions
        func rank(_ index: Int) -> Int {
            let ext = (files[index].name as NSString).pathExtension.lowercased()
            return order.firstIndex(of: ext) ?? order.count
        }
        return indices.min { left, right in
            let leftLevel = files[left].level ?? .plain
            let rightLevel = files[right].level ?? .plain
            if leftLevel != rightLevel { return leftLevel > rightLevel }
            if rank(left) != rank(right) { return rank(left) < rank(right) }
            return files[left].name < files[right].name
        }
    }
}
