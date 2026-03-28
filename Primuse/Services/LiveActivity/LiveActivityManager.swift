import ActivityKit
import Foundation
import PrimuseKit

@MainActor
@Observable
final class LiveActivityManager {
    private var currentActivity: Activity<PlaybackActivityAttributes>?

    func startActivity(song: Song, isPlaying: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = PlaybackActivityAttributes(
            songTitle: song.title,
            artistName: song.artistName ?? "",
            albumTitle: song.albumTitle ?? "",
            duration: song.duration
        )

        let state = PlaybackActivityAttributes.ContentState(
            isPlaying: isPlaying,
            elapsedTime: 0
        )

        let content = ActivityContent(state: state, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    func updateActivity(isPlaying: Bool, elapsedTime: TimeInterval, nextSong: String? = nil) async {
        guard let currentActivity else { return }
        nonisolated(unsafe) let activityToUpdate = currentActivity

        let state = PlaybackActivityAttributes.ContentState(
            isPlaying: isPlaying,
            elapsedTime: elapsedTime,
            nextSongTitle: nextSong
        )

        let content = ActivityContent(state: state, staleDate: nil)
        await activityToUpdate.update(content)
    }

    func endActivity() async {
        guard let currentActivity else { return }
        nonisolated(unsafe) let activityToEnd = currentActivity
        self.currentActivity = nil

        let state = PlaybackActivityAttributes.ContentState(
            isPlaying: false,
            elapsedTime: 0
        )

        let content = ActivityContent(state: state, staleDate: nil)
        await activityToEnd.end(content, dismissalPolicy: .default)
    }
}
