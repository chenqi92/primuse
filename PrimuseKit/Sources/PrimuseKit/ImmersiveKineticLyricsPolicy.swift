import Foundation

/// 全屏效果「动态歌词」：一次只放一句，整句压在画面正中，一个字（逐字歌词）或一个词（逐行歌词按字数摊开时间）
/// 一个字地动起来。一句歌词在画面上走四步：
///
/// 1. **入场**：这句开唱前一点点，字一个接一个从下方弹上来、从虚化里变清楚，停在半透明的「候场」状态；
/// 2. **点亮**：唱到哪个字，哪个字就亮起来，同时弹一下、带一圈主题色的光；拖长的音一直撑着，唱完才落回；
/// 3. **唱过**：亮着，不再动；
/// 4. **退场**：下一句进来的同时，这一句一个字一个字往上飘走、虚化、淡出。
///
/// 和「逐字浪尖」（`ImmersiveSyllableCrestPolicy`）不同：那边是整页歌词里的当前句，字始终在；这里一句一个画面，
/// 字的出现和离开本身就是动画。
///
/// 只算每个字此刻的状态，排版和绘制交给界面。距离、虚化半径都按字号的比例给，便于测。
public enum ImmersiveKineticLyricsPolicy {
    /// 一句里的一个字或一个词，带它开唱与唱完的时刻。
    public struct Token: Equatable, Sendable {
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// 一个字此刻的样子。
    public struct Appearance: Equatable, Sendable {
        public var opacity: Double
        public var scale: Double
        /// 竖直位移，相对字号，向下为正。
        public var offset: Double
        /// 虚化半径，相对字号。
        public var blur: Double
        /// 主题色光的强度，0…1。
        public var glow: Double
        /// 落字成纹那圈涟漪走到哪儿：0 是没有，(0, 1] 从刚荡开到散尽。
        public var ripple: Double
        /// 故障字红、青两色错开多少，0…1。
        public var glitch: Double
        /// 横向位移，相对字号，向右为正（碎裂时字往四面飞）。
        public var offsetX: Double
        /// 绕字自己的中心转多少度（碎裂时字打着转飞）。
        public var rotation: Double

        public init(
            opacity: Double,
            scale: Double,
            offset: Double,
            blur: Double,
            glow: Double,
            ripple: Double = 0,
            glitch: Double = 0,
            offsetX: Double = 0,
            rotation: Double = 0
        ) {
            self.opacity = opacity
            self.scale = scale
            self.offset = offset
            self.blur = blur
            self.glow = glow
            self.ripple = ripple
            self.glitch = glitch
            self.offsetX = offsetX
            self.rotation = rotation
        }

        public static let hidden = Appearance(opacity: 0, scale: 1, offset: 0, blur: 0, glow: 0)
        public static let lit = Appearance(opacity: 1, scale: 1, offset: 0, blur: 0, glow: 0)
    }

    // MARK: - 时间与幅度

    /// 整句比第一个字开唱早多久开始入场：字先站好，唱到时正好亮起。不比全屏页提前切到下一句的那点时间长，
    /// 切过来的第一帧还没开始动。
    public static let entranceLead: TimeInterval = 0.08
    /// 相邻两个字入场相隔多久，以及整句入场摊开的最长时间（字多时每个字隔得更短）。
    public static let entranceStagger: TimeInterval = 0.045
    public static let entranceSpread: TimeInterval = 0.45
    /// 入场时从多低的地方弹上来（相对字号）、从多小放大到原样、多大的虚化变清楚。
    public static let entranceRise = 0.42
    public static let entranceInitialScale = 0.8
    public static let entranceBlur = 0.3
    /// 入场的淡入与变清楚各用多久。弹上来那一下由弹簧曲线决定，约半秒停稳。
    public static let entranceFade: TimeInterval = 0.18
    public static let entranceFocus: TimeInterval = 0.32
    /// 弹簧的阻尼比与角频率：阻尼比 0.6 只过冲一点，角频率 14 大约半秒停稳。
    public static let springDamping = 0.6
    public static let springFrequency = 14.0

