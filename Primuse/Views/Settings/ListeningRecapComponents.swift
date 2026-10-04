import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// 听歌统计页的版式零件。
///
/// 整页是一层随第一名封面变色的底，内容直接排在底上，靠字号和留白分层；只有
/// 「最近的状态」和年度回顾成块。不画图表 —— 一段时间听了多少，几个数字和几句话
/// 就说清楚了。服务器统计页也用这一套，两页看着是一回事。
enum RecapStyle {
    static var pageBase: Color {
        #if os(macOS)
        PMColor.bg
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var horizontalPadding: CGFloat {
        #if os(macOS)
        36
        #else
        20
        #endif
    }

    static let maximumContentWidth: CGFloat = 720
    static let sectionSpacing: CGFloat = 40
}

/// 页面底色：顶上一团封面色的光，往下淡进系统底色。取不到颜色时就是系统底色。
struct RecapBackdrop: View {
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.5 : 0.26
        ZStack {
            RecapStyle.pageBase
            if let tint {
                RadialGradient(
                    colors: [tint.opacity(strength), tint.opacity(0)],
                    center: UnitPoint(x: 0.12, y: 0),
                    startRadius: 0,
                    endRadius: 560
                )
                RadialGradient(
                    colors: [tint.opacity(strength * 0.45), tint.opacity(0)],
                    center: UnitPoint(x: 1, y: 0.32),
                    startRadius: 0,
                    endRadius: 420
                )
            }
        }
        .ignoresSafeArea()
        .pmAnimation(.ambient, value: tint)
        .accessibilityHidden(true)
    }
}

/// 一节的标题，右边可以挂一个小控件（切换榜单、时间说明）。
struct RecapSectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // 长语言下标题和右边的控件挤不下一行时，控件换到标题下面。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                titleText
                Spacer(minLength: 8)
                trailing()
            }
            VStack(alignment: .leading, spacing: 10) {
                titleText
                trailing()
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension RecapSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

/// 一排文字胶囊的单选：选中的那个垫一层淡底、字变深。
struct RecapPillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var compact = false
    /// 放不下一行时可以横着滑，并铺到页面左右边缘（「本周 / 本月……」在波兰语、俄语里很长）。
    var scrolls = false
    let label: (Value) -> Text

    var body: some View {
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) {
                pills.padding(.horizontal, RecapStyle.horizontalPadding)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .padding(.horizontal, -RecapStyle.horizontalPadding)
            .pmStopsAtVerticalBar()
        } else {
            pills
        }
    }

    private var pills: some View {
        HStack(spacing: compact ? 2 : 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    pmWithAnimation(.selection) { selection = option }
                } label: {
                    // 选中与否字重不变：字重一变胶囊宽度跟着变，整排会抖一下。
                    label(option)
                        .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, compact ? 11 : 14)
                        .padding(.vertical, compact ? 5 : 7)
                        .background {
                            if selected {
                                Capsule().fill(.primary.opacity(0.09))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// 大号时长：数字大、单位小，按当前语言的时长格式排（「12小时34分钟」「12h 34m」）。
struct RecapHeroDuration: View {
    let seconds: TimeInterval
    var numberSize: CGFloat = 58

    var body: some View {
        Text(attributed)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(Self.format(seconds))
    }

    private var attributed: AttributedString {
        let numberFont = Font.system(size: numberSize, weight: .bold, design: .rounded)
        let unitFont = Font.system(size: (numberSize * 0.38).rounded(), weight: .semibold, design: .rounded)
        var result = AttributedString()
        var run = ""
        var runIsNumber: Bool?
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.font = runIsNumber == true ? numberFont : unitFont
            result += piece
            run = ""
        }
        for character in Self.format(seconds) {
            let isNumber = character.isNumber
            if let runIsNumber, runIsNumber != isNumber { flush() }
            run.append(character)
            runIsNumber = isNumber
        }
        flush()
        return result
    }

    static func format(_ seconds: TimeInterval) -> String {
        let bounded: TimeInterval = seconds.isFinite ? max(0, seconds) : 0
        let units: Set<Duration.UnitsFormatStyle.Unit>
        if bounded < 60 {
            units = [.seconds]
        } else if bounded < 3_600 {
            units = [.minutes]
        } else {
            units = [.hours, .minutes]
        }
        return Duration.seconds(bounded).formatted(.units(allowed: units, width: .narrow))
    }
}

/// 一排小数字：数字在上、说明在下，平分整行。
struct RecapFigureRow: View {
    struct Figure: Identifiable {
        let id: String
        let value: String
        let label: String
    }

    let figures: [Figure]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(figures) { figure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: figure.value)
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: figure.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// 「这段时间」里的一句话：左边一个圆底图标。
struct RecapMomentRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一个小标签。
struct RecapChip: View {
    let text: String
    var isEmphasized = false

    var body: some View {
        Text(verbatim: text)
            .font(.footnote.weight(isEmphasized ? .semibold : .medium))
            .foregroundStyle(isEmphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.78)))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEmphasized ? AnyShapeStyle(.tint.opacity(0.13)) : AnyShapeStyle(.primary.opacity(0.07)), in: Capsule())
    }
}

