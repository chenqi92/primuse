import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// 睡眠定时现在的状态写成一句话:「将在 23:41 停止」「将在明天 07:00 停止」「当前曲目结束后停止」;
/// 没开时为 nil。播放页「更多」、迷你条菜单、定时面板共用。
enum SleepTimerStatusText {
    @MainActor
    static func summary(_ player: AudioPlayerService, now: Date = Date()) -> String? {
        if let end = player.sleepTimerEndDate {
            return stopTime(end, now: now)
        }
        if player.sleepStopAfterSongID != nil {
            return player.currentListeningSpace?.playbackFamily == .spokenWord
                ? String(localized: "sleep_at_item_end")
                : String(localized: "sleep_at_track_end")
        }
        if player.sleepStopAfterChapter != nil { return String(localized: "sleep_at_chapter_end") }
        if player.sleepStopAfterBook != nil { return String(localized: "sleep_at_book_end") }
        return nil
    }

    /// 「将在 23:41 停止」,不在今天时写「明天」。
    static func stopTime(_ end: Date, now: Date) -> String {
        let clock = end.formatted(date: .omitted, time: .shortened)
        if SleepTimerSchedulePolicy.isOnLaterDay(end, than: now) {
            return String(format: String(localized: "sleep_timer_stops_tomorrow_format"), clock)
        }
        return String(format: String(localized: "sleep_timer_stops_at_format"), clock)
    }
}

extension EnvironmentValues {
    /// 打开睡眠定时面板(迷你条长按菜单里的「自定义…」);挂不上面板的宿主里为 nil,菜单就不给这一项。
    @Entry var presentSleepTimer: (@MainActor () -> Void)? = nil
}

