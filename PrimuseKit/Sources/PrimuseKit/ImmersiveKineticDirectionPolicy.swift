import Foundation

// 全屏效果「动态歌词」的编排：每首歌固定挑一套背景场景、换句镜头、字的强调与机位，副歌（这首歌自己最响的
// 那几段）换成这一套里更激烈的镜头。这里只决定选什么、此刻走到哪一步，画法交给界面。

/// 背景场景。`isEnergetic` 分安静与激烈两组。
public enum ImmersiveKineticScene: String, CaseIterable, Sendable {
    /// 雨窗：雨点落在玻璃上往下滑，窗外是虚化的光斑。
    case rainGlass
    /// 水面涟漪：俯看一片映着专辑色的水，鼓点、字头在水面上荡开一圈圈涟漪。
    case ripplePond
    /// 天光一日：天色随这首歌的进度从拂晓走到入夜。
    case daylight
    /// 曲速隧道：星光拉成线从中心往外冲，速度跟着能量走，重拍时冲出一道冲击波。
    case warpTunnel
    /// 雷暴：翻滚的乌云和斜雨，重拍劈下闪电。
    case thunderstorm
    /// 雾中光柱：光从高处斜穿薄雾，浮尘在光里闪。
    case godRays
    /// 星轨长曝光：星星绕着极点划出一圈圈弧，重拍时划过流星。
    case starTrails
    /// 池底焦散：泳池底那张晃动的光网，跟着能量流动。
    case caustics
    /// 墨入水：鼓点滴进一团团墨，被水流扯成丝慢慢晕开。
    case inkBloom
    /// 激光秀：台口一排激光扫来扫去，鼓点时张开。
    case laserShow
    /// 霓虹夜驰：沿着发光的网格路面往地平线上的城市冲。
    case neonDrive

    public var isEnergetic: Bool {
        switch self {
        case .rainGlass, .ripplePond, .daylight, .godRays, .starTrails, .caustics, .inkBloom: false
        case .warpTunnel, .thunderstorm, .laserShow, .neonDrive: true
        }
    }
}

/// 换句时整句怎么进出，取自电影的转场。
public enum ImmersiveKineticTransition: String, CaseIterable, Sendable {
    /// 逐字浮现：字一个接一个从下方弹上来，唱完往上飘走（最早那一版的样子）。
    case cascade
    /// 甩镜：整句带着拖影横向甩出画面，新句从另一侧甩进来。
    case whipPan
    /// 焦点转移：旧句退向远处、虚掉，新句从镜头前的虚焦里清楚起来。
    case rackFocus
    /// 急推：新句从镜头前猛地推到原样，旧句冲出画面。
    case crashZoom
    /// 圈入圈出：一个圆把旧句收掉，再张开露出新句。
    case iris
    /// 抽帧：一顿一顿地挪进来，身后拖着残影，像王家卫电影里降格又补帧的镜头。
    case stepPrint
    /// 立方体翻转：整句贴在一个立方体的面上，旧句随着立方体往上翻走，新句从下面那一面翻上来。
    case cubeFlip
    /// 穿越：新句从远处的纵深里冲到眼前，旧句迎面掠过镜头。
    case flyThrough
    /// 旋入：整句打着旋、侧着身子从远处转进来，走时转着甩向镜头。
    case spiral
    /// 碎裂：字从四面八方飞回来拼成一句，唱完整句炸开，碎字迎面飞散。
    case shatter

    /// 整句一起进出、字只跟着点亮（`cascade` 以外都是；碎裂时整句不动，进出由每个字自己飞）。
    public var movesWholeLine: Bool { self != .cascade }

    /// 一句里的字怎么动。
    public var choreography: ImmersiveKineticLyricsPolicy.Choreography {
        switch self {
        case .cascade: .cascade
        case .shatter: .scatter
        default: .wholeLine
        }
    }
}

/// 唱到一个字时怎么强调它。每个字都一样，不看它唱多久。
public enum ImmersiveKineticAccent: String, CaseIterable, Sendable {
    /// 弹一下、带一圈光。
    case glow
    /// 落字成纹：字下面荡开一圈涟漪。
    case ripple
    /// 冲击字：字砸下来，整句跟着一震。
    case slam
    /// 霓虹灯管：字像灯管通电，先闪两下再稳稳亮着。
    case neon
    /// 故障字：唱到时红、青两色错开一下。
    case glitch
}

/// 机位：歌词摆在哪个平面上、镜头怎么看它。除了平视，每一句都有自己的角度，换句像多机位剪辑那样换个
/// 机位；同一句唱着时镜头还在慢慢移，跟着鼓点往前顶一下。
public enum ImmersiveKineticStaging: String, CaseIterable, Sendable {
    /// 平视：不转角度（动效关掉时都按这个）。导演不再挑它。
    case flat
    /// 斜面透视：歌词排在一块向远处倾斜的平面上，机位慢慢左右摇。
    case tilted
    /// 竖排：中日文一列一列从右往左排，像古籍的版面。一句里有拉丁字母时这句照常横排。
    case vertical
    /// 环绕：每句从不同的侧面、俯仰角看过去，唱着时镜头绕着字慢慢转。
    case orbit
    /// 荷兰角：画面斜着，一句往左歪、下一句往右歪，副歌歪得更狠。
    case dutch
}

/// 一句歌词此刻的机位（`ImmersiveKineticDirectionPolicy.camera`）：三个角度都是度，`scale` 是跟着鼓点往前顶
/// 和唱着时慢慢推近的那一点放大。
public struct ImmersiveKineticCameraPose: Equatable, Sendable {
    /// 绕竖轴转（左右看）。
    public var yaw: Double
    /// 绕横轴转（俯仰），正值是上沿往远处倒。
    public var pitch: Double
    /// 绕视线转（画面歪）。
    public var roll: Double
    public var scale: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0, scale: Double = 1) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.scale = scale
    }

    public static let level = ImmersiveKineticCameraPose()
}

