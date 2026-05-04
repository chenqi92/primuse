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
                    VStack(spacing: 6) {
                        // 当前 / 下一行歌词 — 仅当后台 push 了 lyric 时显示
                        if let line = context.state.currentLyricLine, !line.isEmpty {
                            VStack(spacing: 2) {
                                Text(line)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                if let next = context.state.nextLyricLine, !next.isEmpty {
                                    Text(next)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        progressBar(context: context)
                    }
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
        VStack(spacing: 8) {
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
            .padding(.horizontal)
            .padding(.top, 12)

            // 歌词 (current + next), 仅当后台 push 了 lyric 时显示。
            // 没歌词的歌静默退化为只显示 song info + progress。
            if let line = context.state.currentLyricLine, !line.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let next = context.state.nextLyricLine, !next.isEmpty {
                        Text(next)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            progressBar(context: context)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    /// 进度条 — isPlaying 用 timerInterval 让系统自动 tick (无需我们 push 进度,
    /// 跟原生锁屏播放器一致的平滑动画)。暂停或没 startedAt 时退化为静态值。
    @ViewBuilder
    private func progressBar(context: ActivityViewContext<PlaybackActivityAttributes>) -> some View {
        let duration = max(context.attributes.duration, 1)
        if let start = context.state.startedAt, context.state.isPlaying {
            let end = start.addingTimeInterval(duration)
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.accentColor)
        } else {
            ProgressView(value: context.state.elapsedTime, total: duration)
                .tint(.accentColor)
        }
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
