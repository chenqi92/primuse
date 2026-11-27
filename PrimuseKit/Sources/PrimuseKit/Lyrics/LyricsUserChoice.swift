import Foundation

/// 用户对一首歌歌词的明确决定，随本机歌词缓存一起存，重启后还在。
///
/// - 保存了一份歌词：记下那份的内容指纹。缓存还是这一份时，读标签、按设置重挑内嵌原文、核对歌词文件、
///   后台补全、自动在线取词这些自动路径都不能把它换掉。缓存被用户别的动作换成了别的，这条就不再算数。
/// - 清空了歌词：之后自动路径一律不能把歌词填回来，各处都显示没有歌词，直到用户对这首歌做了明确的动作。
/// - 隐藏的版本：文件里删不掉、用户选了在 Primuse 里隐藏的那几份，自动路径不再把它们写回缓存或列出来。
public struct LyricsUserChoice: Codable, Equatable, Sendable {
    /// 用户保存的那一份（缓存读出来的样子）。
    public var savedFingerprint: String?
    /// 保存时写进源（歌词文件、服务器、音频文件）的那份，按读源时的样子算的指纹。
    public var savedSourceFingerprint: String?
    /// 保存之前缓存里的那份。源里读回来的还是它，说明源还没跟上，不能拿它换掉刚保存的。
    public var previousFingerprint: String?
    public var isCleared: Bool
    public var hiddenFingerprints: [String]
    public var updatedAt: Date

    public init(
        savedFingerprint: String? = nil,
        savedSourceFingerprint: String? = nil,
        previousFingerprint: String? = nil,
        isCleared: Bool = false,
        hiddenFingerprints: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.savedFingerprint = savedFingerprint
        self.savedSourceFingerprint = savedSourceFingerprint
        self.previousFingerprint = previousFingerprint
        self.isCleared = isCleared
        self.hiddenFingerprints = hiddenFingerprints
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case savedFingerprint, savedSourceFingerprint, previousFingerprint, isCleared, hiddenFingerprints, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        savedFingerprint = try container.decodeIfPresent(String.self, forKey: .savedFingerprint)
        savedSourceFingerprint = try container.decodeIfPresent(String.self, forKey: .savedSourceFingerprint)
        previousFingerprint = try container.decodeIfPresent(String.self, forKey: .previousFingerprint)
        isCleared = try container.decodeIfPresent(Bool.self, forKey: .isCleared) ?? false
        hiddenFingerprints = try container.decodeIfPresent([String].self, forKey: .hiddenFingerprints) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// 什么都没记：不必存这个文件。
    public var isEmpty: Bool {
        savedFingerprint == nil && !isCleared && hiddenFingerprints.isEmpty
    }
}

/// 写进新的一份时，缓存里原来那份在来源候选里怎么记。
public enum LyricsPreviousVersionHandling: Sendable, Equatable {
    /// 记成候选（自动路径一直以来的做法）。
    case remember
    /// 用户「保存」（替换当前版本）：被换掉的那份从候选里去掉，不再作为多出来的一份留着。
    case forget
    /// 用户「另存为新版本」：旧的留在候选里，来源页照样列出来。
    case keep
}

extension LyricsSourceCollection {
    /// 缓存从 `previous` 换成 `incoming` 之后的候选列表。新的那份成为正在用的，选定清掉。
    public mutating func record(
        _ incoming: [LyricLine],
        replacing previous: [LyricLine]?,
        handling: LyricsPreviousVersionHandling,
        normalize: ([LyricLine]) -> [LyricLine] = { $0 }
    ) {
        if let previous, !previous.isEmpty {
            let changed = LyricsDocumentFingerprint(lines: normalize(previous))
                != LyricsDocumentFingerprint(lines: normalize(incoming))
            switch handling {
            case .remember:
                remember(previous)
            case .forget:
                if changed { forget(previous, normalize: normalize) }
            case .keep:
                if changed, let kept = remember(previous) { keep(id: kept.id) }
            }
        }
        remember(incoming)
        selectedID = nil
    }
}

/// 写歌词缓存的是谁。
public enum LyricsCacheWriteOrigin: String, Sendable, Equatable {
    /// 不读源的自动路径：按设置重挑内嵌原文、备用内嵌歌词、自动在线兜底、后台补全、整库补全缺失……
    case automatic
    /// 从这首歌自己的歌词源读到的：歌旁边的歌词文件、音乐服务器、音频文件里的标签。
    /// 和用户保存时写进源的不一样、也不是保存之前那份时，说明别处更新过，可以换掉用户保存的那份。
    case sourceDocument
    /// 用户对这首歌的明确动作：编辑器保存、刮削结果页挑的歌词、播放页「刮削数据」「获取歌词」、
    /// 来源页选用一份、导入歌词文件、明确选了重新刮削覆盖。
    case user
}

/// 写缓存之前问一句：用户对这首歌的决定允不允许这次写入。
public enum LyricsUserChoicePolicy {
    /// - Parameters:
    ///   - force: 调用方要求覆盖（刮削、用户点了从源重新读取）。
    ///   - preservingSelection: 不读源的自动覆盖写入（按设置重挑内嵌、文件被删后换回内嵌）。
    ///     这类写入哪怕带着 `force` 也不能动用户保存的那份。
    ///   - currentFingerprint: 缓存里现在那份的指纹，没有缓存为 nil。
    ///   - incomingFingerprint: 要写进去的那份的指纹。
    public static func admitsWrite(
        origin: LyricsCacheWriteOrigin,
        force: Bool,
        preservingSelection: Bool,
        choice: LyricsUserChoice?,
        currentFingerprint: String?,
        incomingFingerprint: String?
    ) -> Bool {
        guard origin != .user, let choice else { return true }
        if choice.isCleared { return false }
        if let incomingFingerprint, choice.hiddenFingerprints.contains(incomingFingerprint) {
            return false
        }
        guard pins(choice, currentFingerprint: currentFingerprint) else { return true }
        switch origin {
        case .sourceDocument:
            guard let incomingFingerprint else { return false }
            let known = [choice.savedFingerprint, choice.savedSourceFingerprint, choice.previousFingerprint]
            return !known.contains(incomingFingerprint)
        case .automatic:
            return force && !preservingSelection
        case .user:
            return true
        }
    }