/// 一首歌的整套编排。
public struct ImmersiveKineticDirection: Equatable, Sendable {
    public var scene: ImmersiveKineticScene
    public var staging: ImmersiveKineticStaging
    public var accent: ImmersiveKineticAccent
    /// 平常换句用的镜头。
    public var transition: ImmersiveKineticTransition
    /// 平常换句的第二个镜头：和 `transition` 一句一换，免得整首歌都是同一个动作。
    public var alternateTransition: ImmersiveKineticTransition
    /// 副歌换句用的镜头。
    public var climaxTransition: ImmersiveKineticTransition
    /// 立体字：字带一截厚度，侧面是专辑色，跟着机位的角度露出来。
    public var extruded: Bool

    public init(
        scene: ImmersiveKineticScene,
        staging: ImmersiveKineticStaging,
        accent: ImmersiveKineticAccent,
        transition: ImmersiveKineticTransition,
        alternateTransition: ImmersiveKineticTransition? = nil,
        climaxTransition: ImmersiveKineticTransition,
        extruded: Bool = false
    ) {
        self.scene = scene
        self.staging = staging
        self.accent = accent
        self.transition = transition
        self.alternateTransition = alternateTransition ?? transition
        self.climaxTransition = climaxTransition
        self.extruded = extruded
    }

    /// 第 `lineIndex` 句平常用哪个镜头：两个镜头一句一换。
    public func usualTransition(forLine lineIndex: Int) -> ImmersiveKineticTransition {
        lineIndex.isMultiple(of: 2) ? transition : alternateTransition
    }
}

/// 整句此刻的样子（镜头带着整句走时）。
public struct ImmersiveKineticLineTransform: Equatable, Sendable {
    /// 横向位移，相对歌词那一栏的宽度。
    public var offsetX: Double
    /// 竖直位移，相对字号，向下为正。
    public var offsetY: Double
    public var scale: Double
    /// 虚化半径，相对字号。
    public var blur: Double
    public var opacity: Double
    /// 横向拖影的强度，0…1（甩镜）。
    public var smear: Double
    /// 圈入圈出那个圆有多大：1 是整句完全露出，0 是收成一个点；nil 时不加圆。
    public var iris: Double?
    /// 绕横轴、竖轴、视线转的角度（度）。绕横轴正值是上沿往远处倒，绕竖轴正值是右侧往远处转。
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double
    /// 转轴在字后面多深（相对字号）：立方体翻转时字贴在立方体的面上，轴在立方体中心。
    public var depth: Double

    public init(
        offsetX: Double = 0,
        offsetY: Double = 0,
        scale: Double = 1,
        blur: Double = 0,
        opacity: Double = 1,
        smear: Double = 0,
        iris: Double? = nil,
        rotationX: Double = 0,
        rotationY: Double = 0,
        rotationZ: Double = 0,
        depth: Double = 0
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.blur = blur
        self.opacity = opacity
        self.smear = smear
        self.iris = iris
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.depth = depth
    }

    public static let identity = ImmersiveKineticLineTransform()
    public static let hidden = ImmersiveKineticLineTransform(opacity: 0)
}

public enum ImmersiveKineticDirectionPolicy {
    // MARK: - 选编排

    /// 按歌名、歌手、专辑固定挑一套：同一首歌每次都一样，换一首就不同。流派听得出快慢时安静的歌多半挑
    /// 安静的场景，激烈的歌多半挑激烈的；水面配涟漪字，激烈场景偏冲击字。
    public static func direction(
        title: String,
        artist: String,
        album: String,
        genre: String
    ) -> ImmersiveKineticDirection {
        var random = ImmersiveRandom(seed: ImmersiveRandom.seed(for: "\(title)\u{1F}\(artist)\u{1F}\(album)"))
        let energeticChance: Double = switch temperament(of: genre) {
        case .calm: 0.12
        case .lively: 0.8
        case .unknown: 0.4
        }
        let energetic = random.unit() < energeticChance
        let scenes = ImmersiveKineticScene.allCases.filter { $0.isEnergetic == energetic }
        let scene = pick(scenes, &random)

        let accent: ImmersiveKineticAccent
        if scene == .ripplePond {
            accent = .ripple
        } else if scene == .neonDrive {
            accent = random.unit() < 0.6 ? .neon : .glitch
        } else if energetic {
            accent = pick([.slam, .slam, .glitch, .neon, .glow], &random)
        } else {
            accent = pick([.ripple, .glow, .glow, .neon], &random)
        }
        // 平视不再挑：每首歌都有立体的机位。
        let staging: ImmersiveKineticStaging = energetic
            ? pick([.orbit, .orbit, .dutch, .tilted], &random)
            : pick([.orbit, .tilted, .vertical, .vertical, .dutch], &random)

        let usual: [ImmersiveKineticTransition] = energetic
            ? [.whipPan, .crashZoom, .cubeFlip, .flyThrough, .spiral, .shatter]
            : [.cascade, .rackFocus, .iris, .stepPrint, .cubeFlip, .flyThrough]
        let transition = pick(usual, &random)
        let alternate = pick(usual.filter { $0 != transition }, &random)
        let climaxPool: [ImmersiveKineticTransition] = energetic
            ? [.shatter, .crashZoom, .flyThrough, .spiral, .cubeFlip]
            : [.cubeFlip, .whipPan, .flyThrough, .shatter]
        let climaxChoices = climaxPool.filter { $0 != transition && $0 != alternate }
        let climaxTransition = pick(climaxChoices.isEmpty ? [transition] : climaxChoices, &random)
        let extruded = random.unit() < (energetic ? 0.55 : 0.3)
        return ImmersiveKineticDirection(
            scene: scene,
            staging: staging,
            accent: accent,
            transition: transition,
            alternateTransition: alternate,
            climaxTransition: climaxTransition,
            extruded: extruded
        )
    }

