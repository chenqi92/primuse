import Foundation
import Testing
@testable import PrimuseKit

@Suite("Google Drive access change notice timing")
struct GoogleDriveAccessChangePolicyTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @Test func effectiveDateIsLocalMidnightOfTheDay() {
        #expect(GoogleDriveAccessChangePolicy.effectiveDate(in: shanghai) == date("2026-11-19T16:00:00Z"))
        #expect(GoogleDriveAccessChangePolicy.effectiveDate(in: losAngeles) == date("2026-11-20T08:00:00Z"))
    }

    @Test func switchesPhaseAtLocalMidnight() {
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-10-02T12:00:00Z"), timeZone: shanghai) == .upcoming)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-11-19T15:59:59Z"), timeZone: shanghai) == .upcoming)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-11-19T16:00:00Z"), timeZone: shanghai) == .inEffect)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-11-19T16:00:00Z"), timeZone: losAngeles) == .upcoming)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2027-01-01T00:00:00Z"), timeZone: losAngeles) == .inEffect)
    }
}
