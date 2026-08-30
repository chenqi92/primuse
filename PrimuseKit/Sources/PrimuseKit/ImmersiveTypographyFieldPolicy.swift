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

    public static func fieldTitleFontSize(
        for text: String,
        canvasWidth: Double,
        canvasHeight: Double,
        availableWidth: Double,
        platform: ImmersiveLyricDisplayPlatform
    ) -> Double {
        let canvasScale = scale(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            platform: platform
        )
        let base: Double
        let minimum: Double
        switch platform {
        case .handheld:
            base = 66
            minimum = 34
        case .desktop:
            base = 110
            minimum = 52
        case .television:
            base = 142
            minimum = 76
        }

        let units = max(estimatedTypographicUnits(in: text), 1)
        let scaledBase = base * canvasScale
        let capacity = max(1, availableWidth / max(scaledBase * 0.61, 1))
        let lineCount = units > capacity ? 2.0 : 1.0
        let fitted = max(1, availableWidth) * lineCount / (units * 0.61)
        return min(scaledBase, max(minimum * canvasScale, fitted))
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

public struct ImmersiveTypographyFieldItem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public let normalizedTextKey: String
    public let normalizedX: Double
    public let normalizedY: Double
    public let widthFraction: Double
    public let fontScale: Double
    public let opacity: Double
    public let blurRadius: Double
    public let isOutlined: Bool
    public let rotationDegrees: Double
    public let driftXFraction: Double
    public let driftYFraction: Double
    public let phase: Double
}

public struct ImmersiveTypographyFieldMotionState: Equatable, Sendable {
    public let opacityMultiplier: Double
    public let xOffsetFraction: Double
    public let yOffsetFraction: Double

    public init(
        opacityMultiplier: Double,
        xOffsetFraction: Double,
        yOffsetFraction: Double
    ) {
        self.opacityMultiplier = opacityMultiplier
        self.xOffsetFraction = xOffsetFraction
        self.yOffsetFraction = yOffsetFraction
    }
}

/// Defines explicit full-cycle durations for the background typography field.
/// Keeping this pure makes motion testable without rebuilding the text pool or
/// layout on every visual tick.
public enum ImmersiveTypographyFieldMotionPolicy {
    /// The typography field is rendered by a single cached Canvas, so it can
    /// follow display motion smoothly without rebuilding a SwiftUI text tree.
    public static let targetFramesPerSecond = 30
    public static let refreshInterval: TimeInterval = 1.0 / Double(targetFramesPerSecond)

    public static func opacityCycleDuration(for itemID: Int) -> TimeInterval {
        12 + Double(positiveModulo(itemID, 4)) * 2
    }

    public static func horizontalCycleDuration(for itemID: Int) -> TimeInterval {
        30 + Double(positiveModulo(itemID, 4)) * 6
    }

    public static func verticalCycleDuration(for itemID: Int) -> TimeInterval {
        38 + Double(positiveModulo(itemID, 3)) * 8
    }

    public static func state(
        for item: ImmersiveTypographyFieldItem,
        at elapsedTime: TimeInterval,
        allowsMotion: Bool
    ) -> ImmersiveTypographyFieldMotionState {
        guard allowsMotion, elapsedTime.isFinite else {
            return ImmersiveTypographyFieldMotionState(
                opacityMultiplier: 1,
                xOffsetFraction: 0,
                yOffsetFraction: 0
            )
        }

        let opacityWave = sineWave(
            elapsedTime: elapsedTime,
            duration: opacityCycleDuration(for: item.id),
            phase: item.phase
        )
        let xWave = sineWave(
            elapsedTime: elapsedTime,
            duration: horizontalCycleDuration(for: item.id),
            phase: item.phase
        )
        let yWave = cosineWave(
            elapsedTime: elapsedTime,
            duration: verticalCycleDuration(for: item.id),
            phase: item.phase
        )
        return ImmersiveTypographyFieldMotionState(
            opacityMultiplier: 0.92 + opacityWave * 0.08,
            xOffsetFraction: xWave * item.driftXFraction,
            yOffsetFraction: yWave * item.driftYFraction
        )
    }

    private static func sineWave(
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        phase: Double
    ) -> Double {
        sin(elapsedTime * 2 * .pi / duration + phase)
    }