    // MARK: - 机位

    /// 每句换机位时挑的角度（偏航、俯仰、横滚，度），像多机位剪辑：左前、右下、俯拍、右侧、仰拍……一行字的
    /// 立体感主要靠偏航（宽度方向的纵深大），俯仰只改一点点行高，所以偏航给得大。
    static let orbitAngles: [(yaw: Double, pitch: Double, roll: Double)] = [
        (-30, 10, -3), (28, -8, 2), (-14, 18, 0), (34, 6, 3), (-26, -12, -2), (18, 14, 0),
    ]

    /// 第 `lineIndex` 句此刻的机位。`time` 是播放时间（停住时镜头也停住），`swell` 是跟着鼓点、平滑过的那一下
    /// （0…1），`climax` 是进副歌的程度（0…1），`amplitude` 是角度的幅度（竖屏窄，转太狠字会出画）。
    /// `sungFraction` 是这句唱到几成：唱着时镜头慢慢推近一点。
    public static func camera(
        staging: ImmersiveKineticStaging,
        lineIndex: Int,
        seed: Double,
        time: TimeInterval,
        swell: Double,
        climax: Double,
        sungFraction: Double,
        amplitude: Double,
        motion: Bool
    ) -> ImmersiveKineticCameraPose {
        guard motion, time.isFinite else { return .level }
        let wild = 1 + 0.6 * clamp(climax)
        let kick = clamp(swell)
        let phase = Double(lineIndex) * 1.37 + seed * 6.28
        var pose = ImmersiveKineticCameraPose()
        switch staging {
        case .flat:
            break
        case .orbit:
            let offset = Int((seed * Double(orbitAngles.count)).rounded(.down))
            let count = orbitAngles.count
            let angle = orbitAngles[((lineIndex + offset) % count + count) % count]
            pose.yaw = (angle.yaw + 7 * sin(time * 0.23 + phase)) * wild
            pose.pitch = angle.pitch + 4 * sin(time * 0.19 + phase * 0.7)
            pose.roll = angle.roll + 2.5 * sin(time * 0.15 + phase) * wild
        case .tilted:
            let side: Double = lineIndex.isMultiple(of: 2) ? 1 : -1
            pose.pitch = 30
            pose.yaw = (side * 16 + 10 * sin(time * 0.16 + phase)) * wild
        case .dutch:
            let side: Double = lineIndex.isMultiple(of: 2) ? 1 : -1
            pose.roll = (side * 9 + 1.5 * sin(time * 0.3 + phase)) * wild
            pose.yaw = 12 * sin(time * 0.13 + phase) * wild
            pose.pitch = 6
        case .vertical:
            pose.yaw = 18 * sin(time * 0.12 + phase)
            pose.pitch = 5
        }
        pose.yaw *= amplitude
        pose.pitch *= amplitude
        pose.roll *= amplitude
        // 鼓点往前顶一下、往下点一下头；唱着时慢慢推近。
        pose.pitch -= 3 * kick
        pose.scale = (1 + (0.045 + 0.03 * clamp(climax)) * kick) * (1 + 0.06 * clamp(sungFraction))
        return pose
    }

