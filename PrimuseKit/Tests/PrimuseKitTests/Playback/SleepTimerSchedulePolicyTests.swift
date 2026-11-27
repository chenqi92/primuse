import Foundation
import Testing
@testable import PrimuseKit

@Suite("Sleep timer schedule")
struct SleepTimerSchedulePolicyTests {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    @Test("A clock time later today stops today")
    func laterToday() {
        let calendar = Self.calendar("Asia/Shanghai")
        let now = Self.date(2026, 10, 18, 22, 10, in: calendar)
        let end = SleepTimerSchedulePolicy.nextOccurrence(hour: 23, minute: 30, after: now, calendar: calendar)
        #expect(end == Self.date(2026, 10, 18, 23, 30, in: calendar))
        #expect(!SleepTimerSchedulePolicy.isOnLaterDay(end, than: now, calendar: calendar))
    }

    @Test("A clock time already past, or under a minute away, means tomorrow")
    func tomorrow() {
        let calendar = Self.calendar("Asia/Shanghai")
        let now = Self.date(2026, 10, 18, 23, 45, in: calendar)
        let end = SleepTimerSchedulePolicy.nextOccurrence(hour: 7, minute: 0, after: now, calendar: calendar)
        #expect(end == Self.date(2026, 10, 19, 7, 0, in: calendar))
        #expect(SleepTimerSchedulePolicy.isOnLaterDay(end, than: now, calendar: calendar))

        let almost = Self.date(2026, 10, 18, 6, 59, 30, in: calendar)
        let next = SleepTimerSchedulePolicy.nextOccurrence(hour: 7, minute: 0, after: almost, calendar: calendar)
        #expect(next == Self.date(2026, 10, 19, 7, 0, in: calendar))

        let exactly = Self.date(2026, 10, 18, 7, 0, in: calendar)
        #expect(SleepTimerSchedulePolicy.nextOccurrence(hour: 7, minute: 0, after: exactly, calendar: calendar)
            == Self.date(2026, 10, 19, 7, 0, in: calendar))
    }

    @Test("Shortly after midnight is the same night, not a day later")
    func pastMidnight() {
        let calendar = Self.calendar("Asia/Shanghai")
        let now = Self.date(2026, 10, 18, 23, 50, in: calendar)
        let end = SleepTimerSchedulePolicy.nextOccurrence(hour: 0, minute: 30, after: now, calendar: calendar)
        #expect(end == Self.date(2026, 10, 19, 0, 30, in: calendar))
        #expect(end.timeIntervalSince(now) == 40 * 60)
    }

    @Test("Only the hour and minute of a picked time count")
    func pickedTime() {
        let calendar = Self.calendar("Asia/Shanghai")
        let now = Self.date(2026, 10, 18, 21, 0, in: calendar)
        let picked = Self.date(2020, 1, 5, 22, 15, 42, in: calendar)
        #expect(SleepTimerSchedulePolicy.nextOccurrence(ofTimeIn: picked, after: now, calendar: calendar)
            == Self.date(2026, 10, 18, 22, 15, in: calendar))
    }

    @Test("A clock time across a daylight saving change is the wall clock time")
    func daylightSaving() {
        let calendar = Self.calendar("America/New_York")
        // 2026-11-01 02:00 clocks go back to 01:00.
        let now = Self.date(2026, 10, 31, 23, 0, in: calendar)
        let end = SleepTimerSchedulePolicy.nextOccurrence(hour: 7, minute: 0, after: now, calendar: calendar)
        let parts = calendar.dateComponents([.day, .hour, .minute], from: end)
        #expect(parts.day == 1)
        #expect(parts.hour == 7)
        #expect(parts.minute == 0)
        #expect(end.timeIntervalSince(now) == 9 * 3600)
    }

    @Test("Custom lengths stay between a minute and twelve hours")
    func customDuration() {
        #expect(SleepTimerSchedulePolicy.duration(hours: 0, minutes: 0) == 60)
        #expect(SleepTimerSchedulePolicy.duration(hours: 1, minutes: 25) == 85 * 60)
        #expect(SleepTimerSchedulePolicy.duration(hours: 13, minutes: 0) == 12 * 3600)
        #expect(SleepTimerSchedulePolicy.clampedDuration(.nan) == 60)
        #expect(SleepTimerSchedulePolicy.clampedDuration(-5) == 60)
    }

    @Test("Extending pushes the stop time back, from now when nothing runs")
    func extending() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let running = now.addingTimeInterval(10 * 60)
        #expect(SleepTimerSchedulePolicy.extendedEndDate(running, byMinutes: 5, now: now)
            == now.addingTimeInterval(15 * 60))
        #expect(SleepTimerSchedulePolicy.extendedEndDate(nil, byMinutes: 15, now: now)
            == now.addingTimeInterval(15 * 60))
        let expired = now.addingTimeInterval(-30)
        #expect(SleepTimerSchedulePolicy.extendedEndDate(expired, byMinutes: 5, now: now)
            == now.addingTimeInterval(5 * 60))
        let far = now.addingTimeInterval(12 * 3600 - 60)
        #expect(SleepTimerSchedulePolicy.extendedEndDate(far, byMinutes: 15, now: now)
            == now.addingTimeInterval(12 * 3600))
    }

    @Test("The countdown ring empties as the timer runs")
    func ring() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(600)
        #expect(SleepTimerSchedulePolicy.remainingFraction(start: start, end: end, now: start) == 1)
        #expect(SleepTimerSchedulePolicy.remainingFraction(start: start, end: end, now: start.addingTimeInterval(450)) == 0.25)
        #expect(SleepTimerSchedulePolicy.remainingFraction(start: start, end: end, now: end) == 0)
        #expect(SleepTimerSchedulePolicy.remainingFraction(start: nil, end: end, now: start) == 1)
        // Extended past its first length: never more than full.
        #expect(SleepTimerSchedulePolicy.remainingFraction(start: start, end: end, now: start.addingTimeInterval(-60)) == 1)
    }

    @Test("Only a song with a short way to go is played out")
    func finishTrack() {
        #expect(SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: true, isLiveRadio: false, trackDuration: 240, position: 100
        ))
        #expect(!SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: false, isMusic: true, isLiveRadio: false, trackDuration: 240, position: 100
        ))
        #expect(!SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: false, isLiveRadio: false, trackDuration: 240, position: 100
        ))
        #expect(!SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: true, isLiveRadio: true, trackDuration: 240, position: 100
        ))
        // A two-hour mix with an hour left fades out as usual.
        #expect(!SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: true, isLiveRadio: false, trackDuration: 7200, position: 3600
        ))
        #expect(SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: true, isLiveRadio: false, trackDuration: 7200, position: 7200 - 20 * 60
        ))
        #expect(!SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: true, isLiveRadio: false, trackDuration: 0, position: 0
        ))
        #expect(!SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: true, isMusic: true, isLiveRadio: false, trackDuration: 240, position: 240
        ))
    }
}