    private static func cosineWave(
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        phase: Double
    ) -> Double {
        cos(elapsedTime * 2 * .pi / duration + phase)
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

/// Builds a stable, deduplicated lyric pool and maps it onto a bounded set of
/// depth-aware slots. The pool is expected to be cached by the song/lyrics
/// owner; animation only changes transforms, never selection or text parsing.
public enum ImmersiveTypographyFieldPolicy {
    private struct Slot {
        let x: Double
        let y: Double
        let width: Double
        let scale: Double
        let depth: Int
        let rotation: Double
    }

    private static let slots: [Slot] = [
        Slot(x: 0.17, y: 0.07, width: 0.38, scale: 0.74, depth: 2, rotation: -1.6),
        Slot(x: 0.66, y: 0.11, width: 0.58, scale: 1.02, depth: 1, rotation: 0.8),
        Slot(x: 0.39, y: 0.18, width: 0.60, scale: 0.86, depth: 2, rotation: -0.5),
        Slot(x: 0.84, y: 0.25, width: 0.34, scale: 0.68, depth: 1, rotation: 1.8),
        Slot(x: 0.13, y: 0.31, width: 0.42, scale: 0.94, depth: 1, rotation: -1.0),
        Slot(x: 0.56, y: 0.37, width: 0.64, scale: 1.15, depth: 0, rotation: 0.4),
        Slot(x: 0.86, y: 0.45, width: 0.38, scale: 0.78, depth: 2, rotation: -1.4),
        Slot(x: 0.27, y: 0.51, width: 0.56, scale: 1.05, depth: 1, rotation: 1.2),
        Slot(x: 0.68, y: 0.58, width: 0.62, scale: 0.88, depth: 2, rotation: -0.8),
        Slot(x: 0.12, y: 0.65, width: 0.38, scale: 0.72, depth: 2, rotation: 1.6),
        Slot(x: 0.47, y: 0.71, width: 0.58, scale: 1.12, depth: 0, rotation: -0.3),
        Slot(x: 0.84, y: 0.78, width: 0.40, scale: 0.82, depth: 1, rotation: 1.0),
        Slot(x: 0.27, y: 0.84, width: 0.54, scale: 0.92, depth: 1, rotation: -1.4),
        Slot(x: 0.65, y: 0.89, width: 0.60, scale: 1.06, depth: 2, rotation: 0.7),
        Slot(x: 0.13, y: 0.95, width: 0.38, scale: 0.70, depth: 2, rotation: -0.7),
        Slot(x: 0.84, y: 0.96, width: 0.38, scale: 0.76, depth: 2, rotation: 1.5),
    ]

    public static func textPool(
        from rawLines: [String],
        title: String,
        limit: Int = 32
    ) -> [String] {
        guard limit > 0 else { return [] }
        let titleKey = normalizedKey(title)
        var seen: Set<String> = []
        var unique: [String] = []
        unique.reserveCapacity(min(rawLines.count, limit * 2))

        for rawLine in rawLines {
            let line = normalizedLine(rawLine)
            let key = normalizedKey(line)
            guard !line.isEmpty,
                  !key.isEmpty,
                  key != titleKey,
                  containsMeaningfulContent(line),
                  !isMetadataTag(line),
                  seen.insert(key).inserted else { continue }
            unique.append(line)
        }

        guard unique.count > limit else { return unique }
        let count = unique.count
        let offset = stableHash(title) % count
        var selected: [String] = []
        selected.reserveCapacity(limit)
        var selectedIndices: Set<Int> = []
        for index in 0..<limit {
            let spread = Int((Double(index) + 0.5) * Double(count) / Double(limit))
            var candidate = (spread + offset) % count
            while selectedIndices.contains(candidate) {
                candidate = (candidate + 1) % count
            }
            selectedIndices.insert(candidate)
            selected.append(unique[candidate])
        }
        return selected
    }

    public static func layout(
        lines: [String],
        canvasWidth: Double,
        canvasHeight: Double,
        platform: ImmersiveLyricDisplayPlatform,
        reduceMotion: Bool
    ) -> [ImmersiveTypographyFieldItem] {
        let maximum: Int
        switch platform {
        case .handheld:
            maximum = canvasWidth < 500 ? 8 : 10
        case .desktop:
            maximum = canvasWidth >= 1200 && canvasHeight >= 700 ? 14 : 10
        case .television:
            maximum = canvasWidth >= 1700 && canvasHeight >= 900 ? 16 : 12
        }
        let selected = Array(lines.prefix(min(maximum, slots.count)))
        let slotIndices = slotsForSparseContent(count: selected.count)

        return selected.enumerated().map { index, text in
            let slot = slots[slotIndices[index]]
            let units = max(ImmersiveLyricTypographyPolicy.estimatedTypographicUnits(in: text), 1)
            let lengthScale = min(1.12, max(0.54, sqrt(18 / units)))
            let opacity: Double
            let blur: Double
            switch slot.depth {
            case 0:
                opacity = 0.48
                blur = 0
            case 1:
                opacity = 0.32
                blur = 0.65
            default:
                opacity = 0.21
                blur = 1.35
            }
            let motionScale = reduceMotion ? 0 : 1.0
            return ImmersiveTypographyFieldItem(
                id: index,
                text: text,
                normalizedTextKey: normalizedKey(text),
                normalizedX: slot.x,
                normalizedY: slot.y,
                widthFraction: slot.width,
                fontScale: slot.scale * lengthScale,
                opacity: opacity,
                blurRadius: blur,
                isOutlined: slot.depth > 0 || index.isMultiple(of: 3),
                rotationDegrees: slot.rotation,
                driftXFraction: motionScale * (0.008 + Double(index % 4) * 0.0035),
                driftYFraction: motionScale * (0.004 + Double((index + 2) % 3) * 0.002),
                phase: Double(index) * 0.73
            )
        }
    }

    public static func visibleLines(
        in lines: [String],
        excluding title: String,
        currentLyric: String?
    ) -> [String] {
        let titleKey = normalizedKey(title)
        let currentKey = currentLyric.map(normalizedKey) ?? ""
        return lines.filter {
            let key = normalizedKey($0)
            return !key.isEmpty && key != titleKey && key != currentKey
        }
    }

    public static func normalizedKey(_ value: String) -> String {
        normalizedLine(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func slotsForSparseContent(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [5] }
        return (0..<count).map { index in
            Int((Double(index) * Double(slots.count - 1) / Double(count - 1)).rounded())
        }
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

    private static func containsMeaningfulContent(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }

    private static func isMetadataTag(_ value: String) -> Bool {
        guard value.first == "[", value.last == "]" else { return false }
        let interior = value.dropFirst().dropLast()
        guard let separator = interior.firstIndex(of: ":") else { return false }
        let key = interior[..<separator].lowercased()
        return ["al", "ar", "by", "id", "la", "lang", "length", "offset", "re", "ti"].contains(key)
    }

    private static func stableHash(_ value: String) -> Int {
        value.unicodeScalars.reduce(5381) { partial, scalar in
            ((partial << 5) &+ partial &+ Int(scalar.value)) & 0x7fff_ffff
        }
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
