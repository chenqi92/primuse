import Foundation

/// Which singer the user takes in karaoke mode.
public enum KaraokePart: String, Codable, CaseIterable, Sendable {
    /// Every line; the whole lead vocal is reduced.
    case all
    /// The main voice; the duet partner keeps the original vocal.
    case primary
    /// The duet partner; the main voice keeps the original vocal.
    case secondary

    func includes(_ voice: LyricVoice) -> Bool {
        switch self {
        case .all: true
        case .primary: voice == .primary
        case .secondary: voice == .secondary
        }
    }
}

/// The time span in which one synchronized lyric line is sung.
public struct KaraokeLineWindow: Equatable, Sendable {
    public var lineIndex: Int
    public var lineID: String
    public var voice: LyricVoice
    public var start: TimeInterval
    public var end: TimeInterval

    public init(lineIndex: Int, lineID: String, voice: LyricVoice, start: TimeInterval, end: TimeInterval) {
        self.lineIndex = lineIndex
        self.lineID = lineID
        self.voice = voice
        self.start = start
        self.end = end
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// A value snapshot keeps deferred lyric layouts on the same set of rows and
/// windows when the live session clears or replaces a song's lyrics.
public struct KaraokeLyricsSnapshot: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let window: KaraokeLineWindow
        public let line: LyricLine
    }

    public let lines: [LyricLine]
    public let windows: [KaraokeLineWindow]
    public let hasDuetParts: Bool
    public let usesInferredWordTiming: Bool

    public init(lines: [LyricLine] = [], onsets: [KaraokeOnset]? = nil) {
        let windows = KaraokeLineWindowPolicy.windows(in: lines)
        let byIndex = Dictionary(uniqueKeysWithValues: windows.map { ($0.lineIndex, $0) })
        var inferred = false
        self.lines = lines.enumerated().map { index, line in
            guard let window = byIndex[index] else { return line }
            if let onsets, let timed = KaraokeWordTimingPolicy.timedLine(line, window: window, onsets: onsets) {
                inferred = true
                return timed
            }
            return KaraokeSweepPolicy.sweepLine(line, window: window)
        }
        self.windows = windows
        hasDuetParts = KaraokeDuetGatePolicy.hasDuetParts(lines)
        usesInferredWordTiming = inferred
    }

    public func row(at windowIndex: Int) -> Row? {
        guard windows.indices.contains(windowIndex) else { return nil }
        let window = windows[windowIndex]
        return Row(window: window, line: lines[window.lineIndex])
    }

    /// Between sung rows the upcoming row takes focus; after the final row it
    /// stays on stage. An empty snapshot has no focused row.
    public func focusedWindowIndex(at time: TimeInterval) -> Int? {
        guard !windows.isEmpty else { return nil }
        return KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time)
            ?? windows.firstIndex(where: { $0.start > time })
            ?? (windows.count - 1)
    }
}

public enum KaraokeLineWindowPolicy {
    /// A line-level row with no explicit end is never assumed to last longer
    /// than this; a long instrumental gap before the next line is not singing.
    public static let maximumInferredLineDuration: TimeInterval = 8
    /// Shortest window a row keeps even when the next row starts at once.
    public static let minimumLineDuration: TimeInterval = 0.3

