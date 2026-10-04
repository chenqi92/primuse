import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
typealias YearlyReportShareImage = UIImage
#elseif os(macOS)
import AppKit
typealias YearlyReportShareImage = NSImage
#endif

/// 年度报告的章节，按讲述的先后排：听了多久 → 从哪首歌开始 → 听谁、听什么 → 口味 →
/// 什么时候听 → 高光 → 哪个月 → 从哪来 → 你是谁 → 谢幕。没有数据的章不出现。
enum YearlyChapterKind: String, Hashable, CaseIterable {
    case cover, firstSong, artists, songs, taste, time, moments, month, sources, personality, closing

    static func visible(in data: YearlyReportData) -> [YearlyChapterKind] {
        allCases.filter { $0.isAvailable(in: data) }
    }

    func isAvailable(in data: YearlyReportData) -> Bool {
        let recap = data.recap
        switch self {
        case .cover, .closing: return true
        case .firstSong: return data.highlights.firstPlay != nil
        case .artists: return !data.artists.isEmpty
        case .songs: return !data.songs.isEmpty
        case .taste, .personality: return data.personality != nil
        case .time: return recap.peakHour != nil
        case .moments:
            return (recap.longestSession?.songs ?? 0) >= YearlyReportFacts.minimumSessionSongs
                || (recap.longestStreak?.days ?? 0) >= YearlyReportFacts.minimumStreakDays
        case .month:
            // 一年里只在一个月听过歌，「你的音乐月」没有可比的。
            guard let peak = data.highlights.peakMonth else { return false }
            return peak.plays < recap.totals.plays
        case .sources: return !data.sources.isEmpty
        }
    }

    func tone(in data: YearlyReportData) -> YearlyReportTone {
        switch self {
        case .cover: .cover
        case .firstSong: .firstSong
        case .artists: .artists
        case .songs: .songs
        case .taste: .taste
        case .time: .time(data.recap.peakDaypart ?? .evening)
        case .moments: .moments
        case .month: .month(data.highlights.peakMonth?.month ?? 1)
        case .sources: .sources
        case .personality: .personality
        case .closing: .closing
        }
    }
}

/// 几章共用的门槛。
enum YearlyReportFacts {
    /// 连听不到三首算不上「一口气」。
    static let minimumSessionSongs = 3
    static let minimumStreakDays = 3
}

/// 「最近的状态」要用的东西：只在今年的报告里接在音乐人格后面。
struct YearlyReportMood {
    let signals: ListeningMoodSignals
    /// 最近的播放时间，新的在前。
    let recentPlayDates: [Date]
    let clearedAt: Date?
}

/// 年度报告：一章接一章从上往下铺开。
///
/// 每章自己画一段从本章底色渐变到下一章底色的背景，整页连成一条色带；章与章之间
/// 一小段竖线接着。`header` 放在封面那一章最上面（换年份），`footer` 放在最后一章
/// 下面（清空记录），都落在同一条色带里。
struct YearlyReportPages<Header: View, Footer: View>: View {
    let data: YearlyReportData
    var mood: YearlyReportMood?
    /// 这一年听有声内容的时长；有声内容不进报告的任何一项，只在高光里提一句。
    var spokenWordSeconds: TimeInterval = 0
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer

    @State private var shareItem: ShareImageItem?

