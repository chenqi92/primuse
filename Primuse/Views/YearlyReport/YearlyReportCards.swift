import SwiftUI
import PrimuseKit

// MARK: - Reusable: 占位插图视图
//
// 美术阶段插图未到位时, 用渐变方块 + SF Symbol + 文字兜底, 让 UI 不空白。
// 命名规则严格匹配 Docs/YearlyReport.md §七: personality_<CODE> /
// timeofday_<dawn|noon|dusk|night> / month_<01..12> / decor_<name>。

struct YearlyArtView: View {
    let assetName: String
    let fallbackSymbol: String
    let fallbackText: String?

    var body: some View {
        #if os(iOS)
        if let img = UIImage(named: assetName) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            fallbackContent
        }
        #else
        if let img = NSImage(named: assetName) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            fallbackContent
        }
        #endif
    }

    private var fallbackContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            VStack(spacing: 6) {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 50, weight: .light))
                if let fallbackText {
                    Text(fallbackText)
                        .font(.caption2.weight(.semibold))
                }
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - 通用文本组件

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }
}

private struct CardSubtitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
    }
}

private struct BigNumber: View {
    let value: String
    let unit: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            if let unit {
                Text(unit)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Card 1: 封面

struct HeroCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("\(String(data.year))")
                .font(.system(size: 28, weight: .light, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .tracking(8)
            Text("年度音乐报告")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if let personality = data.personality {
                YearlyArtView(
                    assetName: personality.assetName,
                    fallbackSymbol: "person.fill",
                    fallbackText: personality.code
                )
                .frame(width: 240, height: 240)
                .padding(.top, 24)

                Text(personality.displayName)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            } else {
                YearlyArtView(
                    assetName: "decor_overview_hourglass",
                    fallbackSymbol: "hourglass",
                    fallbackText: nil
                )
                .frame(width: 200, height: 200)
                .padding(.top, 32)
            }
            Spacer()
            Text("向上滑动开启你的回顾")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 100)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Card 2: 总览

struct OverviewCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            CardSubtitle(text: "今年, 你与音乐相伴")

            BigNumber(value: "\(Int(data.totalSec / 3600))", unit: "小时")

            HStack(spacing: 32) {
                statColumn(value: "\(data.uniqueSongCount)", label: "首歌")
                divider
                statColumn(value: "\(data.uniqueArtistCount)", label: "位艺术家")
                divider
                statColumn(value: "\(data.totalEntries)", label: "次播放")
            }
            .padding(.top, 16)

            if let growth = MainActorAccessor.yearOverYearGrowth(currentYear: data.year) {
                Text(growthText(growth))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 24)
            }
            Spacer()
            YearlyArtView(
                assetName: "decor_overview_hourglass",
                fallbackSymbol: "hourglass",
                fallbackText: nil
            )
            .frame(width: 160, height: 160)
            .padding(.bottom, 80)
        }
        .padding(.horizontal, 32)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 36)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func growthText(_ growth: Double) -> String {
        let pct = Int(abs(growth * 100))
        if growth > 0.05 {
            return "比去年多听了 \(pct)%"
        } else if growth < -0.05 {
            return "比去年少了 \(pct)%, 来年继续"
        }
        return "听音乐的频率跟去年差不多"
    }
}

// MARK: - Card 3: 首播之歌

struct FirstSongCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            YearlyArtView(
                assetName: "decor_first_song",
                fallbackSymbol: "play.rectangle.fill",
                fallbackText: nil
            )
            .frame(width: 180, height: 240)

            CardSubtitle(text: "你的 \(String(data.year)) 是从这首歌开始的")
                .padding(.top, 24)

            if let first = data.firstSong {
                Text(first.songTitle)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if !first.artistName.isEmpty {
                    Text(first.artistName)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(first.playedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 8)
            } else {
                Text("暂无记录")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 80)
    }
}

// MARK: - Card 4: Top 艺术家 (No.1)

