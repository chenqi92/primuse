import Foundation

/// How a sleep timer is set by hand and what it does when it runs out: a
/// custom length, a clock time ("stop at 23:30"), extending a running timer,
/// and letting the song that is playing finish instead of fading it out.
public enum SleepTimerSchedulePolicy {
    /// The shortest and longest custom timer the sheet offers.
    public static let minimumDuration: TimeInterval = 60
    public static let maximumDuration: TimeInterval = 12 * 3600
    /// A clock time this close to now, or already past today, means the same
    /// time tomorrow: "stop at 07:00" picked at 07:00:30 is not "stop now".
    public static let minimumLeadTime: TimeInterval = 60
    /// The minutes a running timer can be pushed back by in one tap.
    public static let extensionMinutes = [5, 15]
    /// "Finish the song first" plays on past the timer at most this long; a
    /// longer track (a DJ mix, a live album side) fades out as usual.
    public static let maximumTrackFinishWait: TimeInterval = 20 * 60
    /// Local preference: when the timer runs out, let the song that is
    /// playing end instead of fading out.
    public static let finishesTrackPreferenceKey = "primuse.sleepTimer.finishesTrack"

    /// `duration` held between the shortest and longest custom timer.
    public static func clampedDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return minimumDuration }
        return min(max(duration, minimumDuration), maximumDuration)
    }

    /// The custom length picked on the hour and minute wheels.
    public static func duration(hours: Int, minutes: Int) -> TimeInterval {
        clampedDuration(TimeInterval(max(0, hours) * 3600 + max(0, minutes) * 60))
    }

    /// The next moment the clock shows `hour:minute` at least
    /// `minimumLeadTime` after `now`: later today, otherwise tomorrow.
    public static func nextOccurrence(
        hour: Int,
        minute: Int,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let components = DateComponents(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0)
        guard var next = calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        ) else {
            return now.addingTimeInterval(24 * 3600)
        }
        if next.timeIntervalSince(now) < minimumLeadTime,
           let following = calendar.nextDate(
               after: next,
               matching: components,
               matchingPolicy: .nextTime,
               direction: .forward
           ) {
            next = following
        }
        return next
    }

    /// `nextOccurrence` for the hour and minute that `time` shows (what a
    /// time picker hands back: a date whose day does not matter).
    public static func nextOccurrence(
        ofTimeIn time: Date,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return nextOccurrence(hour: parts.hour ?? 0, minute: parts.minute ?? 0, after: now, calendar: calendar)
    }

    /// The stop time falls on a later calendar day than `now`, so it is shown
    /// as "tomorrow 07:00" rather than just "07:00".
    public static func isOnLaterDay(_ end: Date, than now: Date, calendar: Calendar = .current) -> Bool {
        end > now && !calendar.isDate(end, inSameDayAs: now)
    }

    /// The stop time after pushing a timer back by `minutes`. A timer that is
    /// not running (or has just run out) starts from now; the result never
    /// lies beyond the longest custom timer from now.
    public static func extendedEndDate(_ end: Date?, byMinutes minutes: Int, now: Date) -> Date {
        let extra = TimeInterval(max(0, minutes) * 60)
        let base = end.map { max($0, now) } ?? now
        return min(base.addingTimeInterval(extra), now.addingTimeInterval(maximumDuration))
    }

    /// The part of the timer still to run, 1 when it has just been set and 0
    /// once it is up; drives the countdown ring.
    public static func remainingFraction(start: Date?, end: Date, now: Date) -> Double {
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        guard let start, end > start else { return 1 }
        return min(1, remaining / end.timeIntervalSince(start))
    }

    /// Whether a timer running out at `position` into a track lets the track
    /// play to its end. Only songs: radio never ends, and spoken word has its
    /// own end-of-chapter / end-of-item choices.
    public static func shouldFinishTrack(
        isEnabled: Bool,
        isMusic: Bool,
        isLiveRadio: Bool,
        trackDuration: TimeInterval,
        position: TimeInterval
    ) -> Bool {
        guard isEnabled, isMusic, !isLiveRadio,
              trackDuration.isFinite, trackDuration > 0, position.isFinite else { return false }
        let remaining = trackDuration - max(0, position)
        return remaining > 0 && remaining <= maximumTrackFinishWait
    }
}
