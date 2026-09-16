import Foundation

/// Resolved type sizes for one poster, in canvas points (which equal exported
/// pixels, since posters render at scale 1).
public struct LyricPosterTypeMetrics: Hashable, Sendable {
    public let lyricFontSize: Double
    /// Gap between two lyric rows. Wrapped lines inside one row stay tighter,
    /// so a long sentence still reads as a single thought.
    public let lyricLineSpacing: Double
    public let translationFontSize: Double
    public let titleFontSize: Double
    public let captionFontSize: Double
    /// Width available to text after the style's side margins.
    public let textWidth: Double
    /// Estimated height of the whole lyric block at these sizes.
    public let estimatedHeight: Double
    /// Set when translations had to be dropped to fit the passage.
    public let hidesTranslation: Bool
    /// The passage does not fit even at the smallest type size and tightest
    /// leading. The poster will be exported clipped, so the UI has to tell the
    /// user to pick a taller canvas or fewer lines rather than quietly
    /// shipping a cut-off image.
    public let overflows: Bool

    public init(
        lyricFontSize: Double,
        lyricLineSpacing: Double,
        translationFontSize: Double,
        titleFontSize: Double,
        captionFontSize: Double,
        textWidth: Double,
        estimatedHeight: Double,
        hidesTranslation: Bool,
        overflows: Bool = false
    ) {
        self.lyricFontSize = lyricFontSize
        self.lyricLineSpacing = lyricLineSpacing
        self.translationFontSize = translationFontSize
        self.titleFontSize = titleFontSize
        self.captionFontSize = captionFontSize
        self.textWidth = textWidth
        self.estimatedHeight = estimatedHeight
        self.hidesTranslation = hidesTranslation
        self.overflows = overflows
    }
}

/// Picks a lyric type size that fills the poster without overflowing it.
///
/// SwiftUI's own `minimumScaleFactor` cannot be used here: posters render
/// off-screen through `ImageRenderer` at a fixed canvas size, and a passage
/// that overflows is exported clipped rather than shrunk. So the size is
/// solved up front from an estimate of how wide each line runs.
public enum LyricPosterLayoutPolicy {
    /// Fraction of the canvas width a style leaves for text by default.
    public static let defaultTextWidthRatio: Double = 0.80
    /// Fraction of the canvas height the lyric block may occupy by default.
    /// The rest carries title, artist, cover and the app credit.
    public static let defaultLyricHeightRatio: Double = 0.54

    /// 一行文字实际占的高度倍数。取得比系统行高略保守 —— 估算偏小会让
    /// 歌词在离屏渲染时被裁掉, 而离屏渲染没有"挤一挤"的机会。
    private static let lineHeightFactor: Double = 1.45
    private static let translationScale: Double = 0.56
    private static let sizeStep: Double = 1
    /// 行距按这个顺序收紧。宁可句与句挨得紧一点, 也好过把字缩到看不清。
    private static let lineSpacingFactors: [Double] = [0.42, 0.30, 0.22]
    public static let defaultLineSpacingFactor: Double = 0.42

    public static func metrics(
        for content: LyricPosterContent,
        canvas: LyricPosterCanvas,
        textWidthRatio: Double = defaultTextWidthRatio,
        lyricHeightRatio: Double = defaultLyricHeightRatio
    ) -> LyricPosterTypeMetrics {
        let width = canvas.pixelWidth
        let textWidth = width * textWidthRatio
        let availableHeight = canvas.pixelHeight * lyricHeightRatio
        let maximumSize = width * 0.085
        // 下限定得低一点是有意的: 八句长歌词配方形画幅时, 25pt 单行排版
        // 比 32pt 每句折成两行更省高度, 也更好读。
        let minimumSize = width * 0.022

        // A short passage is allowed to run large; a long one starts smaller so
        // the search does not have to walk the whole range every time.
        let startingSize = min(maximumSize, maximumSize * startingScale(for: content))
        // 每行的宽度只跟文本有关, 先量一次, 后面几百轮试算就只剩算术了。
        let widths = lineWidths(of: content)

        func build(
            size: Double,
            spacingFactor: Double,
            includesTranslation: Bool,
            height: Double,
            overflows: Bool
        ) -> LyricPosterTypeMetrics {
            LyricPosterTypeMetrics(
                lyricFontSize: size,
                lyricLineSpacing: size * spacingFactor,
                translationFontSize: size * translationScale,
                titleFontSize: width * 0.040,
                captionFontSize: width * 0.026,
                textWidth: textWidth,
                estimatedHeight: height,
                hidesTranslation: includesTranslation ? false : content.hasCompanionText,
                overflows: overflows
            )
        }

        // 放宽的顺序: 先缩字号, 再收行距, 最后才舍弃注音与译文 —— 它们是歌词
        // 自带或用户开着翻译才会有的东西, 不到放不下不该擅自拿掉。
        let translationPasses = content.hasCompanionText ? [true, false] : [false]
        // 候选字号从大到小, 末尾一定带上下限本身: 按固定步长递减会跨过下限
        // (55, 54 … 24, 然后 23 就退出了), 于是"最小字号都放不下"这个判断
        // 其实从没试过最小字号, 差一两个点的版面会被误判成放不下。
        var candidates: [Double] = []
        var size = startingSize
        while size > minimumSize {
            candidates.append(size)
            size -= sizeStep
        }
        candidates.append(minimumSize)

        for includesTranslation in translationPasses {
            for spacingFactor in lineSpacingFactors {
                for size in candidates {
                    let height = blockHeight(
                        widths: widths,
                        lyricFontSize: size,
                        textWidth: textWidth,
                        includesTranslation: includesTranslation,
                        lineSpacingFactor: spacingFactor
                    )
                    if height <= availableHeight {
                        return build(
                            size: size,
                            spacingFactor: spacingFactor,
                            includesTranslation: includesTranslation,
                            height: height,
                            overflows: false
                        )
                    }
                }
            }
        }

        // 连最小字号 + 最紧行距都放不下。仍然给出一套可渲染的尺寸(总得画出
        // 点东西), 但把 overflows 立起来让 UI 去提示。
        let tightest = lineSpacingFactors[lineSpacingFactors.count - 1]
        let height = blockHeight(
            widths: widths,
            lyricFontSize: minimumSize,
            textWidth: textWidth,
            includesTranslation: false,
            lineSpacingFactor: tightest
        )
        return build(
            size: minimumSize,
            spacingFactor: tightest,
            includesTranslation: false,
            height: height,
            overflows: true
        )
    }

