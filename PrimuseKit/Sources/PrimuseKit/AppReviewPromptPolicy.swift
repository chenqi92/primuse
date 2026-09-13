import Foundation

/// UserDefaults keys backing the review prompt state.
///
/// Shared so every target spells them identically and so the app can hand the
/// same list to the iCloud key-value mirror. The prompt brakes are useless when
/// they live only on one install: engagement data (play history) roams through
/// CloudKit, so a reinstall or a second device would meet every threshold again
/// with an empty prompt history and re-ask someone who already rated.
public enum AppReviewPromptDefaultsKey {
    public static let firstSeenAt = "primuse.review.firstSeenAt"
    public static let appStoreAcquisitionDate = "primuse.review.appStoreAcquisitionDate"
    public static let lastRequestedVersion = "primuse.review.lastRequestedVersion"
    public static let automaticRequestDates = "primuse.review.automaticRequestDates"
    public static let didRateManually = "primuse.review.didRateManually"

    /// Every key that has to roam with the user's iCloud account.
    public static let synchronized = [
        firstSeenAt,
        appStoreAcquisitionDate,
        lastRequestedVersion,
        automaticRequestDates,
        didRateManually,
    ]
}

public struct AppReviewPromptContext: Equatable, Sendable {
    public let now: Date
    public let acquisitionDate: Date
    public let activeDayCount: Int
    public let completedPlaybackCount: Int
    public let currentVersion: String
    public let lastRequestedVersion: String?
    public let automaticRequestDates: [Date]
    /// The user already opened the App Store review page from inside the app.
    public let didRateManually: Bool

    public init(
        now: Date,
        acquisitionDate: Date,
        activeDayCount: Int,
        completedPlaybackCount: Int,
        currentVersion: String,
        lastRequestedVersion: String?,
        automaticRequestDates: [Date],
        didRateManually: Bool = false
    ) {
        self.now = now
        self.acquisitionDate = acquisitionDate
        self.activeDayCount = activeDayCount
        self.completedPlaybackCount = completedPlaybackCount
        self.currentVersion = currentVersion
        self.lastRequestedVersion = lastRequestedVersion
        self.automaticRequestDates = automaticRequestDates
        self.didRateManually = didRateManually
    }
}

public enum AppReviewPromptPolicy {
    public static let minimumUseDuration: TimeInterval = 30 * 24 * 60 * 60
    public static let minimumActiveDayCount = 7
    public static let minimumCompletedPlaybackCount = 20
    public static let requestCooldown: TimeInterval = 180 * 24 * 60 * 60
    public static let rollingWindow: TimeInterval = 365 * 24 * 60 * 60
    public static let maximumRequestsPerRollingWindow = 2

    public static func shouldRequestReview(_ context: AppReviewPromptContext) -> Bool {
        // StoreKit never reports whether the system sheet produced a rating, so
        // the one rating signal we can trust is the user taking the in-app
        // "Rate on the App Store" route. Once they have, stop asking for good.
        guard !context.didRateManually else { return false }

        guard !context.currentVersion.isEmpty,
              context.now.timeIntervalSince(context.acquisitionDate) >= minimumUseDuration,
              context.activeDayCount >= minimumActiveDayCount,
              context.completedPlaybackCount >= minimumCompletedPlaybackCount,
              context.lastRequestedVersion != context.currentVersion
        else {
            return false
        }

        let recentAttempts = recentAutomaticRequestDates(
            context.automaticRequestDates,
            now: context.now
        )
        guard recentAttempts.count < maximumRequestsPerRollingWindow else {
            return false
        }

        if let latestAttempt = context.automaticRequestDates.max(),
           context.now.timeIntervalSince(latestAttempt) < requestCooldown {
            return false
        }
        return true
    }

    public static func recentAutomaticRequestDates(_ dates: [Date], now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-rollingWindow)
        return dates.filter { $0 > cutoff }.sorted()
    }
}

/// Reads and writes the review prompt state kept in UserDefaults.
///
/// Shared by every target that can send someone to the App Store, so the three
/// "Rate on the App Store" entry points record the visit identically. Each
/// mutating call returns the keys it touched; app-layer callers hand those to
/// the iCloud key-value mirror.
public struct AppReviewPromptState {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var didRateManually: Bool {
        defaults.bool(forKey: AppReviewPromptDefaultsKey.didRateManually)
    }

    public var lastRequestedVersion: String? {
        defaults.string(forKey: AppReviewPromptDefaultsKey.lastRequestedVersion)
    }

    public var automaticRequestDates: [Date] {
        (defaults.array(forKey: AppReviewPromptDefaultsKey.automaticRequestDates) ?? [])
            .compactMap { value in
                guard let interval = value as? NSNumber else { return nil }
                return Date(timeIntervalSince1970: interval.doubleValue)
            }
    }

    public func date(forKey key: String) -> Date? {
        guard let interval = defaults.object(forKey: key) as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: interval.doubleValue)
    }

    /// Stamp the first launch this install ever saw, unless one is already known.
    @discardableResult
    public func markFirstSeenIfNeeded(now: Date) -> [String] {
        guard defaults.object(forKey: AppReviewPromptDefaultsKey.firstSeenAt) == nil else {
            return []
        }
        defaults.set(now.timeIntervalSince1970, forKey: AppReviewPromptDefaultsKey.firstSeenAt)
        return [AppReviewPromptDefaultsKey.firstSeenAt]
    }

    @discardableResult
    public func recordAppStoreAcquisitionDate(_ date: Date) -> [String] {
        defaults.set(
            date.timeIntervalSince1970,
            forKey: AppReviewPromptDefaultsKey.appStoreAcquisitionDate
        )
        return [AppReviewPromptDefaultsKey.appStoreAcquisitionDate]
    }

    /// Record that the system review sheet was just presented.
    @discardableResult
    public func recordAutomaticRequest(currentVersion: String, now: Date) -> [String] {
        appendRequestDate(now)
        defaults.set(currentVersion, forKey: AppReviewPromptDefaultsKey.lastRequestedVersion)
        return [
            AppReviewPromptDefaultsKey.automaticRequestDates,
            AppReviewPromptDefaultsKey.lastRequestedVersion,
        ]
    }

    /// Record that the user took the in-app route to the App Store review page.
    ///
    /// Also stamps the ordinary brakes, so a device still running an older
    /// build that predates the flag keeps honouring the cooldown.
    @discardableResult
    public func recordManualRating(currentVersion: String, now: Date) -> [String] {
        defaults.set(true, forKey: AppReviewPromptDefaultsKey.didRateManually)
        appendRequestDate(now)
        var touched = [
            AppReviewPromptDefaultsKey.didRateManually,
            AppReviewPromptDefaultsKey.automaticRequestDates,
        ]
        if !currentVersion.isEmpty {
            defaults.set(currentVersion, forKey: AppReviewPromptDefaultsKey.lastRequestedVersion)
            touched.append(AppReviewPromptDefaultsKey.lastRequestedVersion)
        }
        return touched
    }

    private func appendRequestDate(_ date: Date) {
        let updated = AppReviewPromptPolicy.recentAutomaticRequestDates(
            automaticRequestDates + [date],
            now: date
        )
        defaults.set(
            updated.map(\.timeIntervalSince1970),
            forKey: AppReviewPromptDefaultsKey.automaticRequestDates
        )
    }
}

public enum PrimuseAppStore {
    public static let appID = "6761675450"
    public static let reviewURL = URL(
        string: "https://apps.apple.com/app/id\(appID)?action=write-review"
    )!
}
