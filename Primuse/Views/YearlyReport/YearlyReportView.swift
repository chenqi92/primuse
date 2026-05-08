import SwiftUI
import PrimuseKit

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
            mainBody
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
                Text("\(String(data.year)) 年度报告")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text("今年还没有听够多歌\n听满 30 秒以上的歌曲会自动计入年度统计")
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
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
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
        let dt = now.timeIntervalSince(lastTickAt)
        lastTickAt = now
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
        if let uiImage = renderCardImage(card: currentCard) {
            shareImageItem = ShareImageItem(images: [uiImage])
        }
    }

    /// 公共渲染逻辑: 给定 card, 返回 1080×1920 UIImage。失败返回 nil。
    @MainActor
    private func renderCardImage(card: YearlyReportCard) -> UIImage? {
        let snapshotView = ZStack {
            card.backgroundGradient(data: data).ignoresSafeArea()
            cardForSharing(card: card)
            VStack {
                Spacer()
                Text("由 Primuse · 猿音 生成")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 1080, height: 1920)
        .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: snapshotView)
        renderer.scale = 1
        return renderer.uiImage
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
    case moments, timeOfDay, sources, peakMonth, personality, closing

    /// 顶部副标题 (在 progress 条下方显示)
    var subtitle: String {
        switch self {
        case .hero: return "封面"
        case .overview: return "总览"
        case .firstSong: return "第一首"
        case .topArtistHero: return "你的最爱"
        case .topArtistsList: return "Top 艺术家"
        case .topSongs: return "Top 歌曲"
        case .moments: return "高光时刻"
        case .timeOfDay: return "时段画像"
        case .sources: return "音乐源画像"
        case .peakMonth: return "代表月份"
        case .personality: return "音乐人格"
        case .closing: return "感谢与告别"
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
    let images: [UIImage]
}
