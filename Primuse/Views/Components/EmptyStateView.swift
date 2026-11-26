import SwiftUI

/// Lightweight pulse shared by full-page loading placeholders. It animates a
/// single container opacity instead of driving every skeleton block on its own,
/// keeping large dashboards inexpensive while still making the loading state
/// feel alive. Reduce Motion keeps the same layout without animation.
struct LoadingSkeletonGroup<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRenderingVisible = false

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let animates = isRenderingVisible && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animates)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate / 2.16 * 2 * .pi
            content.opacity(animates ? 0.75 + 0.17 * cos(phase) : 0.82)
        }
        .onRenderingVisibilityChange { isRenderingVisible = $0 }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Reusable empty-state view for sub-pages (library lists, queue,
/// recently deleted, smart playlist no-match, etc.). Three goals:
///
/// 1. **Visual consistency** — every empty state across the app
///    looks like it came from the same designer instead of N
///    different `ContentUnavailableView` flavors.
/// 2. **Lightweight by default** — empty states render as compact SF
///    Symbol compositions. Search/library/tool surfaces should feel like
///    app UI, not a gallery of one-off posters.
/// 3. **Action-aware** — supports an optional CTA button so views
///    that have a recovery path ("add a source", "create a
///    playlist") get a single tap to fix the empty state.
///
/// Use this in preference to `ContentUnavailableView` whenever the
/// empty state is content-related ("no songs in library", "smart
/// playlist matched nothing"). Keep `ContentUnavailableView.search`
/// for the system-styled search empty state — Apple's version
/// already has the perfect treatment for that one specific case.
struct EmptyStateView: View {
    let titleKey: LocalizedStringKey
    let descriptionKey: LocalizedStringKey?
    let systemImage: String
    let actionLabel: LocalizedStringKey?
    let action: (() -> Void)?

    @Environment(\.pmHeightClass) private var heightClass

    init(
        titleKey: LocalizedStringKey,
        descriptionKey: LocalizedStringKey? = nil,
        systemImage: String,
        actionLabel: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.titleKey = titleKey
        self.descriptionKey = descriptionKey
        self.systemImage = systemImage
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: 18) {
            // 空态几乎都是「加载完发现没东西」才出现的：图标先轻轻弹出来，字随后淡入，
            // 比整块一起淡进来更像「到这儿了」。只动透明度、缩放和几个点的上浮，不影响调用方的布局。
            illustration
                .pmPopIn(from: 0.72)
            VStack(spacing: 6) {
                Text(titleKey)
                    .font(.title3).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                if let descriptionKey {
                    Text(descriptionKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .pmEntrance(delay: Self.textDelay, rise: 6)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .fontWeight(.medium)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .prominentLabelOnAccent()
                .clipShape(Capsule())
                .padding(.top, 4)
                .pmEntrance(delay: Self.actionDelay, rise: 6)
            }
        }
        .frame(maxWidth: .infinity)
        // 手机横屏纵向只剩三百多点，空态再占 32 的上下留白就会把 CTA 顶出可视区。
        .padding(.vertical, heightClass.value(32, compact: 16))
        .accessibilityElement(children: .contain)
    }

    /// 字比图标晚一点、按钮再晚一点出来：先看到图，再读到字。
    private static let textDelay: TimeInterval = 0.08
    private static let actionDelay: TimeInterval = 0.14

    private var illustration: some View {
        EmptyStateGlyph(systemImage: systemImage)
    }
}

private struct EmptyStateGlyph: View {
    let systemImage: String

    @Environment(\.pmHeightClass) private var heightClass

    private var accentSymbol: String {
        switch systemImage {
        case "magnifyingglass":
            "music.note"
        case "music.note", "music.note.list":
            "waveform"
        case "square.stack":
            "music.note"
        case "music.mic":
            "person.wave.2"
        case "trash":
            "arrow.uturn.backward"
        default:
            "sparkles"
        }
    }

    var body: some View {
        // 手机横屏收一档。字号、偏移、图标框按同一个系数等比缩 —— 只缩图标框的话，
        // 右上角那枚副符号会被挤到框外。
        let scale = heightClass.value(1, compact: 0.75)
        let accentSize: CGFloat = 24 * scale
        let accentOffsetX: CGFloat = 28 * scale
        let accentOffsetY: CGFloat = -22 * scale
        let mainSize: CGFloat = 54 * scale
        let mainOffsetX: CGFloat = -3 * scale
        let mainOffsetY: CGFloat = 4 * scale
        let boxWidth: CGFloat = 112 * scale
        let boxHeight: CGFloat = 88 * scale

        ZStack {
            Image(systemName: accentSymbol)
                .font(.system(size: accentSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary.opacity(0.28))
                .offset(x: accentOffsetX, y: accentOffsetY)

            Image(systemName: systemImage)
                .font(.system(size: mainSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .offset(x: mainOffsetX, y: mainOffsetY)
        }
        .frame(width: boxWidth, height: boxHeight)
        .accessibilityHidden(true)
    }
}

/// 数字一律按地区分组（「12,345 首歌曲」）：以前各处要么自己 `.formatted()`，要么靠 `Text("\(n) …")` 的本地化插值。
/// `bundle` 与 `locale` 只有测试会传。
enum LibraryCountText {
    static func songs(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("song_count_singular", bundle: bundle) }
        return "\(number(count, locale: locale)) \(localized("songs_count", bundle: bundle))"
    }

    static func formattedSongs(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        songs(count, bundle: bundle, locale: locale)
    }

    static func albums(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("album_count_singular", bundle: bundle) }
        return "\(number(count, locale: locale)) \(localized("albums_count", bundle: bundle))"
    }

    static func formattedAlbums(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        albums(count, bundle: bundle, locale: locale)
    }

    static func artists(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("artist_count_singular", bundle: bundle) }
        return "\(number(count, locale: locale)) \(localized("artists_count", bundle: bundle))"
    }

    static func genres(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("genre_count_singular", bundle: bundle) }
        return "\(number(count, locale: locale)) \(localized("genres_count", bundle: bundle))"
    }

    static func playlists(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("playlist_count_singular", bundle: bundle) }
        return "\(number(count, locale: locale)) \(localized("playlists_count", bundle: bundle))"
    }

    static func rules(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("rule_count_singular", bundle: bundle) }
        return "\(number(count, locale: locale)) \(localized("rules_count", bundle: bundle))"
    }

    static func plays(_ count: Int, bundle: Bundle = .main) -> String {
        if count == 1 { return localized("stats_play_count_singular", bundle: bundle) }
        return String(format: localized("stats_play_count_format", bundle: bundle), count)
    }

    static func monthlyPlays(_ count: Int, bundle: Bundle = .main) -> String {
        if count == 1 { return localized("artist_monthly_plays_singular", bundle: bundle) }
        return String(format: localized("artist_monthly_plays_format", bundle: bundle), count)
    }

    static func results(_ count: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent) -> String {
        if count == 1 { return localized("filter_result_singular", bundle: bundle) }
        return String(format: localized("filter_results_format", bundle: bundle), locale: locale, count)
    }

    static func folderCounts(
        subdirectories: Int, songs: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let dirPart = subdirectories == 1
            ? localized("folder_subdirectory_singular", bundle: bundle)
            : String(format: localized("folder_subdirectories_format", bundle: bundle), locale: locale, subdirectories)
        return "\(dirPart) · \(Self.songs(songs, bundle: bundle, locale: locale))"
    }

    static func playableRatio(
        playable: Int, total: Int, bundle: Bundle = .main, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let ratio = total > 0 ? Double(playable) / Double(total) : 0
        let percent = ratio.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return "\(localized("home_playable", bundle: bundle)) \(percent)"
    }

    private static func number(_ count: Int, locale: Locale) -> String {
        count.formatted(.number.locale(locale))
    }

    private static func localized(_ key: String, bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