    /// 每行(以及它下面的注音 / 译文)的 em 宽度。字号变化不影响它, 所以只量一次。
    private static func lineWidths(
        of content: LyricPosterContent
    ) -> [(text: Double, companions: [Double])] {
        content.lines.map { line in
            let companions = [line.romanization, line.translation]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .map(estimatedEmWidth(of:))
            return (estimatedEmWidth(of: line.text), companions)
        }
    }

    private static func blockHeight(
        widths: [(text: Double, companions: [Double])],
        lyricFontSize: Double,
        textWidth: Double,
        includesTranslation: Bool,
        lineSpacingFactor: Double
    ) -> Double {
        guard !widths.isEmpty, lyricFontSize > 0, textWidth > 0 else { return 0 }
        let translationSize = lyricFontSize * translationScale
        var total = 0.0
        for width in widths {
            let rows = rowCount(emWidth: width.text, fontSize: lyricFontSize, textWidth: textWidth)
            total += Double(rows) * lyricFontSize * lineHeightFactor
            if includesTranslation {
                for companionWidth in width.companions {
                    let companionRows = rowCount(
                        emWidth: companionWidth,
                        fontSize: translationSize,
                        textWidth: textWidth
                    )
                    total += Double(companionRows) * translationSize * lineHeightFactor
                    total += translationSize * 0.24
                }
            }
        }
        total += lyricFontSize * lineSpacingFactor * Double(max(widths.count - 1, 0))
        return total
    }

    private static func rowCount(emWidth: Double, fontSize: Double, textWidth: Double) -> Int {
        let capacity = textWidth / fontSize
        guard capacity > 0 else { return 1 }
        return max(1, Int(ceil(emWidth / capacity)))
    }

    /// Estimated height of the lyric block, counting wrapped lines.
    public static func estimatedHeight(
        of content: LyricPosterContent,
        lyricFontSize: Double,
        textWidth: Double,
        includesTranslation: Bool,
        lineSpacingFactor: Double = defaultLineSpacingFactor
    ) -> Double {
        guard lyricFontSize > 0, textWidth > 0 else { return 0 }
        return blockHeight(
            widths: lineWidths(of: content),
            lyricFontSize: lyricFontSize,
            textWidth: textWidth,
            includesTranslation: includesTranslation,
            lineSpacingFactor: lineSpacingFactor
        )
    }

    public static func wrappedRowCount(
        of text: String,
        fontSize: Double,
        textWidth: Double
    ) -> Int {
        guard fontSize > 0, textWidth > 0 else { return 1 }
        let capacity = textWidth / fontSize
        guard capacity > 0 else { return 1 }
        return max(1, Int(ceil(estimatedEmWidth(of: text) / capacity)))
    }

    /// Width of `text` in em units, estimated per scalar. Poster layout only
    /// needs to know whether a line wraps once or three times, and the real
    /// text metrics are unavailable in a platform-independent policy.
    public static func estimatedEmWidth(of text: String) -> Double {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + emWidth(of: scalar)
        }
    }

    private static func emWidth(of scalar: Unicode.Scalar) -> Double {
        let value = scalar.value
        switch value {
        case 0x20, 0x09:
            return 0.28
        case 0x21...0x40, 0x5B...0x60, 0x7B...0x7E:
            // ASCII punctuation and digits.
            return value >= 0x30 && value <= 0x39 ? 0.55 : 0.34
        case 0x41...0x5A:
            return 0.66
        case 0x61...0x7A:
            return 0.52
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            // Full-width CJK and Hangul.
            return 1.0
        case 0x3000...0x303F:
            return 1.0
        case 0x1F300...0x1FAFF, 0x2600...0x27BF:
            return 1.1
        default:
            return 0.58
        }
    }

    /// Larger passages start the size search lower, which keeps the loop short
    /// and makes the resulting size monotonic in passage length.
    private static func startingScale(for content: LyricPosterContent) -> Double {
        switch content.lines.count {
        case 0, 1: return 1.0
        case 2: return 0.92
        case 3: return 0.84
        case 4: return 0.76
        case 5, 6: return 0.68
        default: return 0.60
        }
    }
}
