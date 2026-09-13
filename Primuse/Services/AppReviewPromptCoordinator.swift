import Foundation
import PrimuseKit
import StoreKit
import SwiftUI

@MainActor
final class AppReviewPromptCoordinator {
    static let shared = AppReviewPromptCoordinator()

    private typealias DefaultsKey = AppReviewPromptDefaultsKey

    private let state: AppReviewPromptState
    private let didCreateFirstSeenStamp: Bool
    private var isPreparingStoreContext = false
    private var hasPreparedStoreContext = false
    #if DEBUG
    private var automaticRequestsAllowed = true
    #else
    private var automaticRequestsAllowed = false
    #endif

    private init(defaults: UserDefaults = .standard, now: Date = Date()) {
        let state = AppReviewPromptState(defaults: defaults)
        self.state = state
        // Never mirrored from here: registration below pulls the account-wide
        // stamp, and pushing this launch's date first would clobber the real
        // one with a date that is always newer.
        self.didCreateFirstSeenStamp = !state.markFirstSeenIfNeeded(now: now).isEmpty
    }

    func prepareStoreContext() async {
        guard !hasPreparedStoreContext, !isPreparingStoreContext else { return }
        isPreparingStoreContext = true
        defer { isPreparingStoreContext = false }

        #if DEBUG
        // AppTransaction can ask the simulator to authenticate an App Store
        // account. Debug builds use the local engagement policy instead.
        hasPreparedStoreContext = true
        return
        #elseif targetEnvironment(simulator)
        automaticRequestsAllowed = false
        hasPreparedStoreContext = true
        return
        #else
        do {
            let result = try await AppTransaction.shared
            guard case .verified(let appTransaction) = result else {
                hasPreparedStoreContext = true
                automaticRequestsAllowed = false
                return
            }

            state.recordAppStoreAcquisitionDate(appTransaction.originalPurchaseDate)
            automaticRequestsAllowed = appTransaction.environment == .production
            hasPreparedStoreContext = true
        } catch {
            automaticRequestsAllowed = false
            // Do not immediately present the same authentication flow again
            // when dismissing it makes the scene active.
            hasPreparedStoreContext = true
        }
        #endif
    }

    func isAutomaticRequestCandidate(
        history: PlayHistoryStore,
        currentVersion: String,
        now: Date = Date()
    ) -> Bool {
        AppReviewPromptPolicy.shouldRequestReview(
            promptContext(history: history, currentVersion: currentVersion, now: now)
        )
    }

    func claimAutomaticRequest(
        history: PlayHistoryStore,
        currentVersion: String,
        now: Date = Date()
    ) -> Bool {
        guard automaticRequestsAllowed else { return false }

        let context = promptContext(history: history, currentVersion: currentVersion, now: now)
        guard AppReviewPromptPolicy.shouldRequestReview(context) else { return false }

        publishToCloud(
            state.recordAutomaticRequest(currentVersion: currentVersion, now: now)
        )
        return true
    }

    /// Record that the user took the in-app "Rate on the App Store" route.
    ///
    /// StoreKit gives no callback for the system sheet, so this is the only
    /// rating signal the app ever receives. Persist it permanently and also
    /// stamp the ordinary brakes, so an older build that predates the flag
    /// still honours the cooldown.
    func recordManualReviewVisit(
        currentVersion: String = AppReviewPromptCoordinator.currentAppVersion,
        now: Date = Date()
    ) {
        publishToCloud(
            state.recordManualRating(currentVersion: currentVersion, now: now)
        )
    }

    /// Mirror the prompt state through iCloud key-value storage.
    ///
    /// Play history roams through CloudKit, so without this a reinstall or a
    /// second device meets every engagement threshold immediately while the
    /// local brakes start empty — and someone who already rated gets asked
    /// again. Call once during startup.
    func startCloudSync() {
        for key in DefaultsKey.synchronized {
            CloudKVSSync.shared.register(key: key) { }
        }
        // A brand new install seeds the shared stamp only if the account has
        // none yet; registration has already replaced ours with the account's
        // copy when one exists, so this pushes whichever date now stands.
        if didCreateFirstSeenStamp {
            publishToCloud([DefaultsKey.firstSeenAt])
        }
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func publishToCloud(_ keys: [String]) {
        for key in keys {
            CloudKVSSync.shared.markChanged(key: key)
        }
    }

    private func promptContext(
        history: PlayHistoryStore,
        currentVersion: String,
        now: Date
    ) -> AppReviewPromptContext {
        let summary = history.summary(in: .all)
        return AppReviewPromptContext(
            now: now,
            acquisitionDate: effectiveAcquisitionDate(history: history, now: now),
            activeDayCount: summary.activeDays,
            completedPlaybackCount: summary.totalPlays,
            currentVersion: currentVersion,
            lastRequestedVersion: state.lastRequestedVersion,
            automaticRequestDates: state.automaticRequestDates,
            didRateManually: state.didRateManually
        )
    }

    private func effectiveAcquisitionDate(history: PlayHistoryStore, now: Date) -> Date {
        var candidates = [state.date(forKey: DefaultsKey.firstSeenAt) ?? now]
        if let appStoreDate = state.date(forKey: DefaultsKey.appStoreAcquisitionDate) {
            candidates.append(appStoreDate)
        }
        if let earliestPlaybackDate = history.entries.map(\.playedAt).min() {
            candidates.append(earliestPlaybackDate)
        }
        return candidates.min() ?? now
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

            let version = AppReviewPromptCoordinator.currentAppVersion
            guard coordinator.isAutomaticRequestCandidate(
                history: history,
                currentVersion: version
            ) else {
                hasPendingRequest = false
                return
            }

            // AppTransaction can require App Store authentication and network
            // access, so query it only after local usage already qualifies.
            await coordinator.prepareStoreContext()
            guard !Task.isCancelled,
                  hasPendingRequest,
                  scenePhase == .active,
                  !player.isPlaying else { return }
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
