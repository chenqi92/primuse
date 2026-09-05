#if os(iOS)
import ActivityKit
import PrimuseKit
import SwiftUI
import WidgetKit

struct LyricsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            lyrics(context)
                .padding()
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    lyrics(context)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
            } compactTrailing: {
                Text(context.isStale ? context.state.title : context.state.lyric)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "text.quote" : "pause.fill")
            }
        }
    }

    private func lyrics(_ context: ActivityViewContext<LyricsActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(context.isStale || context.state.lyric.isEmpty ? context.state.title : context.state.lyric)
                .font(.headline)
                .lineLimit(2)
            Text([context.state.title, context.state.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
