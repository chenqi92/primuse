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

    public init(
        lyricFontSize: Double,
        lyricLineSpacing: Double,
        translationFontSize: Double,
        titleFontSize: Double,
        captionFontSize: Double,
        textWidth: Double,
        estimatedHeight: Double,
        hidesTranslation: Bool
    ) {
        self.lyricFontSize = lyricFontSize
        self.lyricLineSpacing = lyricLineSpacing
        self.translationFontSize = translationFontSize
        self.titleFontSize = titleFontSize
        self.captionFontSize = captionFontSize
        self.textWidth = textWidth
        self.estimatedHeight = estimatedHeight
        self.hidesTranslation = hidesTranslation
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
        let minimumSize = width * 0.030

        // A short passage is allowed to run large; a long one starts smaller so
        // the search does not have to walk the whole range every time.
        let startingSize = min(maximumSize, maximumSize * startingScale(for: content))

        var chosen = minimumSize
        var chosenHeight = 0.0
        var hidesTranslation = false
        var includesTranslation = content.hasTranslation

        search: while true {
            var size = startingSize
            while size >= minimumSize {
                let height = estimatedHeight(
                    of: content,
                    lyricFontSize: size,
                    textWidth: textWidth,
                    includesTranslation: includesTranslation
                )
                if height <= availableHeight {
                    chosen = size
                    chosenHeight = height
                    break search
                }
                size -= sizeStep
            }
            if includesTranslation {
                // Nothing fits with translations: drop them and try once more
                // rather than exporting a clipped poster.
                includesTranslation = false
                hidesTranslation = true
                continue
            }
            chosen = minimumSize
            chosenHeight = estimatedHeight(
                of: content,
                lyricFontSize: minimumSize,
                textWidth: textWidth,
                includesTranslation: false
            )
            break
        }

        return LyricPosterTypeMetrics(
            lyricFontSize: chosen,
            lyricLineSpacing: chosen * 0.42,
            translationFontSize: chosen * translationScale,
            titleFontSize: width * 0.040,
            captionFontSize: width * 0.026,
            textWidth: textWidth,
            estimatedHeight: chosenHeight,
            hidesTranslation: hidesTranslation
        )
    }

    /// Estimated height of the lyric block, counting wrapped lines.
    public static func estimatedHeight(
        of content: LyricPosterContent,
        lyricFontSize: Double,
        textWidth: Double,
        includesTranslation: Bool
    ) -> Double {
        guard !content.lines.isEmpty, lyricFontSize > 0, textWidth > 0 else { return 0 }
        let spacing = lyricFontSize * 0.42
        var total = 0.0
        for line in content.lines {
            let rows = wrappedRowCount(
                of: line.text,
                fontSize: lyricFontSize,
                textWidth: textWidth
            )
            total += Double(rows) * lyricFontSize * lineHeightFactor
            if includesTranslation, let translation = line.translation, !translation.isEmpty {
                let translationSize = lyricFontSize * translationScale
                let translationRows = wrappedRowCount(
                    of: translation,
                    fontSize: translationSize,
                    textWidth: textWidth
                )
                total += Double(translationRows) * translationSize * lineHeightFactor
                total += translationSize * 0.24
            }
        }
        total += spacing * Double(max(content.lines.count - 1, 0))
        return total
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