    /// Windows for every synchronized, non-empty row, in lyric order.
    public static func windows(in lines: [LyricLine]) -> [KaraokeLineWindow] {
        var result: [KaraokeLineWindow] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            guard line.isSynchronized,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = line.timestamp
            let nextStart = lines[(index + 1)...].first(where: {
                $0.isSynchronized && $0.timestamp > start + 0.002
            })?.timestamp
            let end = resolvedEnd(of: line, nextStart: nextStart)
            result.append(KaraokeLineWindow(
                lineIndex: index,
                lineID: line.id,
                voice: line.voice,
                start: start,
                end: max(start + minimumLineDuration, end)
            ))
        }
        return result
    }

    static func resolvedEnd(of line: LyricLine, nextStart: TimeInterval?) -> TimeInterval {
        if let end = line.endTime, end > line.timestamp {
            return end
        }
        let cap = line.timestamp + maximumInferredLineDuration
        guard let nextStart else { return cap }
        return min(nextStart, cap)
    }

    /// Index into `windows` of the row being sung at `time`, if any.
    public static func activeWindowIndex(
        in windows: [KaraokeLineWindow],
        at time: TimeInterval
    ) -> Int? {
        var lower = 0
        var upper = windows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if windows[middle].start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var index = lower - 1
        // Overlapping duet rows: prefer the latest-starting row that still
        // covers `time`.
        while index >= 0 {
            if windows[index].contains(time) { return index }
            if time - windows[index].start > maximumInferredLineDuration * 2 { break }
            index -= 1
        }
        return nil
    }
}

/// Countdown dots shown before the singer's next entry.
public struct KaraokeLeadIn: Equatable, Sendable {
    /// 3, 2 or 1 dots still lit.
    public var remainingBeats: Int
    /// When the next row begins.
    public var entryTime: TimeInterval
    public var nextLineIndex: Int
}

public enum KaraokeLeadInPolicy {
    /// Only gaps at least this long (intro, interlude) get a countdown.
    public static let minimumGap: TimeInterval = 4.5
    public static let countdownDuration: TimeInterval = 3

    public static func leadIn(
        windows: [KaraokeLineWindow],
        at time: TimeInterval
    ) -> KaraokeLeadIn? {
        guard let nextIndex = windows.firstIndex(where: { $0.start > time }) else { return nil }
        let next = windows[nextIndex]
        let remaining = next.start - time
        guard remaining <= countdownDuration else { return nil }
        let previousEnd = windows[..<nextIndex].map(\.end).max() ?? 0
        guard previousEnd <= time, next.start - previousEnd >= minimumGap else { return nil }
        let beats = max(1, min(3, Int(remaining.rounded(.up))))
        return KaraokeLeadIn(remainingBeats: beats, entryTime: next.start, nextLineIndex: next.lineIndex)
    }
}

public enum KaraokeSweepPolicy {
    /// Gives a line-level row evenly spread word timing across its window so
    /// the stage can sweep it like a word-timed row. Word-timed rows are
    /// returned unchanged.
    public static func sweepLine(_ line: LyricLine, window: KaraokeLineWindow) -> LyricLine {
        if let syllables = line.syllables, !syllables.isEmpty { return line }
        let units = sweepUnits(of: line.text)
        guard !units.isEmpty else { return line }

        // Leave a short tail so the last word lands before the row ends.
        let duration = max(0.2, (window.end - window.start) * 0.92)
        let weights = units.map { unit in
            Double(max(1, unit.filter { !$0.isWhitespace }.count))
        }
        let totalWeight = weights.reduce(0, +)
        var cursor = window.start
        var syllables: [LyricSyllable] = []
        syllables.reserveCapacity(units.count)
        for (unit, weight) in zip(units, weights) {
            let length = duration * weight / totalWeight
            syllables.append(LyricSyllable(
                text: unit,
                start: cursor,
                end: cursor + length,
                endTiming: .inferred
            ))
            cursor += length
        }
        var result = line
        result.syllables = syllables
        return result
    }

    /// Splits text into sweep units: one per CJK/kana/hangul character, one
    /// per space-separated word elsewhere. Trailing spaces stay attached so
    /// joining the units restores the original text.
    static func sweepUnits(of text: String) -> [String] {
        var units: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                // Spaces trail whatever came before them.
                if current.isEmpty, !units.isEmpty {
                    units[units.count - 1].append(character)
                } else {
                    current.append(character)
                }
                continue
            }
            if isIdeographicUnit(character) {
                if !current.isEmpty { units.append(current); current = "" }
                units.append(String(character))
                continue
            }
            if let last = current.last, last.isWhitespace {
                units.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty {
            if current.allSatisfy(\.isWhitespace), !units.isEmpty {
                units[units.count - 1] += current
            } else {
                units.append(current)
            }
        }
        return units
    }