    /// 这句适不适合竖排：至少两个汉字或假名，并且没有拉丁字母这类按词拼写的文字（数字、标点不算）。
    public static func suitsVerticalLayout(_ text: String) -> Bool {
        var ideographs = 0
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) {
                ideographs += 1
            } else if CharacterSet.letters.contains(scalar) {
                return false
            }
        }
        return ideographs >= 2
    }

    /// 竖排一句的版式：字号和分列。列数取最少的那个——只要每列的字高加起来放得进 `availableHeight`、字号不比
    /// `preferredFontSize` 小两成；三列还不够时取三列（字号不低于 `minimumFontSize`）。一列字高按 `lineHeight`
    /// 个字号算。以前一列按 0.7 倍高度、至少四个字切，横屏矮的时候一句被切成好几列、每列只有几个字。
    public static func verticalLayout(
        tokenCount: Int,
        availableHeight: Double,
        preferredFontSize: Double,
        minimumFontSize: Double,
        lineHeight: Double = 1.25
    ) -> (fontSize: Double, columns: [Range<Int>]) {
        guard tokenCount > 0, availableHeight > 0 else { return (preferredFontSize, []) }
        let floor = min(minimumFontSize, preferredFontSize)
        var perColumn = tokenCount
        var fontSize = preferredFontSize
        for columnCount in 1...3 {
            perColumn = Int((Double(tokenCount) / Double(columnCount)).rounded(.up))
            fontSize = min(preferredFontSize, availableHeight / (Double(perColumn) * lineHeight))
            if fontSize >= preferredFontSize * 0.8 || perColumn <= 1 { break }
        }
        let columns = stride(from: 0, to: tokenCount, by: perColumn).map { $0..<min($0 + perColumn, tokenCount) }
        return (max(fontSize, floor), columns)
    }

    /// 竖排的歌像一卷展开的卷轴：当前这句在正中，唱过的那句往右退一列、变淡，再往前的淡出；新的一句从左边进来。
    /// 返回此刻卷轴卷到第几句（可以是小数）：下一句开唱前 `scrollLead` 秒开始卷，卷到它开唱时停下。`activeID`
    /// 是当前句，`activeFirst`、`upcomingFirst` 是当前句和下一句第一个字开唱的时刻。
    public static func scrollPosition(
        activeID: Int,
        activeFirst: TimeInterval?,
        upcomingFirst: TimeInterval?,
        at time: TimeInterval
    ) -> Double {
        func rolled(_ start: TimeInterval?) -> Double {
            guard let start else { return 1 }
            return easeInOutCubic((time - (start - scrollLead)) / scrollLead)
        }
        return Double(activeID) - 1 + rolled(activeFirst) + (upcomingFirst.map { _ in rolled(upcomingFirst) } ?? 0)
    }

    /// 卷轴上一句离正中 `distance` 句（正值是唱过的、在右边）时有多显眼。
    public static func scrollOpacity(distance: Double) -> Double {
        if distance < 0 { return smoothstep(1 + distance) }
        if distance <= 0.5 { return 1 - (1 - scrollRestingOpacity) * smoothstep(distance / 0.5) }
        return scrollRestingOpacity * (1 - smoothstep((distance - 1) / 0.75))
    }

    public static let scrollLead: TimeInterval = 0.7
    /// 唱过的那句停在右边时的透明度：比正中那句还没唱到的字（`ImmersiveKineticLyricsPolicy.waitingOpacity`）暗一档，一眼分得出哪句在唱。
    public static let scrollRestingOpacity = 0.22

    enum Temperament: Equatable {
        case calm
        case lively
        case unknown
    }

    /// 从流派里听快慢：两边都沾（「抒情摇滚」）或都不沾时算不知道。
    static func temperament(of genre: String) -> Temperament {
        let text = genre.lowercased()
        guard !text.isEmpty else { return .unknown }
        let lively = livelyGenreWords.contains { text.contains($0) }
        let calm = calmGenreWords.contains { text.contains($0) }
        switch (lively, calm) {
        case (true, false): return .lively
        case (false, true): return .calm
        default: return .unknown
        }
    }

    private static let livelyGenreWords = [
        "rock", "metal", "punk", "electro", "edm", "dance", "house", "techno", "trance", "dubstep",
        "drum", "hip hop", "hip-hop", "hiphop", "rap", "trap", "funk", "disco", "grunge", "hardcore",
        "摇滚", "电子", "舞曲", "说唱", "嘻哈", "金属", "朋克", "迪斯科",
    ]
    private static let calmGenreWords = [
        "classical", "piano", "ambient", "folk", "jazz", "acoustic", "lo-fi", "lofi", "new age", "chill",
        "ballad", "instrumental", "soundtrack", "lullaby", "meditation",
        "古典", "钢琴", "民谣", "爵士", "轻音乐", "纯音乐", "氛围", "抒情", "古风", "摇篮曲",
    ]

    private static func pick<Element>(_ values: [Element], _ random: inout ImmersiveRandom) -> Element {
        values[min(Int(random.unit() * Double(values.count)), values.count - 1)]
    }

    /// 立体字的厚度在画面上往哪边露（相对字号的向量，y 向下）：底子是往右下（像从左上打光的立体标题），镜头
    /// 转到哪边，靠近镜头的那一侧侧面就多露一点——偏航时右侧往远处转，左侧近，侧面往左露；俯仰时上沿往远处倒，
    /// 下沿近，侧面往下露。
    public static func extrusion(for pose: ImmersiveKineticCameraPose) -> (dx: Double, dy: Double) {
        let x = 0.3 - extrusionSteer * sin(pose.yaw * .pi / 180)
        let y = 0.7 + extrusionSteer * sin(pose.pitch * .pi / 180)
        let length = max((x * x + y * y).squareRoot(), 0.001)
        return (x / length * extrusionDepth, y / length * extrusionDepth)
    }

    /// 立体字有多厚（相对字号）、机位角度把它往两边带多少。
    public static let extrusionDepth = 0.2
    static let extrusionSteer = 1.8

    // MARK: - 镜头的时间

    /// 一句进场用多久。
    public static func enterDuration(_ transition: ImmersiveKineticTransition) -> TimeInterval {
        switch transition {
        case .cascade: ImmersiveKineticLyricsPolicy.entranceSpread
        case .whipPan: 0.32
        case .rackFocus: 0.6
        case .crashZoom: 0.3
        case .iris: 0.42
        case .stepPrint: 0.9
        case .cubeFlip: 0.5
        case .flyThrough: 0.55
        case .spiral: 0.6
        case .shatter: 0.6
        }
    }

    /// 一句出场用多久。
    public static func exitDuration(_ transition: ImmersiveKineticTransition) -> TimeInterval {
        switch transition {
        case .cascade: ImmersiveKineticLyricsPolicy.exitDuration
        case .whipPan: 0.3
        case .rackFocus: 0.55
        case .crashZoom: 0.26
        case .iris: 0.36
        case .stepPrint: 0.7
        case .cubeFlip: 0.5
        case .flyThrough: 0.45
        case .spiral: 0.45
        case .shatter: ImmersiveKineticLyricsPolicy.scatterBurst + ImmersiveKineticLyricsPolicy.scatterJitter
        }
    }

    /// 整句开始进场的时刻：进场走完正好唱第一个字（急推和圈入圈出晚一点，让上一句先走开）。
    public static func enterStart(
        firstTokenStart: TimeInterval,
        transition: ImmersiveKineticTransition
    ) -> TimeInterval {
        switch transition {
        case .cascade:
            firstTokenStart - ImmersiveKineticLyricsPolicy.entranceLead
        case .crashZoom, .iris:
            firstTokenStart - enterDuration(transition) * 0.75
        case .whipPan, .rackFocus, .cubeFlip, .flyThrough, .spiral, .shatter:
            firstTokenStart - enterDuration(transition) * 0.9
        case .stepPrint:
            firstTokenStart - enterDuration(transition) * 0.6
        }
    }

    /// 这一句什么时候开始出场（镜头带着整句走时）：赶在下一句进场前走开——甩镜、焦点转移这类与下一句交叠一半，
    /// 立方体翻转两句同时转（同一个立方体），急推与圈入圈出等这一句走完才进下一句；不早于自己最后一个字唱完，除非下一句已经要进来了。隔得久时
    /// 唱完停一会儿先走；最后一句一直留着。
    public static func exitStart(
        lastTokenEnd: TimeInterval,
        nextEnterStart: TimeInterval?,
        transition: ImmersiveKineticTransition
    ) -> TimeInterval? {
        guard lastTokenEnd.isFinite, let nextEnterStart, nextEnterStart.isFinite else { return nil }
        if nextEnterStart - lastTokenEnd > ImmersiveKineticLyricsPolicy.gapThreshold {
            return lastTokenEnd + ImmersiveKineticLyricsPolicy.holdAfterLine
        }
        let overlap: Double = switch transition {
        case .cubeFlip: 0
        case .whipPan, .rackFocus, .stepPrint, .spiral: 0.5
        case .flyThrough, .shatter: 0.6
        case .cascade, .crashZoom, .iris: 1
        }
        let wanted = nextEnterStart - exitDuration(transition) * overlap
        return min(max(lastTokenEnd, wanted), nextEnterStart)
    }

    // MARK: - 整句此刻的样子

    /// 进场走到 `progress`（0…1）时整句的样子。`side` 是甩镜从哪边进来：1 从右往左甩，-1 从左往右。
    public static func entering(
        _ transition: ImmersiveKineticTransition,
        progress: Double,
        side: Double = 1
    ) -> ImmersiveKineticLineTransform {
        let p = clamp(progress)
        switch transition {
        case .cascade:
            return .identity
        case .whipPan:
            let travel = 1 - easeOutCubic(p)
            // 拖影跟速度走：缓出曲线一开始最快。
            return ImmersiveKineticLineTransform(
                offsetX: 1.15 * side * travel,
                opacity: smoothstep(p / 0.35),
                smear: min(1, 3 * (1 - p) * (1 - p))
            )
        case .rackFocus:
            let settle = easeOutCubic(p)
            return ImmersiveKineticLineTransform(
                scale: 1.18 - 0.18 * settle,
                blur: 0.55 * (1 - settle),
                opacity: smoothstep(p / 0.6)
            )
        case .crashZoom:
            let settle = easeOutExpo(p)
            return ImmersiveKineticLineTransform(
                scale: 2.6 - 1.6 * settle,
                blur: 0.35 * (1 - settle),
                opacity: smoothstep(p / 0.25)
            )
        case .iris:
            return ImmersiveKineticLineTransform(iris: easeInOutCubic(p))
        case .stepPrint:
            let stepped = stepPrintProgress(p)
            return ImmersiveKineticLineTransform(
                offsetX: 0.14 * side * (1 - easeOutCubic(stepped)),
                blur: 0.04 * (1 - stepped),
                opacity: smoothstep(stepped / 0.45),
                smear: 0.75 * (1 - stepped)
            )
        case .cubeFlip:
            // 从下面那一面翻上来：先背着光（暗一点），转正了才全亮。
            let turn = easeInOutCubic(p)
            return ImmersiveKineticLineTransform(
                opacity: smoothstep(p / 0.35),
                rotationX: -90 * (1 - turn),
                depth: cubeDepth
            )
        case .flyThrough:
            // 从纵深里冲过来，快到时稍稍冲过头再落回原位。
            let settle = easeOutBack(p)
            return ImmersiveKineticLineTransform(
                offsetY: -0.6 * (1 - easeOutCubic(p)),
                scale: 0.12 + 0.88 * settle,
                blur: 0.45 * (1 - easeOutCubic(p)),
                opacity: smoothstep(p / 0.4),
                rotationX: 38 * (1 - easeOutCubic(p))
            )
        case .spiral:
            let settle = easeOutCubic(p)
            return ImmersiveKineticLineTransform(
                scale: 0.3 + 0.7 * easeOutBack(p),
                blur: 0.3 * (1 - settle),
                opacity: smoothstep(p / 0.35),
                rotationY: 55 * side * (1 - settle),
                rotationZ: -42 * side * (1 - settle)
            )
        case .shatter:
            // 整句不动，字自己飞回来（`ImmersiveKineticLyricsPolicy` 的 scatter）。
            return .identity
        }
    }

    /// 立方体翻转时转轴在字后面多深（相对字号）。
    static let cubeDepth = 0.75

    /// 出场走到 `progress`（0…1）时整句的样子。`side` 与进场相同：1 时往左甩出去。
    public static func exiting(
        _ transition: ImmersiveKineticTransition,
        progress: Double,
        side: Double = 1
    ) -> ImmersiveKineticLineTransform {
        let p = clamp(progress)
        switch transition {
        case .cascade:
            return .identity
        case .whipPan:
            let travel = easeInCubic(p)
            // 缓入曲线越往后越快，拖影跟着越来越长。
            return ImmersiveKineticLineTransform(
                offsetX: -1.15 * side * travel,
                opacity: 1 - smoothstep((p - 0.55) / 0.45),
                smear: min(1, 3 * p * p)
            )
        case .rackFocus:
            // 往上、往远处退开，和从前景对焦进来的新句错开一层，两句不叠在同一处。
            let recede = easeInOutCubic(p)
            return ImmersiveKineticLineTransform(
                offsetY: -0.75 * recede,
                scale: 1 - 0.24 * recede,
                blur: 0.5 * recede,
                opacity: 1 - recede
            )
        case .crashZoom:
            let rush = easeInCubic(p)
            return ImmersiveKineticLineTransform(
                scale: 1 + 2.2 * rush,
                blur: 0.3 * rush,
                opacity: 1 - smoothstep(p / 0.8)
            )
        case .iris:
            return ImmersiveKineticLineTransform(iris: 1 - easeInOutCubic(p))
        case .stepPrint:
            let stepped = stepPrintProgress(p)
            return ImmersiveKineticLineTransform(
                offsetX: -0.14 * side * easeInCubic(stepped),
                blur: 0.04 * stepped,
                opacity: 1 - stepped,
                smear: 0.75 * stepped
            )
        case .cubeFlip:
            // 跟着立方体往上翻走，和翻上来的新句同时转。
            let turn = easeInOutCubic(p)
            return ImmersiveKineticLineTransform(
                opacity: 1 - smoothstep((p - 0.65) / 0.35),
                rotationX: 90 * turn,
                depth: cubeDepth
            )
        case .flyThrough:
            // 迎面掠过镜头：越来越快地放大，掠过时往下压、虚掉。
            let rush = easeInCubic(p)
            return ImmersiveKineticLineTransform(
                offsetY: 0.5 * rush,
                scale: 1 + 3.2 * rush,
                blur: 0.35 * rush,
                opacity: 1 - smoothstep((p - 0.35) / 0.65),
                rotationX: -22 * rush
            )
        case .spiral:
            let rush = easeInCubic(p)
            return ImmersiveKineticLineTransform(
                scale: 1 + 1.4 * rush,
                blur: 0.3 * rush,
                opacity: 1 - smoothstep((p - 0.4) / 0.6),
                rotationY: -50 * side * rush,
                rotationZ: 35 * side * rush
            )
        case .shatter:
            return .identity
        }
    }

    /// 抽帧那种一顿一顿的进度：每秒只走八下左右。
    static let stepPrintSteps = 7.0

    static func stepPrintProgress(_ progress: Double) -> Double {
        let p = clamp(progress)
        return p >= 1 ? 1 : floor(p * stepPrintSteps) / stepPrintSteps
    }

    // MARK: - 副歌

    /// 副歌里背景慢慢推近一点（歌词不动，背后的景往前靠），出副歌再慢慢放回。跟着 `climaxPush` 走：起步和收尾
    /// 都缓，副歌唱多久就推着多久。以前是进副歌那一下半秒内猛推 16% 再弹回、同时一道光从左扫到右，看着像画面
    /// 突然被拽了一下。返回背景的放大倍数。
    public static func backgroundZoom(climaxPush: Double) -> Double {
        1 + climaxZoom * smoothstep(climaxPush)
    }

    public static let climaxZoom = 0.06

    /// 副歌里画面一角亮起的暖光有多亮（0…1）：跟背景推近一起慢慢亮、慢慢灭，位置不动。
    public static func warmGlow(climaxPush: Double) -> Double {
        0.4 * smoothstep(climaxPush)
    }

    // MARK: - 曲线

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    static func smoothstep(_ value: Double) -> Double {
        let x = clamp(value)
        return x * x * (3 - 2 * x)
    }

    static func easeOutCubic(_ value: Double) -> Double {
        let inverse = 1 - clamp(value)
        return 1 - inverse * inverse * inverse
    }

    static func easeInCubic(_ value: Double) -> Double {
        let x = clamp(value)
        return x * x * x
    }

    static func easeInOutCubic(_ value: Double) -> Double {
        let x = clamp(value)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// 缓出、末尾稍稍冲过头再落回 1。
    static func easeOutBack(_ value: Double) -> Double {
        let x = clamp(value) - 1
        let overshoot = 1.4
        return 1 + (overshoot + 1) * x * x * x + overshoot * x * x
    }

    static func easeOutExpo(_ value: Double) -> Double {
        let x = clamp(value)
        return x >= 1 ? 1 : 1 - pow(2, -10 * x)
    }
}

