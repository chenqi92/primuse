import PrimuseKit
import SwiftUI

/// 歌词最上面那一排小标签(iOS 与 Mac 播放页共用):逐字歌词标「逐字」,知道来源时再标来源(#357)。
struct LyricsInfoBadges: View {
    let showsWordLevel: Bool
    var showsSimulatedWordTiming = false
    let source: LyricsSourceBadge?
    let foreground: Color
    let fill: Color
    var companionTracks: LyricBundledTranslationPolicy.Tracks = []
    var trackCatalog: LyricTrackCatalog = .empty
    var songID: String? = nil
    var onInteraction: (() -> Void)? = nil

    var body: some View {
        if companionTracks.isEmpty && !trackCatalog.hasReplacementTracks {
            badges
        } else if !showsWordLevel && !showsSimulatedWordTiming && source == nil {
            buttons
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    badges
                    buttons
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                    badges
                    buttons
                }
            }
        }
    }

    private var buttons: some View {
        LyricsCompanionTrackButtons(
            tracks: companionTracks,
            catalog: trackCatalog,
            songID: songID,
            foreground: foreground,
            fill: fill,
            onInteraction: onInteraction
        )
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if showsSimulatedWordTiming {
                capsule(symbol: "waveform", text: Text("lyrics_simulated_word_badge"))
                    .accessibilityIdentifier("simulatedWordLyricsBadge")
            } else if showsWordLevel {
                capsule(symbol: "waveform", text: Text("lyrics_word_level_badge"))
            }
            if let source {
                let title = source.displayTitle
                capsule(symbol: source.symbolName, text: Text(verbatim: title))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: String(
                        format: String(localized: "lyrics_source_badge_a11y_format"),
                        title
                    )))
            }
        }
    }

    private func capsule(symbol: String, text: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
            text
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(fill))
    }
}

extension LyricsSourceBadge {
    /// 标签上写的字。服务器写它的类型,在线歌词源写源的名字;自定义源删掉了就用取到时记下的名字。
    var displayTitle: String {
        switch self {
        case .localEdit:
            return String(localized: "lyrics_source_badge_local_edit")
        case .file(let format?):
            return String(format: String(localized: "lyrics_source_badge_file_format"), format)
        case .file(.none):
            return String(localized: "lyrics_source_badge_file")
        case .embedded:
            return String(localized: "lyrics_source_badge_embedded")
        case .server(let sourceType):
            return MusicSourceType(rawValue: sourceType)?.displayName ?? sourceType
        case .online(let identifier, let name):
            let type = MusicScraperType(rawValue: identifier)
            if case .custom(let configID) = type, ScraperConfigStore.shared.config(for: configID) == nil {
                return name.isEmpty ? configID : name
            }
            return type.displayName
        case .appleMusic:
            return "Apple Music"
        }
    }

    var symbolName: String {
        switch self {
        case .localEdit: "pencil"
        case .file: "doc.text"
        case .embedded: "tag"
        case .server: "server.rack"
        case .online: "globe"
        case .appleMusic: "music.note"
        }
    }
}
