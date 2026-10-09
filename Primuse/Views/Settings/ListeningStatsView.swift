import SwiftUI
import PrimuseKit

/// 听歌统计的两种样子，在「设置 › 资料库」里选。年度报告是默认的；喜欢看数字和图表的人
/// 可以换回按周、月、年看的数据图表。
enum ListeningStatsStyle: String, CaseIterable, Identifiable, Sendable {
    case report
    case charts

    static let storageKey = "primuse.stats.style.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .report: String(localized: "stats_style_report")
        case .charts: String(localized: "stats_style_charts")
        }
    }
}

/// 听歌统计的入口（资料库、首页、侧栏）：按设置显示年度报告或数据图表。
struct ListeningStatsScreen: View {
    @AppStorage(ListeningStatsStyle.storageKey) private var style = ListeningStatsStyle.report
    @State private var model: Model
    private let initialRange: PlayHistoryStore.Range?
    private let initiallyShowsLocalHistory: Bool
    private let usesInlineSourcePicker: Bool

    /// 后三个参数只给数据图表用。
    init(
        model: Model = Model(),
        initialRange: PlayHistoryStore.Range? = nil,
        initiallyShowsLocalHistory: Bool = false,
        usesInlineSourcePicker: Bool = false
    ) {
        _model = State(initialValue: model)
        self.initialRange = initialRange
        self.initiallyShowsLocalHistory = initiallyShowsLocalHistory
        self.usesInlineSourcePicker = usesInlineSourcePicker
    }

    var body: some View {
        switch style {
        case .report:
            ListeningStatsView(model: model.report)
        case .charts:
            #if os(macOS)
            ListeningStatsChartsView(
                initialRange: initialRange,
                initiallyShowsLocalHistory: initiallyShowsLocalHistory,
                usesInlineSourcePicker: usesInlineSourcePicker,
                model: model.charts
            )
            #else
            ListeningStatsChartsView(
                initialRange: initialRange,
                initiallyShowsLocalHistory: initiallyShowsLocalHistory,
                usesInlineSourcePicker: usesInlineSourcePicker
            )
            #endif
        }
    }

    /// 两种样式各自算好的结果。Mac 把它放在页面外面，切走再回来不用重算。
    @MainActor
    final class Model {
        let report = ListeningStatsView.Model()
        #if os(macOS)
        let charts = ListeningStatsChartsView.Model()
        #endif

        init() {}
    }
}

/// 年度报告样式的听歌统计，一章接一章从上往下铺开（见 `YearlyReportPages`）。
/// 顶上换年份：今年是一月一日到现在，往年是整年；只露出听够了的年份。今年的报告在
/// 音乐人格后面接「最近的状态」（最近 30 天，可由 AI 解读，很少才更新一次）。
///
/// 数字来自本机播放记录加上按年归档的部分（本机只留最近 5000 条）。Navidrome、Emby
/// 等服务器自己记的播放不放在这里：本机放的歌多半也报给了服务器，加在一起就重复了。
/// 要看服务器上的记录，换到数据图表样式（`ListeningStatsChartsView`）。
struct ListeningStatsView: View {
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @State private var selectedYear: Int?
    @State private var model: Model
    @State private var statsCalendar = ListeningCalendar.current
    @State private var refreshGeneration = 0
    @State private var showClearConfirm = false
    private let title: LocalizedStringKey
    /// 清空记录放在页尾；一月自动弹出的报告里不放。
    private let showsManagement: Bool
    private var store: PlayHistoryStore { .shared }