// MARK: - 指挥：声音 → 场景里的动静

/// 一帧里场景要用的动静：都是 0…1，事件是最近几次落点（涟漪、冲击波），闪电单独限频。
public struct ImmersiveKineticDrive: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        /// 在画面里的位置，0…1，左上为原点。
        public var x: Double
        public var y: Double
        /// 发生的时刻（与 `update` 的 `time` 同一个时钟）。
        public var time: TimeInterval
        public var strength: Double

        public init(x: Double, y: Double, time: TimeInterval, strength: Double) {
            self.x = x
            self.y = y
            self.time = time
            self.strength = strength
        }
    }

    /// 整体有多热闹，按零点几秒平滑。
    public var energy: Double = 0
    public var bass: Double = 0
    /// 鼓点（没有频谱时是歌词的字头）那一下的包络：两三帧冲到顶再落回，管亮度。
    public var pulse: Double = 0
    /// 同一下鼓点更圆滑的版本：约 0.15 秒涨上去、0.25 秒落回。管位置、角度这类东西——直接跟 `pulse` 走会一帧跳过去。
    public var swell: Double = 0
    /// 镲片这类高频起音的包络。
    public var sparkle: Double = 0
    /// 这一刻在这首歌自己的响度范围里排在哪儿。
    public var intensity: Double = 0
    /// 正在这首歌的高潮段里。
    public var isClimax = false
    /// 这一次进高潮的时刻（与 `update` 的 `time` 同一个时钟）；不在高潮里时为 nil。
    public var climaxStart: TimeInterval?
    /// 进高潮的程度，0…1：`isClimax` 翻过去以后约一秒渐变到位，画面不会一下子换了速度、亮度。
    public var climaxLevel: Double = 0
    /// 更缓的那一份：两级平滑，起步和收尾都慢，约三秒到位。背景推近、暖光跟它走——大面积的变化起步一快就显得突兀。
    public var climaxPush: Double = 0
    /// 闪电的亮度包络（两下快闪再慢慢暗下去）；`flashSeed` 决定这一道劈在哪儿、什么形状。
    public var flash: Double = 0
    public var flashSeed: Double = 0
    /// 曲速隧道往前冲了多远：速度随能量变，按时间积分，速度变了画面也不会跳。
    public var travel: Double = 0
    /// `travel` 此刻每秒走多少：线条快到一帧跨过一大截时着色器按它拉出拖影。
    public var travelSpeed: Double = 0
    /// 流动时钟：雨、焦散、星轨这类「越热闹走得越快」的东西用它，不用时间乘速度（速度一变相位就跳）。
    public var flow: Double = 0
    /// 最近的落点，最新的在后面，最多 `ImmersiveKineticConductor.eventCapacity` 个。
    public var events: [Event] = []
    /// 这一帧有没有读到频谱；没有时动静来自歌词的字头。
    public var hasSpectrum = false
    /// 这一帧听到的起音（鼓点或人声那一段），0 是没有。只在跟着频谱时有：逐行歌词用它定每个字什么时候亮。
    public var onset: Double = 0

    public init() {}
}

