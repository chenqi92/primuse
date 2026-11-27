import Foundation

public enum ImmersiveLyricDisplayPlatform: String, Codable, Hashable, Sendable {
    case handheld
    case desktop
    case television
}

public struct ImmersiveLyricTypographyMetrics: Equatable, Sendable {
    public let currentFontSize: Double
    public let adjacentFontSize: Double
    public let currentLineLimit: Int
    public let adjacentLineLimit: Int
    public let verticalSpacing: Double

    public init(
        currentFontSize: Double,
        adjacentFontSize: Double,
        currentLineLimit: Int,
        adjacentLineLimit: Int,
        verticalSpacing: Double
    ) {
        self.currentFontSize = currentFontSize
        self.adjacentFontSize = adjacentFontSize
        self.currentLineLimit = currentLineLimit
        self.adjacentLineLimit = adjacentLineLimit
        self.verticalSpacing = verticalSpacing
    }
}

/// Keeps the active lyric legible across television distance, Mac windows and
/// mixed writing systems without relying on a single hard-coded point size.
public enum ImmersiveLyricTypographyPolicy {
    public static func metrics(
        for text: String,
        canvasWidth: Double,
        canvasHeight: Double,
        availableWidth: Double,
        platform: ImmersiveLyricDisplayPlatform
    ) -> ImmersiveLyricTypographyMetrics {
        let canvasScale = scale(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            platform: platform
        )
        let base: Double
        let minimum: Double
        let minimumAdjacent: Double
        switch platform {
        case .handheld:
            base = 23
            minimum = 17
            minimumAdjacent = 13
        case .desktop:
            base = 42
            minimum = 24
            minimumAdjacent = 17
        case .television:
            base = 62
            minimum = 38
            minimumAdjacent = 25
        }

        let units = max(estimatedTypographicUnits(in: text), 1)
        let scaledBase = base * canvasScale
        let lineCapacity = max(1, availableWidth / max(scaledBase * 0.61, 1))
        let currentLineLimit: Int
        if units <= lineCapacity * 1.15 {
            currentLineLimit = 2
        } else if units <= lineCapacity * 2.65 {
            currentLineLimit = 3
        } else {
            currentLineLimit = 4
        }

        let fitted = max(1, availableWidth) * Double(currentLineLimit) / (units * 0.61)
        let current = min(scaledBase, max(minimum * canvasScale, fitted))
        let adjacent = min(
            current * 0.66,
            max(minimumAdjacent * canvasScale, current * 0.58)
        )

        return ImmersiveLyricTypographyMetrics(
            currentFontSize: current,
            adjacentFontSize: adjacent,
            currentLineLimit: currentLineLimit,
            adjacentLineLimit: min(2, currentLineLimit),
            verticalSpacing: max(7, current * (platform == .television ? 0.25 : 0.22))
        )
    }

    public static func estimatedTypographicUnits(in text: String) -> Double {
        text.reduce(into: 0.0) { total, character in
            guard let scalar = character.unicodeScalars.first else { return }
            if character.isWhitespaceOnly {
                total += 0.30
            } else if isWideScript(scalar.value) {
                total += 1.0
            } else if isRightToLeftScript(scalar.value) {
                total += 0.72
            } else if scalar.isASCII {
                if CharacterSet.letters.contains(scalar) {
                    total += CharacterSet.uppercaseLetters.contains(scalar) ? 0.68 : 0.56
                } else if CharacterSet.decimalDigits.contains(scalar) {
                    total += 0.58
                } else {
                    total += 0.36
                }
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                total += 0.82
            } else {
                total += 0.72
            }
        }
    }

    private static func scale(
        canvasWidth: Double,
        canvasHeight: Double,
        platform: ImmersiveLyricDisplayPlatform
    ) -> Double {
        let reference: (width: Double, height: Double)
        let bounds: ClosedRange<Double>
        switch platform {
        case .handheld:
            reference = (393, 852)
            bounds = 0.82...1.30
        case .desktop:
            reference = (1728, 1080)
            bounds = 0.55...1.30
        case .television:
            reference = (1920, 1080)
            bounds = 0.62...1.35
        }
        let raw = min(canvasWidth / reference.width, canvasHeight / reference.height)
        return min(bounds.upperBound, max(bounds.lowerBound, raw))
    }

    private static func isWideScript(_ value: UInt32) -> Bool {
        (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x3134F).contains(value)
    }

    private static func isRightToLeftScript(_ value: UInt32) -> Bool {
        (0x0590...0x08FF).contains(value)
            || (0xFB1D...0xFDFF).contains(value)
            || (0xFE70...0xFEFF).contains(value)
    }
}

/// Normalizes lyric lines for comparison: leading timestamps, spacing, case and
/// diacritics do not make two copies of the same line look different.
public enum ImmersiveTypographyFieldPolicy {
    public static func normalizedKey(_ value: String) -> String {
        normalizedLine(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func normalizedLine(_ rawValue: String) -> String {
        var value = rawValue.replacingOccurrences(of: "\u{00A0}", with: " ")
        while let stripped = strippingLeadingTimestamp(from: value), stripped != value {
            value = stripped
        }
        return value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingLeadingTimestamp(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first,
              first == "[" || first == "<" else { return nil }
        let close: Character = first == "[" ? "]" : ">"
        guard let closeIndex = trimmed.firstIndex(of: close) else { return nil }
        let interior = trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex]
            .replacingOccurrences(of: " ", with: "")
        let components = interior.split(separator: ":")
        guard (2...3).contains(components.count), components.allSatisfy({ component in
            !component.isEmpty && component.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
        }) else { return nil }
        return String(trimmed[trimmed.index(after: closeIndex)...])
    }
}

public enum ImmersiveLyricHighlightProgressPolicy {
    public static func progress(
        from start: TimeInterval,
        to end: TimeInterval,
        at playbackTime: TimeInterval
    ) -> Double {
        guard start.isFinite, end.isFinite, playbackTime.isFinite, end > start else { return 1 }
        return min(1, max(0, (playbackTime - start) / (end - start)))
    }

    public static func progress(
        in syllables: [LyricSyllable],
        at playbackTime: TimeInterval
    ) -> Double {
        guard !syllables.isEmpty else { return 1 }
        let weights = syllables.map {
            max(ImmersiveLyricTypographyPolicy.estimatedTypographicUnits(in: $0.text), 0.25)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 1 }

        var completed = 0.0
        for index in syllables.indices {
            let syllable = syllables[index]
            let nextStart = syllables.indices.contains(index + 1) ? syllables[index + 1].start : nil
            let end = LyricSyllablePlaybackTimingPolicy.effectiveEnd(
                for: syllable,
                nextSyllableStart: nextStart
            )
            if playbackTime >= end {
                completed += weights[index]
                continue
            }
            guard playbackTime > syllable.start else {
                return min(1, max(0, completed / total))
            }
            let duration = max(end - syllable.start, LyricSyllablePlaybackTimingPolicy.minimumTransitionDuration)
            let raw = min(1, max(0, (playbackTime - syllable.start) / duration))
            let eased = 1 - (1 - raw) * (1 - raw)
            return min(1, max(0, (completed + weights[index] * eased) / total))
        }
        return 1
    }
}

private extension Character {
    var isWhitespaceOnly: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
