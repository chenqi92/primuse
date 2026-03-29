import ActivityKit
import Foundation
import UIKit
import PrimuseKit

@MainActor
@Observable
final class LiveActivityManager {
    private var currentActivity: Activity<PlaybackActivityAttributes>?

    /// App Group shared container URL
    private static let containerURL: URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier)
    }()

    // MARK: - Cover directory (via MetadataAssetStore)

    private static let artworkDir: URL = MetadataAssetStore.shared.artworkDirectoryURL

    // MARK: - Public API

    func startActivity(song: Song, isPlaying: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Write cover image to App Group shared container
        let coverName = writeCoverToSharedContainer(coverFileName: song.coverArtFileName)

        let attributes = PlaybackActivityAttributes(
            songTitle: song.title,
            artistName: song.artistName ?? "",
            albumTitle: song.albumTitle ?? "",
            duration: song.duration,
            coverImageName: coverName
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

        // Clean up cover file from shared container
        cleanupSharedCover()
    }

    // MARK: - Cover Image Handling

    /// Writes a downscaled cover image to the App Group shared container.
    /// Returns the filename if successful, nil otherwise.
    private func writeCoverToSharedContainer(coverFileName: String?) -> String? {
        guard let coverFileName, !coverFileName.isEmpty,
              let containerURL = Self.containerURL else {
            return nil
        }

        // Find the source cover file
        let sourceURL = Self.artworkDir.appendingPathComponent(coverFileName)

        guard FileManager.default.fileExists(atPath: sourceURL.path),
              let data = try? Data(contentsOf: sourceURL),
              let originalImage = UIImage(data: data) else {
            return nil
        }

        // Downscale to 80×80 for Live Activity (Apple recommends ~84px max)
        let targetSize = CGSize(width: 80, height: 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))

            // Center-crop to square
            let sourceAspect = originalImage.size.width / originalImage.size.height
            let drawRect: CGRect
            if sourceAspect > 1 {
                let scaledWidth = targetSize.height * sourceAspect
                let xOffset = (targetSize.width - scaledWidth) / 2
                drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: targetSize.height)
            } else {
                let scaledHeight = targetSize.width / sourceAspect
                let yOffset = (targetSize.height - scaledHeight) / 2
                drawRect = CGRect(x: 0, y: yOffset, width: targetSize.width, height: scaledHeight)
            }
            originalImage.draw(in: drawRect)
        }

        // Save as PNG (more reliable in Widget Extensions per Apple forums)
        guard let pngData = resizedImage.pngData() else { return nil }

        let sharedFileName = "live_activity_cover.png"
        let destinationURL = containerURL.appendingPathComponent(sharedFileName)

        do {
            try pngData.write(to: destinationURL, options: .atomic)
            return sharedFileName
        } catch {
            print("Failed to write cover to shared container: \(error)")
            return nil
        }
    }

    /// Removes the cover file from the shared container
    private func cleanupSharedCover() {
        guard let containerURL = Self.containerURL else { return }
        let fileURL = containerURL.appendingPathComponent("live_activity_cover.png")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