    static func isIdeographicUnit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

public enum KaraokeDuetGatePolicy {
    /// The partner's vocal opens slightly before their row so the first
    /// consonant is not clipped, and closes slightly after it.
    public static let partnerPreRoll: TimeInterval = 0.15
    public static let partnerPostRoll: TimeInterval = 0.3

    /// Whether the lyrics mark two alternating singers.
    public static func hasDuetParts(_ lines: [LyricLine]) -> Bool {
        var sawPrimary = false
        var sawSecondary = false
        for line in lines where line.isSynchronized {
            switch line.voice {
            case .primary: sawPrimary = true
            case .secondary: sawSecondary = true
            }
            if sawPrimary && sawSecondary { return true }
        }
        return false
    }

    /// How much of the vocal to remove at `time` for the chosen part, as a
    /// fraction of the user's vocal-removal setting: 1 while the user's part
    /// (or nobody) sings, 0 while only the partner sings.
    public static func reductionFactor(
        windows: [KaraokeLineWindow],
        part: KaraokePart,
        at time: TimeInterval
    ) -> Float {
        guard part != .all else { return 1 }
        var partnerSings = false
        for window in windows {
            if window.start - partnerPreRoll > time { break }
            guard time < window.end + partnerPostRoll else { continue }
            if part.includes(window.voice) {
                // The user's own row always wins, including overlaps.
                if window.contains(time) { return 1 }
            } else {
                partnerSings = true
            }
        }
        return partnerSings ? 0 : 1
    }
}

public enum KaraokeKeyShiftPolicy {
    public static let range: ClosedRange<Int> = -6...6

    public static func clamped(_ semitones: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, semitones))
    }

    /// `AVAudioUnitTimePitch.pitch` takes cents.
    public static func cents(forSemitones semitones: Int) -> Float {
        Float(clamped(semitones) * 100)
    }
}

/// Why karaoke processing cannot run on what is playing now.
public enum KaraokeAvailability: Equatable, Sendable {
    case available
    case noSong
    /// Apple Music plays through the system player, which exposes no audio.
    case appleMusic
    /// Audio leaves the device before any local processing.
    case casting
    /// The bit-perfect output graph contains no effect units.
    case highFidelityOutput

    public static func resolve(
        hasSong: Bool,
        isAppleMusic: Bool,
        isCasting: Bool,
        isHighFidelityOutput: Bool
    ) -> KaraokeAvailability {
        if !hasSong { return .noSong }
        if isAppleMusic { return .appleMusic }
        if isCasting { return .casting }
        if isHighFidelityOutput { return .highFidelityOutput }
        return .available
    }
}

/// Lines the two recorded streams up so the voice sits on the beat the
/// singer actually heard.
public enum KaraokeRecordingAlignment {
    /// Frames to drop from the start of the microphone file (negative: pad
    /// the microphone with silence instead).
    ///
    /// - Parameters:
    ///   - accompanimentFirstHostSeconds: host time of the first rendered
    ///     accompaniment frame.
    ///   - microphoneFirstHostSeconds: host time the first microphone frame
    ///     was delivered.
    ///   - outputLatency: render → speaker delay.
    ///   - inputLatency: microphone → delivery delay.
    public static func microphoneLeadFrames(
        accompanimentFirstHostSeconds: Double,
        microphoneFirstHostSeconds: Double,
        outputLatency: Double,
        inputLatency: Double,
        sampleRate: Double
    ) -> Int {
        // The first accompaniment frame is heard at accompaniment + output
        // latency; the microphone frame captured then is delivered
        // inputLatency later.
        let matchingMicrophoneHostSeconds = accompanimentFirstHostSeconds + outputLatency + inputLatency
        let lead = matchingMicrophoneHostSeconds - microphoneFirstHostSeconds
        return Int((lead * sampleRate).rounded())
    }
}

