import Foundation

/// 整轨镜像（一个 WAV/FLAC/APE + `.cue`）切出来的虚拟分轨，歌词常常是按曲目
/// 分开放在旁边的：`01 标题.lrc`、`01. 标题.lrc`、`艺人 - 标题.lrc`、`01.lrc`……
/// 它们都不和音频同名，同名查找（`<整轨名>.lrc`）永远找不到；而同名的那份
/// 如果存在，是整张专辑的歌词，塞给每一轨只会从第一首唱起。
///
/// 这里只做一件事：给定 CUE 的曲目和目录里的文件名，决定每一轨读哪个歌词文件。
/// 扫描器（三端）、播放时的兜底查找、写回时的目标选择都走这一份判定，所以
/// 读到的和写回的是同一个文件。
///
/// 匹配只看文件名去掉扩展名（`.vtt`/`.srt` 再去掉语言后缀）后的部分，比较时
/// 用宽松键：NFKC + 小写，只留字母、数字和附加符号。这样 `?` 被系统换成 `_`、
/// 全角字符、macOS 上 NFD 形式的文件名都还能对上。
public enum CueTrackLyricsSidecarPolicy {
    public struct Track: Sendable, Equatable {
        public var number: Int
        public var title: String?
        public var performer: String?

        public init(number: Int, title: String?, performer: String?) {
            self.number = number
            self.title = title
            self.performer = performer
        }
    }

    /// 匹配强度，数值越小越强。同一个文件或同一轨有多个候选时，强的先占。
    enum MatchTier: Int, Comparable {
        /// 开头是音轨号，后面是标题：`01 标题`、`01. 艺人 - 标题`。
        case leadingNumber = 0
        /// 整轨名 / CUE 名 / `Track` 之后才是音轨号 + 标题：`专辑 - 01 - 标题`。
        case prefixedLeadingNumber
        /// 只有标题（或艺人 + 标题），且这个标题在 CUE 里独一无二。
        case titleOnly
        /// 只有前缀加音轨号：`专辑 - 01`、`CDImage 01`、`Track 01`。
        case prefixedNumber
        /// 只有音轨号：`01.lrc`。目录里只有一张 CUE 镜像时才认。
        case bareNumber