/// 标签放不下一行时折到下一行。
struct RecapFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    /// 成块内容的衬底：一层很淡的填充和发丝边，让页面底色透上来。
    func recapPanel(cornerRadius: CGFloat = 22, padding: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
    }
}

// MARK: - 最近的状态

/// 最近 30 天的听歌状态。有 AI 解读就显示解读，没有就显示本机按习惯给出的状态；
/// 解读按 `ListeningMoodRefreshPolicy` 很少才更新一次。
struct ListeningMoodCard: View {
    let signals: ListeningMoodSignals
    /// 最近的播放时间（新的在前），用来数上次解读之后又听了多少。
    let recentPlayDates: [Date]
    let clearedAt: Date?

    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var showsConsent = false
    private var store: ListeningMoodStore { .shared }

    var body: some View {
        let reading = store.visibleReading(clearedAt: clearedAt)
        let archetype = ListeningMoodArchetype.classify(signals)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: reading == nil ? "waveform" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("stats_recap_mood_title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                Text("stats_recap_mood_window")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(verbatim: reading?.title ?? archetype.localizedTitle)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)

            Text(verbatim: reading?.summary ?? archetype.localizedSummary)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.82))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)

            let chips = reading?.keywords ?? localChips
            if !chips.isEmpty {
                RecapFlowLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { RecapChip(text: $0) }
                }
            }

            footer(reading: reading)
                .padding(.top, 2)

            if !store.isGenerating, let failure = store.lastFailure {
                Text(failureNote(failure))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .recapPanel()
        .pmAnimation(.contentAppear, value: reading)
        .task(id: signals) { refresh(force: false) }
        .confirmationDialog(
            "stats_recap_mood_consent_title",
            isPresented: $showsConsent,
            titleVisibility: .visible
        ) {
            Button("stats_recap_mood_consent_confirm") {
                do {
                    try intelligence.grantListeningMoodConsent()
                    refresh(force: true)
                } catch {
                    plog("🎧 Listening mood: could not save consent: \(error.localizedDescription)")
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("stats_recap_mood_consent_message")
        }
    }

    @ViewBuilder
    private func footer(reading: ListeningMoodReading?) -> some View {
        HStack(spacing: 10) {
            if store.isGenerating {
                ProgressView().controlSize(.mini)
                Text("stats_recap_mood_generating")
            } else if let reading {
                Text(verbatim: String(
                    format: String(localized: "stats_recap_mood_ai_footer_format"),
                    reading.providerName,
                    reading.generatedAt.formatted(.dateTime.month().day())
                ))
            } else {
                Text("stats_recap_mood_local_footer")
            }
            Spacer(minLength: 8)
            if !store.isGenerating {
                if intelligence.listeningMoodNeedsConsent {
                    Button {
                        showsConsent = true
                    } label: {
                        Label("stats_recap_mood_enable_ai", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
                } else if intelligence.isListeningMoodAvailable,
                          signals.plays >= ListeningMoodRefreshPolicy.minimumPlays,
                          store.nextManualRefresh() == nil {
                    Button {
                        refresh(force: true)
                    } label: {
                        Label(
                            reading == nil
                                ? LocalizedStringKey("stats_recap_mood_enable_ai")
                                : LocalizedStringKey("stats_recap_mood_refresh"),
                            systemImage: reading == nil ? "sparkles" : "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func failureNote(_ failure: AILibraryContentFailure) -> LocalizedStringKey {
        switch failure {
        case .builtInNotOffered: "stats_recap_mood_not_offered"
        default: "stats_recap_mood_failed"
        }
    }

    private var localChips: [String] {
        var chips: [String] = []
        if let daypart = signals.peakDaypart { chips.append(daypart.localizedLabel) }
        chips.append(contentsOf: signals.topGenres.prefix(2))
        return chips
    }

    private func refresh(force: Bool) {
        let since = store.visibleReading(clearedAt: clearedAt)?.generatedAt ?? .distantPast
        store.refreshIfNeeded(
            signals: signals,
            newPlaysSinceReading: recentPlayDates.prefix { $0 > since }.count,
            clearedAt: clearedAt,
            intelligence: intelligence,
            force: force
        )
    }
}

extension ListeningMoodArchetype {
    var localizedTitle: String {
        switch self {
        case .looping: String(localized: "stats_mood_looping_title")
        case .nocturnal: String(localized: "stats_mood_nocturnal_title")
        case .exploring: String(localized: "stats_mood_exploring_title")
        case .immersed: String(localized: "stats_mood_immersed_title")
        case .surging: String(localized: "stats_mood_surging_title")
        case .quiet: String(localized: "stats_mood_quiet_title")
        case .nostalgic: String(localized: "stats_mood_nostalgic_title")
        case .steady: String(localized: "stats_mood_steady_title")
        }
    }

    var localizedSummary: String {
        switch self {
        case .looping: String(localized: "stats_mood_looping_summary")
        case .nocturnal: String(localized: "stats_mood_nocturnal_summary")
        case .exploring: String(localized: "stats_mood_exploring_summary")
        case .immersed: String(localized: "stats_mood_immersed_summary")
        case .surging: String(localized: "stats_mood_surging_summary")
        case .quiet: String(localized: "stats_mood_quiet_summary")
        case .nostalgic: String(localized: "stats_mood_nostalgic_summary")
        case .steady: String(localized: "stats_mood_steady_summary")
        }
    }
}

extension ListeningDaypart {
    /// 与年度报告「时段画像」同一套叫法。
    var localizedLabel: String {
        switch self {
        case .dawn: String(localized: "yearly_time_dawn")
        case .morning: String(localized: "yearly_time_morning")
        case .afternoon: String(localized: "yearly_time_afternoon")
        case .evening: String(localized: "yearly_time_evening")
        case .lateNight: String(localized: "yearly_time_late_night")
        }
    }
}

// MARK: - 听歌人格

struct ListeningPersonalitySection: View {
    let traits: ListeningPersonalityTraits

    var body: some View {
        let personality = MusicPersonality(traits)
        VStack(alignment: .leading, spacing: 10) {
            RecapSectionHeader("stats_recap_personality_title")
            Text(verbatim: personality.displayName)
                .font(.system(.title, design: .rounded).weight(.heavy))
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
            if !personality.oneLiner.isEmpty {
                Text(verbatim: personality.oneLiner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RecapFlowLayout(spacing: 6) {
                ForEach(traitLabels, id: \.self) { RecapChip(text: $0, isEmphasized: true) }
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var traitLabels: [String] {
        [
            traits.exploration == .explorer ? "stats_trait_explorer" : "stats_trait_loyalist",
            traits.diversity == .omnivore ? "stats_trait_omnivore" : "stats_trait_focused",
            traits.recency == .new ? "stats_trait_new" : "stats_trait_vintage",
            traits.dayCycle == .day ? "stats_trait_day" : "stats_trait_moon",
        ].map { String(localized: String.LocalizationValue($0)) }
    }
}

// MARK: - 年度回顾

/// 年度回顾的入口：一块年度报告配色的渐变，下面是往年。
struct YearlyReviewEntry: View {
    let primaryYear: Int
    let isInProgress: Bool
    let pastYears: [Int]
    let open: @MainActor (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                open(primaryYear)
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("stats_recap_year_title", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(verbatim: String(format: String(localized: "yearly_report_entry_title"), primaryYear))
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(isInProgress
                             ? LocalizedStringKey("stats_recap_year_in_progress")
                             : LocalizedStringKey("stats_recap_year_ready"))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.20, green: 0.10, blue: 0.45),
                                Color(red: 0.55, green: 0.22, blue: 0.42),
                                Color(red: 0.88, green: 0.45, blue: 0.27),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Circle()
                            .fill(.white.opacity(0.10))
                            .frame(width: 180, height: 180)
                            .offset(x: 120, y: -60)
                            .blur(radius: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)

            if !pastYears.isEmpty {
                HStack(spacing: 8) {
                    Text("stats_recap_year_past")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(pastYears, id: \.self) { year in
                        Button {
                            open(year)
                        } label: {
                            Text(verbatim: String(year))
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(.primary.opacity(0.07), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 服务器上的记录

/// 服务器源的一行：名字、上次读到的累计播放与最常听的艺人。
struct ServerListeningRow: View {
    let source: MusicSource
    let summary: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.type.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: source.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: summary ?? String(localized: "stats_recap_server_open"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