/// The stage gives the lyrics a fixed height, so a row that would wrap past
/// two lines is shrunk a step or two instead of being clipped (or, before
/// this, pushing the controls under it down and up again).
public enum KaraokeLineFitPolicy {
    /// Shrink steps, largest first. The smallest keeps the sung row at least
    /// as large as the full-size row after it.
    public static let scales: [Double] = [1, 0.88, 0.76, 0.66]

    /// Rows a line is allowed before it is shrunk.
    public static let maximumRows = 2

    /// The largest size at which `text` is expected to fit `maximumRows`
    /// rows of `availableWidth`, down to the smallest step. A line that only
    /// just spills onto a second row takes the first step down instead, so
    /// it does not end in a single orphaned character.
    public static func fontSize(for text: String, base: Double, availableWidth: Double) -> Double {
        guard base > 0, availableWidth > 0 else { return base }
        let units = widthUnits(of: text)
        let rows = scales.map { (units * base * $0 / availableWidth).rounded(.up) }
        if rows[0] > 1, rows[1] <= 1 { return base * scales[1] }
        for (index, count) in rows.enumerated() where count <= Double(maximumRows) {
            return base * scales[index]
        }
        return base * scales[scales.count - 1]
    }

    /// Rough advance of the text in multiples of the font size: an
    /// ideograph is about a full em, a Latin glyph a bit over half, a space
    /// less. Good enough to tell one, two and three rows apart.
    static func widthUnits(of text: String) -> Double {
        text.reduce(0) { total, character in
            if character.isWhitespace { return total + 0.3 }
            if KaraokeSweepPolicy.isIdeographicUnit(character) { return total + 1 }
            return total + 0.55
        }
    }
}

/// Display-only timing; the original document remains suitable for editing and export.
public enum SimulatedWordLyricsPolicy {
    public struct Presentation: Equatable, Sendable {
        public let lines: [LyricLine]
        public let isSimulated: Bool
    }

    public static func presentation(
        of lines: [LyricLine],
        enabled: Bool = false,
        isSpokenWord: Bool = false
    ) -> Presentation {
        var displayed = lines
        var isSimulated = false
        for window in windows(in: lines, enabled: enabled, isSpokenWord: isSpokenWord) {
            let line = lines[window.lineIndex]
            let timed = KaraokeSweepPolicy.sweepLine(line, window: window)
            displayed[window.lineIndex] = timed
            isSimulated = isSimulated || timed.isWordLevel
        }
        return Presentation(lines: displayed, isSimulated: isSimulated)
    }

    public static func windows(
        in lines: [LyricLine],
        enabled: Bool = false,
        isSpokenWord: Bool = false
    ) -> [KaraokeLineWindow] {
        guard enabled, !isSpokenWord,
              !lines.contains(where: \.containsWordLevelContent) else { return [] }
        return KaraokeLineWindowPolicy.windows(in: lines).filter {
            $0.start.isFinite && $0.end.isFinite
        }
    }
}

// MARK: - 伴唱(#377)

/// 伴唱时原唱留多少。rawValue 存进偏好,发布后不能改名。
public enum KaraokeSingAlongLevel: String, CaseIterable, Codable, Sendable {
    /// 只剩伴奏。
    case instrumental
    /// 隐约听得见原唱,跟丢了能找回旋律。
    case faint
    /// 原唱轻声带着唱。
    case soft

    public static let defaultValue: Self = .faint

    /// 存下的值;认不出的(以后的版本加的档)按默认。
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    /// 原唱留下的分贝数;nil 是全部去掉。按分贝分档:人耳听响度是对数的,
    /// 按线性分(0.1 / 0.3)的话「隐约」和「轻声」听着差不多。
    public var vocalDecibels: Double? {
        switch self {
        case .instrumental: nil
        case .faint: -20
        case .soft: -10
        }
    }

    /// 原唱留下的幅度,0...1。
    public var vocalGain: Double {
        vocalDecibels.map { pow(10, $0 / 20) } ?? 0
    }