    init(
        initialYear: Int? = nil,
        title: LocalizedStringKey = "stats_title",
        showsManagement: Bool = true,
        model: Model = Model()
    ) {
        var initialYear = initialYear
        #if DEBUG
        // 截图钩子：`PRIMUSE_DEBUG_STATS_YEAR=2025` 直接打开那一年的报告。
        if initialYear == nil, let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_STATS_YEAR"] {
            initialYear = Int(raw)
        }
        #endif
        _selectedYear = State(initialValue: initialYear)
        _model = State(initialValue: model)
        self.title = title
        self.showsManagement = showsManagement
    }

    var body: some View {
        let snapshot = model.snapshot
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                if let snapshot {
                    if let report = snapshot.report {
                        YearlyReportPages(
                            data: report,
                            mood: report.isInProgress
                                ? YearlyReportMood(signals: snapshot.mood, recentPlayDates: snapshot.recentPlayDates, clearedAt: store.clearedAt)
                                : nil,
                            spokenWordSeconds: snapshot.spokenWordSeconds
                        ) {
                            yearHeader(snapshot)
                        } footer: {
                            if showsManagement { footer }
                        }
                    } else {
                        emptyReport(snapshot)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 120)
                }
            }
            #if os(macOS)
            .scrollIndicators(.hidden)
            #endif
            #if DEBUG
            .task(id: snapshot?.report?.year) { await debugScroll(proxy) }
            #endif
        }
        // iPhone Duo 竖栏：滚动内容铺到屏幕边缘，系统的玻璃胶囊浮在上面。
        .pmExtendsUnderVerticalBar()
        .background {
            if let report = snapshot?.report {
                let tones = YearlyReportPages<EmptyView, EmptyView>.edgeTones(of: report)
                YearlyReportBackdrop(top: tones.top, bottom: tones.bottom)
            } else {
                YearlyReportBackdrop(top: .cover, bottom: .cover)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: refreshTrigger) {
            await refresh(trigger: refreshTrigger)
        }
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
    }

    #if DEBUG
    /// 截图钩子：`PRIMUSE_DEBUG_STATS_SCROLL=<章节>`（cover、artists、songs、taste、time、moments、
    /// month、sources、personality、closing，或 albums 即最常听的专辑）在报告算好后滚过去；
    /// 模拟器没法用命令行滚动。
    private func debugScroll(_ proxy: ScrollViewProxy) async {
        guard model.snapshot?.report != nil,
              let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_STATS_SCROLL"] else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        if raw == "albums" {
            // 专辑横排在歌曲那一章最下面：把这一章的底边对到屏幕底边。
            proxy.scrollTo(YearlyChapterKind.songs, anchor: .bottom)
        } else if let chapter = YearlyChapterKind(rawValue: raw) {
            proxy.scrollTo(chapter, anchor: .top)
        }
    }
    #endif

    // MARK: - 换年份

    @ViewBuilder
    private func yearHeader(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 10) {
            if let years = snapshot.years, years.years.count > 1, let shown = snapshot.report?.year {
                let selection = Binding(get: { shown }, set: { selectedYear = $0 })
                // 年份多到一行放不下时横着滑，否则居中。
                ViewThatFits(in: .horizontal) {
                    RecapPillPicker(options: years.years, selection: selection) { Text(verbatim: String($0)) }
                    RecapPillPicker(options: years.years, selection: selection, scrolls: true) { Text(verbatim: String($0)) }
                }
            }
            if let note = thisYearNote(snapshot) {
                Text(verbatim: note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 今年还没听够、报告停在往年时，说一句还差多少。
    private func thisYearNote(_ snapshot: Snapshot) -> String? {
        let currentYear = statsCalendar.component(.year, from: Date())
        guard snapshot.years?.years.contains(currentYear) != true, snapshot.playsThisYear > 0 else { return nil }
        return String(
            format: String(localized: "yearly_this_year_needs_more_format"),
            String(currentYear),
            max(1, ListeningYearReportPolicy.minimumPlays - snapshot.playsThisYear)
        )
    }

    // MARK: - 还没有报告

    private func emptyReport(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 14) {
            YearlyArtView(art: YearlyArt(name: "decor_overview_hourglass", fallbackSymbol: "hourglass", maxWidth: 180, maxHeight: 160))
            if snapshot.hasHistory {
                let year = statsCalendar.component(.year, from: Date())
                Text(verbatim: String(format: String(localized: "yearly_report_entry_title"), year))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(verbatim: String(
                    format: String(localized: "yearly_not_enough_format"),
                    String(year),
                    max(1, ListeningYearReportPolicy.minimumPlays - snapshot.playsThisYear)
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            } else {
                Text("stats_empty_title")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text("stats_empty_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if snapshot.hasHistory, showsManagement {
                footer.padding(.top, 36)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 页尾

    private var footer: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("stats_clear_action", systemImage: "trash")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            Text("stats_recap_privacy_footer")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// 两种样式的「清除所有听歌记录」都走这里：本机记录、按年归档的部分和最近的状态一起清掉，
    /// 不然换到另一种样式还能看到归档里的数字。
    @MainActor
    static func clearAllHistory() {
        PlayHistoryStore.shared.clearAll()
        PlayHistoryArchiver.removeAll()
        ListeningMoodStore.shared.clear()
    }

    private func clearHistory() {
        Self.clearAllHistory()
        model.archived = nil
        model.corpus = nil
        model.snapshot = nil
        model.snapshotKey = nil
        model.attribution = nil
        model.attributionKey = nil
        refreshGeneration &+= 1
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
        /// 播放记录里的音乐源各记到哪里；记录或音乐源变了才重算（可能要扫一遍曲库）。
        fileprivate var attribution: [String: ListeningSourceAttribution.Resolution]?
        fileprivate var attributionKey: AttributionKey?

        init() {}
    }

    fileprivate struct AttributionKey: Equatable, Sendable {
        let corpus: CorpusKey
        let liveSources: [String]
        let deletedSources: [String]
        /// 曲库装载完之前按歌认源认不出东西，装载完要重算一次。
        let libraryReady: Bool
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
        /// nil：还没选过，看默认的那一年。
        let year: Int?
        let day: Date
        let localeIdentifier: String
        let timeZoneIdentifier: String
        /// 风格、年份和按歌认源都要查曲库；打开页面时曲库可能还在装载，装载完再算一遍。
        let libraryReady: Bool
    }

    fileprivate struct RefreshTrigger: Equatable {
        let presentation: Presentation
        let generation: Int
    }

    struct Snapshot: Sendable {
        let years: ListeningYearReportPolicy.Years?
        /// 正在看的那一年的报告；没有听够的年份时为 nil。
        let report: YearlyReportData?
        let hasHistory: Bool
        let playsThisYear: Int
        /// 报告那一年听有声内容的时长。
        let spokenWordSeconds: TimeInterval
        /// 最近 30 天，和所看的年份无关。
        let mood: ListeningMoodSignals
        /// 最近的播放时间，新的在前。
        let recentPlayDates: [Date]
    }

    private var presentation: Presentation {
        Presentation(
            year: selectedYear,
            day: statsCalendar.startOfDay(for: Date()),
            localeIdentifier: statsCalendar.locale?.identifier ?? Locale.current.identifier,
            timeZoneIdentifier: statsCalendar.timeZone.identifier,
            libraryReady: library?.isReady ?? false
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

        let live = sourcesStore.sources
        let deleted = YearlyReportAnalyzer.deletedSources(in: sourcesStore)
        let attributionKey = AttributionKey(
            corpus: corpusKey,
            liveSources: live.map(\.id).sorted(),
            deletedSources: deleted.map(\.id).sorted(),
            libraryReady: trigger.presentation.libraryReady
        )
        let attribution: [String: ListeningSourceAttribution.Resolution]
        if let cached = model.attribution, model.attributionKey == attributionKey {
            attribution = cached
        } else {
            let librarySongs = library?.songs ?? []
            attribution = await Task.detached(priority: .userInitiated) {
                YearlyReportAnalyzer.attributeSources(music: corpus.music, live: live, deleted: deleted, librarySongs: librarySongs)
            }.value
            guard !Task.isCancelled, trigger == refreshTrigger else { return }
            model.attribution = attribution
            model.attributionKey = attributionKey
            // 归属变了，算好的报告里音乐源那一章也要跟着换。
            model.snapshotKey = nil
        }

        let key = SnapshotKey(corpus: corpusKey, presentation: trigger.presentation)
        guard model.snapshotKey != key || model.snapshot == nil else { return }
        let traits = library.map { YearlyReportAnalyzer.songTraits(for: corpus.music, library: $0) } ?? [:]
        let calendar = statsCalendar
        let now = Date()
        let requestedYear = trigger.presentation.year
        var snapshot = await Task.detached(priority: .userInitiated) {
            Self.makeSnapshot(corpus: corpus, traits: traits, requestedYear: requestedYear, now: now, calendar: calendar)
        }.value
        guard !Task.isCancelled, trigger == refreshTrigger else { return }
        if var report = snapshot.report {
            YearlyReportAnalyzer.resolveSources(in: &report, attribution: attribution, sourcesStore: sourcesStore)
            snapshot = snapshot.replacing(report: report)
        }
        model.snapshotKey = key
        model.snapshot = snapshot
        plog("📊 Yearly report year=\(snapshot.report.map { String($0.year) } ?? "none") plays=\(snapshot.report?.recap.totals.plays ?? 0) history=\(corpus.music.count)")
    }

    nonisolated private static func makeSnapshot(
        corpus: Corpus,
        traits: [String: ListeningRecapSongTraits],
        requestedYear: Int?,
        now: Date,
        calendar: Calendar
    ) -> Snapshot {
        var playsByYear: [Int: Int] = [:]
        for entry in corpus.music {
            playsByYear[calendar.component(.year, from: entry.playedAt), default: 0] += 1
        }
        let currentYear = calendar.component(.year, from: now)
        let years = ListeningYearReportPolicy.years(
            playsByYear: playsByYear,
            currentYear: currentYear,
            currentMonth: calendar.component(.month, from: now)
        )
        let year = requestedYear.flatMap { years?.years.contains($0) == true ? $0 : nil } ?? years?.initial
        let report = year.flatMap {
            YearlyReportAnalyzer.compute(year: $0, music: corpus.music, traits: traits, now: now, calendar: calendar)
        }
        let spokenWordSeconds = report.map { report in
            corpus.spokenWord
                .filter { report.interval.contains($0.playedAt) }
                .reduce(0.0) { $0 + ($1.listenedSec.isFinite ? max(0, $1.listenedSec) : 0) }
        } ?? 0
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
        return Snapshot(
            years: years,
            report: report,
            hasHistory: !corpus.music.isEmpty || !corpus.spokenWord.isEmpty,
            playsThisYear: playsByYear[currentYear] ?? 0,
            spokenWordSeconds: spokenWordSeconds,
            mood: ListeningMoodSignals.make(events: events, traits: traits, now: now, calendar: calendar),
            recentPlayDates: Array(corpus.music.map(\.playedAt).sorted(by: >).prefix(60))
        )
    }
}

private extension ListeningStatsView.Snapshot {
    func replacing(report: YearlyReportData) -> Self {
        Self(
            years: years,
            report: report,
            hasHistory: hasHistory,
            playsThisYear: playsThisYear,
            spokenWordSeconds: spokenWordSeconds,
            mood: mood,
            recentPlayDates: recentPlayDates
        )
    }
}