    /// 还没唱到的字的不透明度。
    public static let waitingOpacity = 0.36
    /// 开唱前多久开始提亮，以及从候场亮到全亮用多久。
    public static let igniteLead: TimeInterval = 0.05
    public static let igniteRamp: TimeInterval = 0.16
    /// 点亮那一下：多快弹到最高、多快落回，弹到最高时放大多少、托起多高（相对字号）。
    public static let pulseAttack: TimeInterval = 0.08
    public static let pulseDecay: TimeInterval = 0.36
    public static let pulseSwell = 0.11
    public static let pulseLift = 0.08
    /// 光最亮时的半径（相对字号）。
    public static let glowRadiusRatio = 0.26

    /// 退场：比下一句入场最多早多久开始走（两句同时在原地时字叠在一起读不出来），每个字用多久飘走、相邻两个字
    /// 相隔多久、整句摊开的最长时间，以及飘多高、虚化多大、放大多少。
    public static let exitLead: TimeInterval = 0.3
    public static let exitDuration: TimeInterval = 0.38
    public static let exitStagger: TimeInterval = 0.016
    public static let exitSpread: TimeInterval = 0.14
    public static let exitRise = 0.85
    public static let exitBlur = 0.42
    public static let exitSwell = 0.05

    /// 唱完离下一句还有多久算「隔得久」（间奏、长换气）：这时唱完停一会儿就先退场，留出空档。
    public static let gapThreshold: TimeInterval = 4
    public static let holdAfterLine: TimeInterval = 1.6
    /// 空档里那三个点淡入淡出用的时长；空档短于 `interludeMinimumGap` 时不出（两句交接时一闪而过很怪）。
    public static let interludeFade: TimeInterval = 0.4
    public static let interludeMinimumGap: TimeInterval = 1.5

    /// 没有动效时（减弱动态效果、歌词动效关闭、省电档）只淡入淡出用的时长。
    public static let plainFade: TimeInterval = 0.2
    public static let plainExit: TimeInterval = 0.3

    /// 字最多会画出自己的字框多远（相对字号）：入场从下方弹上来、退场往上飘、光、冲击字砸下来前放大的那一截、
    /// 涟漪。绘制区域按它留边。
    public static let maximumOverhangRatio = 1.1

    /// 落字成纹：一圈涟漪荡开散尽用多久；字本身只轻轻弹一下。
    public static let rippleDuration: TimeInterval = 1.1
    public static let rippleSwell = 0.05
    public static let rippleLift = 0.04
    /// 冲击字：唱到时从多大砸到原样、砸下来用多久，落地后压扁回弹用多久；光多快散掉。
    public static let slamInitialScale = 1.45
    public static let slamDrop: TimeInterval = 0.12
    public static let slamRebound: TimeInterval = 0.12
    public static let slamSquash = 0.94
    public static let slamGlowDecay: TimeInterval = 0.25
    /// 霓虹灯管：通电时闪几下用多久，之后一直带着的光有多亮。
    public static let neonIgnition: TimeInterval = 0.22
    public static let neonSteadyGlow = 0.55
    /// 故障字：错开多久散掉。
    public static let glitchDuration: TimeInterval = 0.2
    /// 冲击字砸下来时整句震一下：最大幅度（相对字号）、多快衰减、震多久。
    public static let shakeAmplitude = 0.035
    public static let shakeDecay = 14.0
    public static let shakeSpan: TimeInterval = 0.35

    /// 一句里的字怎么进出。`cascade` 一个字接一个从下方弹上来、往上飘走；`wholeLine` 字只跟着整句一起淡入、
    /// 唱到时点亮，进出由整句的镜头带着走（`ImmersiveKineticDirectionPolicy`）；`scatter` 字从四面八方飞回来
    /// 拼成一句，退场时整句炸开、碎字迎面飞散。
    public enum Choreography: Sendable {
        case cascade
        case wholeLine
        case scatter
    }