/// 把频谱（或者没有频谱时歌词的字头）变成场景里的动静。确定性：同一个种子、同样的输入得到同样的落点。
public struct ImmersiveKineticConductor: Sendable {
    public static let eventCapacity = 8
    /// 一个落点留多久（涟漪散尽、冲击波出画）。
    public static let eventLifetime: TimeInterval = 4
    /// 两道闪电至少隔多久：上一道差不多熄了才劈下一道，不然上一道还亮着就跳到别处。
    public static let minimumFlashInterval: TimeInterval = 0.7
    /// 两个落点至少隔多久：`eventCapacity` 个落点正好撑满 `eventLifetime`，挤掉的那个已经散尽，不会凭空消失。
    public static let minimumEventInterval: TimeInterval = eventLifetime / Double(eventCapacity)
    /// 频谱有了多久才改跟频谱、没了多久才改跟歌词：安静段落里频谱时有时无，来回切换会让画面一跳一跳。
    public static let spectrumAttach: TimeInterval = 0.3
    public static let spectrumRelease: TimeInterval = 1.5
    /// 鼓点多重才劈闪电、才落一个点。
    public static let flashThreshold = 0.55
    public static let eventThreshold = 0.3
    /// 进高潮：响度排位持续高于 `climaxEnter` 这么久；出高潮：持续低于 `climaxExit` 这么久。
    public static let climaxEnter = 0.72
    public static let climaxExit = 0.5
    public static let climaxEnterHold: TimeInterval = 1.5
    public static let climaxExitHold: TimeInterval = 2.5
    /// 没有频谱时整体热闹程度的底子。
    public static let lyricDrivenEnergy = 0.35

