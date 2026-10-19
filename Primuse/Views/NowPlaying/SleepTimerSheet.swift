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

/// 睡眠定时面板:进行中时顶上是倒计时环、停止时刻、延长与关闭;下面是预设时长、
/// 「播完本首 / 本章 / 整本再停」、自定义时长或到几点停止,音乐另有「计时结束时播完当前这首」。
/// 选项按正在听的空间给(`SleepTimerOptionPolicy`):电台只有时长,有声内容多出本章、本集、整本。
struct SleepTimerSheet: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SleepTimerSchedulePolicy.finishesTrackPreferenceKey) private var finishesTrack = false
    /// 上一次自定义的时长与时刻,下次打开接着用。
    @AppStorage("primuse.sleepTimer.customMinutes") private var customMinutes = 20
    @AppStorage("primuse.sleepTimer.clockMinuteOfDay") private var clockMinuteOfDay = 23 * 60
    @State private var customMode: CustomMode = .duration

    private enum CustomMode: Hashable {
        case duration
        case clock
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if player.isSleepTimerActive {
                        statusCard
                    }
                    presetSection
                    if !endOptions.isEmpty {
                        endSection
                    }
                    customSection
                    if offersFinishTrack {
                        finishTrackSection
                    }
                    Text("sleep_timer_fade_footer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text("sleep_timer"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 520, idealHeight: 600)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
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
                    }
                    Spacer(minLength: 8)
                    turnOffButton
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
                HStack {
                    Spacer()
                    turnOffButton
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    }

    private var turnOffButton: some View {
        Button(role: .destructive) {
            player.cancelSleep()
        } label: {
            Text("cancel_timer")
        }
        .buttonStyle(.bordered)
    }

    // MARK: Choices

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("sleep_timer_section_duration")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                ForEach(presetMinutes, id: \.self) { minutes in
                    Button {
                        player.scheduleSleep(minutes: minutes)
                        dismiss()
                    } label: {
                        Text(verbatim: "\(minutes) " + String(localized: "minutes"))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var endSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("sleep_timer_section_end")
            VStack(spacing: 0) {
                ForEach(Array(endOptions.enumerated()), id: \.element) { index, option in
                    if index > 0 {
                        Divider().padding(.leading, 48)
                    }
                    endRow(option)
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func endRow(_ option: SleepTimerOption) -> some View {
        let isArmed = player.isSleepOptionArmed(option)
        return Button {
            player.applySleepOption(option)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: endSymbol(option))
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(verbatim: endTitle(option))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isArmed {
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
        case .duration:
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

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("sleep_timer_section_custom")
            VStack(spacing: 12) {
                Picker(selection: $customMode) {
                    Text("sleep_timer_custom_mode_duration").tag(CustomMode.duration)
                    Text("sleep_timer_custom_mode_clock").tag(CustomMode.clock)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch customMode {
                    case .duration: durationPicker
                    case .clock: clockPicker
                    }
                }
                .frame(maxWidth: .infinity)

                TimelineView(.everyMinute) { context in
                    let end = customEndDate(now: context.date)
                    let length = end.timeIntervalSince(context.date)
                    Text(verbatim: SleepTimerStatusText.stopTime(end, now: context.date)
                        + " · " + String(format: String(localized: "sleep_timer_length_format"),
                                         Self.lengthLabel(length)))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    player.scheduleSleep(until: customEndDate(now: Date()))
                    dismiss()
                } label: {
                    Text("sleep_timer_start")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        }
        .frame(height: 140)
        .clipped()
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
                    .font(.body.weight(.medium))
            }
            .toggleStyle(.switch)
            Text("sleep_timer_finish_track_footer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