struct TopArtistHeroCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            CardSubtitle(text: "你今年最常听的艺术家")
            if let top = data.topArtists.first {
                Text(top.title)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Text("听了 \(top.playCount) 次, 累计 \(formatDuration(top.totalSec))")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 8)
            } else {
                Text("暂无记录")
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            YearlyArtView(
                assetName: "decor_trophy",
                fallbackSymbol: "trophy.fill",
                fallbackText: nil
            )
            .frame(width: 180, height: 180)
            .padding(.bottom, 100)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Card 5: Top 艺术家 2-5

struct TopArtistsListCard: View {
    let data: YearlyReportData
    private var artists: [YearlyReportData.RankedItem] {
        Array(data.topArtists.dropFirst().prefix(4))
    }
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            YearlyArtView(
                assetName: "decor_artists_chorus",
                fallbackSymbol: "person.3.fill",
                fallbackText: nil
            )
            .frame(width: 200, height: 120)

            CardSubtitle(text: "另外几位常驻")
                .padding(.top, 4)

            VStack(spacing: 12) {
                ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                    HStack {
                        Text("\(index + 2)")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.title)
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(artist.playCount) 次")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}

// MARK: - Card 6: Top 歌曲

/// 今年循环榜 ── Top 3 大卡 (前三名带金银铜深浅渐变 / 大数字 + 播放次数
/// 突出显示) + 4-8 名紧凑列表。比之前的"8 行平铺"层次感强, 视觉焦点
/// 自然落在前三。
struct TopSongsCard: View {
    let data: YearlyReportData

    private var top3: [YearlyReportData.RankedItem] {
        Array(data.topSongs.prefix(3))
    }
    private var rest: [YearlyReportData.RankedItem] {
        Array(data.topSongs.dropFirst(3).prefix(5))
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            CardSubtitle(text: "今年的循环榜")

            // Top 3 ── 第一名最大, 第二三名稍小, 形成"领奖台"层次感。
            VStack(spacing: 8) {
                ForEach(Array(top3.enumerated()), id: \.element.id) { idx, song in
                    podiumRow(rank: idx + 1, song: song)
                }
            }
            .padding(.horizontal, 20)

            // 4-8 名 ── 单行紧凑显示。
            if !rest.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { idx, song in
                        compactRow(rank: idx + 4, song: song)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    private func podiumRow(rank: Int, song: YearlyReportData.RankedItem) -> some View {
        HStack(spacing: 14) {
            // 排名徽章 (圆形 + 金/银/铜渐变), 大数字
            ZStack {
                Circle()
                    .fill(podiumGradient(rank: rank))
                    .frame(width: rank == 1 ? 56 : 48, height: rank == 1 ? 56 : 48)
                Text("\(rank)")
                    .font(.system(size: rank == 1 ? 28 : 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(rank == 1 ? .title3 : .body, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sub = song.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer()

            // 播放次数 + "次" 标签, 跟标题区分开
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(song.playCount)")
                    .font(.system(size: rank == 1 ? 26 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("次")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.white.opacity(rank == 1 ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func compactRow(rank: Int, song: YearlyReportData.RankedItem) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20)
            Text(song.title)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            Text("\(song.playCount) 次")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func podiumGradient(rank: Int) -> LinearGradient {
        switch rank {
        case 1: return LinearGradient(colors: [Color(red: 1.00, green: 0.78, blue: 0.30), Color(red: 0.95, green: 0.55, blue: 0.10)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)  // 金
        case 2: return LinearGradient(colors: [Color(red: 0.85, green: 0.85, blue: 0.90), Color(red: 0.55, green: 0.58, blue: 0.65)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)  // 银
        case 3: return LinearGradient(colors: [Color(red: 0.88, green: 0.55, blue: 0.35), Color(red: 0.55, green: 0.30, blue: 0.18)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)  // 铜
        default: return LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Card 7: 高光时刻

struct MomentsCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            YearlyArtView(
                assetName: "decor_badge_moment",
                fallbackSymbol: "rosette",
                fallbackText: nil
            )
            .frame(width: 160, height: 160)

            CardSubtitle(text: "属于你的高光时刻")
                .padding(.top, 16)

            VStack(spacing: 16) {
                if let mostPlayed = data.mostPlayedSong {
                    momentRow(
                        icon: "repeat",
                        label: "今年的循环单曲",
                        title: mostPlayed.title,
                        detail: "陪你听了 \(mostPlayed.playCount) 次"
                    )
                }
                if let session = data.longestSession {
                    momentRow(
                        icon: "headphones",
                        label: "最沉浸的一次聆听",
                        title: formatDuration(session.totalSec),
                        detail: "一口气听了 \(session.songCount) 首歌"
                    )
                }
                if let latest = data.latestEntry {
                    momentRow(
                        icon: "moon.stars.fill",
                        label: "陪你最晚的那首歌",
                        title: latest.songTitle,
                        detail: latest.playedAt.formatted(.dateTime.month().day().hour().minute())
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            Spacer()
        }
    }

    private func momentRow(icon: String, label: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Text(title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
    }
}

// MARK: - Card 8: 时段画像

struct TimeOfDayCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            YearlyArtView(
                assetName: data.timeOfDayAsset,
                fallbackSymbol: timeSymbol,
                fallbackText: data.timeOfDayLabel
            )
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)

            CardSubtitle(text: "你的音乐时段")
                .padding(.top, 16)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(data.peakHour)")
                    .font(.system(size: 80, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("时")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text("\(data.timeOfDayLabel) 是你听音乐最久的时段")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            // 24h 柱图
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let value = data.hourDistribution.indices.contains(hour) ? data.hourDistribution[hour] : 0
                    let peakValue = data.hourDistribution.max() ?? 1
                    let ratio = peakValue > 0 ? value / peakValue : 0
                    Capsule()
                        .fill(hour == data.peakHour ? Color.white : Color.white.opacity(0.4))
                        .frame(width: 8, height: Swift.max(4, ratio * 100))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var timeSymbol: String {
        switch data.peakHour {
        case 5...8: return "sun.horizon.fill"
        case 9...13: return "sun.max.fill"
        case 14...18: return "sun.dust.fill"
        default: return "moon.stars.fill"
        }
    }
}

// MARK: - Card 9: 流派画像

struct GenreCard: View {
    let data: YearlyReportData

    private var genres: [YearlyReportData.RankedItem] {
        Array(data.topGenres.prefix(5))
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            YearlyArtView(
                assetName: "decor_record_stack",
                fallbackSymbol: "guitars",
                fallbackText: nil
            )
            .frame(width: 190, height: 150)

            CardSubtitle(text: "今年听过的流派")
                .padding(.top, 10)

            BigNumber(value: "\(data.genreCount)", unit: "种")

            VStack(spacing: 9) {
                if genres.isEmpty {
                    Text("补齐歌曲 genre 后, 这里会出现你的流派地图")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    ForEach(Array(genres.enumerated()), id: \.element.id) { index, genre in
                        genreRow(rank: index + 1, genre: genre)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            Spacer()
        }
    }

    private func genreRow(rank: Int, genre: YearlyReportData.RankedItem) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(genre.title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(genre.playCount) 次播放")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            Text(formatDuration(genre.totalSec))
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Card 10: 探索度

struct ExplorationCard: View {
    let data: YearlyReportData

    private var focusPercent: Int {
        Int((data.explorationTopArtistShare * 100).rounded())
    }

    private var explorationPercent: Int {
        max(0, 100 - focusPercent)
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            YearlyArtView(
                assetName: "decor_sources_pipeline",
                fallbackSymbol: "safari.fill",
                fallbackText: nil
            )
            .frame(width: 200, height: 130)

            CardSubtitle(text: "你的探索度")
                .padding(.top, 12)

            BigNumber(value: "\(explorationPercent)", unit: "%")

            Text(data.personality?.exploration == .explorer ? "今年你把耳朵交给了更多新名字" : "今年你更愿意把喜欢的声音听深")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Top 5 艺术家占比")
                    Spacer()
                    Text("\(focusPercent)%")
                        .monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.70))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(.white.opacity(0.86))
                            .frame(width: geo.size.width * CGFloat(min(max(data.explorationTopArtistShare, 0), 1)))
                    }
                }
                .frame(height: 10)
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)

            Spacer()
        }
    }
}

// MARK: - Card 11: 音乐人格

struct PersonalityCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            CardSubtitle(text: "今年, 你的音乐人格是")

            if let p = data.personality {
                YearlyArtView(
                    assetName: p.assetName,
                    fallbackSymbol: "person.crop.circle.fill",
                    fallbackText: p.code
                )
                .frame(width: 240, height: 240)
                .padding(.top, 8)

                Text(p.displayName)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                Text(p.code)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(4)

                Text(p.oneLiner)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            } else {
                Text("数据不足以判定人格")
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }
}

// MARK: - Card 12: 音乐源画像

struct SourcesCard: View {
    let data: YearlyReportData

    private var topThree: [YearlyReportData.SourceBreakdown] {
        Array(data.sourceBreakdown.prefix(3))
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            YearlyArtView(
                assetName: "decor_sources_pipeline",
                fallbackSymbol: "point.3.connected.trianglepath.dotted",
                fallbackText: nil
            )
            .frame(width: 220, height: 110)

            CardSubtitle(text: "你的音乐都从哪儿来")
                .padding(.top, 4)

            VStack(spacing: 12) {
                ForEach(topThree) { item in
                    sourceRow(item: item)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()
        }
    }

    private func sourceRow(item: YearlyReportData.SourceBreakdown) -> some View {
        // displayName / iconSymbol 在 analyze 时已从 SourcesStore 烘到 data,
        // 这里直接读, 不用 @Environment ── 分享 ImageRenderer 拍快照也能正确显示。
        let total = data.sourceBreakdown.reduce(0.0) { $0 + $1.totalSec }
        let pct = total > 0 ? Int(item.totalSec / total * 100) : 0
        return HStack(spacing: 12) {
            Image(systemName: item.iconSymbol)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(item.playCount) 次播放")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Text("\(pct)%")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Card 13: 代表月份

struct PeakMonthCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            YearlyArtView(
                assetName: String(format: "month_%02d", data.peakMonth),
                fallbackSymbol: "calendar",
                fallbackText: "\(data.peakMonth) 月"
            )
            .frame(height: 200)
            .frame(maxWidth: .infinity)

            CardSubtitle(text: "\(monthName(data.peakMonth)) 是你今年的音乐月")
                .padding(.top, 16)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(data.peakMonth)")
                    .font(.system(size: 100, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("月")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

            if let song = data.peakMonthTopSong {
                Text("那个月你最常听: \(song)")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            }
            Spacer()
        }
    }

    private func monthName(_ m: Int) -> String {
        let names = ["一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月"]
        guard m >= 1, m <= 12 else { return "\(m) 月" }
        return names[m - 1]
    }
}

// MARK: - Card 14: 年终感言

struct ClosingCard: View {
    let data: YearlyReportData
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            CardSubtitle(text: "今年与音乐相伴")
            BigNumber(value: "\(Int(data.totalSec / 3600))", unit: "小时")

            Text("感谢你与猿音的每一次相遇")
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text("\(String(data.year + 1)), 继续吧")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 8)
            Spacer()
            YearlyArtView(
                assetName: "decor_curtain_close",
                fallbackSymbol: "music.note",
                fallbackText: nil
            )
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 100)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Helpers

private func formatDuration(_ seconds: TimeInterval) -> String {
    let h = Int(seconds / 3600)
    let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
    if h > 0 { return "\(h) 小时 \(m) 分" }
    return "\(m) 分钟"
}

/// SwiftUI body 是 nonisolated 的, 直接调 @MainActor 静态方法会编译报错。
/// 这里包一层让 Overview Card body 能拿到同比数据。
@MainActor
private enum MainActorAccessor {
    static func yearOverYearGrowth(currentYear: Int) -> Double? {
        YearlyReportAnalyzer.yearOverYearGrowth(currentYear: currentYear)
    }
}
