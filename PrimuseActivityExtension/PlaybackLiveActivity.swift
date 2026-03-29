import ActivityKit
import SwiftUI
import WidgetKit
import PrimuseKit

struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            // Lock Screen / Stand By view
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    SharedCoverImageView(coverImageName: context.attributes.coverImageName)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.songTitle)
                            .font(.headline)
                            .lineLimit(1)

                        Text(context.attributes.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(
                        value: context.state.elapsedTime,
                        total: max(context.attributes.duration, 1)
                    )
                    .tint(.accentColor)
                    .padding(.horizontal)
                }
            } compactLeading: {
                SharedCoverImageView(coverImageName: context.attributes.coverImageName)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                Text(context.attributes.songTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            } minimal: {
                SharedCoverImageView(coverImageName: context.attributes.coverImageName)
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<PlaybackActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            SharedCoverImageView(coverImageName: context.attributes.coverImageName)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.songTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text(context.attributes.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
        }
        .padding()

        ProgressView(
            value: context.state.elapsedTime,
            total: max(context.attributes.duration, 1)
        )
        .tint(.accentColor)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Shared Cover Image View

/// Loads album cover art from the App Group shared container.
/// Widget Extensions cannot access the main app's sandbox, so images must be
/// written to the shared container by the main app before the activity starts.
private struct SharedCoverImageView: View {
    let coverImageName: String?

    var body: some View {
        if let image = loadImage() {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Fallback placeholder
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.3, green: 0.3, blue: 0.4),
                        Color(red: 0.2, green: 0.2, blue: 0.3)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func loadImage() -> UIImage? {
        guard let coverImageName, !coverImageName.isEmpty else { return nil }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else {
            return nil
        }

        let fileURL = containerURL.appendingPathComponent(coverImageName)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }
}