        static func < (lhs: MatchTier, rhs: MatchTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 目录里哪些文件可能是某一轨的歌词：能读的歌词格式，并且不是目录里某个
    /// 媒体文件自己的同名歌词（`歌.flac` 旁的 `歌.lrc`、`歌.en.vtt`）。返回
    /// `fileNames` 里的下标，保持原顺序。
    public static func candidateIndices(in fileNames: [String]) -> [Int] {
        var mediaStems: Set<String> = []
        var lyricIndices: [Int] = []
        for (index, name) in fileNames.enumerated() {
            let fileExtension = (name as NSString).pathExtension.lowercased()
            if isMediaExtension(fileExtension) {
                mediaStems.insert((name as NSString).deletingPathExtension.lowercased())
            } else if PrimuseConstants.readableLyricsExtensions.contains(fileExtension) {
                lyricIndices.append(index)
            }
        }
        guard !mediaStems.isEmpty else { return lyricIndices }
        return lyricIndices.filter { index in
            let name = fileNames[index]
            let stem = (name as NSString).deletingPathExtension.lowercased()
            if mediaStems.contains(stem) { return false }
            // `歌.it.vtt` 旁边既有 `歌.flac` 也可能有 `歌.it.flac`；两种情况
            // 它都属于那个媒体文件，不是哪一轨 CUE 的。
            if let tagged = LyricsSidecarSelectionPolicy
                .languageTaggedComponents(ofSidecarNamed: name),
               mediaStems.contains(tagged.baseName.lowercased()) {
                return false
            }
            return true
        }
    }

    /// 每一轨对应的歌词文件：音轨号 → `candidateNames` 里的下标。
    ///
    /// - Parameters:
    ///   - tracks: 这张 CUE 里属于这个音频文件的曲目。
    ///   - audioBaseName: 整轨音频文件名去掉扩展名。
    ///   - cueBaseName: `.cue` 文件名去掉扩展名。
    ///   - candidateNames: 一般先经 `candidateIndices(in:)` 过滤；没过滤也
    ///     不会把整轨同名歌词分给某一轨。
    ///   - cueImageCount: 这个目录里有几张 CUE 镜像（被 CUE 引用的音频文件数）。
    ///     只有一张时才认光秃秃的 `01.lrc`。
    public static func assignments(
        tracks: [Track],
        audioBaseName: String,
        cueBaseName: String?,
        candidateNames: [String],
        cueImageCount: Int,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [Int: Int] {
        guard !tracks.isEmpty, !candidateNames.isEmpty else { return [:] }

        var tracksByNumber: [Int: Track] = [:]
        for track in tracks where track.number > 0 && tracksByNumber[track.number] == nil {
            tracksByNumber[track.number] = track
        }
        guard !tracksByNumber.isEmpty else { return [:] }

        let audioKey = looseKey(audioBaseName)
        let normalizedAudio = normalized(audioBaseName)
        let normalizedCue = cueBaseName.map(normalized)
        let cueKey = cueBaseName.map(looseKey) ?? ""

        // 标题和「艺人 - 标题」两种写法都只在 CUE 里独一无二时才可信：两首都叫
        // Intro，`Intro.lrc` 归谁都是猜。
        var titleOnlyOwners: [String: Int] = [:]
        var ambiguousTitleKeys: Set<String> = []
        for track in tracksByNumber.values {
            for key in titleOnlyKeys(for: track) {
                if let owner = titleOnlyOwners[key], owner != track.number {
                    ambiguousTitleKeys.insert(key)
                } else {
                    titleOnlyOwners[key] = track.number
                }
            }
        }
        for key in ambiguousTitleKeys { titleOnlyOwners[key] = nil }

        let languageRanks = languageTagRanks(
            in: candidateNames,
            preferredLanguages: preferredLanguages
        )

        struct Match {
            let track: Int
            let candidate: Int
            let tier: MatchTier
            let extensionRank: Int
            let languageRank: Int
            let sortName: String
        }
        var matches: [Match] = []

        for (index, name) in candidateNames.enumerated() {
            let fileExtension = (name as NSString).pathExtension.lowercased()
            guard let extensionRank = PrimuseConstants.readableLyricsExtensions
                .firstIndex(of: fileExtension) else { continue }
            let baseName = documentBaseName(ofFileName: name)
            let key = looseKey(baseName)
            // 整轨自己的同名歌词是整张专辑的，只能当兜底，不能分给某一轨。
            guard !key.isEmpty, key != audioKey else { continue }

            let tag = LyricsSidecarSelectionPolicy.languageTaggedComponents(ofSidecarNamed: name)?.tag
            let languageRank = tag.map { languageRanks[$0] ?? Int.max } ?? -1
            let normalizedBase = normalized(baseName)

            var found: [(Int, MatchTier)] = []
            if let (number, remainder) = leadingNumber(in: normalizedBase),
               let track = tracksByNumber[number],
               remainderMatches(remainder, track: track) {
                found.append((number, .leadingNumber))
            }
            for prefix in [normalizedAudio, normalizedCue, "track"].compactMap({ $0 }) {
                guard let rest = remainder(of: normalizedBase, afterPrefix: prefix),
                      let (number, remainder) = leadingNumber(in: String(rest)),
                      let track = tracksByNumber[number],
                      remainderMatches(remainder, track: track) else { continue }
                found.append((number, .prefixedLeadingNumber))
                break
            }
            if let owner = titleOnlyOwners[key] {
                found.append((owner, .titleOnly))
            }
            for prefixKey in [audioKey, cueKey, "track"] where !prefixKey.isEmpty {
                guard key.hasPrefix(prefixKey),
                      let number = trackNumber(fromDigits: key.dropFirst(prefixKey.count)),
                      tracksByNumber[number] != nil else { continue }
                found.append((number, .prefixedNumber))
                break
            }
            if cueImageCount == 1,
               let number = trackNumber(fromDigits: Substring(key)),
               tracksByNumber[number] != nil {
                found.append((number, .bareNumber))
            }

            for (track, tier) in found {
                matches.append(Match(
                    track: track,
                    candidate: index,
                    tier: tier,
                    extensionRank: extensionRank,
                    languageRank: languageRank,
                    sortName: name.lowercased()
                ))
            }
        }

        // 强的匹配先占，同一档里按歌词读取优先级（lrc 在前、字幕在后），再按
        // 文件名定序，保证同一个目录永远分出同一个结果。
        matches.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.extensionRank != rhs.extensionRank { return lhs.extensionRank < rhs.extensionRank }
            if lhs.languageRank != rhs.languageRank { return lhs.languageRank < rhs.languageRank }
            if lhs.sortName != rhs.sortName { return lhs.sortName < rhs.sortName }
            if candidateNames[lhs.candidate] != candidateNames[rhs.candidate] {
                return candidateNames[lhs.candidate] < candidateNames[rhs.candidate]
            }
            return lhs.track < rhs.track
        }
        var result: [Int: Int] = [:]
        var usedCandidates: Set<Int> = []
        for match in matches
        where result[match.track] == nil && !usedCandidates.contains(match.candidate) {
            result[match.track] = match.candidate
            usedCandidates.insert(match.candidate)
        }
        return result
    }

    /// 歌词文件去掉扩展名、再去掉 `.vtt`/`.srt` 的语言后缀后的部分，也就是
    /// 写回时替身文件（`<它>.ttml`）要用的名字。
    public static func documentBaseName(ofFileName fileName: String) -> String {
        if let tagged = LyricsSidecarSelectionPolicy.languageTaggedComponents(ofSidecarNamed: fileName) {
            return tagged.baseName
        }
        return (fileName as NSString).deletingPathExtension
    }

    /// 某一轨还没有自己的歌词文件、要新建时用的名字。有真标题时是
    /// `01 标题.lrc`，否则是 `<整轨名> - 01.lrc`；两种都能被 `assignments`
    /// 认回这一轨，所以存一轨不会动到别的轨。
    public static func newDocumentFileName(
        for track: Track,
        audioBaseName: String,
        fileExtension: String = "lrc"
    ) -> String {
        let number = (0..<10).contains(track.number)
            ? "0\(track.number)"
            : String(track.number)
        if let title = track.title, !isPlaceholderTitle(title) {
            let sanitized = sanitizedFileNameComponent(title)
            // 截断或清洗后对不上原标题，就认不回来了，改用不依赖标题的写法。
            if !sanitized.isEmpty,
               sanitized.count <= maximumTitleLength,
               looseKey(sanitized) == looseKey(title) {
                return "\(number) \(sanitized).\(fileExtension)"
            }
        }
        let audio = sanitizedFileNameComponent(audioBaseName)
        return "\(audio.isEmpty ? "Track" : audio) - \(number).\(fileExtension)"
    }

    /// 一首歌记下的歌词引用是不是某一轨自己的歌词文件，而不是整轨同名的那份、
    /// 本机缓存名或提供方的不透明 ID。只凭名字判断：认不出来就答「不是」，
    /// 调用方沿用原来的做法。
    public static func referencesTrackDocument(_ reference: String?, audioPath: String) -> Bool {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty,
              !reference.contains("://") else { return false }
        let name = (reference as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard PrimuseConstants.readableLyricsExtensions.contains(fileExtension) else { return false }
        if reference.contains("/"), audioPath.contains("/") {
            let referenceParent = normalizedDirectory((reference as NSString).deletingLastPathComponent)
            let audioParent = normalizedDirectory((audioPath as NSString).deletingLastPathComponent)
            guard referenceParent == audioParent else { return false }
        }
        let audioBase = ((audioPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let key = looseKey(documentBaseName(ofFileName: name))
        return !key.isEmpty && key != looseKey(audioBase)
    }

    /// CUE 没写标题时扫描器会填「Track 01」「曲目 01」之类的占位，它们不是
    /// 能拿来匹配文件名的标题。
    public static func isPlaceholderTitle(_ title: String?) -> Bool {
        guard let title else { return true }
        let key = looseKey(title)
        guard !key.isEmpty else { return true }
        if key.allSatisfy(\.isASCIIDigitCharacter) { return true }
        for word in placeholderTitleWords where key.hasPrefix(word) {
            let rest = key.dropFirst(word.count)
            if !rest.isEmpty, rest.allSatisfy(\.isASCIIDigitCharacter) { return true }
        }
        if key.hasPrefix("第") {
            let body = key.dropFirst()
            let digits = body.prefix(while: \.isASCIIDigitCharacter)
            let suffix = body.dropFirst(digits.count)
            if !digits.isEmpty, ["轨", "軌", "首", "曲"].contains(String(suffix)) { return true }
        }
        return false
    }

    // MARK: - Keys

    /// NFKC + 小写。数字要在这一步变成半角，音轨号才解析得出来。
    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// 只留字母、附加符号和数字。标点、空格、分隔符、被系统替换出来的 `_`
    /// 全都不参与比较。
    static func looseKey(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in normalized(value).unicodeScalars where isKeyScalar(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static let maximumTitleLength = 120

    private static let placeholderTitleWords: [String] = [
        "track", "audiotrack", "pista", "piste", "parça", "rastrear", "titel", "ścieżka",
        "трек", "المسار", "ट्रैक", "แทร็ก", "トラック", "曲目", "音轨", "音軌", "트랙",
    ].map(looseKey)

    private static func titleOnlyKeys(for track: Track) -> Set<String> {
        guard let title = track.title, !isPlaceholderTitle(title) else { return [] }
        let titleKey = looseKey(title)
        var keys: Set<String> = [titleKey]
        if let performer = track.performer {
            let performerKey = looseKey(performer)
            if !performerKey.isEmpty {
                keys.insert(performerKey + titleKey)
                keys.insert(titleKey + performerKey)
            }
        }
        return keys
    }

    /// 开头 1–3 位音轨号（允许补零）之后的部分。四位以上的数字是年份之类，
    /// 不算音轨号。
    private static func leadingNumber(in normalizedBase: String) -> (Int, Substring)? {
        let trimmed = normalizedBase.drop(while: { $0.isWhitespace })
        let digits = trimmed.prefix(while: \.isASCIIDigitCharacter)
        guard (1...3).contains(digits.count),
              let number = Int(digits), number > 0 else { return nil }
        return (number, trimmed.dropFirst(digits.count))
    }

    /// 音轨号后面是 `标题`、`艺人 - 标题` 或 `标题 - 艺人`。
    private static func remainderMatches(_ remainder: Substring, track: Track) -> Bool {
        let key = looseKey(String(remainder))
        guard !key.isEmpty, let title = track.title else { return false }
        let titleKey = looseKey(title)
        guard !titleKey.isEmpty else { return false }
        if key == titleKey { return true }
        guard let performer = track.performer else { return false }
        let performerKey = looseKey(performer)
        guard !performerKey.isEmpty else { return false }
        return key == performerKey + titleKey || key == titleKey + performerKey
    }

    /// 去掉前缀后剩下的部分；前缀后面紧跟字母时不算（`Albums` 不是
    /// `Album` 加东西）。
    private static func remainder(of normalizedBase: String, afterPrefix prefix: String) -> Substring? {
        guard !prefix.isEmpty, normalizedBase.hasPrefix(prefix) else { return nil }
        let rest = normalizedBase.dropFirst(prefix.count)
        guard let first = rest.first, !first.isLetter else { return nil }
        return rest.drop(while: { !$0.isLetter && !$0.isNumber })
    }

    /// `1`、`01`、`001` 都是第 1 轨；超过三位不认。
    private static func trackNumber(fromDigits digits: Substring) -> Int? {
        guard (1...3).contains(digits.count),
              digits.allSatisfy(\.isASCIIDigitCharacter),
              let number = Int(digits), number > 0 else { return nil }
        return number
    }

    /// 语言后缀的先后次序，用的是同名字幕那一档同样的偏好排序。
    private static func languageTagRanks(
        in names: [String],
        preferredLanguages: [String]
    ) -> [String: Int] {
        var remaining: [String] = []
        var seen: Set<String> = []
        for name in names {
            guard let tag = LyricsSidecarSelectionPolicy
                .languageTaggedComponents(ofSidecarNamed: name)?.tag,
                seen.insert(tag).inserted else { continue }
            remaining.append(tag)
        }
        var ranks: [String: Int] = [:]
        var rank = 0
        while !remaining.isEmpty {
            let best = LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
                tags: remaining,
                preferredLanguages: preferredLanguages
            ) ?? 0
            ranks[remaining.remove(at: best)] = rank
            rank += 1
        }
        return ranks
    }

    private static func isMediaExtension(_ fileExtension: String) -> Bool {
        PrimuseConstants.supportedAudioExtensions.contains(fileExtension)
            || PrimuseConstants.supportedStreamDescriptorExtensions.contains(fileExtension)
            || PrimuseConstants.supportedMusicVideoExtensions.contains(fileExtension)
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }

    private static func sanitizedFileNameComponent(_ value: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var result = ""
        for character in value {
            if forbidden.contains(character)
                || character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                result.append("_")
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool {
        guard let ascii = asciiValue else { return false }
        return (48...57).contains(ascii)
    }
}