struct SleepTimerSheet: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(SleepTimerSchedulePolicy.finishesTrackPreferenceKey) private var finishesTrack = false
    /// 上一次自定义的时长与时刻,下次打开接着用。
    @AppStorage("primuse.sleepTimer.customMinutes") private var customMinutes = 20
    @AppStorage("primuse.sleepTimer.clockMinuteOfDay") private var clockMinuteOfDay = 23 * 60
    @State private var customMode: CustomMode = .duration
    @State private var selectedEndOption: SleepTimerOption?
    @State private var isEditing = false

    private enum CustomMode: Hashable {
        case duration
        case clock
        case end
    }

    private var space: ListeningSpace { player.currentListeningSpace ?? .music }

    private var options: [SleepTimerOption] {
        SleepTimerOptionPolicy.options(for: space, hasChapters: player.hasChapters)
    }

    private var presetMinutes: [Int] {
        options.compactMap { option in
            if case .minutes(let minutes) = option { return minutes }
            return nil
        }
    }

    private var endOptions: [SleepTimerOption] {
        options.filter { option in
            if case .minutes = option { return false }
            return true
        }
    }

    /// 只有歌曲有「播完这首」可等;电台没有结尾,有声内容有自己的本章 / 本集。
    private var offersFinishTrack: Bool {
        space == .music && !player.isLiveRadio
    }

    private var showsRunningTimer: Bool { player.isSleepTimerActive && !isEditing }

    private var canStart: Bool {
        guard customMode == .end else { return true }
        guard let selectedEndOption, endOptions.contains(selectedEndOption) else { return false }
        return !isEndOptionUnavailable(selectedEndOption)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !showsRunningTimer {
                    modePicker
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if showsRunningTimer {
                            statusCard
                        } else {
                            modeEditor
                                .frame(minHeight: 202)
                            if offersFinishTrack && customMode != .end {
                                Divider()
                                finishTrackSection
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("sleepTimer.content")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
            .navigationTitle(Text("sleep_timer"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("close"))
                    .accessibilityIdentifier("sleepTimer.close")
                }
            }
            .onAppear { selectAvailableEndOption() }
            .onChange(of: endOptions) { _, _ in
                selectAvailableEndOption()
                if endOptions.isEmpty { customMode = .duration }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 560, idealHeight: 600)
        #else
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(560), .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var modePicker: some View {
        Picker(selection: $customMode) {
            Text("sleep_timer_custom_mode_duration").tag(CustomMode.duration)
            Text("sleep_timer_custom_mode_clock").tag(CustomMode.clock)
            if !endOptions.isEmpty {
                Text("sleep_timer_section_end").tag(CustomMode.end)
            }
        } label: {
            Text("sleep_timer")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("sleepTimer.mode")
    }

    @ViewBuilder
    private var modeEditor: some View {
        switch customMode {
        case .duration:
            VStack(spacing: 14) {
                durationPicker
                presetSection
            }
        case .clock:
            clockPicker
        case .end:
            endSection
        }
    }

    private var actionFooter: some View {
        VStack(spacing: 12) {
            Divider()
            if showsRunningTimer {
                HStack(spacing: 12) {
                    turnOffButton
                        .frame(maxWidth: .infinity)
                    Button { editRunningTimer() } label: {
                        Text("edit")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sleepTimer.edit")
                }
            } else {
                TimelineView(.everyMinute) { context in
                    Text(verbatim: draftSummary(now: context.date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("sleepTimer.summary")
                }
                Button { startTimer() } label: {
                    Text("sleep_timer_start")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .accessibilityIdentifier("sleepTimer.start")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private func draftSummary(now: Date) -> String {
        if customMode == .end {
            return selectedEndOption.map(endTitle) ?? ""
        }
        let end = customEndDate(now: now)
        return SleepTimerStatusText.stopTime(end, now: now)
            + " · " + String(format: String(localized: "sleep_timer_length_format"),
                              Self.lengthLabel(end.timeIntervalSince(now)))
    }

    private func selectAvailableEndOption() {
        if let selectedEndOption, endOptions.contains(selectedEndOption),
           !isEndOptionUnavailable(selectedEndOption) { return }
        selectedEndOption = endOptions.first(where: { player.isSleepOptionArmed($0) })
            ?? endOptions.first(where: { !isEndOptionUnavailable($0) })
            ?? endOptions.first
    }

    private func startTimer() {
        guard canStart else { return }
        if customMode == .end, let selectedEndOption {
            player.applySleepOption(selectedEndOption)
        } else {
            player.scheduleSleep(until: customEndDate(now: Date()))
        }
        dismiss()
    }

    private func editRunningTimer() {
        if let end = player.sleepTimerEndDate {
            let remainingMinutes = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
            if remainingMinutes > 720 {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: end)
                clockMinuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                customMode = .clock
            } else {
                customMinutes = remainingMinutes
                customMode = .duration
            }
        } else {
            selectedEndOption = endOptions.first(where: { player.isSleepOptionArmed($0) })
            selectAvailableEndOption()
            customMode = endOptions.isEmpty ? .duration : .end
        }
        isEditing = true
    }

    // MARK: Running

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let end = player.sleepTimerEndDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownRow(end: end, now: context.date)
                }
                HStack(spacing: 10) {
                    ForEach(SleepTimerSchedulePolicy.extensionMinutes, id: \.self) { minutes in
                        Button {
                            player.extendSleep(minutes: minutes)
                        } label: {
                            Text(verbatim: String(format: String(localized: "sleep_timer_extend_format"), minutes))
                                .monospacedDigit()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("sleepTimer.extend.\(minutes)")
                    }
                    Spacer(minLength: 8)
                }
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.14), in: Circle())
                    Text(verbatim: SleepTimerStatusText.summary(player) ?? "")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(.vertical, 24)
    }

    private func countdownRow(end: Date, now: Date) -> some View {
        let remaining = max(0, end.timeIntervalSince(now))
        let fraction = SleepTimerSchedulePolicy.remainingFraction(
            start: player.sleepTimerStartDate,
            end: end,
            now: now
        )
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
                Image(systemName: "moon.zzz.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: remaining.formattedDuration)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(verbatim: SleepTimerStatusText.stopTime(end, now: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if offersFinishTrack, finishesTrack {
                    Text("sleep_timer_finish_track_note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sleepTimer.remaining")
    }

    private var turnOffButton: some View {
        Button(role: .destructive) {
            player.cancelSleep()
            isEditing = false
        } label: {
            Text("cancel_timer")
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("sleepTimer.cancel")
    }

    // MARK: Choices

    private var presetSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 120 : 72), spacing: 8)], spacing: 8) {
            ForEach(presetMinutes, id: \.self) { minutes in
                Button {
                    customMinutes = minutes
                } label: {
                    Text(verbatim: "\(minutes) " + String(localized: "minutes"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(customMinutes == minutes ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.06)))
                        }
                        .foregroundStyle(customMinutes == minutes ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(customMinutes == minutes ? .isSelected : [])
                .accessibilityIdentifier("sleepTimer.preset.\(minutes)")
            }
        }
    }

    private var endSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(endOptions.enumerated()), id: \.element) { index, option in
                if index > 0 {
                    Divider().padding(.leading, 48)
                }
                endRow(option)
            }
        }
    }

    private func endRow(_ option: SleepTimerOption) -> some View {
        let isSelected = selectedEndOption == option
        return Button {
            selectedEndOption = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: endSymbol(option))
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(verbatim: endTitle(option))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEndOptionUnavailable(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sleepTimer.end.\(endSymbol(option))")
    }

    private func endTitle(_ option: SleepTimerOption) -> String {
        switch option {
        case .minutes(let minutes):
            "\(minutes) " + String(localized: "minutes")
        case .endOfTrack:
            space.playbackFamily == .spokenWord
                ? String(localized: "sleep_at_item_end")
                : String(localized: "sleep_at_track_end")
        case .endOfChapter:
            String(localized: "sleep_at_chapter_end")
        case .endOfBook:
            String(localized: "sleep_at_book_end")
        }
    }

    private func endSymbol(_ option: SleepTimerOption) -> String {
        switch option {
        case .minutes: "timer"
        case .endOfTrack: "play.circle"
        case .endOfChapter: "list.bullet.indent"
        case .endOfBook: "book.closed"
        }
    }

    private func isEndOptionUnavailable(_ option: SleepTimerOption) -> Bool {
        switch option {
        case .endOfTrack: player.currentSong == nil
        case .endOfChapter: player.currentChapterIndex == nil
        case .minutes, .endOfBook: false
        }
    }

    // MARK: Custom

    private var customHours: Binding<Int> {
        Binding(
            get: { min(12, max(0, customMinutes / 60)) },
            set: { hours in
                let minutes = hours >= 12 ? 0 : customMinutes % 60
                customMinutes = max(1, hours * 60 + minutes)
            }
        )
    }

    private var customMinuteOfHour: Binding<Int> {
        Binding(
            get: { customMinutes >= 12 * 60 ? 0 : customMinutes % 60 },
            set: { minutes in
                let hours = min(11, customMinutes / 60)
                customMinutes = max(1, hours * 60 + minutes)
            }
        )
    }

    private var clockTime: Binding<Date> {
        Binding(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return start.addingTimeInterval(TimeInterval(clockMinuteOfDay * 60))
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                clockMinuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func customEndDate(now: Date) -> Date {
        switch customMode {
        case .duration, .end:
            return now.addingTimeInterval(SleepTimerSchedulePolicy.duration(
                hours: customMinutes / 60,
                minutes: customMinutes % 60
            ))
        case .clock:
            return SleepTimerSchedulePolicy.nextOccurrence(
                hour: clockMinuteOfDay / 60,
                minute: clockMinuteOfDay % 60,
                after: now
            )
        }
    }

    @ViewBuilder
    private var durationPicker: some View {
        #if os(iOS)
        HStack(spacing: 0) {
            Picker(selection: customHours) {
                ForEach(0...12, id: \.self) { hours in
                    Text(verbatim: "\(hours) " + String(localized: "sleep_timer_hours_unit")).tag(hours)
                }
            } label: {
                Text("sleep_timer_hours_unit")
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("sleepTimer.hours")

            Picker(selection: customMinuteOfHour) {
                ForEach(0..<60, id: \.self) { minutes in
                    Text(verbatim: "\(minutes) " + String(localized: "minutes")).tag(minutes)
                }
            } label: {
                Text("minutes")
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .disabled(customHours.wrappedValue >= 12)
            .accessibilityIdentifier("sleepTimer.minutes")
        }
        .frame(height: 140)
        .clipped()
        .contentShape(Rectangle())
        #else
        HStack(spacing: 12) {
            Stepper(value: customHours, in: 0...12) {
                Text(verbatim: "\(customHours.wrappedValue) " + String(localized: "sleep_timer_hours_unit"))
                    .monospacedDigit()
            }
            Stepper(value: customMinuteOfHour, in: 0...59, step: 5) {
                Text(verbatim: "\(customMinuteOfHour.wrappedValue) " + String(localized: "minutes"))
                    .monospacedDigit()
            }
            .disabled(customHours.wrappedValue >= 12)
        }
        #endif
    }

    @ViewBuilder
    private var clockPicker: some View {
        #if os(iOS)
        ClockWheelPicker(minuteOfDay: $clockMinuteOfDay)
            .frame(height: 140)
            .accessibilityIdentifier("sleepTimer.clock")
        #else
        DatePicker(selection: clockTime, displayedComponents: .hourAndMinute) {
            Text("sleep_timer_custom_mode_clock")
        }
        .datePickerStyle(.field)
        .labelsHidden()
        #endif
    }

    /// 「1 小时 25 分钟」这种写法,给自定义那一格下面的说明用。
    static func lengthLabel(_ length: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = length >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        // 不到一分钟的零头进位,免得 59 分 30 秒写成 59 分钟。
        return formatter.string(from: (length / 60).rounded(.up) * 60) ?? ""
    }

    // MARK: Finish track

    private var finishTrackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $finishesTrack) {
                Text("sleep_timer_finish_track")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("sleepTimer.finishTrack")
            Text("sleep_timer_finish_track_footer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if os(iOS)
/// 「到点停止」的时刻滚轮。SwiftUI 的滚轮 DatePicker 缩不到系统的 216pt 以下，
/// `.frame(height:).clipped()` 只裁掉画面，上下多出来的那截照样接点按，正好压住上面
/// 「倒计时 / 到点停止」的分段控件：切到到点停止就切不回倒计时，点上去反倒拨动了小时。
/// 放进裁边的容器里，点按只落在看得见的那一截。
private struct ClockWheelPicker: UIViewRepresentable {
    @Binding var minuteOfDay: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(minuteOfDay: $minuteOfDay)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.date = Self.date(minuteOfDay: minuteOfDay)
        picker.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        context.coordinator.picker = picker
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.minuteOfDay = $minuteOfDay
        guard let picker = context.coordinator.picker,
              Self.minuteOfDay(of: picker.date) != minuteOfDay else { return }
        picker.setDate(Self.date(minuteOfDay: minuteOfDay), animated: false)
    }

    private static func date(minuteOfDay: Int) -> Date {
        let now = Date()
        return Calendar.current.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: now
        ) ?? now
    }

    fileprivate static func minuteOfDay(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    @MainActor
    final class Coordinator: NSObject {
        var minuteOfDay: Binding<Int>
        weak var picker: UIDatePicker?

        init(minuteOfDay: Binding<Int>) {
            self.minuteOfDay = minuteOfDay
        }

        @objc func valueChanged(_ picker: UIDatePicker) {
            minuteOfDay.wrappedValue = ClockWheelPicker.minuteOfDay(of: picker.date)
        }
    }
}
#endif
