import Foundation

/// Identifies a poster style. A string-backed value rather than an enum so a
/// later style can be added — including from another module — without any
/// exhaustive switch elsewhere having to change.
public struct LyricPosterStyleID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension LyricPosterStyleID {
    /// Blurred cover filling the frame under a frosted card.
    static let auroraGlass = LyricPosterStyleID("aurora_glass")
    /// Cover as a record on a turntable; the motion poster spins it.
    static let vinyl = LyricPosterStyleID("vinyl")
    /// Editorial black-on-paper typography, no cover needed.
    static let magazine = LyricPosterStyleID("magazine")
    /// Cinema subtitle over a letterboxed still.
    static let filmStill = LyricPosterStyleID("film_still")
    /// Cover-tinted gradient with oversized quotation marks.
    static let gradientQuote = LyricPosterStyleID("gradient_quote")
    /// Neon type on deep night, glow follows the sung line.
    static let neonNight = LyricPosterStyleID("neon_night")
    /// Instant-camera print with a handwritten caption.
    static let polaroid = LyricPosterStyleID("polaroid")
    /// Cassette J-card with monospaced tracklist chrome.
    static let cassette = LyricPosterStyleID("cassette")
    /// 牛皮纸信笺: 胶带、邮戳、手写落款, 照片像贴上去的。
    static let retroLetter = LyricPosterStyleID("retro_letter")
    /// 深色聚光: 大字歌词, 被唱到的那句用主色点亮。
    static let spotlight = LyricPosterStyleID("spotlight")
    /// 动态歌词卡: 封面配半张唱片, 底部声波, 为实况照片而生。
    static let motionCard = LyricPosterStyleID("motion_card")
    /// Deep navy sheet with a cover tile and a glow in the song's colour.
    /// Arrives with the Minimal interface skin.
    static let deepSea = LyricPosterStyleID("deep_sea")
}

/// Poster aspect. Values are the exported pixel sizes, which are also the
/// SwiftUI point sizes the renderers lay out in (rendered at scale 1).
public enum LyricPosterCanvas: String, Hashable, Sendable, CaseIterable, Codable {
    /// 1:1 — chat apps and avatars.
    case square
    /// 4:5 — the tallest frame feeds show without cropping.
    case portrait
    /// 9:16 — full-bleed stories and status updates.
    case story

    public var pixelWidth: Double { 1080 }

    public var pixelHeight: Double {
        switch self {
        case .square: return 1080
        case .portrait: return 1350
        case .story: return 1920
        }
    }

    public var aspectRatio: Double { pixelWidth / pixelHeight }
}

/// Everything the picker and the export pipeline need to know about a style
/// without instantiating its renderer.
public struct LyricPosterStyleDescriptor: Hashable, Sendable, Identifiable {
    public let id: LyricPosterStyleID
    /// Localization key for the style name shown in the picker.
    public let nameKey: String
    public let symbolName: String
    /// Canvas used when the user has not chosen one for this style yet.
    public let preferredCanvas: LyricPosterCanvas
    public let supportedCanvases: [LyricPosterCanvas]
    /// A style built around the cover art cannot stand in for a song whose
    /// artwork never resolved; the catalog hides it instead of drawing a
    /// placeholder square where the art should be.
    public let requiresArtwork: Bool
    public let supportsMotion: Bool
    /// Poster chrome is dark, so exported overlays and share previews can pick
    /// a matching status style.
    public let prefersDarkChrome: Bool
    /// Ascending display order in the picker.
    public let order: Int

    public init(
        id: LyricPosterStyleID,
        nameKey: String,
        symbolName: String,
        preferredCanvas: LyricPosterCanvas = .portrait,
        supportedCanvases: [LyricPosterCanvas] = LyricPosterCanvas.allCases,
        requiresArtwork: Bool = false,
        supportsMotion: Bool = true,
        prefersDarkChrome: Bool = true,
        order: Int
    ) {
        self.id = id
        self.nameKey = nameKey
        self.symbolName = symbolName
        self.preferredCanvas = preferredCanvas
        self.supportedCanvases = supportedCanvases
        self.requiresArtwork = requiresArtwork
        self.supportsMotion = supportsMotion
        self.prefersDarkChrome = prefersDarkChrome
        self.order = order
    }

    public func canvas(preferring requested: LyricPosterCanvas?) -> LyricPosterCanvas {
        guard let requested, supportedCanvases.contains(requested) else { return preferredCanvas }
        return requested
    }
}

