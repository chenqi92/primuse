import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
typealias YearlyReportShareImage = UIImage
#elseif os(macOS)
import AppKit
typealias YearlyReportShareImage = NSImage
#endif

/// 年度音乐报告主容器 ── Stories 风格的纵向翻页卡片浏览器。
///
/// - 12 张卡片按顺序播放, 每张默认 ~6s
/// - 上下滑翻页 (上滑下一张 / 下滑上一张)
/// - 右上 X 退出
/// - 仅"音乐人格"卡显示分享按钮 ── 渲染当前卡为图片直接分享
///
/// 设计来源: Spotify Wrapped / Instagram Stories 同款交互。
struct YearlyReportView: View {
    let data: YearlyReportData
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    @State private var elapsed: TimeInterval = 0
    @State private var lastTickAt: Date = Date()
    @State private var shareImageItem: ShareImageItem?
    /// 滑动方向 ── 上滑下一张时新卡从下方进入, 下滑上一张时从上方进入,
    /// 跟手势方向一致, 比单纯 opacity 更有"翻页"质感。
    @State private var lastTransitionDirection: TransitionDirection = .forward

    private static let cardDuration: TimeInterval = 6.0
    private let cards: [YearlyReportCard] = YearlyReportCard.allCases

    private var currentCard: YearlyReportCard { cards[currentIndex] }

    enum TransitionDirection { case forward, backward }

    var body: some View {
        if data.isEmpty {
            emptyStateView
        } else {
            #if os(macOS)
            macMainBody
            #else
            mainBody
            #endif
        }
    }

