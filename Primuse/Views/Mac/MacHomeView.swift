#if os(macOS)
import SwiftUI
import AppKit
import PrimuseKit

/// 1.6 重设计后的 macOS 首页 — Hero (AmbientBackdrop + 封面马赛克 + 欢迎语) →
/// 库健康度 / 源状态 双卡 → 4 节点 pipeline → 最近添加专辑 → 最近播放 → 艺术家。
struct MacHomeView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ThemeService.self) private var theme
    @Environment(AppUpdateChecker.self) private var updateChecker

    private var hasContent: Bool { !library.visibleSongs.isEmpty }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: PMSpace.xxl) {
                if updateChecker.availableUpdate != nil {
                    updateBanner
                }

                heroSection

                if hasContent {
                    statsRow
                    pipelineSection
                    recentlyAddedSection
                    recentlyPlayedSection
                    if !library.visibleArtists.isEmpty {
                        artistsSection
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.top, PMSpace.l24)
            .padding(.bottom, 104)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    // MARK: - Update banner

    private var updateBanner: some View {
        HStack(spacing: PMSpace.m) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 22)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let v = updateChecker.availableUpdate?.version {
                    Text(String(format: String(localized: "update_banner_title_format"), v))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Text("update_banner_subtitle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            ZStack {
                Text("update_banner_action")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(PMColor.brand, in: Capsule())
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .overlay {
                MacWindowSafeClickArea {
                    updateChecker.openAppStore()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("update_banner_action"))
            }
            .shadow(color: PMColor.brand.opacity(0.35), radius: 6, y: 2)

            ZStack {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .overlay {
                MacWindowSafeClickArea {
                    updateChecker.snooze()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("later"))
            }
            .help(Text("later"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            // 设计稿 update banner 是带轻微 brand 暖色调的卡片, 不能像普通 pmCard
            // 那样几乎贴底色 — 用 bgElev 实色 + 6% brand tint 拉对比。
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .fill(PMColor.bgElev)
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .fill(PMColor.brand.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .strokeBorder(PMColor.brand.opacity(0.28), lineWidth: 0.5)
        }
    }

    // MARK: - Hero

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    /// "今晚, 你的资料库里藏着 11,248 个故事" 这样的动态叙事。
    /// 1.6 重设计后用它替代静态 "猿音", 把首页从"应用展示页"变成"用户专属仪表盘"。
    private var heroNarrative: String {
        let count = library.visibleSongs.count
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let key: String
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  key = "home_hero_narrative_morning"
        case 12..<18: key = "home_hero_narrative_afternoon"
        case 18..<22: key = "home_hero_narrative_evening"
        default:      key = "home_hero_narrative_night"
        }
        return String(format: String(localized: String.LocalizationValue(key)), formatted)
    }

    /// "来自 8 个源 · 842 张专辑 · 312 位艺术家 · 总时长 47 天 18 小时"
    private var heroStats: String {
        let sources = sourcesStore.sources.filter(\.isEnabled).count
        let albums = library.visibleAlbums.count
        let artists = library.visibleArtists.count
        let totalSec = library.visibleSongs.reduce(0.0) { $0 + max(0, $1.duration) }
        let days = Int(totalSec / 86400)
        let hours = Int((totalSec.truncatingRemainder(dividingBy: 86400)) / 3600)
        if days > 0 {
            return String(format: String(localized: "home_hero_stats_with_days"),
                          sources, albums, artists, days, hours)
        } else {
            return String(format: String(localized: "home_hero_stats_hours_only"),
                          sources, albums, artists, hours)
        }
    }

    private var heroSection: some View {
        ZStack {
            // 1. 卡片底色 — 暗色模式必须明显高于窗口 bg, 否则跟背景融在一起。设计里 hero
            //    是一张清晰可见的卡。先铺 bgElev, 再叠 AmbientBackdrop 给暖色调。
            RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                .fill(PMColor.bgElev)

            // 2. Hero 的 ambient 用固定 brand 暖色, 不跟 theme.accentColor 走 — 设计稿
            //    里 hero 一直是温暖的 pink/cream 调, 跟当前播放歌曲色相无关。
            //    AmbientBackdrop 内部用 blur + offset 把色圈推到 Hero 边界外, 不依靠
            //    内部 clipShape (drawingGroup 栅格化会让 clip 失效), 改在最外层 ZStack
            //    统一裁剪。
            AmbientBackdrop(
                accent: PMColor.brand,
                darkAccent: PMColor.brand.opacity(0.55),
                strength: 0.72
            )

            HStack(alignment: .center, spacing: 36) {
                coverMosaic
                    .frame(width: 240, height: 240)

                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: greeting)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))

                    Text(verbatim: heroNarrative)
                        .font(.system(size: 40, weight: .bold))
                        .tracking(-0.8)
                        .lineSpacing(2)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(verbatim: heroStats)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: 660, alignment: .leading)

                    HStack(spacing: PMSpace.s10) {
                        Button { playLibrary(shuffled: true) } label: {
                            Label("shuffle_all", systemImage: "shuffle")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 11)
                                .background(PMColor.brand, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasContent)
                        .shadow(color: PMColor.brand.opacity(0.45), radius: 10, y: 4)

                        Button { playLibrary(shuffled: false) } label: {
                            Label("play_all", systemImage: "play.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.18), in: Capsule())
                                .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.5) }
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasContent)
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PMSpace.xxl)
            .padding(.vertical, PMSpace.l24)
        }
        .frame(height: 296)
        // 3. 整张 Hero 强制裁剪到圆角矩形 — AmbientBackdrop 的 blur 圈会越界, 必须在
        //    最外层统一切, 否则暖色会"漏"到 Hero 上下方区域。
        .clipShape(RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous))
        // 4. 边框 + 收紧的浮动阴影 (radius 18→8, 防止 shadow 把卡片边缘的暖色又扩散
        //    回外面)。
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }

    private var coverMosaic: some View {
        Group {
            if mosaicSongs.isEmpty {
                RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.42))
                    }
            } else if mosaicLayout.columns == 1, let song = mosaicLayout.songs.first {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    cornerRadius: PMRadius.l,
                    sourceID: song.sourceID, filePath: song.filePath
                )
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
            } else {
                // 设计稿的封面马赛克是"散落叠放"的: 每张按固定角度轻微倾斜 + 上下错位,
                // 不是横平竖直的网格。这里复刻 home.jsx CoverMosaic 的 transforms。
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                   count: mosaicLayout.columns),
                    spacing: 8
                ) {
                    ForEach(Array(mosaicLayout.songs.enumerated()), id: \.element.id) { idx, song in
                        CachedArtworkView(
                            coverRef: song.coverArtFileName, songID: song.id,
                            cornerRadius: PMRadius.m,
                            sourceID: song.sourceID, filePath: song.filePath
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                        .rotationEffect(.degrees(Self.mosaicTilt[idx % Self.mosaicTilt.count]))
                        .offset(y: Self.mosaicYOffset[idx % Self.mosaicYOffset.count])
                    }
                }
                // 留点内边距, 让倾斜出界的封面角不被 hero 圆角裁掉。
                .padding(6)
            }
        }
    }

    /// home.jsx CoverMosaic 的散落参数: 每张封面的旋转角度 (度) 与垂直错位 (pt)。
    private static let mosaicTilt: [Double] = [-4, 2, -1, 4, -3, 1]
    private static let mosaicYOffset: [CGFloat] = [-6, 0, 4, -4, 2, 0]

    /// 把候选封面收敛成"整行铺满"的网格: ≥6 张走 3×2, 4–5 张走 2×2, 其余只展示
    /// 单张大封面。这样马赛克始终是横平竖直的完整矩形, 不会出现落单的半行。
    private var mosaicLayout: (songs: [Song], columns: Int) {
        let pool = mosaicSongs
        if pool.count >= 6 { return (Array(pool.prefix(6)), 3) }
        if pool.count >= 4 { return (Array(pool.prefix(4)), 2) }
        return (Array(pool.prefix(1)), 1)
    }

    private var mosaicSongs: [Song] {
        let recent = library.recentlyPlayedSongs(limit: 12)
        let added = library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(40)
        var pool = recent
        for song in added where !pool.contains(where: { $0.id == song.id }) {
            pool.append(song)
        }
        let covered = pool.filter { $0.coverArtFileName?.isEmpty == false }
        return Array((covered.isEmpty ? pool : covered).prefix(6))
    }

    // MARK: - Stats row (库健康度 + 源状态)

    private var statsRow: some View {
        HStack(alignment: .top, spacing: PMSpace.m16) {
            libraryHealthCard
            sourceStatusCard
        }
        // 两张卡用 equal-height: HStack 默认会拉到两边最高的那张, 但 homeCard 内部
        // VStack 自然高度小的那张就会留白。fixedSize 关掉自动收缩, 让 HStack 强制
        // 两边 .frame(maxHeight: .infinity), 这样卡片背景填满, 不会出现"音乐源卡
        // 比库健康度卡矮一截"。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var libraryHealthCard: some View {
        homeCard(title: "home_health_title", spec: "LIB-09") {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(spacing: PMSpace.m) {
                    metric(value: library.visibleSongs.count, label: "tab_songs")
                    metric(value: library.visibleAlbums.count, label: "tab_albums")
                    metric(value: library.visibleArtists.count, label: "tab_artists")
                }
                Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.vertical, 2)
                // 设计稿: 封面绿 / 歌词红 / 可播放蓝 (跟"健康"语义不同维度区分)。
                healthBar("home_cover_art", value: coverRatio, color: PMColor.ok)
                healthBar("home_lyrics", value: lyricsRatio, color: PMColor.bad)
                healthBar("home_playable", value: playableRatio,
                          color: Color(red: 0.4, green: 0.7, blue: 0.95))
            }
        }
    }

    private var sourceStatusCard: some View {
        homeCard(title: "Source Status", spec: "SRC-* · LIB-14/15") {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(spacing: PMSpace.m) {
                    metric(value: enabledSourcesCount, label: "home_enabled_sources")
                    metric(value: activeTaskCount, label: "home_active_scans")
                    metric(value: backfill.remainingCount(forSource: nil), label: "home_pending_details")
                }
                Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.vertical, 2)
                if let entry = activeScanEntry {
                    // 文件扫描 (发现新歌)。
                    sourceTaskBox(
                        title: entry.source.name,
                        phase: entry.state.isScanning ? Lz("Reading files") : Lz("Resume pending"),
                        detail: entry.state.currentFile,
                        progress: entry.state.totalCount > 0 ? min(entry.state.progress, 1) : 0,
                        indeterminate: entry.state.totalCount == 0
                    )
                } else if backfill.isRunning || backfill.hasPendingWork {
                    // 元数据回填 (读取本地文件标签补全基础信息) —— 就是源卡片上那个
                    // 「读取标签中 · 剩余 N 首」。之前首页完全没检测它, 所以明明在跑却
                    // 显示「暂无扫描任务」。
                    let processed = backfill.processedCount
                    let total = processed + backfill.remainingCount
                    sourceTaskBox(
                        title: Lz("Metadata backfill"),
                        phase: Lz("Reading tags"),
                        detail: String(format: String(localized: "backfill_remaining"), backfill.remainingCount),
                        progress: total > 0 ? Double(processed) / Double(total) : 0,
                        indeterminate: total == 0
                    )
                } else if scraperService.isScraping {
                    // 在线刮削封面 / 歌词。
                    sourceTaskBox(
                        title: Lz("Metadata scraping"),
                        phase: Lz("Covers / Lyrics"),
                        detail: scraperService.currentSongTitle,
                        progress: scraperService.progress,
                        indeterminate: scraperService.totalCount == 0
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(PMColor.ok)
                        Text("home_no_scans")
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                    }
                }
            }
        }
    }

    /// 当前正在扫描的源 (含其 sourceID 对应的 MusicSource) —— scanStates 的 key 才是
    /// sourceID, .values 拿不到, 所以这里遍历配对。
    private var activeScanEntry: (source: MusicSource, state: ScanService.ScanState)? {
        for (id, state) in scanService.scanStates where state.isScanning || state.canResume {
            if let src = sourcesStore.sources.first(where: { $0.id == id }) {
                return (src, state)
            }
        }
        return nil
    }

    /// 设计稿的「源任务」进度块: 源名 · 阶段 + 当前文件 + 带百分比的进度条。
    private func sourceTaskBox(title: String, phase: String, detail: String,
                               progress: Double, indeterminate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(PMColor.brand).frame(width: 6, height: 6)
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: "· \(phase)")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if indeterminate {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    taskProgressBar(progress)
                    Text(verbatim: "\(Int(min(max(progress, 0), 1) * 100))%")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(PMColor.bgDeep.opacity(0.35), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func homeCard<C: View>(title: LocalizedStringKey, spec: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: PMSpace.m14) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.3)
                Spacer()
                let visibleSpec = PMTextWithoutDesignCodes(spec)
                if !visibleSpec.isEmpty {
                    Text(verbatim: visibleSpec)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            content()
            // 用一个透明 Spacer 把内容顶到顶部, 让 .frame(maxHeight: .infinity) 真
            // 把卡片拉到行高。source 卡内容短的时候就靠它把高度撑到跟健康度卡相同。
            Spacer(minLength: 0)
        }
        .padding(PMSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pmCard(cornerRadius: PMRadius.l)
    }

    private func metric(value: Int, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(PMColor.text)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthBar(_ title: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.text)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(PMColor.textMuted)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PMColor.divider)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }

    private func scanProgressBar(_ scan: ScanService.ScanState) -> some View {
        let pct = scan.totalCount > 0 ? min(scan.progress, 1) : 0
        return taskProgressBar(pct)
    }

    private func taskProgressBar(_ pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.divider)
                Capsule().fill(PMColor.brand).frame(width: geo.size.width * min(max(pct, 0), 1))
            }
        }
        .frame(height: 5)
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        HStack(spacing: PMSpace.s8) {
            pipelineNode("externaldrive.fill", "Sources",
                         statusText: "\(enabledSourcesCount) \(Lz("online"))",
                         isActive: !sourcesStore.sources.isEmpty)
            pipelineConnector(isActive: !activeScans.isEmpty || hasContent)
            pipelineNode("arrow.triangle.2.circlepath", "Scan",
                         statusText: activeScans.isEmpty ? Lz("No Scan") : "\(activeScans.count) \(Lz("in progress"))",
                         isActive: !activeScans.isEmpty || hasContent)
            pipelineConnector(isActive: hasContent)
            pipelineNode("tag.fill", "Metadata",
                         statusText: scraperService.isScraping
                             ? "\(scraperService.processedCount)/\(scraperService.totalCount) \(Lz("in progress"))"
                             : (backfill.remainingCount(forSource: nil) == 0
                                 ? Lz("Done")
                                 : "\(backfill.remainingCount(forSource: nil)) \(Lz("pending backfill"))"),
                         isActive: hasContent || scraperService.isScraping)
            pipelineConnector(isActive: player.currentSong != nil)
            pipelineNode("play.fill", "Listen",
                         statusText: player.currentSong?.title ?? Lz("Not Playing"),
                         isActive: player.currentSong != nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .pmCard(cornerRadius: PMRadius.l)
    }

    private func pipelineNode(_ icon: String, _ title: String,
                              statusText: String, isActive: Bool) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 52, height: 52)
                .background(
                    (isActive ? PMColor.brand.opacity(0.18) : PMColor.brand.opacity(0.10)),
                    in: .rect(cornerRadius: 12, style: .continuous)
                )
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func pipelineConnector(isActive: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? PMColor.text.opacity(0.6) : PMColor.textFaint.opacity(0.4))
            .padding(.horizontal, 6)
    }

    // MARK: - Recently added (6-col 140pt grid)

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "recently_added",
                          subtitle: "home_recently_added_subtitle",
                          destination: .recentlyAdded)

            LazyVGrid(
                columns: Array(repeating: GridItem(.adaptive(minimum: 130, maximum: 160),
                                                    spacing: PMSpace.m16, alignment: .top),
                               count: 1),
                alignment: .leading,
                spacing: PMSpace.l
            ) {
                ForEach(library.recentlyAddedAlbums(limit: 12)) { album in
                    Button { playAlbum(album) } label: {
                        albumCard(album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func albumCard(_ album: Album) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return VStack(alignment: .leading, spacing: 8) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                cornerRadius: PMRadius.m,
                sourceID: song?.sourceID,
                filePath: song?.filePath
            )
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            Text(album.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            if let artist = album.artistName {
                Text(artist)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Recently played (4-col compact grid)

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "recently_played",
                          subtitle: "home_recently_played_subtitle",
                          destination: .recentlyPlayed)

            LazyVGrid(
                columns: Array(repeating: GridItem(.adaptive(minimum: 260, maximum: 320),
                                                    spacing: PMSpace.m, alignment: .top),
                               count: 1),
                alignment: .leading,
                spacing: PMSpace.m
            ) {
                ForEach(recentSongs.prefix(8)) { song in
                    Button { playSong(song) } label: {
                        recentSongRow(song)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func recentSongRow(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 42, cornerRadius: PMRadius.s,
                sourceID: song.sourceID,
                filePath: song.filePath
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(8)
        .background(PMColor.rowHover, in: .rect(cornerRadius: PMRadius.m))
    }

    private var recentSongs: [Song] {
        recentSongs(limit: 18)
    }

    private func recentSongs(limit: Int) -> [Song] {
        let recent = library.recentlyPlayedSongs(limit: limit)
        if !recent.isEmpty { return recent }
        return Array(library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(limit))
    }

    // MARK: - Artists (horizontal scroll)

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "tab_artists",
                          subtitle: "home_artists_subtitle",
                          destination: .artists)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PMSpace.l) {
                    ForEach(library.visibleArtists.prefix(14)) { artist in
                        NavigationLink(value: artist) {
                            artistChip(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            // 系统"总是显示滚动条"设置下 showsIndicators 不生效, 直接在底层
            // NSScrollView 上强制隐藏横向滚动条。
            .pmForceHideScrollers()
            // 鼠标按住可拖动滚动 — SwiftUI 横向 ScrollView 默认只响应触控板/滚轮,
            // 这个 modifier 在底层 NSScrollView 上加 pan gesture, 鼠标拖也能滚。
            .pmEnableHorizontalDragScroll()
        }
    }

    private func artistChip(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            CachedArtworkView(
                artistID: artist.id,
                artistName: artist.name,
                size: 92,
                cornerRadius: 46
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            Text(artist.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text("\(library.songs(forArtist: artist.id).count)")
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
        }
        .frame(width: 100)
    }

    // MARK: - Section header

    private enum HomeSectionDestination {
        case recentlyAdded
        case recentlyPlayed
        case artists
    }

    private func sectionHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey?, destination: HomeSectionDestination? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(PMColor.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer()
            if let destination {
                NavigationLink {
                    sectionDestination(destination)
                } label: {
                    HStack(spacing: 3) {
                        Text("home_section_view_all")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("home_section_view_all"))
            }
        }
    }

    @ViewBuilder
    private func sectionDestination(_ destination: HomeSectionDestination) -> some View {
        switch destination {
        case .recentlyAdded:
            recentlyAddedAllView
                .navigationTitle("recently_added")
        case .recentlyPlayed:
            recentlyPlayedAllView
                .navigationTitle("recently_played")
        case .artists:
            ArtistListView(artists: library.visibleArtists)
                .navigationTitle("tab_artists")
        }
    }

    private var recentlyAddedAllView: some View {
        let albums = library.recentlyAddedAlbums(limit: max(library.visibleAlbums.count, 1))

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                homeCollectionHeader(
                    eyebrow: "library_title",
                    title: "recently_added",
                    detail: "\(albums.count) \(String(localized: "albums_count"))"
                )

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 5),
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            albumCard(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
            }
            .padding(.top, 24)
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private var recentlyPlayedAllView: some View {
        let songs = recentSongs(limit: max(library.visibleSongs.count, 1))

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                homeCollectionHeader(
                    eyebrow: "library_title",
                    title: "recently_played",
                    detail: "\(songs.count) \(String(localized: "songs_count"))"
                )

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: PMSpace.m, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: PMSpace.m
                ) {
                    ForEach(songs) { song in
                        Button { playSong(song) } label: {
                            recentSongRow(song)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
            }
            .padding(.top, 24)
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private func homeCollectionHeader(eyebrow: LocalizedStringKey, title: LocalizedStringKey, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textMuted)
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: PMSpace.l) {
            Spacer().frame(height: 60)
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(PMColor.textFaint)
            Text("welcome_title")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("welcome_desc")
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
            Text("home_empty_mac_hint")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived

    private var activeScans: [ScanService.ScanState] {
        scanService.scanStates.values.filter { $0.isScanning || $0.canResume }
    }

    /// "扫描中" = 文件扫描任务 + 正在进行的元数据刮削 (扫描标签)。
    private var activeTaskCount: Int {
        activeScans.count
            + (scraperService.isScraping ? 1 : 0)
            + ((backfill.isRunning || backfill.hasPendingWork) ? 1 : 0)
    }

    /// 刮削进行中的状态文案: "已处理/总数 · 当前歌曲" (当前曲名拿得到才拼)。
    private var scrapingStatusText: String {
        let counts = "\(scraperService.processedCount)/\(scraperService.totalCount)"
        let title = scraperService.currentSongTitle
        return title.isEmpty ? counts : "\(counts) · \(title)"
    }

    private var enabledSourcesCount: Int { sourcesStore.sources.filter(\.isEnabled).count }

    private var coverRatio: Double { ratio(count: library.visibleSongs.filter { $0.coverArtFileName?.isEmpty == false }.count) }
    private var lyricsRatio: Double { ratio(count: library.visibleSongs.filter { $0.lyricsFileName?.isEmpty == false }.count) }
    private var playableRatio: Double { ratio(count: library.visibleSongs.filter(\.isPlayable).count) }

    private func ratio(count: Int) -> Double {
        guard !library.visibleSongs.isEmpty else { return 0 }
        return Double(count) / Double(library.visibleSongs.count)
    }

    // MARK: - Actions

    private func playAlbum(_ album: Album) {
        var queue = library.songs(forAlbum: album.id)
        if queue.count < 20 {
            let existingIDs = Set(queue.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }.shuffled()
            queue.append(contentsOf: extra)
        }
        queue = queue.filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        var queue = library.recentlyPlayedSongs(limit: 50)
        if !queue.contains(where: { $0.id == song.id }) { queue.insert(song, at: 0) }
        if queue.count < 20 {
            let existingIDs = Set(queue.map(\.id))
            queue.append(contentsOf: library.visibleSongs.filter { !existingIDs.contains($0.id) })
        }
        queue = queue.filteredPlayable()
        guard let startIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: startIndex)
        Task { await player.play(song: queue[startIndex]) }
    }

    private func playLibrary(shuffled: Bool) {
        let candidates = library.visibleSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }
        let queue = shuffled ? candidates.shuffled() : candidates
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
}

private struct MacWindowSafeClickArea: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = WindowSafeNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performClick)
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1, height: proposal.height ?? 1)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performClick() {
            action()
        }
    }
}

private final class WindowSafeNSButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
#endif