    var body: some View {
        let chapters = YearlyChapterKind.visible(in: data)
        VStack(spacing: 0) {
            ForEach(Array(chapters.enumerated()), id: \.element) { index, kind in
                section(kind, index: index, of: chapters)
            }
        }
        .tint(YearlyReportPalette.accent)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.images)
        }
    }

    /// 底色：本章的颜色渐到下一章的颜色。首尾两章各自延伸到页面外（见 `YearlyReportBackdrop`）。
    static func edgeTones(of data: YearlyReportData) -> (top: YearlyReportTone, bottom: YearlyReportTone) {
        let chapters = YearlyChapterKind.visible(in: data)
        return (chapters.first?.tone(in: data) ?? .cover, chapters.last?.tone(in: data) ?? .closing)
    }

    private func section(_ kind: YearlyChapterKind, index: Int, of chapters: [YearlyChapterKind]) -> some View {
        let tone = kind.tone(in: data)
        let next = index + 1 < chapters.count ? chapters[index + 1].tone(in: data) : tone
        let isLast = index == chapters.count - 1
        return VStack(spacing: 0) {
            if index == 0 {
                header()
                    .padding(.bottom, 18)
            } else {
                YearlyThread()
                    .padding(.bottom, 22)
            }
            chapter(kind, number: index)
            if isLast {
                footer()
                    .padding(.top, 40)
            }
        }
        .padding(.horizontal, RecapStyle.horizontalPadding)
        .padding(.top, index == 0 ? 12 : 0)
        .padding(.bottom, isLast ? 56 : 30)
        .frame(maxWidth: RecapStyle.maximumContentWidth)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [tone.color, next.color], startPoint: .top, endPoint: .bottom)
        }
        .id(kind)
    }

    @ViewBuilder
    private func chapter(_ kind: YearlyChapterKind, number: Int) -> some View {
        switch kind {
        case .cover: coverChapter
        case .firstSong: firstSongChapter(number)
        case .artists: artistsChapter(number)
        case .songs: songsChapter(number)
        case .taste: tasteChapter(number)
        case .time: timeChapter(number)
        case .moments: momentsChapter(number)
        case .month: monthChapter(number)
        case .sources: sourcesChapter(number)
        case .personality: personalityChapter(number)
        case .closing: closingChapter
        }
    }

    /// 「02 · 年度艺人」。
    private func eyebrow(_ number: Int, _ key: String.LocalizationValue) -> String {
        String(format: "%02d", number) + "  ·  " + String(localized: key)
    }

    private var yearText: String { String(data.year) }

    // MARK: 封面

    private var coverChapter: some View {
        let totals = data.recap.totals
        return YearlyChapter(
            eyebrow: String(format: String(localized: "yearly_report_entry_title"), data.year),
            art: YearlyArt(name: "decor_overview_hourglass", fallbackSymbol: "hourglass", maxWidth: 200, maxHeight: 168),
            lead: [coverLead, growthLine].compactMap { $0 }
        ) {
            RecapHeroDuration(seconds: totals.seconds, numberSize: 56)
                .multilineTextAlignment(.center)
        } content: {
            YearlyFigureGrid(figures: [
                .init(id: "songs", value: totals.uniqueSongs.formatted(), label: String(localized: "stats_unique_songs")),
                .init(id: "artists", value: totals.uniqueArtists.formatted(), label: String(localized: "stats_recap_figure_artists")),
                .init(id: "plays", value: totals.plays.formatted(), label: String(localized: "stats_total_plays")),
                .init(id: "days", value: totals.activeDays.formatted(), label: String(localized: "stats_active_days")),
            ])
        }
    }

    private var coverLead: String {
        guard data.isInProgress else { return String(localized: "yearly_cover_lead_complete") }
        return String(
            format: String(localized: "yearly_cover_lead_in_progress_format"),
            data.interval.end.formatted(.dateTime.month().day())
        )
    }

    /// 今年还没过完就比去年同期，过完了比去年整年。
    private var growthLine: String? {
        guard let growth = data.growth else { return nil }
        let percent = Int((abs(growth) * 100).rounded())
        if growth > 0.05 {
            return String(format: String(localized: data.isInProgress ? "yearly_growth_more_so_far_format" : "yearly_card_growth_more_format"), percent)
        }
        if growth < -0.05 {
            return String(format: String(localized: data.isInProgress ? "yearly_growth_less_so_far_format" : "yearly_card_growth_less_format"), percent)
        }
        return String(localized: data.isInProgress ? "yearly_growth_same_so_far" : "yearly_card_growth_same")
    }

    // MARK: 第一首歌

    @ViewBuilder
    private func firstSongChapter(_ number: Int) -> some View {
        if let first = data.highlights.firstPlay {
            let when = first.playedAt.formatted(.dateTime.month().day().hour().minute())
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_first_song"),
                art: YearlyArt(name: "decor_first_song", fallbackSymbol: "play.rectangle.fill", maxWidth: 150, maxHeight: 190),
                lead: [first.artist.isEmpty ? when : first.artist + "  ·  " + when]
            ) {
                YearlyHeadline(text: first.title)
            }
        }
    }

    // MARK: 年度艺人

    @ViewBuilder
    private func artistsChapter(_ number: Int) -> some View {
        if let leader = data.artists.first {
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_artists"),
                art: YearlyArt(name: "decor_trophy", fallbackSymbol: "trophy.fill", maxWidth: 180, maxHeight: 170),
                lead: [String(
                    format: String(localized: "yearly_card_top_artist_detail_format"),
                    leader.playCount,
                    RecapHeroDuration.format(leader.totalSec)
                )]
            ) {
                YearlyHeadline(text: leader.title)
            } content: {
                YearlyRankRows(
                    items: data.artists,
                    leaderPlayCount: leader.playCount,
                    firstPosition: 0,
                    isArtistRanking: true,
                    collapsedCount: 5
                )
            }
        }
    }

    // MARK: 年度歌曲

    @ViewBuilder
    private func songsChapter(_ number: Int) -> some View {
        if let leader = data.songs.first {
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_songs"),
                art: YearlyArt(name: "decor_record_stack", fallbackSymbol: "music.note.list", maxWidth: 140, maxHeight: 200),
                lead: [leader.subtitle.isEmpty
                    ? ListeningRankText.playCount(leader.playCount)
                    : String(format: String(localized: "yearly_meta_top_songs_sub_format"), leader.subtitle, leader.playCount)]
            ) {
                YearlyHeadline(text: leader.title)
            } content: {
                VStack(spacing: 16) {
                    YearlyRankRows(
                        items: data.songs,
                        leaderPlayCount: leader.playCount,
                        firstPosition: 0,
                        collapsedCount: 5
                    )
                    if data.albums.count > 1 {
                        YearlyAlbumShelf(
                            title: String(localized: "yearly_top_albums_title"),
                            items: Array(data.albums.prefix(8))
                        )
                    }
                }
            }
        }
    }

    // MARK: 口味

    @ViewBuilder
    private func tasteChapter(_ number: Int) -> some View {
        if let personality = data.personality {
            let recap = data.recap
            let explorer = personality.exploration == .explorer
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_taste"),
                art: YearlyArt(name: "decor_artists_chorus", fallbackSymbol: "person.3.fill", maxWidth: 300, maxHeight: 170),
                lead: [String(localized: explorer ? "yearly_taste_explorer_lead" : "yearly_taste_loyalist_lead")]
            ) {
                YearlyHeadline(text: String(localized: explorer ? "yearly_taste_explorer_title" : "yearly_taste_loyalist_title"))
            } content: {
                YearlyFactList(facts: tasteFacts(recap))
            }
        }
    }

    private func tasteFacts(_ recap: ListeningRecap) -> [YearlyFactList.Fact] {
        var facts = [YearlyFactList.Fact(
            symbol: "person.2.fill",
            text: String(
                format: String(localized: "yearly_taste_artists_format"),
                recap.totals.uniqueArtists,
                Int((recap.topFiveArtistShare * 100).rounded())
            )
        )]
        if recap.genreCount > 0, !recap.topGenres.isEmpty {
            facts.append(.init(symbol: "guitars.fill", text: String(
                format: String(localized: "yearly_taste_genres_format"),
                recap.genreCount,
                recap.topGenres.map(\.name).formatted(.list(type: .and))
            )))
        }
        if let discoveries = recap.discoveries, discoveries > 0 {
            facts.append(.init(symbol: "sparkles", text: String(
                format: String(localized: "yearly_discoveries_format"),
                discoveries
            )))
        }
        return facts
    }

    // MARK: 听歌的时间

    @ViewBuilder
    private func timeChapter(_ number: Int) -> some View {
        if let hour = data.recap.peakHour {
            let daypart = data.recap.peakDaypart ?? .of(hour: hour)
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_time"),
                art: YearlyArt(name: daypart.yearlyArtworkName, fallbackSymbol: daypart.symbolName, maxWidth: 340, maxHeight: 136),
                lead: [
                    String(format: String(localized: "yearly_card_time_detail_format"), daypart.localizedLabel),
                    String(format: String(localized: "yearly_time_night_share_format"), Int((data.recap.nightShare * 100).rounded())),
                ]
            ) {
                YearlyHeadline(text: hourLabel(hour))
            } content: {
                if let latest = data.highlights.latestNight {
                    YearlyFactList(facts: [.init(symbol: "moon.stars.fill", text: String(
                        format: String(localized: "yearly_latest_night_format"),
                        latest.title,
                        latest.playedAt.formatted(.dateTime.month().day().hour().minute())
                    ))])
                }
            }
        }
    }

    /// 「晚上11时」「11 PM」：按当前语言写钟点。
    private func hourLabel(_ hour: Int) -> String {
        let calendar = ListeningCalendar.current
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: 高光时刻

    private func momentsChapter(_ number: Int) -> some View {
        let recap = data.recap
        let session = recap.longestSession.flatMap { $0.songs >= YearlyReportFacts.minimumSessionSongs ? $0 : nil }
        let streak = recap.longestStreak.flatMap { $0.days >= YearlyReportFacts.minimumStreakDays ? $0 : nil }
        let facts = momentFacts(session: session, streak: streak)
        let headline: String
        let lead: String
        if let session {
            headline = RecapHeroDuration.format(session.seconds)
            lead = String(
                format: String(localized: "yearly_moments_session_lead_format"),
                session.start.formatted(.dateTime.month().day()),
                session.songs
            )
        } else {
            headline = String(format: String(localized: "stats_moment_streak_format"), streak?.days ?? 0)
            lead = String(localized: "yearly_moments_streak_lead")
        }
        return YearlyChapter(
            eyebrow: eyebrow(number, "yearly_chapter_moments"),
            art: YearlyArt(name: "decor_badge_moment", fallbackSymbol: "rosette", maxWidth: 160, maxHeight: 150),
            lead: [lead]
        ) {
            YearlyHeadline(text: headline)
        } content: {
            if !facts.isEmpty {
                YearlyFactList(facts: facts)
            }
        }
    }

    /// 标题讲了最长的一次连听，这里补上连续天数、听得最多的一天和有声内容。
    private func momentFacts(session: ListeningRecap.Session?, streak: ListeningRecap.Streak?) -> [YearlyFactList.Fact] {
        let recap = data.recap
        var facts: [YearlyFactList.Fact] = []
        if session != nil, let streak {
            facts.append(.init(symbol: "flame.fill", text: String(format: String(localized: "stats_moment_streak_format"), streak.days)))
        }
        if recap.totals.activeDays > 1, let day = recap.busiestDay {
            facts.append(.init(symbol: "calendar", text: String(
                format: String(localized: "stats_moment_busiest_day_format"),
                day.date.formatted(.dateTime.month().day()),
                RecapHeroDuration.format(day.seconds)
            )))
        }
        if spokenWordSeconds >= 60 {
            facts.append(.init(symbol: ListeningSpace.spokenWord.systemImage, text: String(
                format: String(localized: "stats_moment_spoken_format"),
                RecapHeroDuration.format(spokenWordSeconds)
            )))
        }
        return facts
    }

    // MARK: 音乐月

    @ViewBuilder
    private func monthChapter(_ number: Int) -> some View {
        if let peak = data.highlights.peakMonth {
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_month"),
                art: YearlyArt(name: String(format: "month_%02d", peak.month), fallbackSymbol: "calendar", maxWidth: 340, maxHeight: 164),
                lead: monthLead(peak)
            ) {
                YearlyHeadline(text: monthName(peak.month))
            }
        }
    }

    private func monthLead(_ peak: ListeningYearHighlights.Month) -> [String] {
        var lead = [String(format: String(localized: "yearly_month_lead_format"), RecapHeroDuration.format(peak.seconds))]
        if let song = peak.topSong {
            lead.append(String(format: String(localized: "yearly_card_peak_month_top_format"), song.title))
        }
        return lead
    }

    private func monthName(_ month: Int) -> String {
        guard (1...12).contains(month) else {
            return String(format: String(localized: "yearly_month_n_format"), month)
        }
        // 先拼成普通字符串：直接写插值字面量会被当成带占位符的键「yearly_month_%lld」。
        let key = "yearly_month_\(month)"
        return String(localized: String.LocalizationValue(key))
    }

    // MARK: 音乐源

    @ViewBuilder
    private func sourcesChapter(_ number: Int) -> some View {
        if let top = data.sources.first {
            let total = data.sources.reduce(0.0) { $0 + $1.seconds }
            let percent: (YearlyReportData.SourceShare) -> Int = { total > 0 ? Int(($0.seconds / total * 100).rounded()) : 0 }
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_sources"),
                art: YearlyArt(name: "decor_sources_pipeline", fallbackSymbol: "point.3.connected.trianglepath.dotted", maxWidth: 300, maxHeight: 150),
                lead: [String(format: String(localized: "yearly_sources_lead_format"), percent(top))]
            ) {
                YearlyHeadline(text: top.name)
            } content: {
                if data.sources.count > 1 {
                    VStack(spacing: 14) {
                        ForEach(data.sources.prefix(4)) { share in
                            YearlySourceRow(share: share, percent: percent(share))
                        }
                    }
                    .recapPanel(padding: 16)
                }
            }
        }
    }

    // MARK: 音乐人格

    @ViewBuilder
    private func personalityChapter(_ number: Int) -> some View {
        if let personality = data.personality {
            YearlyChapter(
                eyebrow: eyebrow(number, "yearly_chapter_personality"),
                art: YearlyArt(name: personality.assetName, fallbackSymbol: "person.crop.circle.fill", maxWidth: 230, maxHeight: 230),
                lead: personality.oneLiner.isEmpty ? [] : [personality.oneLiner]
            ) {
                YearlyHeadline(text: personality.displayName)
            } content: {
                VStack(spacing: 20) {
                    YearlyChipRow(labels: personality.traitLabels)
                    Button {
                        share(personality)
                    } label: {
                        Label("share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(YearlyReportPalette.accent.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(YearlyReportPalette.accent)

                    if let mood, mood.signals.plays >= ListeningMoodRefreshPolicy.minimumPlays {
                        ListeningMoodCard(
                            signals: mood.signals,
                            recentPlayDates: mood.recentPlayDates,
                            clearedAt: mood.clearedAt
                        )
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    @MainActor
    private func share(_ personality: MusicPersonality) {
        let card = YearlyPersonalityShareCard(year: data.year, personality: personality)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        #if os(iOS)
        let image = renderer.uiImage
        #else
        let image = renderer.nsImage
        #endif
        if let image { shareItem = ShareImageItem(images: [image]) }
    }

    // MARK: 谢幕

    private var closingChapter: some View {
        YearlyChapter(
            eyebrow: String(localized: data.isInProgress ? "yearly_chapter_to_be_continued" : "yearly_chapter_closing"),
            art: YearlyArt(name: "decor_curtain_close", fallbackSymbol: "music.note", maxWidth: 340, maxHeight: 180),
            lead: [data.isInProgress
                ? String(localized: "yearly_closing_in_progress_lead")
                : String(format: String(localized: "yearly_card_closing_next_format"), String(data.year + 1))]
        ) {
            YearlyHeadline(
                text: data.isInProgress
                    ? String(format: String(localized: "yearly_closing_in_progress_title_format"), yearText)
                    : String(localized: "yearly_card_closing_thanks"),
                style: data.isInProgress ? .title : .title2
            )
        }
    }
}

extension YearlyReportPages where Header == EmptyView, Footer == EmptyView {
    init(data: YearlyReportData, mood: YearlyReportMood? = nil, spokenWordSeconds: TimeInterval = 0) {
        self.init(data: data, mood: mood, spokenWordSeconds: spokenWordSeconds, header: { EmptyView() }, footer: { EmptyView() })
    }
}

/// 页面上下拉过头时露出的底色：上半是第一章的颜色，下半是最后一章的颜色。
struct YearlyReportBackdrop: View {
    let top: YearlyReportTone
    let bottom: YearlyReportTone

    var body: some View {
        VStack(spacing: 0) {
            top.color
            bottom.color
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - 分享图

/// 音乐人格的分享图：固定深色，竖版 360 × 640 点，按 3 倍渲染成 1080 × 1920。
private struct YearlyPersonalityShareCard: View {
    let year: Int
    let personality: MusicPersonality

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: String(format: String(localized: "yearly_report_entry_title"), year))
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(YearlyReportPalette.accent)
                .padding(.top, 54)
            Spacer(minLength: 12)
            YearlyArtView(art: YearlyArt(
                name: personality.assetName,
                fallbackSymbol: "person.crop.circle.fill",
                maxWidth: 260,
                maxHeight: 260
            ))
            Text(verbatim: String(localized: "yearly_chapter_personality"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 24)
            Text(verbatim: personality.displayName)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text(verbatim: personality.oneLiner)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
            YearlyChipRow(labels: personality.traitLabels)
                .padding(.top, 18)
            Spacer(minLength: 12)
            Text(verbatim: String(localized: "yearly_share_footer"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
        .frame(width: 360, height: 640)
        .tint(YearlyReportPalette.accent)
        .background {
            LinearGradient(
                colors: [YearlyReportTone.personality.color, YearlyReportTone.closing.color],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct ShareImageItem: Identifiable {
    let id = UUID()
    let images: [YearlyReportShareImage]
}

// MARK: - 一月自动弹出的报告

/// 去年报告的那一年，给 `fullScreenCover(item:)` 用。
struct YearlyReportYear: Identifiable {
    let year: Int
    var id: Int { year }
}

/// 一月自动弹出的去年报告：就是「听歌统计」这一页，单独开一屏，右上角关掉。
struct YearlyReportScreen: View {
    let year: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ListeningStatsView(initialYear: year, showsManagement: false)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(Text("close"))
                    }
                }
        }
    }
}

// MARK: - 叫法

extension MusicPersonality {
    /// 四个维度的标签：爱探索 / 杂食 / 追新 / 夜行……
    var traitLabels: [String] {
        [
            exploration == .explorer ? "stats_trait_explorer" : "stats_trait_loyalist",
            diversity == .omnivore ? "stats_trait_omnivore" : "stats_trait_focused",
            recency == .new ? "stats_trait_new" : "stats_trait_vintage",
            dayCycle == .day ? "stats_trait_day" : "stats_trait_moon",
        ].map { String(localized: String.LocalizationValue($0)) }
    }
}

extension ListeningDaypart {
    var symbolName: String {
        switch self {
        case .dawn: "sunrise.fill"
        case .morning: "sun.max.fill"
        case .afternoon: "sun.haze.fill"
        case .evening: "sunset.fill"
        case .lateNight: "moon.stars.fill"
        }
    }

    /// 时段插画：清晨、白天、傍晚、深夜四张。
    var yearlyArtworkName: String {
        switch self {
        case .dawn: "timeofday_dawn"
        case .morning, .afternoon: "timeofday_noon"
        case .evening: "timeofday_dusk"
        case .lateNight: "timeofday_night"
        }
    }
}