    /// 人声消除单元的「减去多少」:1 全减,0 不减。
    public var reduction: Double { 1 - vocalGain }
}

/// 伴唱此刻能不能作用在正在放的东西上。用不了时照放原唱,并说明为什么。
public enum KaraokeSingAlongAvailability: Equatable, Sendable {
    case available
    /// 没在放,或放的是有声书、播客、电台、环境声:伴唱不管,也不提示。
    case notApplicable
    /// Apple Music 由系统播放器出声,拿不到声音。
    case appleMusic
    /// 声音在别的设备上出。
    case casting
    /// 高保真直通的图里没有效果单元;能一键切到音效输出。
    case highFidelityOutput
    /// 空间音频在消除单元之前把整首重新渲染成双耳声,分离出的人声轨对不上,减不干净。
    case spatialAudio
    /// 串烧、MV、系统多声道播放器这类不经过本机音效图的播放方式。
    case unsupportedPlayback
    /// 这台设备拿不到 AI 模型(系统版本不够,或开发构建下不了托管资源包)。
    case unsupportedSystem

    public static func resolve(
        hasSong: Bool,
        isSpokenWordOrRadio: Bool,
        isAppleMusic: Bool,
        isCasting: Bool,
        isHighFidelityOutput: Bool,
        isSpatialAudio: Bool,
        isSystemPlayback: Bool,
        isMedley: Bool
    ) -> Self {
        guard hasSong, !isSpokenWordOrRadio else { return .notApplicable }
        if isAppleMusic { return .appleMusic }
        if isCasting { return .casting }
        if isHighFidelityOutput { return .highFidelityOutput }
        if isSystemPlayback || isMedley { return .unsupportedPlayback }
        if isSpatialAudio { return .spatialAudio }
        return .available
    }
}

/// AI 模型在这台设备上的状态(App 里 `KaraokeSeparationService.ModelState` 的镜像)。
public enum KaraokeSingAlongModelStatus: Equatable, Sendable {
    case unsupportedSystem
    case notDownloaded
    case downloading(Double)
    case ready
    case failed
}

/// 一首歌的分离状态(App 里 `KaraokeSeparationService.SongState` 的镜像)。
public enum KaraokeSingAlongSongStatus: Equatable, Sendable {
    case idle
    case preparing
    case separating(Double)
    case ready
    /// 太长或解不了码,分离不了。
    case unsupported
    case failed
}

/// 分离为什么暂停着。
public enum KaraokeSingAlongHold: Equatable, Sendable {
    /// 设备热,降温后继续。
    case cooling
    /// App 在后台,GPU 跑不了模型;回到前台接着分离。
    case background
}

/// 伴唱现在走到哪一步,菜单与播放页底部的状态都按它写。
public enum KaraokeSingAlongPhase: Equatable, Sendable {
    case off
    /// 卡拉OK舞台开着,人声消除单元让给舞台。
    case yieldingToKaraoke
    /// 正在放的不是歌(或没在放):什么都不做,也不提示。
    case idle
    /// 这首放不了伴唱,照放原唱。
    case unavailable(KaraokeSingAlongAvailability)
    case downloadingModel(Double)
    case modelFailed
    /// 这首还在分离,先放原唱;`progress` 为 nil 是还没开始算(排队、装模型、读文件),
    /// 为 1 是分离完了、正在把人声轨装进播放图。
    case preparing(progress: Double?, hold: KaraokeSingAlongHold?)
    /// 这首分离不了(太长、格式解不了),照放原唱。
    case songUnsupported
    /// 这首分离失败了(已自动重试过一次),照放原唱。
    case songFailed
    /// 人声轨装上了,还在和播放对齐(要等开口唱);对齐前照放原唱,对齐后原唱淡出。
    case aligning
    case active

