import CoreGraphics
import Foundation
import PrimuseKit
import SwiftUI

// 「水彩小剧场」的世界坐标、三种镜头的布景与配色，以及换镜头时在后台用 CoreGraphics 画好的水彩背景。
//
// 世界坐标照网页原型：横画面宽 1600 个单位，竖画面宽 900（站位往中间收），高按视口比例；角色的大小在世界里
// 固定（主唱约 365 个单位高），布景的位置跟着地平线和画面宽度走。背景只在换镜头时画一次（水彩一层层叠、
// 边缘积色、阴影排线），之后每帧只按镜头挪动、缩放这一张图。

// MARK: - 颜色

struct ImmersiveTheaterRGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    init(hex: UInt32) {
        self.init(
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    /// 色相 0…360、饱和度与亮度 0…1。
    static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> ImmersiveTheaterRGB {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let s = min(max(saturation, 0), 1)
        let l = min(max(lightness, 0), 1)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let rgb: (Double, Double, Double)
        switch h {
        case ..<60: rgb = (chroma, x, 0)
        case ..<120: rgb = (x, chroma, 0)
        case ..<180: rgb = (0, chroma, x)
        case ..<240: rgb = (0, x, chroma)
        case ..<300: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        return ImmersiveTheaterRGB(rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

    var hue: Double { hslComponents.hue }
    var saturation: Double { hslComponents.saturation }

    private var hslComponents: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2
        guard maximum > minimum else { return (0, 0, lightness) }
        let delta = maximum - minimum
        let saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        var hue: Double
        if maximum == r {
            hue = (g - b) / delta + (g < b ? 6 : 0)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        return (hue, saturation, lightness)
    }

    func mixed(with other: ImmersiveTheaterRGB, _ amount: Double) -> ImmersiveTheaterRGB {
        ImmersiveTheaterRGB(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(min(max(alpha, 0), 1)))
    }

    /// 缓存键里用：两位十六进制一个通道。
    var key: String {
        String(format: "%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// 按最短的那一段在色相环上混合。
    static func mixHue(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        let delta = ((to - from + 540).truncatingRemainder(dividingBy: 360)) - 180
        return (from + delta * amount + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension ImmersiveTheaterRGB {
    /// 从 SwiftUI 的颜色取 sRGB 分量（封面取色给的是 `Color`）。
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }
}

/// 一个镜头的配色：从封面的主色、辅色派生（照原型 `scenePalette`）。
struct ImmersiveTheaterScenePalette: Equatable, Sendable {
    var paper = ImmersiveTheaterRGB(hex: 0xEFE8DA)
    var skyTop = ImmersiveTheaterRGB(hex: 0x202840)
    var skyLow = ImmersiveTheaterRGB(hex: 0x404870)
    var ink = ImmersiveTheaterRGB(hex: 0x10121B)
    var shadow = ImmersiveTheaterRGB(hex: 0x070912)
    var light = ImmersiveTheaterRGB(hex: 0xFFE0C0)
    /// 歌词与歌名的字色、垫在下面那条水彩带的颜色和浓淡。
    var lyric = ImmersiveTheaterRGB(hex: 0xF8F1E3)
    var lyricWash = ImmersiveTheaterRGB(hex: 0x0A0C1A)
    var lyricWashAlpha = 0.42
    /// 盖在角色身上的一层场景光。
    var tint = ImmersiveTheaterRGB(hex: 0x1B2347)
    var tintAlpha = 0.2
    var accents: [ImmersiveTheaterRGB] = []
    // 夜空
    var glow = ImmersiveTheaterRGB(hex: 0xF0C080)
    var moon = ImmersiveTheaterRGB(hex: 0xF8F0D0)
    var crater = ImmersiveTheaterRGB(hex: 0xC8B890)
    var cloud = ImmersiveTheaterRGB(hex: 0x606880)
    var hillFar = ImmersiveTheaterRGB(hex: 0x303850)
    var hillNear = ImmersiveTheaterRGB(hex: 0x203038)
    var ground = ImmersiveTheaterRGB(hex: 0x181C28)
    var star = ImmersiveTheaterRGB(hex: 0xFFF0B0)
    // 雨夜
    var back = ImmersiveTheaterRGB(hex: 0x3A4050)
    var front = ImmersiveTheaterRGB(hex: 0x252A36)
    var street = ImmersiveTheaterRGB(hex: 0x2A2F3C)
    var puddle = ImmersiveTheaterRGB(hex: 0x507090)
    var lampPost = ImmersiveTheaterRGB(hex: 0x1D1F29)
    var lamp = ImmersiveTheaterRGB(hex: 0xFFD080)
    var window = ImmersiveTheaterRGB(hex: 0xF0C060)
    var mist = ImmersiveTheaterRGB(hex: 0x808890)
    var rain = ImmersiveTheaterRGB(hex: 0xCDDCF0)
    // 花田
    var sun = ImmersiveTheaterRGB(hex: 0xF0A040)
    var halo = ImmersiveTheaterRGB(hex: 0xF8D090)
    var hillMid = ImmersiveTheaterRGB(hex: 0x6A9A50)
    var field = ImmersiveTheaterRGB(hex: 0x70A040)
    var flowers: [ImmersiveTheaterRGB] = []

    init(template: ImmersiveTheaterTemplate, primary c1: ImmersiveTheaterRGB, secondary c2: ImmersiveTheaterRGB) {
        typealias RGB = ImmersiveTheaterRGB
        let h1 = c1.hue
        let h2 = c2.hue
        let saturation = min(max(c1.saturation, 0.35), 0.9)
        switch template {
        case .night:
            paper = RGB(hex: 0xEFE8DA)
            skyTop = .hsl(RGB.mixHue(h2, 228, 0.78), 0.45, 0.16)
            skyLow = .hsl(RGB.mixHue(h2, 252, 0.55), 0.38, 0.34)
            glow = .hsl(h1, 0.7, 0.72)
            moon = .hsl(RGB.mixHue(h1, 50, 0.55), 0.65, 0.86)
            crater = .hsl(RGB.mixHue(h1, 40, 0.5), 0.35, 0.7)
            cloud = .hsl(RGB.mixHue(h2, 235, 0.6), 0.25, 0.46)
            hillFar = .hsl(RGB.mixHue(h2, 238, 0.65), 0.3, 0.27)
            hillNear = .hsl(RGB.mixHue(h1, 205, 0.7), 0.24, 0.19)
            ground = .hsl(RGB.mixHue(h2, 242, 0.6), 0.22, 0.14)
            ink = RGB(hex: 0x10121B)
            star = .hsl(RGB.mixHue(h1, 55, 0.5), 0.85, 0.86)
            tint = .hsl(232, 0.55, 0.22)
            tintAlpha = 0.2
            shadow = RGB(hex: 0x070912)
            light = .hsl(h1, 0.75, 0.8)
            lyric = RGB(hex: 0xF8F1E3)
            lyricWash = RGB(hex: 0x0A0C1A)
            lyricWashAlpha = 0.42
            accents = [c1, c2, .hsl(h1 + 40, 0.7, 0.7), RGB(hex: 0xF4F0FF)]
        case .rain:
            paper = RGB(hex: 0xEBE7DF)
            skyTop = .hsl(RGB.mixHue(h2, 215, 0.85), 0.24, 0.2)
            skyLow = .hsl(RGB.mixHue(h2, 220, 0.75), 0.2, 0.36)
            back = .hsl(RGB.mixHue(h2, 222, 0.7), 0.18, 0.3)
            front = .hsl(RGB.mixHue(h2, 225, 0.7), 0.2, 0.18)
            street = .hsl(222, 0.18, 0.2)
            puddle = .hsl(RGB.mixHue(h1, 210, 0.4), 0.35, 0.42)
            lampPost = RGB(hex: 0x1D1F29)
            lamp = .hsl(h1, 0.95, 0.72)
            window = .hsl(RGB.mixHue(h1, 45, 0.4), 0.85, 0.68)
            mist = .hsl(220, 0.15, 0.55)
            ink = RGB(hex: 0x0E1018)
            tint = .hsl(220, 0.45, 0.25)
            tintAlpha = 0.2
            shadow = RGB(hex: 0x05070D)
            rain = RGB(hex: 0xCDDCF0)
            light = .hsl(h1, 0.9, 0.75)
            lyric = RGB(hex: 0xF3EFE6)
            lyricWash = RGB(hex: 0x080A14)
            lyricWashAlpha = 0.45
            accents = [c1, c2, .hsl(h1, 0.9, 0.7), RGB(hex: 0xBFE3FF)]
        case .flower:
            paper = RGB(hex: 0xF4EEDF)
            skyTop = .hsl(RGB.mixHue(h2, 205, 0.55), 0.55, 0.78)
            skyLow = .hsl(RGB.mixHue(h2, 45, 0.5), 0.75, 0.86)
            sun = .hsl(RGB.mixHue(h1, 40, 0.45), 0.9, 0.62)
            halo = .hsl(RGB.mixHue(h1, 45, 0.5), 0.9, 0.78)
            cloud = RGB(hex: 0xFBF6EC)
            hillFar = .hsl(RGB.mixHue(h1, 140, 0.72), 0.32, 0.6)
            hillMid = .hsl(RGB.mixHue(h1, 100, 0.75), 0.42, 0.5)
            field = .hsl(RGB.mixHue(h1, 85, 0.75), 0.48, 0.47)
            flowers = [c1, c2, .hsl(h1 + 150, saturation * 0.8, 0.62), RGB(hex: 0xFFFAF0)]
            ink = RGB(hex: 0x1B1712)
            tint = .hsl(40, 0.9, 0.7)
            tintAlpha = 0.08
            shadow = RGB(hex: 0x3A2A14)
            light = .hsl(h1, 0.9, 0.82)
            lyric = RGB(hex: 0x1F1A14)
            lyricWash = RGB(hex: 0xFFFAEC)
            lyricWashAlpha = 0.55
            accents = [c1, c2, .hsl(h1 + 150, 0.7, 0.62), .hsl(h2 + 40, 0.8, 0.7)]
        }
        if flowers.isEmpty { flowers = accents }
    }

    func accent(_ index: Int) -> ImmersiveTheaterRGB {
        guard !accents.isEmpty else { return light }
        return accents[((index % accents.count) + accents.count) % accents.count]
    }
}

// MARK: - 世界

/// 舞台的世界坐标：宽度固定（横 1600、竖 900），高度按视口比例；`floor` 是主唱的脚底。
struct ImmersiveTheaterWorld: Equatable, Sendable {
    /// 角色母版（1600 单位）到世界的缩放：主唱、两侧、后排。
    static let leadScale = 0.27
    static let sideScale = 0.212
    static let backScale = 0.17
    /// 主唱从脚底到头顶的高度（世界单位）。
    static let leadHeight = 1350 * leadScale

    let width: Double
    let height: Double
    let floor: Double
    /// 两侧角色离中间多远。
    let spread: Double

    init(width: Double, height: Double, floor: Double, spread: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.floor = floor
        self.spread = spread
    }

    /// 按视口算世界：先让世界宽度铺满视口，再保证主唱从脚底到头顶放得下（放不下就把世界放宽，等于把镜头拉远）。
    /// `floorY` 是脚底在视口里的位置，`topY` 是头顶上面要留出来的位置（歌名那一块）。
    static func fitting(size: CGSize, floorY: Double, topY: Double) -> ImmersiveTheaterWorld {
        let viewWidth = max(Double(size.width), 1)
        let viewHeight = max(Double(size.height), 1)
        let portrait = viewHeight > viewWidth * 1.05
        var width = portrait ? 900.0 : 1600.0
        var scale = viewWidth / width
        let room = max(floorY - topY, 40)
        let largest = room / (leadHeight * 1.2)
        if scale > largest {
            scale = largest
            width = viewWidth / scale
        }
        return ImmersiveTheaterWorld(
            width: width,
            height: viewHeight / scale,
            floor: floorY / scale,
            spread: portrait ? 300 : 405
        )
    }

    var centerX: Double { width / 2 }
    /// 世界到视口的缩放。
    func scale(for size: CGSize) -> Double { Double(size.width) / width }

    /// 地面那条线（原型 760）、远近山脊、雨夜的地平线。
    var ground: Double { floor - 62 }
    var horizon: Double { floor - 122 }
    var nearRidge: Double { floor - 172 }
    var farRidge: Double { floor - 282 }

    /// 背景比画面大一圈，镜头推、摇时不露边。
    var backdropRect: CGRect {
        CGRect(x: -0.1 * width, y: -0.1 * height, width: 1.2 * width, height: 1.2 * height)
    }

    /// 站位：脚底在世界里的位置和角色的缩放。
    func position(of slot: ImmersiveTheaterSlot) -> (x: Double, y: Double, scale: Double) {
        switch slot {
        case .lead: (centerX, floor, Self.leadScale)
        case .left: (centerX - spread, floor - 24, Self.sideScale)
        case .right: (centerX + spread, floor - 24, Self.sideScale)
        case .back: (centerX + spread * 0.52, floor - 70, Self.backScale)
        }
    }

    /// 缓存键：取整到 10 个单位，同一种视口不会因为一点点差别重画背景。
    var key: String {
        "\(Int((width / 10).rounded()))x\(Int((height / 10).rounded()))f\(Int((floor / 10).rounded()))"
    }
}

// MARK: - 布景

struct ImmersiveTheaterStar: Sendable {
    var x: Double
    var y: Double
    var size: Double
    var phase: Double
    var sparkles: Bool
}

struct ImmersiveTheaterBuilding: Sendable {
    var x: Double
    var width: Double
    var height: Double
    var isBack: Bool
}

struct ImmersiveTheaterEllipse: Sendable {
    var x: Double
    var y: Double
    var rx: Double
    var ry: Double
}

struct ImmersiveTheaterFlower: Sendable {
    var x: Double
    var y: Double
    var size: Double
    var color: Int
    var rotation: Double
    var phase: Double
}

/// 一个镜头的布景（世界坐标），按场景、变体和种子算一次。
struct ImmersiveTheaterSceneLayout: Sendable {
    let template: ImmersiveTheaterTemplate
    let world: ImmersiveTheaterWorld
    /// 月亮或太阳（x、y、半径）；雨夜没有。
    var orb: (x: Double, y: Double, radius: Double)?
    var stars: [ImmersiveTheaterStar] = []
    var farRidge: [CGPoint] = []
    var nearRidge: [CGPoint] = []
    var groundRidge: [CGPoint] = []
    var clouds: [ImmersiveTheaterEllipse] = []
    var buildings: [ImmersiveTheaterBuilding] = []
    var windows: [CGRect] = []
    var windowIsBack: [Bool] = []
    var puddles: [ImmersiveTheaterEllipse] = []
    var lamp: (x: Double, top: Double, base: Double)?
    var flowers: [ImmersiveTheaterFlower] = []
    var frontFlowers: [ImmersiveTheaterFlower] = []

    init(template: ImmersiveTheaterTemplate, variant: Int, seed: UInt64, world: ImmersiveTheaterWorld) {
        self.template = template
        self.world = world
        var random = ImmersiveRandom(seed: seed ^ ImmersiveRandom.seed(for: "\(template.rawValue):\(variant)"))
        func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * random.unit() }
        let side: Double = random.unit() < 0.5 ? -1 : 1
        let rect = world.backdropRect
        let left = Double(rect.minX)
        let right = Double(rect.maxX)
        let unit = world.width / 1600
        switch template {
        case .night:
            let horizon = world.nearRidge
            orb = (
                world.centerX + side * range(300, 560) * max(unit, 0.6),
                horizon * range(0.2, 0.36),
                range(72, 96)
            )
            let skyArea = world.width * max(horizon, 1)
            let target = Int(min(max(36 * skyArea / (1600 * 650), 24), 48))
            var attempts = 0
            while stars.count < target, attempts < target * 2 {
                attempts += 1
                let star = ImmersiveTheaterStar(
                    x: range(left, right),
                    y: range(Double(rect.minY), horizon - 150),
                    size: range(0.6, 1.4),
                    phase: random.unit(),
                    sparkles: random.unit() >= 0.3
                )
                if let orb, hypot(star.x - orb.x, star.y - orb.y) <= orb.radius * 2.4 { continue }
                stars.append(star)
            }
            let farWaves = 3 + random.unit() * 2
            farRidge = Self.ridge(base: world.farRidge, amplitude: 70, waves: farWaves,
                                  from: left, to: right, width: world.width, random: &random)
            let nearWaves = 4 + random.unit() * 2
            nearRidge = Self.ridge(base: world.nearRidge, amplitude: 40, waves: nearWaves,
                                   from: left, to: right, width: world.width, random: &random)
            groundRidge = Self.ridge(base: world.ground, amplitude: 14, waves: 5,
                                     from: left, to: right, width: world.width, random: &random)
            let cloudCount = 2 + (random.unit() < 0.5 ? 1 : 0)
            for _ in 0..<cloudCount {
                clouds.append(ImmersiveTheaterEllipse(
                    x: range(-60, world.width + 60), y: horizon * range(0.09, 0.55),
                    rx: range(160, 280), ry: range(34, 56)
                ))
            }
        case .rain:
            let horizon = world.horizon
            lamp = (world.centerX + side * range(430, 620) * max(unit, 0.6), horizon - 400, world.floor - 32)
            var x = left - 20
            while x < right {
                let width = range(90, 190)
                buildings.append(ImmersiveTheaterBuilding(x: x, width: width, height: range(160, 380), isBack: random.unit() < 0.5))
                x += width * range(0.75, 1.0)
            }
            let fronts = buildings.filter { !$0.isBack }
            for building in buildings {
                let height = building.isBack ? building.height * 1.15 : building.height * 0.8
                var row = horizon - height + 22
                while row < horizon - 24 {
                    var column = building.x + 14
                    while column < building.x + building.width - 22 {
                        defer { column += 26 }
                        guard random.unit() <= 0.3 else { continue }
                        if building.isBack, fronts.contains(where: { front in
                            column > front.x && column < front.x + front.width && row > horizon - front.height * 0.8
                        }) {
                            continue
                        }
                        windows.append(CGRect(x: column, y: row, width: 10, height: 14))
                        windowIsBack.append(building.isBack)
                    }
                    row += 30
                }
            }
            for _ in 0..<4 {
                puddles.append(ImmersiveTheaterEllipse(
                    x: range(80, world.width - 80), y: range(world.floor - 22, world.floor + 128),
                    rx: range(70, 150), ry: range(12, 22)
                ))
            }
        case .flower:
            let horizon = world.nearRidge
            orb = (
                world.centerX + side * range(320, 560) * max(unit, 0.6),
                horizon * range(0.18, 0.34),
                range(80, 104)
            )
            let farWaves = 2.5 + random.unit() * 1.5
            farRidge = Self.ridge(base: world.floor - 262, amplitude: 60, waves: farWaves,
                                  from: left, to: right, width: world.width, random: &random)
            let nearWaves = 3.5 + random.unit() * 2
            nearRidge = Self.ridge(base: world.nearRidge, amplitude: 35, waves: nearWaves,
                                   from: left, to: right, width: world.width, random: &random)
            groundRidge = Self.ridge(base: world.horizon, amplitude: 16, waves: 4,
                                     from: left, to: right, width: world.width, random: &random)
            for _ in 0..<2 {
                clouds.append(ImmersiveTheaterEllipse(
                    x: range(-60, world.width + 60), y: horizon * range(0.09, 0.46),
                    rx: range(170, 300), ry: range(36, 60)
                ))
            }
            let flowerCount = Int(170 * max(world.width / 1600, 0.6))
            for _ in 0..<flowerCount {
                let y = range(world.floor - 132, world.floor + 168)
                let depth = (y - (world.floor - 132)) / 300
                flowers.append(ImmersiveTheaterFlower(
                    x: range(left, right), y: y, size: 6 + depth * 16,
                    color: Int(random.unit() * 4) % 4, rotation: random.unit() * 2 * Double.pi, phase: 0
                ))
            }
            let frontCount = max(8, Int(14 * world.width / 1600))
            for _ in 0..<frontCount {
                frontFlowers.append(ImmersiveTheaterFlower(
                    x: range(-60, world.width + 60), y: range(world.floor + 58, world.floor + 138), size: range(24, 40),
                    color: Int(random.unit() * 4) % 4, rotation: 0, phase: random.unit()
                ))
            }
        }
    }

    /// 起伏的山脊：两个正弦叠起来，每 `width / 40` 一个点。
    static func ridge(
        base: Double,
        amplitude: Double,
        waves: Double,
        from left: Double,
        to right: Double,
        width: Double,
        random: inout ImmersiveRandom
    ) -> [CGPoint] {
        let phaseA = random.unit() * 10
        let phaseB = random.unit() * 10
        let step = max(width / 40, 10)
        var points: [CGPoint] = []
        var x = left - step
        while x <= right + step {
            let u = x / width
            let wave: Double = 0.62 * sin(u * waves * Double.pi + phaseA) + 0.38 * sin(u * waves * 2 * Double.pi * 1.15 + phaseB)
            points.append(CGPoint(x: x, y: base - amplitude * wave))
            x += step
        }
        return points
    }

    /// 山脊往下封到 `bottom` 的多边形。
    static func closed(_ ridge: [CGPoint], bottom: Double) -> [CGPoint] {
        guard let first = ridge.first, let last = ridge.last else { return [] }
        return ridge + [CGPoint(x: last.x, y: bottom), CGPoint(x: first.x, y: bottom)]
    }

    /// 前排楼顶连成的天际线（雨夜的墨线用）。
    var frontSkyline: [CGPoint] {
        var points: [CGPoint] = []
        for building in buildings.filter({ !$0.isBack }).sorted(by: { $0.x < $1.x }) {
            let top = world.horizon - building.height * 0.8
            points.append(CGPoint(x: building.x, y: top))
            points.append(CGPoint(x: building.x + building.width, y: top))
        }
        return points
    }
}

// MARK: - 背景图

struct ImmersiveTheaterBackdropSpec: Equatable, Sendable {
    var template: ImmersiveTheaterTemplate
    var variant: Int
    var seed: UInt64
    var world: ImmersiveTheaterWorld
    var primary: ImmersiveTheaterRGB
    var secondary: ImmersiveTheaterRGB
    /// 背景图横向多少像素。
    var pixelWidth: Int

    var key: String {
        "\(template.rawValue)|\(variant)|\(seed)|\(world.key)|\(primary.key)\(secondary.key)|\(pixelWidth)"
    }
}

/// 画好的一张背景，连同它的布景和配色（逐帧的墨线、光晕照这份画）。
final class ImmersiveTheaterBackdrop: @unchecked Sendable {
    let key: String
    let image: CGImage
    let layout: ImmersiveTheaterSceneLayout
    let palette: ImmersiveTheaterScenePalette
    /// 图在世界坐标里铺的范围。
    let rect: CGRect

    init(key: String, image: CGImage, layout: ImmersiveTheaterSceneLayout, palette: ImmersiveTheaterScenePalette, rect: CGRect) {
        self.key = key
        self.image = image
        self.layout = layout
        self.palette = palette
        self.rect = rect
    }
}

/// 最近几张背景：换镜头时先看有没有画好的，没有就在后台画；同一张同时只画一次。
@MainActor
enum ImmersiveTheaterBackdropCache {
    private static var entries: [ImmersiveTheaterBackdrop] = []
    private static var inFlight: [String: Task<ImmersiveTheaterBackdrop?, Never>] = [:]
    static let capacity = 4

    static func cached(_ spec: ImmersiveTheaterBackdropSpec) -> ImmersiveTheaterBackdrop? {
        let key = spec.key
        return entries.first { $0.key == key }
    }

    static func paint(_ spec: ImmersiveTheaterBackdropSpec) async -> ImmersiveTheaterBackdrop? {
        if let hit = cached(spec) { return hit }
        let key = spec.key
        let task: Task<ImmersiveTheaterBackdrop?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                ImmersiveTheaterBackdropPainter.paint(spec)
            }
            inFlight[key] = task
        }
        let value = await task.value
        inFlight[key] = nil
        if let hit = cached(spec) { return hit }
        if let value {
            entries.insert(value, at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        }
        return value
    }
}

/// 用 CoreGraphics 画水彩背景：天空渐变打底，云、山、楼、街、花田一块块晕上去，
/// 每块颜料是几十层轻轻变形的半透明填充（中间叠得浓、边上晕开，边缘积一圈深色），近处的山加铅笔排线，
/// 最后把亮的东西（月亮、窗、路灯、花）留白一样点在上面。
enum ImmersiveTheaterBackdropPainter {
    static func paint(_ spec: ImmersiveTheaterBackdropSpec) -> ImmersiveTheaterBackdrop? {
        let world = spec.world
        let rect = world.backdropRect
        let pixelWidth = max(spec.pixelWidth, 64)
        let pixelsPerUnit = Double(pixelWidth) / Double(rect.width)
        let pixelHeight = max(Int((Double(rect.height) * pixelsPerUnit).rounded()), 64)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // 换成世界坐标：y 朝下，原点在背景范围的左上角。
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(pixelsPerUnit), y: -CGFloat(pixelsPerUnit))
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let layout = ImmersiveTheaterSceneLayout(
            template: spec.template,
            variant: spec.variant,
            seed: spec.seed,
            world: world
        )
        let palette = ImmersiveTheaterScenePalette(
            template: spec.template,
            primary: spec.primary,
            secondary: spec.secondary
        )
        var random = ImmersiveRandom(seed: spec.seed ^ ImmersiveRandom.seed(for: spec.key))
        let painter = Brush(context: context, pixelsPerUnit: pixelsPerUnit)

        context.setFillColor(palette.paper.cgColor())
        context.fill(rect)
        switch spec.template {
        case .night: paintNight(layout, palette, painter, rect: rect, random: &random)
        case .rain: paintRain(layout, palette, painter, rect: rect, random: &random)
        case .flower: paintFlower(layout, palette, painter, rect: rect, random: &random)
        }
        guard let image = context.makeImage() else { return nil }
        return ImmersiveTheaterBackdrop(key: spec.key, image: image, layout: layout, palette: palette, rect: rect)
    }

    // MARK: 三种布景

    private static func paintNight(
        _ layout: ImmersiveTheaterSceneLayout,
        _ palette: ImmersiveTheaterScenePalette,
        _ brush: Brush,
        rect: CGRect,
        random: inout ImmersiveRandom
    ) {
        let world = layout.world
        brush.sky(top: palette.skyTop, low: palette.skyLow, from: Double(rect.minY), to: world.nearRidge + 40, rect: rect)
        brush.wash(band(rect, from: Double(rect.minY) - 20, height: world.nearRidge * 0.7), palette.skyTop, 0.55, bleed: 0.15, random: &random)
        brush.wash(band(rect, from: world.nearRidge * 0.3, height: world.nearRidge * 0.75), palette.skyTop.mixed(with: palette.skyLow, 0.4), 0.45, bleed: 0.18, random: &random)
        for cloud in layout.clouds {
            brush.wash(blob(cloud, random: &random), palette.cloud, 0.33, bleed: 0.3, random: &random)
        }
        let bottom = Double(rect.maxY) + 20
        brush.wash(ImmersiveTheaterSceneLayout.closed(layout.farRidge, bottom: bottom), palette.hillFar, 0.72, bleed: 0.1, random: &random)
        let near = ImmersiveTheaterSceneLayout.closed(layout.nearRidge, bottom: bottom)
        brush.wash(near, palette.hillNear, 0.78, bleed: 0.08, random: &random)
        brush.hatch(near, spacing: 6, angle: Double.pi * 0.2, color: palette.ink, alpha: 0.14, random: &random)
        brush.wash(ImmersiveTheaterSceneLayout.closed(layout.groundRidge, bottom: bottom), palette.ground, 0.82, bleed: 0.05, random: &random)
        if let moon = layout.orb {
            brush.glow(at: CGPoint(x: moon.x, y: moon.y), inner: moon.radius * 0.8, outer: moon.radius * 3, color: palette.glow, alpha: 0.35)
            brush.disc(at: CGPoint(x: moon.x, y: moon.y), radius: moon.radius, color: palette.moon, edge: 0.03, random: &random)
            brush.context.setFillColor(palette.crater.cgColor(alpha: 0.25))
            for crater in [(-0.3, -0.2, 0.22), (0.25, 0.3, 0.16), (0.1, -0.4, 0.1)] {
                let radius = moon.radius * crater.2
                brush.context.fillEllipse(in: CGRect(
                    x: moon.x + moon.radius * crater.0 - radius,
                    y: moon.y + moon.radius * crater.1 - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }
    }

    private static func paintRain(
        _ layout: ImmersiveTheaterSceneLayout,
        _ palette: ImmersiveTheaterScenePalette,
        _ brush: Brush,
        rect: CGRect,
        random: inout ImmersiveRandom
    ) {
        let world = layout.world
        let horizon = world.horizon
        brush.sky(top: palette.skyTop, low: palette.skyLow, from: Double(rect.minY), to: horizon, rect: rect)
        brush.wash(band(rect, from: Double(rect.minY) - 20, height: horizon * 0.75), palette.skyTop, 0.5, bleed: 0.15, random: &random)
        brush.wash(skyline(layout, back: true), palette.back, 0.9, bleed: 0.06, random: &random)
        let front = skyline(layout, back: false)
        brush.wash(front, palette.front, 0.94, bleed: 0.05, random: &random)
        brush.wash(front, palette.front, 0.6, bleed: 0.04, random: &random)
        brush.wash(band(rect, from: horizon - 90, height: 140), palette.mist, 0.24, bleed: 0.3, random: &random)
        brush.wash(band(rect, from: horizon + 10, height: Double(rect.maxY) - horizon + 10), palette.street, 0.84, bleed: 0.04, random: &random)
        for puddle in layout.puddles {
            brush.wash(blob(puddle, random: &random, jag: 0.12), palette.puddle, 0.47, bleed: 0.08, random: &random)
        }
        for (index, window) in layout.windows.enumerated() {
            let isBack = index < layout.windowIsBack.count ? layout.windowIsBack[index] : false
            brush.context.setFillColor(palette.window.cgColor(alpha: isBack ? 0.32 : 0.62))
            brush.context.fill(window)
        }
        if let lamp = layout.lamp {
            brush.wash(blob(ImmersiveTheaterEllipse(x: lamp.x, y: lamp.base + 60, rx: 160, ry: 40), random: &random, jag: 0.1),
                       palette.lamp, 0.22, bleed: 0.25, random: &random)
            brush.context.setFillColor(palette.lampPost.cgColor(alpha: 0.95))
            brush.context.fill(CGRect(x: lamp.x - 9, y: lamp.top, width: 18, height: lamp.base - lamp.top))
            brush.disc(at: CGPoint(x: lamp.x, y: lamp.top - 18), radius: 30, color: palette.lamp, edge: 0.02, random: &random)
        }
    }

    private static func paintFlower(
        _ layout: ImmersiveTheaterSceneLayout,
        _ palette: ImmersiveTheaterScenePalette,
        _ brush: Brush,
        rect: CGRect,
        random: inout ImmersiveRandom
    ) {
        let world = layout.world
        brush.sky(top: palette.skyTop, low: palette.skyLow, from: Double(rect.minY), to: world.nearRidge, rect: rect)
        brush.wash(band(rect, from: Double(rect.minY) - 20, height: world.nearRidge * 0.6), palette.skyTop, 0.4, bleed: 0.15, random: &random)
        if let sun = layout.orb {
            brush.wash(blob(ImmersiveTheaterEllipse(x: sun.x, y: sun.y, rx: sun.radius * 2.2, ry: sun.radius * 2.2), random: &random, jag: 0.1),
                       palette.halo, 0.24, bleed: 0.3, random: &random)
            brush.disc(at: CGPoint(x: sun.x, y: sun.y), radius: sun.radius, color: palette.sun, edge: 0.04, random: &random)
        }
        for cloud in layout.clouds {
            brush.wash(blob(cloud, random: &random), palette.cloud, 0.6, bleed: 0.25, random: &random)
        }
        let bottom = Double(rect.maxY) + 20
        brush.wash(ImmersiveTheaterSceneLayout.closed(layout.farRidge, bottom: bottom), palette.hillFar, 0.67, bleed: 0.1, random: &random)
        brush.wash(ImmersiveTheaterSceneLayout.closed(layout.nearRidge, bottom: bottom), palette.hillMid, 0.72, bleed: 0.08, random: &random)
        let field = ImmersiveTheaterSceneLayout.closed(layout.groundRidge, bottom: bottom)
        brush.wash(field, palette.field, 0.78, bleed: 0.06, random: &random)
        brush.hatch(field, spacing: 7, angle: Double.pi * 0.42, color: palette.field.mixed(with: palette.ink, 0.5), alpha: 0.16, random: &random)
        let context = brush.context
        for flower in layout.flowers {
            let color = palette.flowers[flower.color % max(palette.flowers.count, 1)]
            let size = flower.size
            context.setFillColor(color.cgColor(alpha: 0.55))
            for petal in 0..<5 {
                let angle = flower.rotation + Double(petal) * 2 * Double.pi / 5
                context.saveGState()
                context.translateBy(x: flower.x + cos(angle) * size * 0.55, y: flower.y + sin(angle) * size * 0.55)
                context.rotate(by: angle)
                context.fillEllipse(in: CGRect(x: -size * 0.42, y: -size * 0.3, width: size * 0.84, height: size * 0.6))
                context.restoreGState()
            }
            let center = flower.color == 3 ? palette.sun : ImmersiveTheaterRGB(hex: 0xFFF3C4)
            context.setFillColor(center.cgColor(alpha: 0.8))
            context.fillEllipse(in: CGRect(x: flower.x - size * 0.22, y: flower.y - size * 0.22, width: size * 0.44, height: size * 0.44))
        }
    }

    // MARK: 形状

    private static func band(_ rect: CGRect, from top: Double, height: Double) -> [CGPoint] {
        let left = Double(rect.minX) - 20
        let right = Double(rect.maxX) + 20
        let middle = (left + right) / 2
        let bottom = top + max(height, 10)
        return [
            CGPoint(x: left, y: top), CGPoint(x: middle, y: top), CGPoint(x: right, y: top),
            CGPoint(x: right, y: bottom), CGPoint(x: middle, y: bottom), CGPoint(x: left, y: bottom),
        ]
    }

    private static func blob(_ ellipse: ImmersiveTheaterEllipse, random: inout ImmersiveRandom, jag: Double = 0.18) -> [CGPoint] {
        var points: [CGPoint] = []
        let count = 16
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * Double.pi
            let wobble = 1 + (random.unit() - 0.5) * jag * 2
            points.append(CGPoint(x: ellipse.x + cos(angle) * ellipse.rx * wobble, y: ellipse.y + sin(angle) * ellipse.ry * wobble))
        }
        return points
    }

    private static func skyline(_ layout: ImmersiveTheaterSceneLayout, back: Bool) -> [CGPoint] {
        let horizon = layout.world.horizon
        let rect = layout.world.backdropRect
        var points: [CGPoint] = [CGPoint(x: Double(rect.minX) - 20, y: horizon)]
        for building in layout.buildings.filter({ $0.isBack == back }).sorted(by: { $0.x < $1.x }) {
            let height = back ? building.height * 1.15 : building.height * 0.8
            points.append(CGPoint(x: building.x, y: horizon - height))
            points.append(CGPoint(x: building.x + building.width, y: horizon - height))
        }
        points.append(CGPoint(x: Double(rect.maxX) + 20, y: horizon))
        points.append(CGPoint(x: Double(rect.maxX) + 20, y: horizon + 40))
        points.append(CGPoint(x: Double(rect.minX) - 20, y: horizon + 40))
        return points
    }

    // MARK: 画笔

    /// 一支水彩笔：所有尺寸都按世界单位给，线宽按像素换算。
    struct Brush {
        let context: CGContext
        let pixelsPerUnit: Double

        /// 天空的底：上下两色的渐变，铺满背景，地平线以下用下面那一色。
        func sky(top: ImmersiveTheaterRGB, low: ImmersiveTheaterRGB, from start: Double, to end: Double, rect: CGRect) {
            let colors = [top.cgColor(), low.cgColor()] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else {
                context.setFillColor(top.cgColor())
                context.fill(rect)
                return
            }
            context.saveGState()
            context.addRect(rect)
            context.clip()
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: start),
                end: CGPoint(x: rect.midX, y: end),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }

        /// 一块水彩：底形先做两轮中点位移，再分三叠、每叠五层各自再变形一点，每层很淡；每叠第一层描一圈淡边当积色。
        func wash(_ points: [CGPoint], _ color: ImmersiveTheaterRGB, _ opacity: Double, bleed: Double, random: inout ImmersiveRandom) {
            guard points.count > 2 else { return }
            var weights: [Double] = []
            weights.reserveCapacity(points.count)
            for _ in points { weights.append(bleed * (0.6 + 0.8 * random.unit())) }
            let base = ImmersiveWatercolorGeometry.deform(
                ImmersiveWatercolorPolygon(points: points, weights: weights),
                depth: 2,
                random: &random
            )
            context.setFillColor(color.cgColor())
            context.setStrokeColor(color.mixed(with: ImmersiveTheaterRGB(0, 0, 0), 0.25).cgColor())
            context.setLineWidth(CGFloat(1.3 / pixelsPerUnit))
            for _ in 0..<3 {
                let stack = ImmersiveWatercolorGeometry.deform(base, depth: 1, random: &random)
                for layer in 0..<5 {
                    let wet = ImmersiveWatercolorGeometry.deform(stack, depth: 1, random: &random)
                    let path = CGMutablePath()
                    path.addLines(between: wet.points)
                    path.closeSubpath()
                    context.setAlpha(CGFloat(min(opacity * 0.17, 1)))
                    context.addPath(path)
                    context.fillPath()
                    if layer == 0 {
                        context.setAlpha(CGFloat(min(opacity * 0.12, 1)))
                        context.addPath(path)
                        context.strokePath()
                    }
                }
            }
            context.setAlpha(1)
        }

        /// 铅笔排线：在形状里斜着排一道道断续的细线。
        func hatch(_ polygon: [CGPoint], spacing: Double, angle: Double, color: ImmersiveTheaterRGB, alpha: Double, random: inout ImmersiveRandom) {
            guard polygon.count > 2 else { return }
            let path = CGMutablePath()
            path.addLines(between: polygon)
            path.closeSubpath()
            let box = path.boundingBoxOfPath
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setStrokeColor(color.cgColor(alpha: alpha))
            context.setLineWidth(CGFloat(max(0.8 / pixelsPerUnit, 0.6)))
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let reach = Double(hypot(box.width, box.height))
            let center = CGPoint(x: box.midX, y: box.midY)
            let lineSpacing = max(spacing, 2)
            var offset = -reach / 2
            while offset < reach / 2 {
                defer { offset += lineSpacing * (0.85 + 0.3 * random.unit()) }
                // 一条线断成几截，有的地方空着。
                var along = -reach / 2
                while along < reach / 2 {
                    let length = 20 + random.unit() * 60
                    if random.unit() < 0.7 {
                        let start = CGPoint(
                            x: Double(center.x) + Double(normal.dx) * offset + Double(direction.dx) * along,
                            y: Double(center.y) + Double(normal.dy) * offset + Double(direction.dy) * along
                        )
                        let end = CGPoint(
                            x: Double(start.x) + Double(direction.dx) * length,
                            y: Double(start.y) + Double(direction.dy) * length + (random.unit() - 0.5) * 2
                        )
                        context.move(to: start)
                        context.addLine(to: end)
                    }
                    along += length + random.unit() * 30
                }
            }
            context.strokePath()
            context.restoreGState()
        }

        /// 亮的圆（月亮、太阳、路灯）：几圈很淡的大一点的晕，再一圈实的，边上带一点毛。
        func disc(at center: CGPoint, radius: Double, color: ImmersiveTheaterRGB, edge: Double, random: inout ImmersiveRandom) {
            for pass in 0..<5 {
                let path = CGMutablePath()
                let grow: Double = pass < 4 ? 0.05 + Double(pass) * 0.025 : 0
                for index in 0...36 {
                    let angle = Double(index) / 36 * 2 * Double.pi
                    let r = radius * (1 + grow + (random.unit() - 0.5) * edge)
                    let point = CGPoint(x: Double(center.x) + cos(angle) * r, y: Double(center.y) + sin(angle) * r)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.setFillColor(color.cgColor(alpha: pass == 4 ? 0.95 : 0.16))
                context.addPath(path)
                context.fillPath()
            }
        }

        func glow(at center: CGPoint, inner: Double, outer: Double, color: ImmersiveTheaterRGB, alpha: Double) {
            let colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: CGFloat(inner),
                endCenter: center,
                endRadius: CGFloat(outer),
                options: []
            )
        }
    }
}
