import Foundation

public struct AppReviewPromptContext: Equatable, Sendable {
    public let now: Date
    public let acquisitionDate: Date
    public let activeDayCount: Int
    public let completedPlaybackCount: Int
    public let currentVersion: String
    public let lastRequestedVersion: String?
    public let automaticRequestDates: [Date]

    public init(
        now: Date,
        acquisitionDate: Date,
        activeDayCount: Int,
        completedPlaybackCount: Int,
        currentVersion: String,
        lastRequestedVersion: String?,
        automaticRequestDates: [Date]
    ) {
        self.now = now
        self.acquisitionDate = acquisitionDate
        self.activeDayCount = activeDayCount
        self.completedPlaybackCount = completedPlaybackCount
        self.currentVersion = currentVersion
        self.lastRequestedVersion = lastRequestedVersion
        self.automaticRequestDates = automaticRequestDates
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

public enum PrimuseAppStore {
    public static let appID = "6761675450"
    public static let reviewURL = URL(
        string: "https://apps.apple.com/app/id\(appID)?action=write-review"
    )!
}