    /// 碎裂：字飞回来、炸开各用多久，相邻两个字最多错开多久，飞多远（相对字号）、迎面放多大。
    public static let scatterAssemble: TimeInterval = 0.6
    public static let scatterBurst: TimeInterval = 0.65
    public static let scatterJitter: TimeInterval = 0.09
    public static let scatterReach = 2.6
    public static let scatterApproach = 1.5
    /// 碎裂时字会飞出字框多远（相对字号），绘制区域按它留边。
    public static let scatterOverhangRatio = 4.2

    /// 整句一起动时字提前多久就位：整句的镜头比第一个字早一截开始进场（最长约 0.6 秒），进场之前由镜头把整句
    /// 藏起来（透明、在画外或收在圆里），字自己不再晚一步才出现。
    public static let wholeLineLead: TimeInterval = 0.6

    // MARK: - 切分

    /// 一句歌词切成这一页上会各自动起来的字。逐字歌词直接用它的字；逐行歌词按字切开（汉字、假名一个字一段，
    /// 其余按词，空白与标点跟在前一段后面），再把这一行的时间按字数摊开。没有时间的歌词（不跟播放的那种）
    /// 返回空，界面整句静止显示。
    public static func tokens(
        text: String,
        syllables: [LyricSyllable]?,
        lineStart: TimeInterval?,
        lineEnd: TimeInterval?
    ) -> [Token] {
        if let syllables, !syllables.isEmpty {
            return syllables.indices.compactMap { index in
                let syllable = syllables[index]
                guard syllable.start.isFinite, !syllable.text.isEmpty else { return nil }
                let nextStart = syllables.indices.contains(index + 1) ? syllables[index + 1].start : nil
                let end = LyricSyllablePlaybackTimingPolicy.effectiveEnd(
                    for: syllable,
                    nextSyllableStart: nextStart
                )
                return Token(text: syllable.text, start: syllable.start, end: max(end, syllable.start))
            }
        }
        guard let lineStart, let lineEnd,
              lineStart.isFinite, lineEnd.isFinite, lineEnd > lineStart else { return [] }
        let pieces = units(in: text)
        guard !pieces.isEmpty else { return [] }
        // 唱满整行不现实：句尾常有拖音或换气，最后一个字留一截。
        let span = (lineEnd - lineStart) * 0.85
        let weights = pieces.map { piece in
            Double(max(piece.filter { !$0.isWhitespace && !$0.isPunctuation }.count, 1))
        }
        let total = weights.reduce(0, +)
        var cursor = lineStart
        return pieces.indices.map { index in
            let duration = span * weights[index] / total
            defer { cursor += duration }
            return Token(text: pieces[index], start: cursor, end: cursor + duration)
        }
    }

    /// 按字切开：汉字、假名一个字一段，其余连着的字母算一个词（词中间的撇号、连字符不断开）；
    /// 空白和标点跟在前一段后面，开头的标点并进第一段。
    public static func units(in text: String) -> [String] {
        var units: [String] = []
        var pendingPrefix = ""
        // 上一个字符是夹在字母中间的撇号或连字符：下一个字母接着这个词。
        var joinsNextLetter = false
        for character in text {
            if joinsNextLetter, isWordCharacter(character), !units.isEmpty {
                units[units.count - 1].append(character)
                joinsNextLetter = false
                continue
            }
            joinsNextLetter = false
            if !isWordCharacter(character), !isIdeographic(character) {
                if units.isEmpty {
                    pendingPrefix.append(character)
                } else {
                    let previous = units[units.count - 1].last
                    units[units.count - 1].append(character)
                    joinsNextLetter = wordJoiners.contains(character) && previous.map(isWordCharacter) == true
                }
                continue
            }
            if isWordCharacter(character),
               let lastCharacter = units.last?.last,
               isWordCharacter(lastCharacter) {
                units[units.count - 1].append(character)
            } else {
                units.append(pendingPrefix + String(character))
                pendingPrefix = ""
            }
        }
        if !pendingPrefix.isEmpty {
            if units.isEmpty {
                let trimmed = pendingPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { units.append(pendingPrefix) }
            } else {
                units[units.count - 1].append(pendingPrefix)
            }
        }
        return units
    }

