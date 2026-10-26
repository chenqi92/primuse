import Foundation

/// 封面取主题色:哪些像素算候选、哪些色相桶够格当主色。
///
/// 鲜艳色不设亮度上限:纯红、亮黄这类满亮度的颜色本来就是封面的主色,原来
/// 「亮度 < 0.95」把它们当成接近白丢掉,白底红字的封面一个候选都没有,只能落到深灰(#361)。
/// 接近白、接近灰靠饱和度排除。
///
/// 鲜艳色一块都不够大时,依次再看两种:很小但明显有颜色的一块(白底上的小字、细线),
/// 以及占了封面一大片的浅色(浅绿封面取浅绿而不是灰)。黑白照片偏一点冷暖,
/// 饱和度到不了小字那一档,亮部也占不满一大片,仍然算没有主色。
public enum ArtworkAccentPixelPolicy {
    public struct Pixel: Sendable, Equatable {
        public let hue: Double
        public let saturation: Double
        public let brightness: Double

        public init(hue: Double, saturation: Double, brightness: Double) {
            self.hue = hue
            self.saturation = saturation
            self.brightness = brightness
        }
    }

    public struct Bucket: Sendable, Equatable {
        public let index: Int
        public let hue: Double
        public let saturation: Double
        public let brightness: Double
        public let score: Double
    }

    public enum Kind: Sendable, Equatable { case vivid, pastel }

    /// 色相分得细一点,相邻的暖色不会吞掉更有特点的冷色、亮色。
    public static let bucketCount = 24
    static let minimumBrightness = 0.10
    static let vividMinimumSaturation = 0.24
    static let pastelMinimumSaturation = 0.07
    static let pastelMinimumBrightness = 0.60
    static let pastelMinimumShare = 0.20
    static let markMinimumPixels = 4
    static let markMinimumSaturation = 0.45
    /// 暗部的噪点通道差一点饱和度就很高,小块颜色要看得见才算。
    static let markMinimumBrightness = 0.40

    public static func kind(saturation: Double, brightness: Double) -> Kind? {
        guard brightness > minimumBrightness else { return nil }
        if saturation >= vividMinimumSaturation { return .vivid }
        if saturation >= pastelMinimumSaturation, brightness >= pastelMinimumBrightness { return .pastel }
        return nil
    }

    /// 能当主色的色相桶,分数高的是主色;空数组表示这张封面没有主色(黑白、灰阶)。
    public static func candidateBuckets(_ pixels: [Pixel]) -> [Bucket] {
        var vivid = [[Pixel]](repeating: [], count: bucketCount)
        var pastel = [[Pixel]](repeating: [], count: bucketCount)
        for pixel in pixels {
            guard let kind = kind(saturation: pixel.saturation, brightness: pixel.brightness) else { continue }
            // 错开半个桶,色相 0 和 1 附近的红色落在同一个桶里。
            let index = Int(pixel.hue * Double(bucketCount) + 0.5) % bucketCount
            switch kind {
            case .vivid: vivid[index].append(pixel)
            case .pastel: pastel[index].append(pixel)
            }
        }
        let regular = summarize(vivid) { $0.count >= max(8, pixels.count / 200) }
        if !regular.isEmpty { return regular }
        let marks = summarize(vivid) { bucket in
            let count = Double(bucket.count)
            return bucket.count >= markMinimumPixels
                && bucket.reduce(0) { $0 + $1.saturation } / count >= markMinimumSaturation
                && bucket.reduce(0) { $0 + $1.brightness } / count >= markMinimumBrightness
        }
        if !marks.isEmpty { return marks }
        return summarize(pastel) { Double($0.count) >= Double(pixels.count) * pastelMinimumShare }
    }

    private static func summarize(_ buckets: [[Pixel]], accepts: ([Pixel]) -> Bool) -> [Bucket] {
        buckets.indices.compactMap { index in
            let bucket = buckets[index]
            guard !bucket.isEmpty, accepts(bucket) else { return nil }
            var hueX = 0.0, hueY = 0.0, saturation = 0.0, brightness = 0.0, total = 0.0
            for pixel in bucket {
                // 饱和度加权:大片米色、肤色、纸色不会让不相干的封面都变成棕色。
                let weight = pixel.saturation * pixel.saturation * (0.55 + 0.45 * pixel.brightness)
                let angle = pixel.hue * 2 * .pi
                hueX += cos(angle) * weight
                hueY += sin(angle) * weight
                saturation += pixel.saturation * weight
                brightness += pixel.brightness * weight
                total += weight
            }
            guard total > 0 else { return nil }
            var hue = atan2(hueY, hueX) / (2 * .pi)
            if hue < 0 { hue += 1 }
            return Bucket(index: index, hue: hue, saturation: saturation / total,
                          brightness: brightness / total, score: total)
        }
    }
}
