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
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.blue)
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
                    .tint(.blue)
                    .padding(.horizontal)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text(context.attributes.songTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "music.note")
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<PlaybackActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
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
                .foregroundStyle(.blue)
        }
        .padding()

        ProgressView(
            value: context.state.elapsedTime,
            total: max(context.attributes.duration, 1)
        )
        .tint(.blue)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
