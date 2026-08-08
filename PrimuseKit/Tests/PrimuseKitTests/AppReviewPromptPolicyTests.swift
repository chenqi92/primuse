import Foundation
import Testing
@testable import PrimuseKit

@Suite("App review prompt policy")
struct AppReviewPromptPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Engaged long-term users become eligible")
    func acceptsEngagedLongTermUser() {
        #expect(AppReviewPromptPolicy.shouldRequestReview(context()))
    }

    @Test("Every engagement threshold is required")
    func requiresAllEngagementThresholds() {
        #expect(!AppReviewPromptPolicy.shouldRequestReview(context(daysSinceAcquisition: 29)))
        #expect(!AppReviewPromptPolicy.shouldRequestReview(context(activeDayCount: 6)))
        #expect(!AppReviewPromptPolicy.shouldRequestReview(context(completedPlaybackCount: 19)))
    }

    @Test("The same app version is never requested twice")
    func rejectsPreviouslyRequestedVersion() {
        #expect(!AppReviewPromptPolicy.shouldRequestReview(
            context(lastRequestedVersion: "2.0")
        ))
    }

    @Test("A new version still respects the 180-day cooldown")
    func enforcesCooldownAcrossVersions() {
        let recentAttempt = now.addingTimeInterval(-179 * 24 * 60 * 60)
        #expect(!AppReviewPromptPolicy.shouldRequestReview(
            context(lastRequestedVersion: "1.9", requestDates: [recentAttempt])
        ))

        let oldEnoughAttempt = now.addingTimeInterval(-180 * 24 * 60 * 60)
        #expect(AppReviewPromptPolicy.shouldRequestReview(
            context(lastRequestedVersion: "1.9", requestDates: [oldEnoughAttempt])
        ))
    }

    @Test("At most two automatic attempts are allowed in a rolling year")
    func capsRollingYearAttempts() {
        let attempts = [
            now.addingTimeInterval(-300 * 24 * 60 * 60),
            now.addingTimeInterval(-200 * 24 * 60 * 60),
        ]
        #expect(!AppReviewPromptPolicy.shouldRequestReview(
            context(lastRequestedVersion: "1.9", requestDates: attempts)
        ))
    }

    @Test("Attempts outside the rolling year no longer count")
    func prunesExpiredAttempts() {
        let expired = now.addingTimeInterval(-366 * 24 * 60 * 60)
        let recent = AppReviewPromptPolicy.recentAutomaticRequestDates([expired], now: now)

        #expect(recent.isEmpty)
        #expect(AppReviewPromptPolicy.shouldRequestReview(
            context(lastRequestedVersion: "1.9", requestDates: [expired])
        ))
    }

    @Test("The review link targets the App Store review composer")
    func buildsReviewURL() {
        let components = URLComponents(url: PrimuseAppStore.reviewURL, resolvingAgainstBaseURL: false)

        #expect(components?.host == "apps.apple.com")
        #expect(components?.path == "/app/id6761675450")
        #expect(components?.queryItems == [URLQueryItem(name: "action", value: "write-review")])
    }

    private func context(
        daysSinceAcquisition: Int = 30,
        activeDayCount: Int = 7,
        completedPlaybackCount: Int = 20,
        lastRequestedVersion: String? = nil,
        requestDates: [Date] = []
    ) -> AppReviewPromptContext {
        AppReviewPromptContext(
            now: now,
            acquisitionDate: now.addingTimeInterval(-TimeInterval(daysSinceAcquisition) * 24 * 60 * 60),
            activeDayCount: activeDayCount,
            completedPlaybackCount: completedPlaybackCount,
            currentVersion: "2.0",
            lastRequestedVersion: lastRequestedVersion,
            automaticRequestDates: requestDates
        )
    }
}