    private var random: ImmersiveRandom
    private var tracker = ImmersiveBeatTracker()
    private var drive = ImmersiveKineticDrive()
    private var lastTime: TimeInterval?
    private var lastPlaybackTime: TimeInterval?
    private var lastFlash = -Double.infinity
    private var flashStart = -Double.infinity
    private var aboveSince: TimeInterval?
    private var belowSince: TimeInterval?
    private var lyricPulse = 0.0
    private var lastEvent = -Double.infinity
    private var climaxPushStage = 0.0
    private var followsSpectrum = false
    private var spectrumSince: TimeInterval?
    private var silentSince: TimeInterval?

    public init(seed: UInt64) {
        random = ImmersiveRandom(seed: seed)
    }

    /// 换歌时接着上一首的动静：里程、流动时钟、还没散的落点照旧，背景淡入淡出时旧场景不会突然跳回起点。
    public init(seed: UInt64, continuing previous: ImmersiveKineticDrive, at time: TimeInterval) {
        self.init(seed: seed)
        drive.travel = previous.travel
        drive.flow = previous.flow
        drive.energy = previous.energy
        drive.events = previous.events
        lastEvent = previous.events.last?.time ?? -Double.infinity
        lastTime = time
        // 上一首一直读得到频谱，这一首开头不必再等一会儿才认。
        followsSpectrum = previous.hasSpectrum
        drive.hasSpectrum = previous.hasSpectrum
    }

