import SwiftUI
import PrimuseKit

/// 听歌统计 —— 一整页的听歌回顾，不画图表。从上到下：
/// - 这段时间听了多久，和几个数字（播放、歌曲、艺人、天数）
/// - 最近的状态：最近 30 天的听歌习惯，可由 AI 解读（很少才更新一次）
/// - 最常听：第一名聚光，其后编号
/// - 听歌人格：和年度报告同一套判定，随所选时间段
/// - 这段时间：几句话说清最常在什么时候听、最长连听、新发现……
/// - 年度回顾：随时可看今年至今和往年的年度报告
/// - 服务器上的记录：Navidrome、Emby 等服务器自己记下的播放，单独列出
///
/// 数字来自本机播放记录加上按年归档的部分（本机只留最近 5000 条）。服务器的记录
/// 不和本机相加：在本机放的歌多半也报给了服务器，加在一起就重复了；只有累计次数的
/// 服务器也分不出是哪段时间听的。
struct ListeningStatsView: View {
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @Environment(CoverTintProvider.self) private var coverTints: CoverTintProvider?
    @State private var range: PlayHistoryStore.Range
    @State private var rankTab: RankTab = .songs
    @State private var model: Model
    @State private var statsCalendar = ListeningCalendar.current
    @State private var refreshGeneration = 0
    @State private var showClearConfirm = false
    @State private var yearlyReport: YearlyReportData?
    @State private var serverSummaries: [String: String] = [:]
    @State private var serverSummaryGeneration = 0
    #if os(macOS)
    @State private var presentedServerSource: MusicSource?
    #endif
    private var store: PlayHistoryStore { .shared }

    /// 一年至少听这么多次，年度回顾才有东西可讲。
    private static let yearlyReviewMinimumPlays = 20

    init(initialRange: PlayHistoryStore.Range? = nil, model: Model = Model()) {
        #if os(macOS)
        _range = State(initialValue: initialRange ?? .year)
        #else
        _range = State(initialValue: initialRange ?? .month)
        #endif
        _model = State(initialValue: model)
    }

    enum RankTab: String, CaseIterable {
        case songs, artists, albums

        var label: String {
            switch self {
            case .songs: return String(localized: "stats_rank_songs")
            case .artists: return String(localized: "stats_rank_artists")
            case .albums: return String(localized: "stats_rank_albums")
            }
        }
    }