    /// 去掉进度的样子:系统菜单只在这个变了时才重建,分离进度一点点涨时不动(进度写在播放页底部)。
    /// 「还没开始算」(nil)、「在算」(0)、「算完在装」(1)仍分得开。
    public var withoutProgress: Self {
        switch self {
        case .downloadingModel:
            .downloadingModel(0)
        case .preparing(let progress, let hold):
            .preparing(progress: progress.map { $0 >= 1 ? 1.0 : 0.0 }, hold: hold)
        case .off, .yieldingToKaraoke, .idle, .unavailable, .modelFailed, .songUnsupported, .songFailed,
             .aligning, .active:
            self
        }
    }

    /// 用户此刻听到的是原唱(伴唱开着却没起作用),菜单里要说明原因。
    public var playsOriginal: Bool {
        switch self {
        case .unavailable, .downloadingModel, .modelFailed, .preparing, .songUnsupported, .songFailed:
            true
        case .off, .yieldingToKaraoke, .idle, .aligning, .active:
            false
        }
    }
}

/// 伴唱(#377):平时听歌时把这首换成 AI 分离出的伴奏,原唱压到选定的音量。不开麦克风、
/// 不打分、歌词照常。和卡拉OK共用分离模型、分离缓存与人声消除单元;卡拉OK舞台打开时让给舞台。
public enum KaraokeSingAlongPolicy {
    /// 一首歌分离好之前、App 在前台时提前分离接下来几首:后台 GPU 跑不了模型,锁屏听的
    /// 那几首要靠这时候先备好。
    public static let prefetchDepth = 2
    /// 分离缓存的上限。伴唱一直开着时每首歌留一份人声轨(44.1 kHz 16 位立体声,一首 4 分钟
    /// 约 10 MB),超过就从最久没用的删起。
    public static let stemCacheLimitBytes: Int64 = 1_000_000_000

    /// 能不能打开:这台设备拿不到模型时打不开,菜单里说明原因。
    public static func canEnable(model: KaraokeSingAlongModelStatus) -> Bool {
        model != .unsupportedSystem
    }

    /// 打开时要不要顺手下载模型(打开即同意下载,下载量在打开前就写明了)。
    public static func downloadsModelOnEnable(_ model: KaraokeSingAlongModelStatus) -> Bool {
        model == .notDownloaded || model == .failed
    }

    /// 启动时上次开着的伴唱还开不开。模型不在了(被删掉、被系统清掉)不自己去下 80 MB,
    /// 开关回到关;和卡拉OK「AI 人声分离」开关的规则一样。
    public static func staysEnabledAtLaunch(model: KaraokeSingAlongModelStatus) -> Bool {
        model == .ready
    }

    /// 开着的时候模型被删了(卡拉OK舞台里的「删除 AI 模型」):跟着关掉。打开时会先发起下载,
    /// 所以「开着 + 没下载」只会是删掉之后。
    public static func turnsOff(model: KaraokeSingAlongModelStatus) -> Bool {
        model == .notDownloaded
    }

    /// 这一刻该不该把这首的人声轨挂进播放图。
    public static func wantsStem(
        isEnabled: Bool,
        isKaraokeActive: Bool,
        availability: KaraokeSingAlongAvailability,
        model: KaraokeSingAlongModelStatus
    ) -> Bool {
        isEnabled && !isKaraokeActive && availability == .available && model == .ready
    }

    public enum SeparationRequest: Equatable, Sendable {
        /// 不用动:已经在分、分好了、分离不了,或失败后已经自动重试过。
        case skip
        case start
        /// 失败过一次,自动再试一次;常见原因是一次性的(当时在后台、文件一时取不到)。
        case retry
    }

    /// 这首要不要开始分离。失败的歌每首只自动重试一次,之后靠菜单里的「重试」。
    public static func separationRequest(
        for song: KaraokeSingAlongSongStatus,
        alreadyRetried: Bool
    ) -> SeparationRequest {
        switch song {
        case .idle: .start
        case .failed: alreadyRetried ? .skip : .retry
        case .preparing, .separating, .ready, .unsupported: .skip
        }
    }