    private static let wordJoiners: Set<Character> = ["'", "\u{2019}", "-", "\u{2010}"]

    /// 拼成词的字符：字母、数字这类，不含空白、标点、符号，也不含一个字一段的汉字和假名。
    private static func isWordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isPunctuation && !character.isSymbol && !isIdeographic(character)
    }

    private static func isIdeographic(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    // MARK: - 每个字此刻的样子

    /// 一句里每个字此刻的样子。`exitStart` 是这句开始退场的时刻（下一句进来、或者唱完进间奏），还在台上时为 nil。
    /// `motion` 为 false 时只淡入、亮起、淡出，不弹、不飘、不虚化、不发光。
    public static func appearances(
        for tokens: [Token],
        exitStart: TimeInterval?,
        at time: TimeInterval,
        motion: Bool
    ) -> [Appearance] {
        appearances(
            for: tokens,
            exitStart: exitStart,
            at: time,
            motion: motion,
            choreography: .cascade,
            accent: .glow
        )
    }

    /// 同上，按编排与强调方式算。`wholeLine` 时 `exitStart` 不起作用：退场交给整句的镜头。
    public static func appearances(
        for tokens: [Token],
        exitStart: TimeInterval?,
        at time: TimeInterval,
        motion: Bool,
        choreography: Choreography,
        accent: ImmersiveKineticAccent
    ) -> [Appearance] {
        guard let first = tokens.first, time.isFinite else { return tokens.map { _ in .hidden } }
        if choreography == .scatter {
            return tokens.indices.map { index in
                scatterAppearance(
                    token: tokens[index],
                    index: index,
                    lineStart: first.start,
                    exitStart: exitStart,
                    time: time,
                    motion: motion,
                    accent: accent
                )
            }
        }
        let cascades = choreography == .cascade
        let entranceStart = first.start - entranceLead - (cascades ? 0 : wholeLineLead)
        let count = tokens.count
        let entranceStep = cascades && count > 1 ? min(entranceStagger, entranceSpread / Double(count - 1)) : 0
        let exitStep = count > 1 ? min(exitStagger, exitSpread / Double(count - 1)) : 0
        return tokens.indices.map { index in
            appearance(
                token: tokens[index],
                enterAt: entranceStart + entranceStep * Double(index),
                exitAt: cascades ? exitStart.map { $0 + exitStep * Double(index) } : nil,
                time: time,
                motion: motion,
                cascades: cascades,
                accent: accent
            )
        }
    }

    /// 冲击字砸下来时整句跟着震的位移（相对字号）。每个字砸下来都一样震，不看它唱多久。
    public static func shake(
        for tokens: [Token],
        at time: TimeInterval,
        motion: Bool
    ) -> (x: Double, y: Double) {
        guard motion, time.isFinite else { return (0, 0) }
        var x = 0.0
        var y = 0.0
        for index in tokens.indices {
            let sung = time - tokens[index].start
            guard sung >= 0, sung < shakeSpan else { continue }
            let amplitude = shakeAmplitude * exp(-sung * shakeDecay)
            let phase = Double(index) * 1.7
            x += amplitude * sin(sung * 95 + phase)
            y += amplitude * 0.6 * cos(sung * 80 + phase)
        }
        return (x, y)
    }

    /// 这一句什么时候开始退场。下一句紧接着来时赶在下一句入场前一点先往上飘（最多早 `exitLead`，但不早于自己
    /// 最后一个字唱完），下一句从下方弹上来时这一句已经淡得差不多了；隔得久时唱完停一会儿先走；最后一句
    /// （后面没有下一句）一直留着。
    public static func exitStart(of tokens: [Token], nextLineStart: TimeInterval?) -> TimeInterval? {
        guard let lastEnd = tokens.map(\.end).max(),
              let nextLineStart, nextLineStart.isFinite else { return nil }
        if nextLineStart - lastEnd > gapThreshold {
            return lastEnd + holdAfterLine
        }
        let entrance = nextLineStart - entranceLead
        return min(max(lastEnd, entrance - exitLead), entrance)
    }

    /// 两句之间空档里那三个点有多显眼（0…1）：上一句退得差不多了才出来，下一句入场前收起。
    public static func interludeVisibility(
        previousExit: TimeInterval?,
        nextLineStart: TimeInterval?,
        at time: TimeInterval
    ) -> Double {
        guard let previousExit, time.isFinite else { return 0 }
        let shown = smoothstep((time - previousExit - exitDuration * 0.5) / interludeFade)
        guard let nextLineStart else { return shown }
        guard nextLineStart - previousExit >= interludeMinimumGap else { return 0 }
        let hidden = smoothstep((nextLineStart - entranceLead - time) / interludeFade)
        return min(shown, hidden)
    }

    /// 整句退场要多久才完全看不见（最后一个字飘走为止）。界面过了这段就不必再画上一句。
    public static func exitSpan(tokenCount: Int) -> TimeInterval {
        let step = tokenCount > 1 ? min(exitStagger, exitSpread / Double(tokenCount - 1)) : 0
        return max(exitDuration, plainExit) + step * Double(max(tokenCount - 1, 0))
    }

    /// 整句一起动的东西（译文、罗马音）此刻的样子：跟着第一个字入场、和第一个字一起退场，不弹、不发光。
    public static func companionAppearance(
        lineStart: TimeInterval,
        exitStart: TimeInterval?,
        at time: TimeInterval,
        motion: Bool
    ) -> Appearance {
        guard time.isFinite, lineStart.isFinite else { return .hidden }
        let entered = time - (lineStart - entranceLead + entranceFade)
        guard entered >= 0 else { return .hidden }
        var result = Appearance.lit
        let fadeIn = smoothstep(min(1, entered / (motion ? entranceFocus : plainFade)))
        result.opacity = fadeIn
        if motion {
            result.offset = entranceRise * 0.5 * (1 - fadeIn)
            result.blur = entranceBlur * (1 - fadeIn)
        }
        if let exitStart, time >= exitStart {
            let progress = smoothstep(min(1, (time - exitStart) / (motion ? exitDuration : plainExit)))
            result.opacity *= 1 - progress
            if motion {
                result.offset -= exitRise * progress
                result.blur += exitBlur * progress
            }
        }
        return result
    }

    static func appearance(
        token: Token,
        enterAt: TimeInterval,
        exitAt: TimeInterval?,
        time: TimeInterval,
        motion: Bool,
        cascades: Bool = true,
        accent: ImmersiveKineticAccent = .glow
    ) -> Appearance {
        let entered = time - enterAt
        guard entered >= 0 else { return .hidden }

        var result = Appearance.lit
        // 入场：一个字一个字弹上来；整句一起动时只淡入，挪动交给整句。
        let fadeIn = smoothstep(min(1, entered / entranceFade))
        if motion, cascades {
            let settle = spring(entered)
            result.offset = entranceRise * (1 - settle)
            result.scale = entranceInitialScale + (1 - entranceInitialScale) * settle
            result.blur = entranceBlur * (1 - easeOutCubic(min(1, entered / entranceFocus)))
        }

        // 点亮
        let sung = time - token.start
        let lit = sung < -igniteLead ? 0 : smoothstep(min(1, (sung + igniteLead) / igniteRamp))
        result.opacity = fadeIn * (waitingOpacity + (1 - waitingOpacity) * lit)
        if motion {
            switch accent {
            case .glow:
                let pulse = pulseStrength(sung: sung)
                result.scale *= 1 + pulseSwell * pulse
                result.offset -= pulseLift * pulse
                result.glow = pulse
            case .ripple:
                let pulse = pulseStrength(sung: sung)
                result.scale *= 1 + rippleSwell * pulse
                result.offset -= rippleLift * pulse
                result.glow = 0.55 * pulse
                if sung >= 0, sung < rippleDuration {
                    result.ripple = max(sung / rippleDuration, 0.0001)
                }
            case .slam:
                result.scale *= slamScale(sung: sung)
                if sung >= 0 {
                    result.glow = exp(-sung / slamGlowDecay)
                }
            case .neon:
                // 灯管通电：先闪两下，亮了就一直带着光。
                if sung >= 0 {
                    result.opacity *= neonFlicker(sung: sung)
                    result.glow = sung < neonIgnition ? 0.9 : neonSteadyGlow
                }
            case .glitch:
                if sung >= 0, sung < glitchDuration {
                    result.glitch = 1 - sung / glitchDuration
                }
            }
        }

        // 退场
        if let exitAt, time >= exitAt {
            let progress = smoothstep(min(1, (time - exitAt) / (motion ? exitDuration : plainExit)))
            result.opacity *= 1 - progress
            if motion {
                result.offset -= exitRise * progress
                result.blur += exitBlur * progress
                result.scale *= 1 + exitSwell * progress
                result.glow *= 1 - progress
            }
        }
        return result
    }

    /// 碎裂编排里一个字此刻的样子：整句入场时从四面八方带着旋转飞回原位（稍微冲过头再落定），唱的时候和别的
    /// 编排一样点亮、强调，退场时沿同一个方向炸开、迎面放大、虚掉。每个字飞的方向按它在句子里的位置固定。
    static func scatterAppearance(
        token: Token,
        index: Int,
        lineStart: TimeInterval,
        exitStart: TimeInterval?,
        time: TimeInterval,
        motion: Bool,
        accent: ImmersiveKineticAccent
    ) -> Appearance {
        let shard = scatterShard(index: index)
        let assembleStart = lineStart - scatterAssemble * 0.9 + shard.delay
        var result = appearance(
            token: token,
            enterAt: assembleStart,
            exitAt: motion ? nil : exitStart,
            time: time,
            motion: motion,
            cascades: false,
            accent: accent
        )
        guard motion else { return result }
        let entered = time - assembleStart
        if entered >= 0 {
            let settle = spring(entered)
            let away = 1 - settle
            result.offsetX += shard.dx * scatterReach * away
            result.offset += shard.dy * scatterReach * away
            result.rotation += shard.spin * away
            result.scale *= 1 + scatterApproach * max(away, 0)
            // 只虚一点：飞着的字要认得出来。
            result.blur += 0.12 * (1 - easeOutCubic(min(1, entered / (scatterAssemble * 0.6))))
        }
        if let exitStart, time >= exitStart + shard.delay {
            let progress = min(1, (time - exitStart - shard.delay) / scatterBurst)
            let burst = easeOutCubic(progress)
            result.offsetX += shard.dx * scatterReach * 1.3 * burst
            result.offset += shard.dy * scatterReach * 1.3 * burst
            result.rotation -= shard.spin * 0.8 * burst
            result.scale *= 1 + scatterApproach * 1.2 * burst
            result.blur += 0.15 * progress
            result.glow *= 1 - progress
            result.opacity *= 1 - smoothstep((progress - 0.15) / 0.85)
        }
        return result
    }

    /// 第 `index` 个字飞的方向（单位向量，y 向下）、转多少度、比整句晚多久动。按黄金角摊开，相邻的字方向
    /// 差得远，整句炸开时四面都有。
    static func scatterShard(index: Int) -> (dx: Double, dy: Double, spin: Double, delay: TimeInterval) {
        let angle = Double(index) * 2.399963 + 0.7
        let reach = 0.75 + 0.5 * fraction(Double(index) * 0.618034 + 0.31)
        let spin = (fraction(Double(index) * 0.381966 + 0.17) * 2 - 1) * 200
        let delay = fraction(Double(index) * 0.7548777 + 0.41) * scatterJitter
        return (cos(angle) * reach, sin(angle) * reach * 0.8, spin, delay)
    }

    private static func fraction(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    /// 点亮那一下的强度：极快弹到顶再慢慢落回。每个字都一样，不看这个字唱多久——以前长音唱着时
    /// 一直撑在一半，「按字的演唱时长分两种显示」是 US12592007B2 独立权利要求里的一项，已去掉。
    static func pulseStrength(sung: TimeInterval) -> Double {
        guard sung >= 0 else { return 0 }
        return sung < pulseAttack
            ? easeOutCubic(sung / pulseAttack)
            : exp(-(sung - pulseAttack) / pulseDecay)
    }

    /// 霓虹灯管通电那一下的亮度：亮、暗、亮、半暗、亮，之后一直亮着。
    static func neonFlicker(sung: TimeInterval) -> Double {
        guard sung >= 0, sung < neonIgnition else { return 1 }
        switch sung / neonIgnition {
        case ..<0.2: return 1
        case ..<0.4: return 0.25
        case ..<0.6: return 1
        case ..<0.75: return 0.5
        default: return 1
        }
    }

    /// 冲击字的大小：开唱那一刻从 `slamInitialScale` 砸到原样，落地压扁一下再回弹。
    static func slamScale(sung: TimeInterval) -> Double {
        guard sung >= 0 else { return 1 }
        if sung < slamDrop {
            let progress = easeInCubic(sung / slamDrop)
            return slamInitialScale + (slamSquash - slamInitialScale) * progress
        }
        let rebound = sung - slamDrop
        guard rebound < slamRebound else { return 1 }
        return slamSquash + (1 - slamSquash) * easeOutCubic(rebound / slamRebound)
    }

    /// 欠阻尼弹簧从 0 到 1 的阶跃响应：先冲过一点，再停在 1。
    static func spring(_ time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        let zeta = springDamping
        let omega = springFrequency
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * time)
        return 1 - decay * (cos(damped * time) + zeta * omega / damped * sin(damped * time))
    }

    // MARK: - 字号

    /// 当前句的字号：先用整页的基准字号，放不进 `maximumLines` 行时按宽度缩小，最小不低于 `minimum`。
    public static func fontSize(
        for text: String,
        base: Double,
        minimum: Double,
        availableWidth: Double,
        maximumLines: Int
    ) -> Double {
        let width = max(availableWidth, 1)
        let lines = Double(max(maximumLines, 1))
        // 按词换行时每行尾巴上总会空出一截，只算九成。
        let fitted = width * lines * 0.9 / max(estimatedWidth(of: text), 1)
        return max(min(base, fitted), min(minimum, base))
    }

    /// 粗体排出来大约多少个字号宽。汉字、假名、谚文一个字一个字号宽，其余按整页歌词的估算
    /// （一个排版单位约 0.62 个字号）。
    public static func estimatedWidth(of text: String) -> Double {
        text.reduce(into: 0.0) { total, character in
            guard let scalar = character.unicodeScalars.first else { return }
            if isFullWidth(scalar.value) {
                total += 1.0
            } else {
                total += ImmersiveLyricTypographyPolicy.estimatedTypographicUnits(in: String(character)) * 0.62
            }
        }
    }

    private static func isFullWidth(_ value: UInt32) -> Bool {
        (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFF00...0xFFEF).contains(value)
            || (0x20000...0x3134F).contains(value)
    }

    private static func easeInCubic(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * clamped
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        let inverse = 1 - value
        return 1 - inverse * inverse * inverse
    }

    private static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