/// The built-in style list plus the rules for which styles a given song can
/// actually use. Rendering lives in the app layer; this stays Foundation-only
/// so the ordering and fallback rules are testable.
public enum LyricPosterStyleCatalog {
    /// 新风格排在最前面用的是负数序号: 已有条目的序号一个都不用改,
    /// 同时在做界面皮肤的分支也就不会和这里撞在同一行上。
    public static let builtInDescriptors: [LyricPosterStyleDescriptor] = [
        LyricPosterStyleDescriptor(
            id: .retroLetter,
            nameKey: "lyric_poster_style_retro_letter",
            symbolName: "envelope",
            preferredCanvas: .portrait,
            requiresArtwork: true,
            prefersDarkChrome: false,
            order: -3
        ),
        LyricPosterStyleDescriptor(
            id: .spotlight,
            nameKey: "lyric_poster_style_spotlight",
            symbolName: "sun.max",
            preferredCanvas: .story,
            requiresArtwork: false,
            order: -2
        ),
        LyricPosterStyleDescriptor(
            id: .motionCard,
            nameKey: "lyric_poster_style_motion_card",
            symbolName: "opticaldisc.fill",
            preferredCanvas: .portrait,
            requiresArtwork: true,
            order: -1
        ),
        LyricPosterStyleDescriptor(
            id: .auroraGlass,
            nameKey: "lyric_poster_style_aurora_glass",
            symbolName: "sparkles",
            preferredCanvas: .portrait,
            requiresArtwork: true,
            order: 0
        ),
        LyricPosterStyleDescriptor(
            id: .gradientQuote,
            nameKey: "lyric_poster_style_gradient_quote",
            symbolName: "quote.opening",
            preferredCanvas: .portrait,
            requiresArtwork: false,
            order: 1
        ),
        LyricPosterStyleDescriptor(
            id: .magazine,
            nameKey: "lyric_poster_style_magazine",
            symbolName: "newspaper",
            preferredCanvas: .portrait,
            requiresArtwork: false,
            prefersDarkChrome: false,
            order: 2
        ),
        LyricPosterStyleDescriptor(
            id: .vinyl,
            nameKey: "lyric_poster_style_vinyl",
            symbolName: "opticaldisc",
            preferredCanvas: .square,
            requiresArtwork: true,
            order: 3
        ),
        LyricPosterStyleDescriptor(
            id: .filmStill,
            nameKey: "lyric_poster_style_film_still",
            symbolName: "film",
            preferredCanvas: .story,
            requiresArtwork: true,
            order: 4
        ),
        LyricPosterStyleDescriptor(
            id: .neonNight,
            nameKey: "lyric_poster_style_neon_night",
            symbolName: "bolt.fill",
            preferredCanvas: .story,
            requiresArtwork: false,
            order: 5
        ),
        LyricPosterStyleDescriptor(
            id: .polaroid,
            nameKey: "lyric_poster_style_polaroid",
            symbolName: "camera",
            preferredCanvas: .portrait,
            requiresArtwork: true,
            prefersDarkChrome: false,
            order: 6
        ),
        LyricPosterStyleDescriptor(
            id: .cassette,
            nameKey: "lyric_poster_style_cassette",
            symbolName: "recordingtape",
            preferredCanvas: .square,
            requiresArtwork: false,
            order: 7
        ),
        LyricPosterStyleDescriptor(
            id: .deepSea,
            nameKey: "lyric_poster_style_deep_sea",
            symbolName: "water.waves",
            preferredCanvas: .portrait,
            requiresArtwork: false,
            order: 8
        ),
    ]

    /// Styles offered for one song, in picker order.
    ///
    /// `requiresMotion` filters to styles that can animate — a saved
    /// preference for a still-only style must not silently produce a poster
    /// whose Live Photo half never moves.
    public static func availableDescriptors(
        in descriptors: [LyricPosterStyleDescriptor] = builtInDescriptors,
        hasArtwork: Bool,
        requiresMotion: Bool = false
    ) -> [LyricPosterStyleDescriptor] {
        descriptors
            .filter { hasArtwork || !$0.requiresArtwork }
            .filter { !requiresMotion || $0.supportsMotion }
            .sorted { $0.order < $1.order }
    }

    /// Resolves the style to show, honoring a stored preference when it is
    /// still usable and otherwise falling back to the first available style.
    public static func resolvedDescriptor(
        preferred: LyricPosterStyleID?,
        in descriptors: [LyricPosterStyleDescriptor] = builtInDescriptors,
        hasArtwork: Bool,
        requiresMotion: Bool = false
    ) -> LyricPosterStyleDescriptor? {
        let available = availableDescriptors(
            in: descriptors,
            hasArtwork: hasArtwork,
            requiresMotion: requiresMotion
        )
        if let preferred, let match = available.first(where: { $0.id == preferred }) {
            return match
        }
        return available.first
    }

    public static func descriptor(
        for id: LyricPosterStyleID,
        in descriptors: [LyricPosterStyleDescriptor] = builtInDescriptors
    ) -> LyricPosterStyleDescriptor? {
        descriptors.first { $0.id == id }
    }
}
