import Testing
@testable import PrimuseKit

@Suite("Toast schedule")
struct ToastScheduleTests {
    @Test("A new toast replaces the visible one instead of stacking")
    func replacesInsteadOfStacking() {
        var schedule = ToastSchedule()
        let first = schedule.show(key: "queue", duration: 2, now: 0)
        let second = schedule.show(key: "cache", duration: 3, now: 1)
        #expect(schedule.visible == second)
        #expect(schedule.transient == second)
        #expect(ToastSchedule.change(from: first, to: second) == .replace)
        #expect(schedule.nextDeadline == 4)
    }

    @Test("Showing the same source again restarts its timer with a new serial")
    func sameSourceRestarts() {
        var schedule = ToastSchedule()
        let first = schedule.show(key: "queue", duration: 2, now: 0)
        let again = schedule.show(key: "queue", duration: 2, now: 1.5)
        #expect(again.serial != first.serial)
        #expect(schedule.nextDeadline == 3.5)
        let expiredEarly = schedule.expire(now: 2)
        #expect(!expiredEarly)
        #expect(schedule.visible == again)
        let expiredOnTime = schedule.expire(now: 3.5)
        #expect(expiredOnTime)
        #expect(schedule.visible == nil)
    }

    @Test("A transient toast covers a persistent one and uncovers it on expiry")
    func transientCoversPersistent() {
        var schedule = ToastSchedule()
        let progress = schedule.show(key: "removal.progress", duration: nil, now: 0)
        let queued = schedule.show(key: "queue", duration: 2, now: 1)
        #expect(schedule.visible == queued)
        #expect(schedule.persistent == progress)
        #expect(schedule.nextDeadline == 3)
        let queueExpired = schedule.expire(now: 3)
        #expect(queueExpired)
        #expect(schedule.visible == progress)
        #expect(schedule.nextDeadline == nil)
    }

    @Test("A persistent update stays underneath a showing transient toast")
    func persistentUpdateStaysUnderneath() {
        var schedule = ToastSchedule()
        let queued = schedule.show(key: "queue", duration: 2, now: 0)
        _ = schedule.show(key: "removal.progress", duration: nil, now: 0.5)
        #expect(schedule.visible == queued)
    }

    @Test("A result from the same source drops its persistent progress")
    func sameSourceDropsOtherLayer() {
        var schedule = ToastSchedule()
        _ = schedule.show(key: "undo", duration: nil, now: 0)
        let result = schedule.show(key: "undo", duration: 3, now: 1)
        #expect(schedule.persistent == nil)
        #expect(schedule.visible == result)
        let resultExpired = schedule.expire(now: 4)
        #expect(resultExpired)
        #expect(schedule.visible == nil)
    }

    @Test("Dismissing by key removes both layers; by serial only that entry")
    func dismissal() {
        var schedule = ToastSchedule()
        let undo = schedule.show(key: "undo", duration: nil, now: 0)
        let dismissedUnknown = schedule.dismiss(serial: undo.serial &+ 7)
        #expect(!dismissedUnknown)
        #expect(schedule.visible == undo)
        let dismissedUndo = schedule.dismiss(serial: undo.serial)
        #expect(dismissedUndo)
        #expect(schedule.visible == nil)

        _ = schedule.show(key: "undo", duration: nil, now: 0)
        _ = schedule.show(key: "queue", duration: 1, now: 0)
        let dismissedByKey = schedule.dismiss(key: "undo")
        #expect(dismissedByKey)
        #expect(schedule.persistent == nil)
        let dismissedAgain = schedule.dismiss(key: "undo")
        #expect(!dismissedAgain)
    }

    @Test("A stale timer cannot dismiss a newer toast from the same source")
    func staleTimerIgnored() {
        var schedule = ToastSchedule()
        let old = schedule.show(key: "cache", duration: 3, now: 0)
        let new = schedule.show(key: "cache", duration: 3, now: 2)
        let dismissedStale = schedule.dismiss(serial: old.serial)
        #expect(!dismissedStale)
        #expect(schedule.visible == new)
    }

    @Test("Change classification")
    func changeClassification() {
        var schedule = ToastSchedule()
        let entry = schedule.show(key: "a", duration: 1, now: 0)
        #expect(ToastSchedule.change(from: nil, to: nil) == .none)
        #expect(ToastSchedule.change(from: nil, to: entry) == .appear)
        #expect(ToastSchedule.change(from: entry, to: nil) == .disappear)
        #expect(ToastSchedule.change(from: entry, to: entry) == .none)
    }

    @Test("Negative durations expire immediately instead of living forever")
    func negativeDuration() {
        var schedule = ToastSchedule()
        _ = schedule.show(key: "a", duration: -5, now: 10)
        #expect(schedule.nextDeadline == 10)
        let expiredImmediately = schedule.expire(now: 10)
        #expect(expiredImmediately)
    }
}
