import Foundation
import PrimuseKit
import StoreKit
import SwiftUI

@MainActor
final class AppReviewPromptCoordinator {
    static let shared = AppReviewPromptCoordinator()

    private enum DefaultsKey {
        static let firstSeenAt = "primuse.review.firstSeenAt"
        static let appStoreAcquisitionDate = "primuse.review.appStoreAcquisitionDate"
        static let lastRequestedVersion = "primuse.review.lastRequestedVersion"
        static let automaticRequestDates = "primuse.review.automaticRequestDates"
    }

    private let defaults: UserDefaults
    private var isPreparingStoreContext = false
    private var hasPreparedStoreContext = false
    #if DEBUG
    private var automaticRequestsAllowed = true
    #else
    private var automaticRequestsAllowed = false
    #endif

    private init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        if defaults.object(forKey: DefaultsKey.firstSeenAt) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.firstSeenAt)
        }
    }

    func prepareStoreContext() async {
        guard !hasPreparedStoreContext, !isPreparingStoreContext else { return }
        isPreparingStoreContext = true
        defer { isPreparingStoreContext = false }

        do {
            let result = try await AppTransaction.shared
            guard case .verified(let appTransaction) = result else {
                hasPreparedStoreContext = true
                #if !DEBUG
                automaticRequestsAllowed = false
                #endif
                return
            }

            defaults.set(
                appTransaction.originalPurchaseDate.timeIntervalSince1970,
                forKey: DefaultsKey.appStoreAcquisitionDate
            )
            #if !DEBUG
            automaticRequestsAllowed = appTransaction.environment == .production
            #endif
            hasPreparedStoreContext = true
        } catch {
            #if !DEBUG
            automaticRequestsAllowed = false
            #endif
        }
    }

    func claimAutomaticRequest(
        history: PlayHistoryStore,
        currentVersion: String,
        now: Date = Date()
    ) -> Bool {
        guard automaticRequestsAllowed else { return false }

        let summary = history.summary(in: .all)
        let context = AppReviewPromptContext(
            now: now,
            acquisitionDate: effectiveAcquisitionDate(history: history, now: now),
            activeDayCount: summary.activeDays,
            completedPlaybackCount: summary.totalPlays,
            currentVersion: currentVersion,
            lastRequestedVersion: defaults.string(forKey: DefaultsKey.lastRequestedVersion),
            automaticRequestDates: automaticRequestDates
        )
        guard AppReviewPromptPolicy.shouldRequestReview(context) else { return false }

        let updatedDates = AppReviewPromptPolicy.recentAutomaticRequestDates(
            context.automaticRequestDates + [now],
            now: now
        )
        defaults.set(
            updatedDates.map(\.timeIntervalSince1970),
            forKey: DefaultsKey.automaticRequestDates
        )
        defaults.set(currentVersion, forKey: DefaultsKey.lastRequestedVersion)
        return true
    }

    private var automaticRequestDates: [Date] {
        (defaults.array(forKey: DefaultsKey.automaticRequestDates) ?? []).compactMap { value in
            guard let interval = value as? NSNumber else { return nil }
            return Date(timeIntervalSince1970: interval.doubleValue)
        }
    }

    private func effectiveAcquisitionDate(history: PlayHistoryStore, now: Date) -> Date {
        var candidates = [date(forKey: DefaultsKey.firstSeenAt) ?? now]
        if let appStoreDate = date(forKey: DefaultsKey.appStoreAcquisitionDate) {
            candidates.append(appStoreDate)
        }
        if let earliestPlaybackDate = history.entries.map(\.playedAt).min() {
            candidates.append(earliestPlaybackDate)
        }
        return candidates.min() ?? now
    }

    private func date(forKey key: String) -> Date? {
        guard let interval = defaults.object(forKey: key) as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: interval.doubleValue)
    }
}

private struct AutomaticAppReviewPromptModifier: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AudioPlayerService.self) private var player
    @State private var hasPendingRequest = false
    @State private var requestTask: Task<Void, Never>?

    private let history = PlayHistoryStore.shared
    private let coordinator = AppReviewPromptCoordinator.shared

    func body(content: Content) -> some View {
        content
            .task {
                await coordinator.prepareStoreContext()
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseQualifiedPlaybackDidRecord)) { _ in
                hasPendingRequest = true
                scheduleRequestIfPossible()
            }
            .onChange(of: player.isPlaying) { _, isPlaying in
                if !isPlaying {
                    scheduleRequestIfPossible()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await coordinator.prepareStoreContext() }
                    scheduleRequestIfPossible()
                } else {
                    requestTask?.cancel()
                    requestTask = nil
                    hasPendingRequest = false
                }
            }
            .onDisappear {
                requestTask?.cancel()
                requestTask = nil
                hasPendingRequest = false
            }
    }

    private func scheduleRequestIfPossible() {
        guard hasPendingRequest, scenePhase == .active, !player.isPlaying else { return }
        requestTask?.cancel()
        requestTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard hasPendingRequest, scenePhase == .active else { return }
            guard !player.isPlaying else { return }

            let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? ""
            guard coordinator.claimAutomaticRequest(
                history: history,
                currentVersion: version
            ) else {
                hasPendingRequest = false
                return
            }

            hasPendingRequest = false
            requestReview()
        }
    }
}

extension View {
    func automaticAppReviewPrompt() -> some View {
        modifier(AutomaticAppReviewPromptModifier())
    }
}