    /// 走一帧。`levels` 为空或几乎无声（Apple Music、电台读不到频谱）时，`playbackTime` 越过 `lyricOnsets`
    /// 里哪个字头，就当那里有一下鼓点。`time` 是动画时钟，事件与闪电都记在它上面。
    public mutating func update(
        levels: [Double],
        lyricOnsets: [TimeInterval],
        playbackTime: TimeInterval?,
        at time: TimeInterval
    ) -> ImmersiveKineticDrive {
        let dt = lastTime.map { min(max(time - $0, 0), 0.25) } ?? 0
        lastTime = time
        let features = tracker.update(levels: levels, at: time)
        let hasSpectrum = updateSpectrumPresence(features.energy > 0.02, at: time)
        drive.hasSpectrum = hasSpectrum

        var hit = 0.0
        var accent = 0.0
        var pulseTarget: Double
        if hasSpectrum {
            drive.energy = follow(drive.energy, toward: min(features.energy * 2.2, 1), dt: dt, halfLife: 0.25)
            drive.bass = follow(drive.bass, toward: features.bass, dt: dt, halfLife: 0.08)
            pulseTarget = features.pulse
            drive.sparkle = follow(drive.sparkle, toward: features.onsets[2], dt: dt, halfLife: 0.12)
            drive.intensity = follow(drive.intensity, toward: features.intensity, dt: dt, halfLife: 0.3)
            hit = features.beat
            accent = features.onsets[1]
            drive.onset = max(hit, accent)
        } else {
            drive.onset = 0
            let crossed = crossedOnsets(lyricOnsets, playbackTime: playbackTime)
            lyricPulse *= pow(0.5, dt / 0.18)
            if crossed > 0 {
                lyricPulse = 1
                hit = 0.62
            }
            drive.energy = follow(drive.energy, toward: Self.lyricDrivenEnergy + 0.25 * lyricPulse, dt: dt, halfLife: 0.4)
            drive.bass = follow(drive.bass, toward: 0.3 * lyricPulse, dt: dt, halfLife: 0.08)
            pulseTarget = lyricPulse
            drive.sparkle = follow(drive.sparkle, toward: 0, dt: dt, halfLife: 0.12)
            drive.intensity = follow(drive.intensity, toward: 0.5, dt: dt, halfLife: 0.3)
        }
        lastPlaybackTime = playbackTime
        // 涨的时候两三帧冲上去（不是一帧从 0 跳到 1，那是频闪），落的时候跟着包络。
        drive.pulse = pulseTarget > drive.pulse
            ? follow(drive.pulse, toward: pulseTarget, dt: dt, halfLife: 0.02)
            : pulseTarget
        drive.swell = follow(
            drive.swell,
            toward: drive.pulse,
            dt: dt,
            halfLife: drive.pulse > drive.swell ? 0.06 : 0.25
        )

        if hit >= Self.eventThreshold {
            addEvent(strength: hit, at: time)
        } else if accent >= 0.6 {
            addEvent(strength: accent * 0.6, at: time)
        }
        if hit >= Self.flashThreshold, time - lastFlash >= Self.minimumFlashInterval {
            lastFlash = time
            flashStart = time
            drive.flashSeed = random.unit()
        }
        drive.flash = Self.flashEnvelope(age: time - flashStart)
        updateClimax(at: time)
        drive.climaxLevel = follow(drive.climaxLevel, toward: drive.isClimax ? 1 : 0, dt: dt, halfLife: 0.35)
        climaxPushStage = follow(climaxPushStage, toward: drive.isClimax ? 1 : 0, dt: dt, halfLife: 0.5)
        drive.climaxPush = follow(drive.climaxPush, toward: climaxPushStage, dt: dt, halfLife: 0.5)
        drive.travelSpeed = 0.25 + 1.4 * drive.energy + 1.2 * drive.swell + 0.5 * drive.climaxLevel
        drive.travel += dt * drive.travelSpeed
        drive.flow += dt * (0.55 + 0.9 * drive.energy + 0.35 * drive.climaxLevel)
        drive.events.removeAll { time - $0.time > Self.eventLifetime }
        return drive
    }

    /// 带迟滞的「此刻有没有频谱」：有了 `spectrumAttach` 才算有，没了 `spectrumRelease` 才算没有。
    private mutating func updateSpectrumPresence(_ audible: Bool, at time: TimeInterval) -> Bool {
        if audible {
            silentSince = nil
            spectrumSince = spectrumSince ?? time
            if !followsSpectrum, let since = spectrumSince, time - since >= Self.spectrumAttach {
                followsSpectrum = true
            }
        } else {
            spectrumSince = nil
            silentSince = silentSince ?? time
            if followsSpectrum, let since = silentSince, time - since >= Self.spectrumRelease {
                followsSpectrum = false
            }
        }
        return followsSpectrum
    }

    /// 闪电的亮度：一下全亮、暗一下、再亮一下，然后慢慢熄。
    public static func flashEnvelope(age: TimeInterval) -> Double {
        guard age >= 0, age.isFinite else { return 0 }
        switch age {
        case ..<0.06: return 1
        case ..<0.12: return 0.35
        case ..<0.18: return 0.8
        default: return 0.8 * exp(-(age - 0.18) * 7)
        }
    }

    private mutating func addEvent(strength: Double, at time: TimeInterval) {
        guard time - lastEvent >= Self.minimumEventInterval else { return }
        lastEvent = time
        let event = ImmersiveKineticDrive.Event(
            x: 0.12 + 0.76 * random.unit(),
            y: 0.18 + 0.66 * random.unit(),
            time: time,
            strength: min(max(strength, 0), 1)
        )
        drive.events.append(event)
        if drive.events.count > Self.eventCapacity {
            drive.events.removeFirst(drive.events.count - Self.eventCapacity)
        }
    }

    /// 上一帧到这一帧之间播放进度越过了几个字头。往回拖、跳太远（切歌、拖进度）不算。
    private func crossedOnsets(_ onsets: [TimeInterval], playbackTime: TimeInterval?) -> Int {
        guard let playbackTime, let lastPlaybackTime,
              playbackTime > lastPlaybackTime, playbackTime - lastPlaybackTime < 0.5 else { return 0 }
        return onsets.filter { $0 > lastPlaybackTime && $0 <= playbackTime }.count
    }

    private mutating func updateClimax(at time: TimeInterval) {
        guard drive.hasSpectrum else {
            drive.isClimax = false
            drive.climaxStart = nil
            aboveSince = nil
            belowSince = nil
            return
        }
        if drive.intensity >= Self.climaxEnter {
            aboveSince = aboveSince ?? time
        } else {
            aboveSince = nil
        }
        if drive.intensity < Self.climaxExit {
            belowSince = belowSince ?? time
        } else {
            belowSince = nil
        }
        if !drive.isClimax, let aboveSince, time - aboveSince >= Self.climaxEnterHold {
            drive.isClimax = true
            drive.climaxStart = time
        } else if drive.isClimax, let belowSince, time - belowSince >= Self.climaxExitHold {
            drive.isClimax = false
            drive.climaxStart = nil
        }
    }

    private func follow(_ value: Double, toward target: Double, dt: TimeInterval, halfLife: TimeInterval) -> Double {
        guard dt > 0 else { return target }
        let keep = pow(0.5, dt / halfLife)
        return target + (value - target) * keep
    }
}
