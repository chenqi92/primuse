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

    @Test("Rating from inside the app silences the prompt for good")
    func rejectsUsersWhoAlreadyRated() {
        #expect(!AppReviewPromptPolicy.shouldRequestReview(context(didRateManually: true)))

        // A new version and an expired cooldown must not re-arm it either.
        let expired = now.addingTimeInterval(-366 * 24 * 60 * 60)
        #expect(!AppReviewPromptPolicy.shouldRequestReview(
            context(
                lastRequestedVersion: "1.9",
                requestDates: [expired],
                didRateManually: true
            )
        ))
    }

    @Test("Prompt state keys are all mirrored through iCloud")
    func synchronizesEveryPromptStateKey() {
        #expect(AppReviewPromptDefaultsKey.synchronized == [
            "primuse.review.firstSeenAt",
            "primuse.review.appStoreAcquisitionDate",
            "primuse.review.lastRequestedVersion",
            "primuse.review.automaticRequestDates",
            "primuse.review.didRateManually",
        ])
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
        requestDates: [Date] = [],
        didRateManually: Bool = false
    ) -> AppReviewPromptContext {
        AppReviewPromptContext(
            now: now,
            acquisitionDate: now.addingTimeInterval(-TimeInterval(daysSinceAcquisition) * 24 * 60 * 60),
            activeDayCount: activeDayCount,
            completedPlaybackCount: completedPlaybackCount,
            currentVersion: "2.0",
            lastRequestedVersion: lastRequestedVersion,
            automaticRequestDates: requestDates,
            didRateManually: didRateManually
        )
    }
}

@Suite("App review prompt state")
struct AppReviewPromptStateTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("A fresh install carries no prompt history")
    func startsEmpty() {
        withStore { store, _ in
            #expect(!store.didRateManually)
            #expect(store.lastRequestedVersion == nil)
            #expect(store.automaticRequestDates.isEmpty)
        }
    }

    @Test("The install date is stamped once and never restamped")
    func stampsFirstSeenOnce() {
        withStore { store, _ in
            #expect(store.markFirstSeenIfNeeded(now: now) == [AppReviewPromptDefaultsKey.firstSeenAt])
            #expect(store.date(forKey: AppReviewPromptDefaultsKey.firstSeenAt) == now)

            #expect(store.markFirstSeenIfNeeded(now: now.addingTimeInterval(day)).isEmpty)
            #expect(store.date(forKey: AppReviewPromptDefaultsKey.firstSeenAt) == now)
        }
    }

    @Test("Showing the system sheet arms both brakes")
    func recordsAutomaticRequest() {
        withStore { store, _ in
            let touched = store.recordAutomaticRequest(currentVersion: "2.0", now: now)

            #expect(touched == [
                AppReviewPromptDefaultsKey.automaticRequestDates,
                AppReviewPromptDefaultsKey.lastRequestedVersion,
            ])
            #expect(store.lastRequestedVersion == "2.0")
            #expect(store.automaticRequestDates == [now])
        }
    }

    @Test("Rating from inside the app is remembered permanently")
    func recordsManualRating() {
        withStore { store, _ in
            store.recordAutomaticRequest(currentVersion: "2.0", now: now)
            let touched = store.recordManualRating(
                currentVersion: "2.1",
                now: now.addingTimeInterval(day)
            )

            #expect(store.didRateManually)
            #expect(touched.contains(AppReviewPromptDefaultsKey.didRateManually))
            #expect(store.lastRequestedVersion == "2.1")
            #expect(store.automaticRequestDates.count == 2)
        }
    }

    @Test("A missing version string never overwrites a real one")
    func keepsVersionWhenUnknown() {
        withStore { store, _ in
            store.recordAutomaticRequest(currentVersion: "2.0", now: now)
            let touched = store.recordManualRating(
                currentVersion: "",
                now: now.addingTimeInterval(day)
            )

            #expect(store.lastRequestedVersion == "2.0")
            #expect(!touched.contains(AppReviewPromptDefaultsKey.lastRequestedVersion))
            #expect(store.didRateManually)
        }
    }

    @Test("Usage restored from iCloud cannot re-ask someone who rated")
    func staysSilentForRatedUsers() {
        withStore { store, _ in
            store.recordManualRating(currentVersion: "2.1", now: now)

            let context = AppReviewPromptContext(
                now: now.addingTimeInterval(400 * day),
                acquisitionDate: now.addingTimeInterval(-400 * day),
                activeDayCount: 300,
                completedPlaybackCount: 5000,
                currentVersion: "3.0",
                lastRequestedVersion: store.lastRequestedVersion,
                automaticRequestDates: store.automaticRequestDates,
                didRateManually: store.didRateManually
            )
            #expect(!AppReviewPromptPolicy.shouldRequestReview(context))
        }
    }

    private func withStore(_ body: (AppReviewPromptState, UserDefaults) -> Void) {
        let suiteName = "primuse.review.tests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create a UserDefaults suite")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        body(AppReviewPromptState(defaults: suite), suite)
    }
}
