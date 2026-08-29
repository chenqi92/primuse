import Foundation

/// 结构化歌词编辑器的一行。跟 `LyricLine` 的区别在于 `timestamp` 是可选的 ──
/// 编辑器需要表达"这句还没打轴"的中间状态,而 `LyricLine` 的 timestamp 永远
/// 有值(纯文本行用 0 + isSynchronized=false 表示)。
public struct EditableLyricLine: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// nil 表示未打轴。
    public var timestamp: TimeInterval?
    public var text: String
    /// 字级数据。改动 `text` 后必须清掉,否则音节和文本对不上。
    public var syllables: [LyricSyllable]?

    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval? = nil,
        text: String,
        syllables: [LyricSyllable]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.syllables = syllables
    }

    public var isStamped: Bool { timestamp != nil }
    public var isWordLevel: Bool { syllables?.isEmpty == false }

    /// 该行占据的最早时间点。字级行的首个音节理论上不会早于行头,但坏数据
    /// 可能违反,整体偏移的下限计算必须把它算进去。
    var earliestTime: TimeInterval? {
        guard let timestamp else { return nil }
        guard let firstSyllableStart = syllables?.map(\.start).min() else { return timestamp }
        return min(timestamp, firstSyllableStart)
    }

    /// 改文本 ── 字级数据作废,降级成行级。
    mutating func replaceText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        syllables = nil
    }
}

/// 可编辑歌词文档。承载结构化编辑器的全部状态变换 ── 打轴、整体偏移、
/// 增删排序 ── 并能和 LRC/ELRC 文本双向往返。
///
/// 编辑器 UI 只做绑定,所有语义都在这里,这样能脱离 SwiftUI 单测。
/// 保存链路仍然以序列化后的文本为真相(`LyricsContentParser.validateEditableText`
/// 负责校验和写回),所以这里的 `serialized()` 必须输出那套解析器认得的格式。
public struct LyricsEditorDocument: Hashable, Sendable {
    /// 前导文档元数据(`[ti:]` / `[ar:]` / `[by:]` 等),原样保留。
    public var metadataLines: [String]
    public var lines: [EditableLyricLine]

    public init(metadataLines: [String] = [], lines: [EditableLyricLine] = []) {
        self.metadataLines = metadataLines
        self.lines = lines
    }

    // MARK: - Parsing

    nonisolated(unsafe) private static let metadataPattern = /^\[[A-Za-z][A-Za-z0-9_-]*:.*\]\s*$/
    nonisolated(unsafe) private static let timedHeadPattern = /\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
    nonisolated(unsafe) private static let relativeHeadPattern = /^\[(\d+),(\d+)\]/

    /// 逐行解析。不能直接用 `LyricsContentParser.parse` ── 那个解析器会丢掉
    /// 没有时间戳的行(混合文档里正是"待打轴"的那些行),而编辑器必须留住它们。
    public init(parsing text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var metadata: [String] = []
        var parsed: [EditableLyricLine] = []
        var isLeadingRegion = true

        for raw in normalized.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if isLeadingRegion, raw.firstMatch(of: Self.metadataPattern) != nil {
                metadata.append(trimmed)
                continue
            }
            if trimmed.isEmpty { continue }
            isLeadingRegion = false

            // 交给既有解析器认时间戳和音节,保证和播放侧对同一份文本的理解一致。
            let hasTimeMarker = raw.firstMatch(of: Self.timedHeadPattern) != nil
                || raw.firstMatch(of: Self.relativeHeadPattern) != nil
            guard hasTimeMarker else {
                parsed.append(EditableLyricLine(timestamp: nil, text: trimmed))
                continue
            }

            let decoded = LyricsContentParser.parse(raw)
            guard !decoded.isEmpty else {
                // 时间戳写坏了(比如 `[00:6O.10]`)。保留原文让用户能看到并修,
                // 丢掉反而让人以为歌词被吃了。
                parsed.append(EditableLyricLine(timestamp: nil, text: trimmed))
                continue
            }
            // 一行挂多个时间戳(`[00:12.30][01:40.10]副歌`)展开成多行,
            // 跟播放侧的解析结果保持一致。
            for line in decoded {
                parsed.append(
                    EditableLyricLine(
                        timestamp: line.timestamp,
                        text: line.text,
                        syllables: line.syllables
                    )
                )
            }
        }