    /// 缓存里还是用户保存的那一份。
    public static func pins(_ choice: LyricsUserChoice?, currentFingerprint: String?) -> Bool {
        guard let saved = choice?.savedFingerprint, let currentFingerprint else { return false }
        return saved == currentFingerprint
    }

    /// 用户写进了一份歌词：记下它，解除清空。隐藏的版本照旧隐藏，除非用户选用的正是其中一份。
    public static func choice(
        afterUserWriteOf fingerprint: String,
        sourceFingerprint: String? = nil,
        replacing previousFingerprint: String? = nil,
        previous: LyricsUserChoice?,
        now: Date = Date()
    ) -> LyricsUserChoice {
        LyricsUserChoice(
            savedFingerprint: fingerprint,
            savedSourceFingerprint: sourceFingerprint,
            previousFingerprint: previousFingerprint,
            isCleared: false,
            hiddenFingerprints: (previous?.hiddenFingerprints ?? []).filter { $0 != fingerprint },
            updatedAt: now
        )
    }

    /// 用户清空了歌词（或者把版本删到一份不剩）。
    public static func choice(
        afterUserClear previous: LyricsUserChoice?,
        now: Date = Date()
    ) -> LyricsUserChoice {
        LyricsUserChoice(
            savedFingerprint: nil,
            isCleared: true,
            hiddenFingerprints: previous?.hiddenFingerprints ?? [],
            updatedAt: now
        )
    }

    /// 用户在 Primuse 里隐藏了一份删不掉的版本。最多记 32 份，先记的先忘。
    public static func choice(
        hiding fingerprint: String,
        previous: LyricsUserChoice?,
        now: Date = Date()
    ) -> LyricsUserChoice {
        var hidden = (previous?.hiddenFingerprints ?? []).filter { $0 != fingerprint }
        hidden.append(fingerprint)
        if hidden.count > 32 { hidden.removeFirst(hidden.count - 32) }
        var savedFingerprint = previous?.savedFingerprint
        if savedFingerprint == fingerprint { savedFingerprint = nil }
        return LyricsUserChoice(
            savedFingerprint: savedFingerprint,
            savedSourceFingerprint: savedFingerprint == nil ? nil : previous?.savedSourceFingerprint,
            previousFingerprint: savedFingerprint == nil ? nil : previous?.previousFingerprint,
            isCleared: previous?.isCleared ?? false,
            hiddenFingerprints: hidden,
            updatedAt: now
        )
    }
}