    public static func phase(
        isEnabled: Bool,
        isKaraokeActive: Bool,
        availability: KaraokeSingAlongAvailability,
        model: KaraokeSingAlongModelStatus,
        song: KaraokeSingAlongSongStatus?,
        hold: KaraokeSingAlongHold?,
        isStemLoaded: Bool,
        isStemLocked: Bool
    ) -> KaraokeSingAlongPhase {
        guard isEnabled else { return .off }
        if isKaraokeActive { return .yieldingToKaraoke }
        switch model {
        case .unsupportedSystem: return .unavailable(.unsupportedSystem)
        // 打开的同时就发起了下载,「没下载」只会闪一下。
        case .notDownloaded: return .downloadingModel(0)
        case .downloading(let fraction): return .downloadingModel(fraction)
        case .failed: return .modelFailed
        case .ready: break
        }
        switch availability {
        case .available: break
        case .notApplicable: return .idle
        default: return .unavailable(availability)
        }
        if isStemLoaded { return isStemLocked ? .active : .aligning }
        switch song {
        case nil, .idle?, .preparing?: return .preparing(progress: nil, hold: hold)
        case .separating(let fraction)?: return .preparing(progress: fraction, hold: hold)
        case .ready?: return .preparing(progress: 1, hold: nil)
        case .unsupported?: return .songUnsupported
        case .failed?: return .songFailed
        }
    }

    /// 什么时候提前分离接下来的歌:这首已经不再占着模型(伴唱在起作用,或这首本来就分离不了),
    /// App 在前台,没开低电量模式,设备不热。
    public static func prefetchesUpcoming(
        current: KaraokeSingAlongPhase,
        isForeground: Bool,
        isLowPowerMode: Bool,
        isHot: Bool
    ) -> Bool {
        guard isForeground, !isLowPowerMode, !isHot else { return false }
        switch current {
        case .active, .aligning, .songUnsupported, .songFailed, .idle,
             .unavailable(.appleMusic), .unavailable(.unsupportedPlayback):
            return true
        case .off, .yieldingToKaraoke, .unavailable, .downloadingModel, .modelFailed, .preparing:
            return false
        }
    }

    /// 隔多久对齐一次人声轨与播放。没锁定时(刚装上、刚拖过进度)要快;锁定以后偶尔复核,
    /// 拖动、换歌会让锁定失效再快起来。开着 ReplayGain 时先快几次把音量比例攒出来。
    public static func alignmentInterval(isLocked: Bool, needsGainEstimate: Bool) -> Duration {
        isLocked && !needsGainEstimate ? .seconds(2) : .milliseconds(250)
    }

    // MARK: 卡拉OK舞台的「只听伴奏」

    /// 舞台里给不给「只听伴奏」:伴唱此刻能作用在这首上(播放方式支持、模型在这台设备上;
    /// 模型还没下载时不在这里替用户下 80 MB,舞台的 AI 开关会先说明),而且放的不是伴奏版本
    /// (本来就是伴奏,收起舞台就是)。
    public static func offersStageHandoff(
        availability: KaraokeSingAlongAvailability,
        model: KaraokeSingAlongModelStatus,
        isPlayingInstrumental: Bool
    ) -> Bool {
        availability == .available && model == .ready && !isPlayingInstrumental
    }

    /// 点了「只听伴奏」时,舞台已经装好的人声轨能不能原样交给伴唱(连同对齐结果,不撤下、不重新对齐,
    /// 中间不漏原唱)。是这首的人声轨、舞台没在放伴奏版本、伴唱确实打开了才交;否则舞台照常撤下,
    /// 伴唱自己去装(有缓存时约 0.3 秒,开口后再对齐)。
    public static func handsStemOver(
        isSingAlongEnabled: Bool,
        stageHasStem: Bool,
        stemSongMatchesPlaying: Bool,
        isPlayingInstrumental: Bool
    ) -> Bool {
        isSingAlongEnabled && stageHasStem && stemSongMatchesPlaying && !isPlayingInstrumental
    }
}
