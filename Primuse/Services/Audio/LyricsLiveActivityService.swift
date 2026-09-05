#if os(iOS) && DEBUG
import ActivityKit
import Foundation
import PrimuseKit
import UIKit

/// Local feasibility probe; no production demand until background rendering is verified.
@MainActor
final class LyricsLiveActivityService {
    static let shared = LyricsLiveActivityService()
    static let isProbeEnabled = ProcessInfo.processInfo.arguments.contains("-PrimuseLyricsActivityProbe")

    private var activityID: String?
    private var latest: LyricsActivityAttributes.ContentState?
    private var lastSent: LyricsActivityAttributes.ContentState?
    private var worker: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var isDismissed = false

    func publish(_ state: LyricsActivityAttributes.ContentState?) {
        guard Self.isProbeEnabled else { return }
        latest = state
        revision &+= 1
        guard worker == nil else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            var appliedRevision: UInt64 = 0
            while appliedRevision != revision {
                appliedRevision = revision
                await reconcile()
            }
        }
    }

    private func reconcile() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let latest else {
            for existing in Activity<LyricsActivityAttributes>.activities {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
            activityID = nil
            lastSent = nil
            return
        }
        let content = ActivityContent(state: latest, staleDate: Date().addingTimeInterval(20))
        // Keep only the identity across suspensions: Activity isn't Sendable in this SDK.
        if let activity = Activity<LyricsActivityAttributes>.activities.first(where: {
            activityID == nil || $0.id == activityID
        }) {
            if activity.activityState == .dismissed || activity.activityState == .ended {
                isDismissed = true
                activityID = nil
                lastSent = nil
                return
            }
            activityID = activity.id
            guard latest != lastSent else { return }
            await Self.update(activityID: activity.id, content: content)
            lastSent = latest
            plog("[LyricsActivityProbe] update completed playing=\(latest.isPlaying) background=\(UIApplication.shared.applicationState != .active) line=\(latest.lyric)")
        } else if activityID != nil {
            isDismissed = true
            activityID = nil
            lastSent = nil
        } else if !isDismissed, UIApplication.shared.applicationState == .active, latest.isPlaying {
            do {
                activityID = try Activity.request(attributes: LyricsActivityAttributes(), content: content, pushType: nil).id
                lastSent = latest
                plog("[LyricsActivityProbe] activity requested")
            } catch {
                plog("[LyricsActivityProbe] request failed: \(error)")
            }
        }
    }

    private nonisolated static func update(
        activityID: String,
        content: ActivityContent<LyricsActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<LyricsActivityAttributes>.activities.first(where: {
            $0.id == activityID
        }) else { return }
        await activity.update(content)
    }
}
#endif