    var body: some View {
        let snapshot = model.snapshot
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: RecapStyle.sectionSpacing) {
                    heroSection(snapshot)

                    if let snapshot, !snapshot.recap.isEmpty {
                        if snapshot.mood.plays >= ListeningMoodRefreshPolicy.minimumPlays {
                            ListeningMoodCard(
                                signals: snapshot.mood,
                                recentPlayDates: snapshot.recentPlayDates,
                                clearedAt: store.clearedAt
                            )
                        }
                        rankingSection(snapshot)
                            .id(DebugAnchor.ranking)
                        if let traits = snapshot.recap.personality {
                            ListeningPersonalitySection(traits: traits)
                                .id(DebugAnchor.personality)
                        }
                        momentsSection(snapshot)
                            .id(DebugAnchor.moments)
                    }

                    if let snapshot, let years = yearlyReviewYears(snapshot) {
                        YearlyReviewEntry(
                            primaryYear: years.primary,
                            isInProgress: years.inProgress,
                            pastYears: years.past,
                            open: openYearlyReport
                        )
                        .id(DebugAnchor.year)
                    }

                    if !serverSources.isEmpty {
                        serverSection
                            .id(DebugAnchor.servers)
                    }

                    if snapshot?.hasHistory == true {
                        footerSection
                    }
                }
                .padding(.horizontal, RecapStyle.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 56)
                .frame(maxWidth: RecapStyle.maximumContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            #if os(macOS)
            .scrollIndicators(.hidden)
            #endif
            #if DEBUG
            .task(id: snapshot == nil) { await debugScroll(proxy) }
            #endif
        }
        // iPhone Duo 竖栏：滚动内容铺到屏幕边缘，系统的玻璃胶囊浮在上面。
        .pmExtendsUnderVerticalBar()
        .background { RecapBackdrop(tint: backdropTint) }
        .navigationTitle("stats_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: refreshTrigger) {
            await refresh(trigger: refreshTrigger)
        }
        .task(id: backdropSongID) {
            guard let songID = backdropSongID, let song = library?.song(id: songID) else { return }
            coverTints?.prepare([song])
        }
        .task(id: serverSummaryKey) {
            await loadServerSummaries()
        }
        .onAppear { serverSummaryGeneration &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            refreshGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            statsCalendar = ListeningCalendar.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            statsCalendar = ListeningCalendar.current
        }
        .alert("stats_clear_confirm", isPresented: $showClearConfirm) {
            Button("delete", role: .destructive) { clearHistory() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("stats_clear_recap_message")
        }
        #if os(iOS)
        .fullScreenCover(item: $yearlyReport) { data in
            YearlyReportView(data: data)
        }
        #else
        .sheet(item: $yearlyReport) { data in
            YearlyReportView(data: data)
        }
        .sheet(item: $presentedServerSource) { source in
            NavigationStack {
                ServerListeningStatsView(source: source)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("done") { presentedServerSource = nil }
                        }
                    }
            }
            .frame(minWidth: 640, idealWidth: 720, minHeight: 620, idealHeight: 760)
        }
        #endif
    }

    private enum DebugAnchor: String {
        case ranking, personality, moments, year, servers
    }

    #if DEBUG
    /// 截图钩子：`PRIMUSE_DEBUG_STATS_SCROLL=ranking|personality|moments|year|servers`
    /// 在数据算好后把页面滚到那一节；模拟器没法用命令行滚动。
    private func debugScroll(_ proxy: ScrollViewProxy) async {
        guard model.snapshot != nil,
              let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_STATS_SCROLL"],
              let anchor = DebugAnchor(rawValue: raw) else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        proxy.scrollTo(anchor, anchor: .top)
    }
    #endif

    // MARK: - 时长与数字

    private func heroSection(_ snapshot: Snapshot?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            RecapPillPicker(options: PlayHistoryStore.Range.allCases, selection: $range, scrolls: true) { item in
                Text(LocalizedStringKey(item.localizationKey))
            }
            .settingsAnchor("stats.range")
            // 铺到 iPhone Duo 竖栏底下时，静止时就在竖排状态栏旁边的这一行照旧让开竖栏。
            .pmClearOfVerticalBar()

            if let snapshot {
                if !snapshot.hasHistory {
                    emptyHistory
                } else if snapshot.recap.isEmpty {
                    Text("stats_rank_empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(leadText(for: snapshot.range))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        RecapHeroDuration(seconds: snapshot.recap.totals.seconds)
                        HStack(spacing: 10) {
                            Text(verbatim: spanText(snapshot))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                            changeBadge(snapshot)
                        }
                    }
                    RecapFigureRow(figures: figures(snapshot.recap.totals))
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            }
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("stats_empty_title")
                .font(.headline)
            Text("stats_empty_desc")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func leadText(for range: PlayHistoryStore.Range) -> LocalizedStringKey {
        switch range {
        case .week: "stats_recap_lead_week"
        case .month: "stats_recap_lead_month"
        case .year: "stats_recap_lead_year"
        case .all: "stats_recap_lead_all"
        }
    }

    private func spanText(_ snapshot: Snapshot) -> String {
        if let interval = snapshot.interval {
            return String(
                format: String(localized: "stats_recap_span_format"),
                interval.start.formatted(.dateTime.month().day())
            )
        }
        guard let earliest = snapshot.earliestPlay else { return "" }
        return String(
            format: String(localized: "stats_recap_since_format"),
            earliest.formatted(.dateTime.year().month().day())
        )
    }

    @ViewBuilder
    private func changeBadge(_ snapshot: Snapshot) -> some View {
        if let previous = snapshot.recap.previous,
           let change = previous.secondsChange(to: snapshot.recap.totals.seconds),
           change.isFinite {
            let percent = Int((change * 100).rounded())
            HStack(spacing: 3) {
                Image(systemName: percent >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text(verbatim: String(
                    format: String(localized: "stats_comparison_format"),
                    "\(percent >= 0 ? "+" : "")\(percent)%",
                    previousPeriodLabel(snapshot.range)
                ))
            }
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.06), in: Capsule())
        }
    }

    private func previousPeriodLabel(_ range: PlayHistoryStore.Range) -> String {
        switch range {
        case .week: String(localized: "stats_previous_week")
        case .month: String(localized: "stats_previous_month")
        case .year: String(localized: "stats_previous_year")
        case .all: ""
        }
    }

    private func figures(_ totals: ListeningRecap.Totals) -> [RecapFigureRow.Figure] {
        [
            .init(id: "plays", value: totals.plays.formatted(), label: String(localized: "stats_total_plays")),
            .init(id: "songs", value: totals.uniqueSongs.formatted(), label: String(localized: "stats_unique_songs")),
            .init(id: "artists", value: totals.uniqueArtists.formatted(), label: String(localized: "stats_recap_figure_artists")),
            .init(id: "days", value: totals.activeDays.formatted(), label: String(localized: "stats_active_days")),
        ]
    }

    // MARK: - 最常听

    private func rankingSection(_ snapshot: Snapshot) -> some View {
        let items: [PlayHistoryStore.RankedItem] = switch rankTab {
        case .songs: snapshot.topSongs
        case .artists: snapshot.topArtists
        case .albums: snapshot.topAlbums
        }
        return VStack(alignment: .leading, spacing: 18) {
            RecapSectionHeader(title: "stats_recap_top_title") {
                RecapPillPicker(options: RankTab.allCases, selection: $rankTab, compact: true) { tab in
                    Text(verbatim: tab.label)
                }
                .settingsAnchor("stats.rank")
            }
            if items.isEmpty {
                Text("stats_rank_empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ListeningRankSpotlightList(
                    items: items,
                    isArtistRanking: rankTab == .artists,
                    identity: rankTab.rawValue + "." + snapshot.range.rawValue,
                    spotlightArtwork: Self.spotlightArtwork
                )
            }
        }
    }

    private static var spotlightArtwork: CGFloat {
        #if os(macOS)
        140
        #else
        116
        #endif
    }

    // MARK: - 这段时间

    @ViewBuilder
    private func momentsSection(_ snapshot: Snapshot) -> some View {
        let items = moments(snapshot)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                RecapSectionHeader("stats_recap_moments_title")
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { moment in
                        RecapMomentRow(symbol: moment.symbol, text: moment.text)
                    }
                }
            }
        }
    }

    private struct Moment: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol + text }

        init(_ symbol: String, _ text: String) {
            self.symbol = symbol
            self.text = text
        }
    }

    private func moments(_ snapshot: Snapshot) -> [Moment] {
        let recap = snapshot.recap
        var result: [Moment] = []
        if let daypart = recap.peakDaypart, let hour = recap.peakHour {
            result.append(Moment(daypart.symbolName, String(
                format: String(localized: "stats_moment_peak_format"),
                daypart.localizedLabel,
                hourLabel(hour)
            )))
        }
        if recap.totals.activeDays > 1, let day = recap.busiestDay {
            result.append(Moment("calendar", String(
                format: String(localized: "stats_moment_busiest_day_format"),
                day.date.formatted(.dateTime.month().day()),
                RecapHeroDuration.format(day.seconds)
            )))
        }
        if let session = recap.longestSession, session.songs >= 3 {
            result.append(Moment("headphones", String(
                format: String(localized: "stats_moment_session_format"),
                RecapHeroDuration.format(session.seconds),
                session.songs
            )))
        }
        if let streak = recap.longestStreak, streak.days >= 3 {
            result.append(Moment("flame.fill", String(
                format: String(localized: "stats_moment_streak_format"),
                streak.days
            )))
        }
        if let discoveries = recap.discoveries, discoveries > 0 {
            result.append(Moment("sparkles", String(
                format: String(localized: "stats_moment_discoveries_format"),
                discoveries
            )))
        }
        if !recap.topGenres.isEmpty {
            result.append(Moment("guitars.fill", String(
                format: String(localized: "stats_moment_genres_format"),
                recap.topGenres.map(\.name).formatted(.list(type: .and))
            )))
        }
        if snapshot.spokenWordSeconds >= 60 {
            result.append(Moment(ListeningSpace.spokenWord.systemImage, String(
                format: String(localized: "stats_moment_spoken_format"),
                RecapHeroDuration.format(snapshot.spokenWordSeconds)
            )))
        }
        return result
    }

    /// 「晚上11时」「11 PM」：按当前语言写钟点。
    private func hourLabel(_ hour: Int) -> String {
        let date = statsCalendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: - 年度回顾

    private func yearlyReviewYears(_ snapshot: Snapshot) -> (primary: Int, inProgress: Bool, past: [Int])? {
        let now = Date()
        let currentYear = statsCalendar.component(.year, from: now)
        let month = statsCalendar.component(.month, from: now)
        let eligible = snapshot.yearPlays
            .filter { $0.value >= Self.yearlyReviewMinimumPlays }
            .keys
            .sorted(by: >)
        guard let latest = eligible.first else { return nil }
        let primary: Int
        // 一月里今年还没听几首，主推去年的。
        if month == 1, eligible.contains(currentYear - 1) {
            primary = currentYear - 1
        } else if eligible.contains(currentYear) {
            primary = currentYear
        } else {
            primary = latest
        }
        return (primary, primary == currentYear && month < 12, eligible.filter { $0 != primary })
    }

    private func openYearlyReport(_ year: Int) {
        guard let corpus = model.corpus, let library else { return }
        let calendar = Calendar.current
        let entries = corpus.music.filter { calendar.component(.year, from: $0.playedAt) == year }
        yearlyReport = YearlyReportAnalyzer.analyze(
            year: year,
            entries: entries,
            library: library,
            sourcesStore: sourcesStore
        )
    }

    // MARK: - 服务器上的记录

    private var serverSources: [MusicSource] {
        sourcesStore.sources.filter {
            $0.isEnabled
                && !$0.isDeleted
                && $0.type.serverListeningStatsCapability != .unavailable
        }
    }

    private var serverSummaryKey: [String] {
        serverSources.map { "\($0.id):\($0.modifiedAt.timeIntervalSince1970)" } + ["\(serverSummaryGeneration)"]
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecapSectionHeader("stats_recap_servers_title")
            Text("stats_recap_servers_footer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(serverSources) { source in
                    #if os(macOS)
                    Button {
                        presentedServerSource = source
                    } label: {
                        ServerListeningRow(source: source, summary: serverSummaries[source.id])
                    }
                    .buttonStyle(.plain)
                    #else
                    NavigationLink {
                        ServerListeningStatsView(source: source)
                    } label: {
                        ServerListeningRow(source: source, summary: serverSummaries[source.id])
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
    }

    /// 只读上次存下的服务器快照，不联网；点进去才向服务器要最新的。
    private func loadServerSummaries() async {
        let snapshotStore = ServerListeningStatsSnapshotStore()
        var summaries: [String: String] = [:]
        for source in serverSources {
            guard let loaded = await snapshotStore.load(for: source),
                  let presentation = ServerListeningStatsPresentationBuilder.build(
                    payload: loaded.snapshot.payload,
                    range: .all
                  ) else { continue }
            var parts = [String(
                format: String(localized: "stats_recap_server_plays_format"),
                (presentation.allTimePlayCount ?? presentation.totalPlays).formatted()
            )]
            if let artist = presentation.topArtists.first?.title, artist != "—" {
                parts.append(String(format: String(localized: "stats_recap_server_top_artist_format"), artist))
            }
            summaries[source.id] = parts.joined(separator: " · ")
        }
        guard !Task.isCancelled else { return }
        serverSummaries = summaries
    }

    // MARK: - 页尾

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("stats_clear_action", systemImage: "trash")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .settingsAnchor("stats.clear")
            Text("stats_recap_privacy_footer")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clearHistory() {
        store.clearAll()
        PlayHistoryArchiver.removeAll()
        ListeningMoodStore.shared.clear()
        model.archived = nil
        model.corpus = nil
        model.snapshot = nil
        model.snapshotKey = nil
        refreshGeneration &+= 1
    }

    // MARK: - 底色

    /// 底色取这段时间第一名歌曲的封面。
    private var backdropSongID: String? {
        model.snapshot?.topSongs.first?.artworkSongID
    }

    private var backdropTint: Color? {
        backdropSongID.flatMap { coverTints?.tint(forSongID: $0) }
    }
}

// MARK: - 数据

extension ListeningStatsView {
    /// 页面算好的结果。Mac 把它放在页面外面，切走再回来不用重算。
    @MainActor
    @Observable
    final class Model {
        /// 按年归档的记录，清空前不会变，读一次留着。
        fileprivate var archived: ArchivedHistory?
        fileprivate var corpus: Corpus?
        fileprivate var snapshot: Snapshot?
        fileprivate var snapshotKey: SnapshotKey?

        init() {}
    }

    fileprivate struct ArchivedHistory: Sendable {
        let clearedAt: Date?
        let entries: [PlayHistoryStore.Entry]
    }

    fileprivate struct CorpusKey: Equatable, Sendable {
        let historyRevision: Int
        let clearedAt: Date?
        let spokenWordSongIDs: Set<String>
    }

    /// 全部播放记录（本机 + 归档），音乐和有声内容分开。
    fileprivate struct Corpus: Sendable {
        let key: CorpusKey
        let music: [PlayHistoryStore.Entry]
        let spokenWord: [PlayHistoryStore.Entry]
    }

    fileprivate struct SnapshotKey: Equatable, Sendable {
        let corpus: CorpusKey
        let presentation: Presentation
    }

    fileprivate struct Presentation: Equatable, Sendable {
        let range: PlayHistoryStore.Range
        let day: Date
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    fileprivate struct RefreshTrigger: Equatable {
        let presentation: Presentation
        let generation: Int
    }

    struct Snapshot: Sendable {
        let range: PlayHistoryStore.Range
        let interval: DateInterval?
        let hasHistory: Bool
        let recap: ListeningRecap
        let topSongs: [PlayHistoryStore.RankedItem]
        let topArtists: [PlayHistoryStore.RankedItem]
        let topAlbums: [PlayHistoryStore.RankedItem]
        /// 有声内容只记时长，不进上面任何一项。
        let spokenWordSeconds: TimeInterval
        let mood: ListeningMoodSignals
        /// 最近的播放时间，新的在前。
        let recentPlayDates: [Date]
        /// 每年听了多少次音乐，决定年度回顾露出哪几年。
        let yearPlays: [Int: Int]
        let earliestPlay: Date?
    }

    private var presentation: Presentation {
        Presentation(
            range: range,
            day: statsCalendar.startOfDay(for: Date()),
            localeIdentifier: statsCalendar.locale?.identifier ?? Locale.current.identifier,
            timeZoneIdentifier: statsCalendar.timeZone.identifier
        )
    }

    private var refreshTrigger: RefreshTrigger {
        RefreshTrigger(presentation: presentation, generation: refreshGeneration)
    }

    private func refresh(trigger: RefreshTrigger) async {
        await Task.yield()
        guard !Task.isCancelled, trigger == refreshTrigger else { return }

        let clearedAt = store.clearedAt
        let corpusKey = CorpusKey(
            historyRevision: store.revision,
            clearedAt: clearedAt,
            spokenWordSongIDs: store.spokenWordSongIDs
        )
        let corpus: Corpus
        if let cached = model.corpus, cached.key == corpusKey {
            corpus = cached
        } else {
            let live = store.entries
            let cachedArchive = model.archived?.clearedAt == clearedAt ? model.archived : nil
            let loaded = await Task.detached(priority: .userInitiated) {
                let archived = cachedArchive ?? ArchivedHistory(
                    clearedAt: clearedAt,
                    entries: PlayHistoryArchiver.completeHistory(live: [], clearedAt: clearedAt)
                )
                let all = PlayHistoryArchiver.merged(live: live, archived: archived.entries, clearedAt: clearedAt)
                var music: [PlayHistoryStore.Entry] = []
                var spokenWord: [PlayHistoryStore.Entry] = []
                for entry in all {
                    if corpusKey.spokenWordSongIDs.contains(entry.songID) {
                        spokenWord.append(entry)
                    } else {
                        music.append(entry)
                    }
                }
                return (archived, Corpus(key: corpusKey, music: music, spokenWord: spokenWord))
            }.value
            guard !Task.isCancelled, trigger == refreshTrigger else { return }
            model.archived = loaded.0
            model.corpus = loaded.1
            corpus = loaded.1
        }

        let key = SnapshotKey(corpus: corpusKey, presentation: trigger.presentation)
        guard model.snapshotKey != key || model.snapshot == nil else { return }
        let traits = songTraits(for: corpus.music)
        let calendar = statsCalendar
        let now = Date()
        let range = trigger.presentation.range
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.makeSnapshot(corpus: corpus, traits: traits, range: range, now: now, calendar: calendar)
        }.value
        guard !Task.isCancelled, trigger == refreshTrigger else { return }
        model.snapshotKey = key
        model.snapshot = snapshot
        plog("📊 Listening recap range=\(range.rawValue) plays=\(snapshot.recap.totals.plays) history=\(corpus.music.count)")
    }

    /// 播放记录里没有风格和年份，按 id 去曲库查（O(1)），只查记录里出现过的歌。
    private func songTraits(for entries: [PlayHistoryStore.Entry]) -> [String: ListeningRecapSongTraits] {
        guard let library else { return [:] }
        var traits: [String: ListeningRecapSongTraits] = [:]
        for songID in Set(entries.map(\.songID)) {
            guard let song = library.song(id: songID) else { continue }
            traits[songID] = ListeningRecapSongTraits(genre: song.genre, year: song.year)
        }
        return traits
    }

    nonisolated private static func makeSnapshot(
        corpus: Corpus,
        traits: [String: ListeningRecapSongTraits],
        range: PlayHistoryStore.Range,
        now: Date,
        calendar: Calendar
    ) -> Snapshot {
        let interval: DateInterval? = range == .all ? nil : {
            let start = range.statisticsStartDate(now: now, calendar: calendar)
            return DateInterval(start: start, end: max(start, now))
        }()
        let events = corpus.music.map {
            ListeningRecapEvent(
                songID: $0.songID,
                title: $0.songTitle,
                artist: $0.artistName,
                album: $0.albumTitle,
                playedAt: $0.playedAt,
                seconds: $0.listenedSec
            )
        }
        let recap = ListeningRecapBuilder.build(
            events: events,
            interval: interval,
            previousInterval: interval.flatMap { previousInterval(range: range, current: $0, calendar: calendar) },
            traits: traits,
            calendar: calendar,
            referenceYear: calendar.component(.year, from: now)
        )
        func inRange(_ date: Date) -> Bool {
            interval?.contains(date) ?? (date <= now)
        }
        let scoped = corpus.music.filter { inRange($0.playedAt) }
        let spokenWordSeconds = corpus.spokenWord
            .filter { inRange($0.playedAt) }
            .reduce(0.0) { $0 + ($1.listenedSec.isFinite ? max(0, $1.listenedSec) : 0) }

        var yearPlays: [Int: Int] = [:]
        for entry in corpus.music {
            yearPlays[calendar.component(.year, from: entry.playedAt), default: 0] += 1
        }

        return Snapshot(
            range: range,
            interval: interval,
            hasHistory: !corpus.music.isEmpty || !corpus.spokenWord.isEmpty,
            recap: recap,
            topSongs: PlayHistoryStore.rankedItems(from: scoped, category: .songs, limit: 20),
            topArtists: PlayHistoryStore.rankedItems(from: scoped, category: .artists, limit: 20),
            topAlbums: PlayHistoryStore.rankedItems(from: scoped, category: .albums, limit: 20),
            spokenWordSeconds: spokenWordSeconds,
            mood: ListeningMoodSignals.make(events: events, traits: traits, now: now, calendar: calendar),
            recentPlayDates: Array(corpus.music.map(\.playedAt).sorted(by: >).prefix(60)),
            yearPlays: yearPlays,
            earliestPlay: corpus.music.lazy.map(\.playedAt).min()
        )
    }

    /// 上一个等长周期：本周对上周同一时刻为止，本月对上月，以此类推。
    nonisolated private static func previousInterval(
        range: PlayHistoryStore.Range,
        current: DateInterval,
        calendar: Calendar
    ) -> DateInterval? {
        let component: Calendar.Component
        switch range {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all: return nil
        }
        guard let start = calendar.date(byAdding: component, value: -1, to: current.start),
              let end = calendar.date(byAdding: component, value: -1, to: current.end),
              start < end else {
            return nil
        }
        return DateInterval(start: start, end: end)
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
}