        self.metadataLines = metadata
        self.lines = parsed
    }

    // MARK: - Serialization

    /// 回写成 LRC/ELRC 文本。已打轴行输出 `[mm:ss.SSS]`,未打轴行原样输出,
    /// 混合文档因此仍是 `validateEditableText` 能接受的输入。
    public func serialized() -> String {
        let body = lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard let timestamp = line.timestamp else {
                return text.isEmpty ? nil : text
            }

            let head = "[\(Self.formatTimestamp(timestamp))]"
            guard let syllables = line.syllables, !syllables.isEmpty else {
                return text.isEmpty ? nil : head + text
            }

            var wordBody = syllables
                .map { "<\(Self.formatTimestamp($0.start))>\($0.text)" }
                .joined()
            if let last = syllables.last, last.end > last.start {
                wordBody += "<\(Self.formatTimestamp(last.end))>"
            }
            return head + wordBody
        }

        return (metadataLines + body).joined(separator: "\n")
    }

    static func formatTimestamp(_ time: TimeInterval) -> String {
        let milliseconds = max(0, (time * 1_000).rounded()).finiteInt()
        return String(
            format: "%02d:%02d.%03d",
            milliseconds / 60_000,
            (milliseconds % 60_000) / 1_000,
            milliseconds % 1_000
        )
    }

    // MARK: - 整体偏移

    /// 允许的负向偏移幅度(正数)。再往前推就会把最早那句挤到 0 之前。
    public var maximumBackwardShift: TimeInterval {
        lines.compactMap(\.earliestTime).min() ?? 0
    }

    /// 整体平移所有已打轴的行。**按整份文档统一 clamp**,不是逐行 clamp ──
    /// 逐行会让靠前的几句先塌到 0 并挤成一堆,行间相对关系被永久破坏且不可逆。
    /// 统一 clamp 则最多把最早那句顶到 0,全文相对间距保持不变。
    ///
    /// 返回实际生效的偏移量,UI 拿它显示"已到头"。
    @discardableResult
    public mutating func shift(by delta: TimeInterval) -> TimeInterval {
        let effective = clampedShift(delta)
        guard effective != 0 else { return 0 }

        for index in lines.indices {
            guard let timestamp = lines[index].timestamp else { continue }
            lines[index].timestamp = max(0, timestamp + effective)
            guard let syllables = lines[index].syllables else { continue }
            // 音节必须跟着行头一起动,否则字级歌词偏移后逐字高亮会和整行脱节。
            lines[index].syllables = syllables.map {
                LyricSyllable(
                    text: $0.text,
                    start: max(0, $0.start + effective),
                    end: max(0, $0.end + effective),
                    endTiming: $0.endTiming
                )
            }
        }
        return effective
    }

    /// 不可变版本,给"调整中实时预览"用 ── UI 保留一份基线文档,每次滑动都从
    /// 基线重算,这样反复来回拖不会因为 clamp 而丢失原始时间。
    public func shifted(by delta: TimeInterval) -> LyricsEditorDocument {
        var copy = self
        copy.shift(by: delta)
        return copy
    }

    private func clampedShift(_ delta: TimeInterval) -> TimeInterval {
        guard delta.isFinite else { return 0 }
        guard delta < 0 else { return delta }
        return max(delta, -maximumBackwardShift)
    }

    // MARK: - 打轴

    /// 把某行的时间戳设成 `time`。字级音节整体平移相同距离,保留行内的逐字节奏。
    public mutating func stamp(at index: Int, time: TimeInterval) {
        guard lines.indices.contains(index), time.isFinite else { return }
        let target = max(0, time)

        if let previous = lines[index].timestamp, let syllables = lines[index].syllables {
            let delta = target - previous
            lines[index].syllables = syllables.map {
                LyricSyllable(
                    text: $0.text,
                    start: max(0, $0.start + delta),
                    end: max(0, $0.end + delta),
                    endTiming: $0.endTiming
                )
            }
        } else if lines[index].syllables != nil {
            // 之前没打轴却带着音节,说明数据本就不自洽,直接降级成行级。
            lines[index].syllables = nil
        }

        lines[index].timestamp = target
    }

    /// 重新给某个音节打点。被选音节以及它后面的音节整体平移相同距离，既允许
    /// 用户顺着播放重新逐字打轴，也保留尚未重打部分原有的字间节奏。
    ///
    /// 返回实际生效的时间；坏下标或非有限时间返回 nil。
    @discardableResult
    public mutating func stampSyllable(
        at lineIndex: Int,
        syllableIndex: Int,
        time: TimeInterval
    ) -> TimeInterval? {
        guard lines.indices.contains(lineIndex),
              time.isFinite,
              var syllables = lines[lineIndex].syllables,
              syllables.indices.contains(syllableIndex) else { return nil }

        let lowerBound = syllableIndex > 0 ? syllables[syllableIndex - 1].start : 0
        let target = max(lowerBound, time)
        let delta = target - syllables[syllableIndex].start

        if delta != 0 {
            for index in syllableIndex..<syllables.count {
                syllables[index].start = max(target, syllables[index].start + delta)
                syllables[index].end = max(syllables[index].start, syllables[index].end + delta)
            }
        }

        if syllableIndex > 0 {
            syllables[syllableIndex - 1].end = target
        } else {
            lines[lineIndex].timestamp = target
        }
        lines[lineIndex].syllables = syllables
        return target
    }

    /// 只移动某个音节的起点，也就是它和前一音节之间的边界。微调会被相邻
    /// 音节夹住，避免保存出倒序的 ELRC 时间戳。
    @discardableResult
    public mutating func nudgeSyllable(
        at lineIndex: Int,
        syllableIndex: Int,
        by delta: TimeInterval
    ) -> TimeInterval? {
        guard lines.indices.contains(lineIndex),
              delta.isFinite,
              var syllables = lines[lineIndex].syllables,
              syllables.indices.contains(syllableIndex) else { return nil }

        let current = syllables[syllableIndex].start
        let lowerBound = syllableIndex > 0 ? syllables[syllableIndex - 1].start : 0
        let upperBound = syllableIndex + 1 < syllables.count
            ? syllables[syllableIndex + 1].start
            : .greatestFiniteMagnitude
        let target = min(max(current + delta, lowerBound), upperBound)

        syllables[syllableIndex].start = target
        if syllableIndex > 0 {
            syllables[syllableIndex - 1].end = target
        } else {
            lines[lineIndex].timestamp = target
        }
        if syllableIndex == syllables.indices.last,
           syllables[syllableIndex].end <= target {
            syllables[syllableIndex].end = target + 0.4
        }
        lines[lineIndex].syllables = syllables
        return target
    }

    /// 撤销某行的打轴。
    public mutating func clearStamp(at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].timestamp = nil
        lines[index].syllables = nil
    }

    /// 时间戳是否单调递增。打轴过程中不自动排序 ── 行在用户指下跳走比乱序更难受 ──
    /// 所以用这个给出提示,由用户决定要不要排。
    public var isMonotonic: Bool {
        var previous: TimeInterval = -.greatestFiniteMagnitude
        for line in lines {
            guard let timestamp = line.timestamp else { continue }
            if timestamp < previous { return false }
            previous = timestamp
        }
        return true
    }

    /// 按时间戳排序。未打轴的行留在原来的相对位置 ── 它们没有时间可比,
    /// 冒然挪到末尾会打乱用户正在逐句推进的打轴顺序。
    public mutating func sortByTimestamp() {
        let stamped = lines.enumerated().filter { $0.element.isStamped }
        let sortedTimestamps = stamped
            .map(\.element)
            .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }

        for (slot, original) in zip(stamped.map(\.offset), sortedTimestamps) {
            lines[slot] = original
        }
    }

    /// 为打轴完成后的保存准备一份可提交文档。
    ///
    /// 标题、歌手和制作信息不会进入打轴游标，但刮削得到的 LRC 往往仍给这些行
    /// 带了时间戳。用户重新给所有唱词打轴后，这些被跳过的旧时间戳可能夹在新
    /// 时间轴之间，导致整篇校验报“时间顺序错误”，即使所有真正的歌词行都已按
    /// 顺序完成。只有在歌词行本身全部有时间且顺序正确、乱序明确来自被跳过行时，
    /// 才把已打轴行按时间排序；用户自己打乱的歌词仍交给编辑器提示，不悄悄修正。
    public func preparedForTimingCommit(eligibleIndices: [Int]) -> LyricsEditorDocument {
        guard !isMonotonic else { return self }

        let eligible = Array(Set(eligibleIndices.filter(lines.indices.contains))).sorted()
        guard !eligible.isEmpty,
              eligible.allSatisfy({ lines[$0].timestamp != nil }),
              Self.timestampsAreMonotonic(eligible.compactMap { lines[$0].timestamp }) else {
            return self
        }

        let eligibleSet = Set(eligible)
        guard lines.indices.contains(where: {
            !eligibleSet.contains($0) && lines[$0].timestamp != nil
        }) else {
            return self
        }

        var prepared = self
        prepared.sortByTimestamp()
        return prepared
    }

    private static func timestampsAreMonotonic(_ timestamps: [TimeInterval]) -> Bool {
        zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 <= $1 }
    }

    // MARK: - 增删改

    public mutating func updateText(_ text: String, at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].replaceText(text)
    }

    /// 在 `index` 位置插入空行,返回新行的 id 好让 UI 立刻聚焦它。
    @discardableResult
    public mutating func insertLine(at index: Int, text: String = "") -> UUID {
        let line = EditableLyricLine(timestamp: nil, text: text)
        lines.insert(line, at: min(max(0, index), lines.count))
        return line.id
    }

    /// 倒序删除,否则删掉前面的元素会让后面的下标失效。
    /// (`remove(atOffsets:)` 是 SwiftUI 的扩展,纯逻辑模块里拿不到。)
    public mutating func removeLines(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where lines.indices.contains(index) {
            lines.remove(at: index)
        }
    }

    /// 语义和 SwiftUI 的 `move(fromOffsets:toOffset:)` 对齐:`destination` 用
    /// **移除之前**的下标表达,所以插入点要扣掉排在它前面的待移动项数量。
    public mutating func moveLines(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().filter { lines.indices.contains($0) }.map { lines[$0] }
        guard !moving.isEmpty else { return }

        let removedBefore = source.filter { $0 < destination }.count
        removeLines(at: source)
        let insertionPoint = min(max(0, destination - removedBefore), lines.count)
        lines.insert(contentsOf: moving, at: insertionPoint)
    }

    // MARK: - 统计

    public var stampedCount: Int { lines.lazy.filter(\.isStamped).count }
    public var unstampedCount: Int { lines.count - stampedCount }
    public var hasWordLevelLines: Bool { lines.contains(where: \.isWordLevel) }

    /// 忽略编辑会话临时 UUID，只比较最终会写回的歌词内容。
    public func hasSameContent(as other: LyricsEditorDocument) -> Bool {
        serialized() == other.serialized()
    }

    /// 没有语义改动时返回用户原始文本，避免仅打开编辑器就把 `.xx` 时间戳
    /// 规范化成 `.xxx`；真正改过时才输出编辑文档的标准序列化结果。
    public func committedText(
        preserving originalText: String,
        comparedTo originalDocument: LyricsEditorDocument
    ) -> String {
        hasSameContent(as: originalDocument) ? originalText : serialized()
    }

    /// 播放到 `time` 时应当高亮的行下标。只看已打轴的行。
    ///
    /// 编辑器允许用户暂时保留乱序时间戳，因此不能遇到一个未来时间就提前结束；
    /// 应从整份文档里找“不晚于播放位置、且时间最靠后”的那一行。
    public func activeLineIndex(at time: TimeInterval) -> Int? {
        var result: (index: Int, timestamp: TimeInterval)?
        for (index, line) in lines.enumerated() {
            guard let timestamp = line.timestamp else { continue }
            guard timestamp <= time else { continue }
            if let current = result, current.timestamp > timestamp { continue }
            result = (index, timestamp)
        }
        return result?.index
    }

    /// 打轴模式下"下一句该打"的行下标 ── 第一个还没打轴的行。
    public var nextUnstampedIndex: Int? {
        lines.firstIndex(where: { !$0.isStamped })
    }
}