    /// 真实数据为空时显示的占位 ── 让用户知道"听够多歌再来看"。
    private var emptyStateView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.10, blue: 0.45), Color(red: 0.10, green: 0.10, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 80, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                Text(String(format: String(localized: "yearly_empty_title_format"), String(data.year)))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text(String(localized: "yearly_empty_desc"))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    #if os(macOS)
    /// macOS follows `design/猿音/scenes/yearly.jsx`: one wide report
    /// window with a horizontal story strip, not the iOS vertical Stories
    /// pager. The data source and share renderer stay shared.
    private var macMainBody: some View {
        ZStack {
            Color(red: 0.055, green: 0.050, blue: 0.042).ignoresSafeArea()
            AmbientBackdrop(
                accent: Color(red: 0.85, green: 0.43, blue: 0.27),
                darkAccent: Color(red: 0.16, green: 0.10, blue: 0.23),
                strength: 0.86
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                macHeader
                    .padding(.horizontal, 48)
                    .padding(.top, 36)
                    .padding(.bottom, 24)

                macStoryStrip
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                macFooter
                    .padding(.horizontal, 48)
                    .padding(.top, 18)
                    .padding(.bottom, 48)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .preferredColorScheme(.dark)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width < -60 { macAdvance() }
                    else if value.translation.width > 60 { macBack() }
                }
        )
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        .sheet(item: $shareImageItem) { item in
            ShareSheet(items: item.images)
        }
    }

    private var macHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.85, green: 0.43, blue: 0.27))

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "yearly_wrapped_brand"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(String(format: String(localized: "yearly_report_year_title_format"), String(data.year)))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.90))
            }

            Spacer()

            Text(verbatim: "\(currentIndex + 1) / \(cards.count)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.50))

            PMRoundBtn(icon: "xmark", size: 28, iconSize: 11, style: .glass, help: "close") {
                dismiss()
            }
        }
    }

    private var macStoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(Array(cards.enumerated()), id: \.element) { index, card in
                        macStoryTile(card: card, index: index)
                            .id(card)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 28)
            }
            .onChange(of: currentIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.26)) {
                    proxy.scrollTo(cards[newValue], anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(currentCard, anchor: .center)
            }
        }
    }

    private func macStoryTile(card: YearlyReportCard, index: Int) -> some View {
        let selected = index == currentIndex
        let dimmed = abs(index - currentIndex) > 2
        let meta = macMetadata(for: card)

        return Button {
            withAnimation(.easeInOut(duration: 0.24)) {
                lastTransitionDirection = index >= currentIndex ? .forward : .backward
                currentIndex = index
                elapsed = 0
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: meta.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)

                    Text(verbatim: meta.big)
                        .font(.system(size: selected ? 56 : 34, weight: .bold))
                        .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.90))
                        .lineLimit(3)
                        .minimumScaleFactor(0.62)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                if meta.showsBars && selected {
                    macBars
                        .frame(height: 100)
                        .padding(.bottom, 18)
                } else {
                    Image(systemName: meta.symbol)
                        .font(.system(size: selected ? 64 : 46, weight: .light))
                        .foregroundStyle(Color.white.opacity(selected ? 0.42 : 0.22))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, selected ? 28 : 18)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: meta.sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    if selected {
                        HStack(spacing: 8) {
                            Button {
                                shareCurrent()
                            } label: {
                                Label(String(localized: "yearly_share_card"), systemImage: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .labelStyle(.titleAndIcon)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            Button {
                                macAdvance()
                            } label: {
                                Text(String(localized: "yearly_next_card"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.72))
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
            .frame(width: selected ? 380 : 260, height: selected ? 580 : 460)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(selected ? 0.16 : 0.10),
                                Color.white.opacity(selected ? 0.04 : 0.02),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.24 : 0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(selected ? 0.45 : 0.25),
                    radius: selected ? 30 : 18,
                    y: selected ? 24 : 12)
            .offset(y: selected ? -8 : 0)
            .opacity(dimmed ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.24), value: currentIndex)
        }
        .buttonStyle(.plain)
    }

    private var macBars: some View {
        let values: [CGFloat] = [24, 28, 32, 40, 46, 52, 58, 72, 76, 82, 98, 92]
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index == 10
                          ? Color(red: 0.85, green: 0.43, blue: 0.27)
                          : Color.white.opacity(0.62))
                    .frame(height: value)
            }
        }
    }

    private var macFooter: some View {
        HStack(spacing: 10) {
            PMRoundBtn(icon: "chevron.left", size: 32, iconSize: 13, style: .glass, help: "back") {
                macBack()
            }

            HStack(spacing: 4) {
                ForEach(cards.indices, id: \.self) { index in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(index <= currentIndex ? 0.40 : 0.18))
                            if index < currentIndex {
                                Capsule().fill(Color.white.opacity(0.72))
                            } else if index == currentIndex {
                                Capsule().fill(Color.white)
                                    .frame(width: max(4, geo.size.width * CGFloat(min(elapsed / Self.cardDuration, 1))))
                            }
                        }
                    }
                    .frame(height: 3)
                }
            }

            PMRoundBtn(icon: "chevron.right", size: 32, iconSize: 13, style: .glass, help: "next") {
                macAdvance()
            }
            PMRoundBtn(icon: "square.and.arrow.down", size: 32, iconSize: 13, style: .glass, help: "share") {
                shareCurrent()
            }
        }
    }

    private func macMetadata(for card: YearlyReportCard) -> (title: String, big: String, sub: String, symbol: String, showsBars: Bool) {
        let hours = Int(data.totalSec / 3600)
        let topSong = data.mostPlayedSong ?? data.topSongs.first
        let topArtist = data.topArtists.first
        let topSource = data.sourceBreakdown.first
        let personality = data.personality

        switch card {
        case .hero:
            return (String(localized: "yearly_wrapped_brand"), "\(data.year)", String(localized: "yearly_meta_hero_sub"), "sparkles", false)
        case .overview:
            return (String(localized: "yearly_meta_overview_title"),
                    String(format: String(localized: "yearly_meta_overview_big_format"), hours),
                    String(format: String(localized: "yearly_meta_overview_sub_format"), data.uniqueSongCount, data.uniqueArtistCount, data.totalEntries),
                    "chart.bar.xaxis", true)
        case .firstSong:
            return (String(localized: "yearly_meta_first_song_title"),
                    data.firstSong?.songTitle ?? String(localized: "yearly_no_record"),
                    data.firstSong?.artistName ?? String(localized: "yearly_meta_first_song_placeholder_artist"),
                    "play.rectangle.fill", false)
        case .topArtistHero:
            return (String(localized: "yearly_meta_top_artist_title"),
                    topArtist?.title ?? String(localized: "yearly_no_artist"),
                    String(format: String(localized: "yearly_meta_top_artist_sub_format"), topArtist?.playCount ?? 0, formatDuration(topArtist?.totalSec ?? 0)),
                    "person.wave.2", false)
        case .topArtistsList:
            return (String(localized: "yearly_meta_artists_title"), topArtistsText, String(localized: "yearly_meta_artists_sub"), "person.3.fill", false)
        case .topSongs:
            return (String(localized: "yearly_meta_top_songs_title"),
                    topSong?.title ?? String(localized: "yearly_no_song"),
                    String(format: String(localized: "yearly_meta_top_songs_sub_format"), topSong?.subtitle ?? "", topSong?.playCount ?? 0),
                    "music.note.list", false)
        case .moments:
            return (String(localized: "yearly_meta_moments_title"),
                    formatDuration(data.longestSession?.totalSec ?? 0),
                    String(format: String(localized: "yearly_meta_moments_sub_format"), data.longestSession?.songCount ?? 0, dateText(data.longestSession?.startedAt)),
                    "clock.arrow.circlepath", false)
        case .timeOfDay:
            return (String(localized: "yearly_meta_time_title"),
                    String(format: String(localized: "yearly_meta_time_big_format"), Int(data.nightRatio * 100)),
                    String(format: String(localized: "yearly_meta_time_sub_format"), data.timeOfDayLabel, data.peakHour),
                    "moon.stars.fill", false)
        case .genres:
            let topGenre = data.topGenres.first
            let names = data.topGenres.prefix(3).map(\.title).joined(separator: " · ")
            return (String(localized: "yearly_meta_genres_title"),
                    topGenre?.title ?? String(format: String(localized: "yearly_meta_genres_placeholder_format"), data.genreCount),
                    names.isEmpty ? String(localized: "yearly_meta_genres_sub_empty") : String(localized: "yearly_meta_genres_sub"),
                    "guitars", false)
        case .exploration:
            let focus = (data.explorationTopArtistShare * 100).rounded().finiteInt()
            let exploration = max(0, 100 - focus)
            let tendency = data.personality?.exploration == .explorer
                ? String(localized: "yearly_exploration_explorer")
                : String(localized: "yearly_exploration_deep")
            return (String(localized: "yearly_meta_exploration_title"),
                    "\(exploration)%",
                    String(format: String(localized: "yearly_meta_exploration_sub_format"), focus, tendency),
                    "safari.fill", false)
        case .sources:
            return (String(localized: "yearly_meta_sources_title"),
                    topSource?.displayName ?? String(localized: "yearly_no_source"),
                    String(format: String(localized: "yearly_meta_sources_sub_format"), topSource?.playCount ?? 0, formatDuration(topSource?.totalSec ?? 0)),
                    topSource?.iconSymbol ?? "externaldrive", false)
        case .peakMonth:
            return (String(localized: "yearly_meta_peak_month_title"),
                    String(format: String(localized: "yearly_meta_peak_month_big_format"), data.peakMonth),
                    data.peakMonthTopSong.map { String(format: String(localized: "yearly_meta_peak_month_sub_format"), $0) } ?? String(localized: "yearly_meta_peak_month_sub_default"),
                    "calendar", false)
        case .personality:
            return (String(localized: "yearly_meta_personality_title"),
                    personality?.displayName ?? String(localized: "yearly_meta_personality_placeholder"),
                    personality?.oneLiner ?? String(localized: "yearly_meta_personality_sub"),
                    "person.crop.circle.badge.checkmark", false)
        case .closing:
            return (String(localized: "yearly_meta_closing_title"),
                    String(format: String(localized: "yearly_meta_closing_big_format"), max(1, hours / 24)),
                    String(localized: "yearly_meta_closing_sub"), "heart.fill", false)
        }
    }

    private var topArtistsText: String {
        let names = data.topArtists.prefix(3).map(\.title)
        return names.isEmpty ? String(localized: "yearly_no_artist") : names.joined(separator: " · ")
    }

    private func macAdvance() {
        lastTransitionDirection = .forward
        withAnimation(.easeInOut(duration: 0.26)) {
            currentIndex = min(cards.count - 1, currentIndex + 1)
            elapsed = 0
        }
    }

    private func macBack() {
        lastTransitionDirection = .backward
        withAnimation(.easeInOut(duration: 0.26)) {
            currentIndex = max(0, currentIndex - 1)
            elapsed = 0
        }
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        guard sec > 0 else { return String(localized: "yearly_duration_zero") }
        let hours = (sec / 3600).finiteInt()
        let minutes = (sec.truncatingRemainder(dividingBy: 3600) / 60).finiteInt()
        if hours > 0 { return String(format: String(localized: "yearly_duration_hm_format"), hours, minutes) }
        return String(format: String(localized: "yearly_duration_minutes_format"), minutes)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return String(localized: "yearly_no_date") }
        return date.formatted(.dateTime.month().day())
    }
    #endif

    private var mainBody: some View {
        ZStack {
            // 卡片背景渐变 ── 每张卡各自的色调, 用 transition 衔接。
            currentCard.backgroundGradient(data: data)
                .ignoresSafeArea()

            // 卡片内容 ── 顶 / 底 padding 给 topBar / bottomBar 让位, 内容
            // 在中间区域居中显示。Transition 跟手势方向一致, 上滑时新卡从下
            // 方进入。
            cardContent
                .id(currentCard)
                .padding(.top, 60)
                .padding(.bottom, 60)
                .transition(slideTransition)
                .contentShape(Rectangle())

            // 关闭 / 分享按钮 ── 放在 ZStack 最上层, 不会被翻页手势吞。
            // 之前左右 tap hit area 在最上层吞掉了 X / 分享按钮的 tap; 改成
            // 全屏 DragGesture 让按钮能正常 hit test。
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                Spacer()
                bottomBar
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)
            }
        }
        .preferredColorScheme(.dark)
        // 上下滑动翻页。minimumDistance=20 防止跟系统边缘手势 / VoiceOver
        // 冲突。50pt 阈值是体感平衡点。
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dy = value.translation.height
                    if dy < -50 { advance() }
                    else if dy > 50 { back() }
                }
        )
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        .sheet(item: $shareImageItem) { item in
            ShareSheet(items: item.images)
        }
    }

    /// 根据滑动方向构造 transition: forward (上滑) 时新卡从下进 / 旧卡从上出,
    /// backward (下滑) 时反向。两个方向都带 opacity 更柔和。
    private var slideTransition: AnyTransition {
        switch lastTransitionDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            )
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var cardContent: some View {
        switch currentCard {
        case .hero: HeroCard(data: data)
        case .overview: OverviewCard(data: data)
        case .firstSong: FirstSongCard(data: data)
        case .topArtistHero: TopArtistHeroCard(data: data)
        case .topArtistsList: TopArtistsListCard(data: data)
        case .topSongs: TopSongsCard(data: data)
        case .moments: MomentsCard(data: data)
        case .timeOfDay: TimeOfDayCard(data: data)
        case .genres: GenreCard(data: data)
        case .exploration: ExplorationCard(data: data)
        case .personality: PersonalityCard(data: data)
        case .sources: SourcesCard(data: data)
        case .peakMonth: PeakMonthCard(data: data)
        case .closing: ClosingCard(data: data)
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("yearly_report_title")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Text("\(String(data.year)) ・ \(currentCard.subtitle)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.white.opacity(0.15), in: Circle())
            }
        }
    }

    /// 分享按钮 ── 仅在"音乐人格"卡显示。设计上人格是整段报告的核心精华,
    /// 用户最有动机分享它; 总览 / Top 列表 / 时段等数据卡分享出去对其他人
    /// 来说价值低 (隐私性也偏高), 索性都不给分享入口。
    @ViewBuilder
    private var bottomBar: some View {
        if currentCard == .personality {
            HStack {
                Spacer()
                Button {
                    shareCurrent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("share")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
                }
            }
        }
    }

    // MARK: - Logic

    private func tick() {
        let now = Date()
        // 分享面板打开期间暂停计时, 否则底层卡片会继续 advance, 最终走到
        // 末张的 dismiss() 把报告连同分享面板一起关掉, 打断用户分享。
        guard shareImageItem == nil else {
            lastTickAt = now
            return
        }
        let dt = now.timeIntervalSince(lastTickAt)
        lastTickAt = now
        // 单次 dt 设上限: App 退后台再回前台时 dt 会包含整个后台时长,
        // 直接累计会跳过若干张卡, 丢弃这类异常大的间隔。
        guard dt <= 1 else { return }
        elapsed += dt
        if elapsed >= Self.cardDuration {
            advance()
        }
    }

    private func advance() {
        lastTransitionDirection = .forward
        withAnimation(.easeInOut(duration: 0.32)) {
            if currentIndex < cards.count - 1 {
                currentIndex += 1
                elapsed = 0
            } else {
                dismiss()
            }
        }
    }

    private func back() {
        lastTransitionDirection = .backward
        withAnimation(.easeInOut(duration: 0.32)) {
            if elapsed > 1.5 {
                elapsed = 0
            } else if currentIndex > 0 {
                currentIndex -= 1
                elapsed = 0
            } else {
                elapsed = 0
            }
        }
    }

    @MainActor
    private func shareCurrent() {
        if let image = renderCardImage(card: currentCard) {
            shareImageItem = ShareImageItem(images: [image])
        }
    }

    /// 公共渲染逻辑: 给定 card, 返回 1080×1920 平台图。失败返回 nil。
    @MainActor
    private func renderCardImage(card: YearlyReportCard) -> YearlyReportShareImage? {
        let snapshotView = ZStack {
            card.backgroundGradient(data: data).ignoresSafeArea()
            cardForSharing(card: card)
            VStack {
                Spacer()
                Text(String(localized: "yearly_share_footer"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 1080, height: 1920)
        .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: snapshotView)
        renderer.scale = 1
        #if os(iOS)
        return renderer.uiImage
        #else
        return renderer.nsImage
        #endif
    }

    @ViewBuilder
    private func cardForSharing(card: YearlyReportCard) -> some View {
        switch card {
        case .hero: HeroCard(data: data)
        case .overview: OverviewCard(data: data)
        case .firstSong: FirstSongCard(data: data)
        case .topArtistHero: TopArtistHeroCard(data: data)
        case .topArtistsList: TopArtistsListCard(data: data)
        case .topSongs: TopSongsCard(data: data)
        case .moments: MomentsCard(data: data)
        case .timeOfDay: TimeOfDayCard(data: data)
        case .genres: GenreCard(data: data)
        case .exploration: ExplorationCard(data: data)
        case .personality: PersonalityCard(data: data)
        case .sources: SourcesCard(data: data)
        case .peakMonth: PeakMonthCard(data: data)
        case .closing: ClosingCard(data: data)
        }
    }
}

// MARK: - 卡片枚举

enum YearlyReportCard: Int, CaseIterable {
    // 人格放倒数第二 ── 是整段叙事的"点睛之笔", 让用户看完所有数据再揭晓
    // 人格类型, 仪式感更强。closing 是收尾的告别。
    case hero, overview, firstSong, topArtistHero, topArtistsList, topSongs
    case moments, timeOfDay, genres, exploration, sources, peakMonth, personality, closing

    /// 顶部副标题 (在 progress 条下方显示)
    var subtitle: String {
        switch self {
        case .hero: return String(localized: "yearly_sub_hero")
        case .overview: return String(localized: "yearly_sub_overview")
        case .firstSong: return String(localized: "yearly_sub_first_song")
        case .topArtistHero: return String(localized: "yearly_sub_top_artist_hero")
        case .topArtistsList: return String(localized: "yearly_sub_top_artists")
        case .topSongs: return String(localized: "yearly_sub_top_songs")
        case .moments: return String(localized: "yearly_sub_moments")
        case .timeOfDay: return String(localized: "yearly_sub_time_of_day")
        case .genres: return String(localized: "yearly_sub_genres")
        case .exploration: return String(localized: "yearly_sub_exploration")
        case .sources: return String(localized: "yearly_sub_sources")
        case .peakMonth: return String(localized: "yearly_sub_peak_month")
        case .personality: return String(localized: "yearly_sub_personality")
        case .closing: return String(localized: "yearly_sub_closing")
        }
    }

    /// 每张卡的背景渐变 (上下双色)
    @ViewBuilder
    func backgroundGradient(data: YearlyReportData) -> some View {
        let colors: [Color] = self.gradientColors(data: data)
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func gradientColors(data: YearlyReportData) -> [Color] {
        switch self {
        case .hero:
            return [Color(red: 0.20, green: 0.10, blue: 0.45), Color(red: 0.45, green: 0.18, blue: 0.62)]
        case .overview:
            return [Color(red: 0.10, green: 0.18, blue: 0.40), Color(red: 0.32, green: 0.30, blue: 0.65)]
        case .firstSong:
            return [Color(red: 0.85, green: 0.55, blue: 0.30), Color(red: 0.55, green: 0.20, blue: 0.40)]
        case .topArtistHero:
            return [Color(red: 0.35, green: 0.10, blue: 0.55), Color(red: 0.65, green: 0.30, blue: 0.40)]
        case .topArtistsList:
            return [Color(red: 0.20, green: 0.30, blue: 0.55), Color(red: 0.10, green: 0.50, blue: 0.55)]
        case .topSongs:
            return [Color(red: 0.12, green: 0.40, blue: 0.55), Color(red: 0.30, green: 0.20, blue: 0.55)]
        case .moments:
            return [Color(red: 0.65, green: 0.40, blue: 0.15), Color(red: 0.35, green: 0.18, blue: 0.40)]
        case .timeOfDay:
            // 主导时段决定颜色
            switch data.peakHour {
            case 5...8: return [Color(red: 0.95, green: 0.65, blue: 0.40), Color(red: 0.55, green: 0.30, blue: 0.55)]
            case 9...13: return [Color(red: 0.40, green: 0.65, blue: 0.85), Color(red: 0.20, green: 0.40, blue: 0.65)]
            case 14...18: return [Color(red: 0.85, green: 0.45, blue: 0.30), Color(red: 0.40, green: 0.20, blue: 0.55)]
            default: return [Color(red: 0.10, green: 0.10, blue: 0.30), Color(red: 0.25, green: 0.15, blue: 0.45)]
            }
        case .genres:
            return [Color(red: 0.14, green: 0.42, blue: 0.36), Color(red: 0.56, green: 0.26, blue: 0.42)]
        case .exploration:
            return [Color(red: 0.18, green: 0.36, blue: 0.62), Color(red: 0.52, green: 0.30, blue: 0.20)]
        case .personality:
            return [Color(red: 0.45, green: 0.20, blue: 0.55), Color(red: 0.20, green: 0.30, blue: 0.55)]
        case .sources:
            return [Color(red: 0.15, green: 0.35, blue: 0.45), Color(red: 0.30, green: 0.20, blue: 0.55)]
        case .peakMonth:
            return [Color(red: 0.55, green: 0.25, blue: 0.45), Color(red: 0.25, green: 0.30, blue: 0.65)]
        case .closing:
            return [Color(red: 0.10, green: 0.10, blue: 0.25), Color(red: 0.35, green: 0.18, blue: 0.55)]
        }
    }
}

// MARK: - Share helpers

private struct ShareImageItem: Identifiable {
    let id = UUID()
    let images: [YearlyReportShareImage]
}
