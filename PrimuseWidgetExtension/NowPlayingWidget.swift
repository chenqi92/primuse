import SwiftUI
import WidgetKit
import PrimuseKit

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), state: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), state: PlaybackState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = NowPlayingEntry(date: Date(), state: PlaybackState.load())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: PlaybackState?
}

struct NowPlayingWidget: Widget {
    let kind = "NowPlayingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("正在播放")
        .description("在桌面上快速查看当前歌曲和播放进度")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state, state.currentSongID != nil {
            switch family {
            case .systemSmall:
                SmallNowPlayingView(state: state)
            case .systemMedium:
                MediumNowPlayingView(state: state)
            case .systemLarge:
                LargeNowPlayingView(state: state)
            default:
                SmallNowPlayingView(state: state)
            }
        } else {
            switch family {
            case .systemSmall:
                SmallEmptyStateView()
            case .systemMedium:
                MediumEmptyStateView()
            case .systemLarge:
                LargeEmptyStateView()
            default:
                SmallEmptyStateView()
            }
        }
    }
}

private struct SmallNowPlayingView: View {
    let state: PlaybackState

    var body: some View {
        ZStack {
            WidgetArtworkBackdrop(coverImageName: state.coverImageName, shadeOpacity: 0.18)
            LinearGradient(
                colors: [Color.black.opacity(0.05), Color.black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                WidgetStatusPill(
                    text: state.isPlaying ? "播放中" : "已暂停",
                    systemImage: state.isPlaying ? "waveform" : "pause.fill",
                    tint: state.isPlaying ? WidgetDesign.cyan : WidgetDesign.coral
                )

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.songTitle ?? "未知歌曲")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)

                    Text(state.artistName ?? "未知艺术家")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(1)
                }

                VStack(spacing: 6) {
                    WidgetProgressBar(value: state.currentTime, total: max(state.duration, 1))
                    HStack {
                        Text(formatTime(state.currentTime))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WidgetDesign.secondaryText)
                        Spacer()
                        Text(formatTime(state.duration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct MediumNowPlayingView: View {
    let state: PlaybackState

    var body: some View {
        ZStack {
            WidgetArtworkBackdrop(coverImageName: state.coverImageName, blurRadius: 28, shadeOpacity: 0.48)

            HStack(spacing: 14) {
                WidgetCoverImageView(
                    coverImageName: state.coverImageName,
                    cornerRadius: 20,
                    placeholderIndex: 0
                )
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            WidgetSectionEyebrow(text: "正在播放")
                            Text(state.songTitle ?? "未知歌曲")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetDesign.strongText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 10)

                        WidgetStatusPill(
                            text: state.isPlaying ? "LIVE" : "PAUSE",
                            systemImage: state.isPlaying ? "dot.radiowaves.left.and.right" : "pause.fill",
                            tint: state.isPlaying ? WidgetDesign.cyan : WidgetDesign.coral
                        )
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.artistName ?? "未知艺术家")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)

                        if let albumTitle = state.albumTitle, !albumTitle.isEmpty {
                            Text(albumTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    WidgetPanel(padding: 10, cornerRadius: 18) {
                        VStack(spacing: 8) {
                            WidgetProgressBar(value: state.currentTime, total: max(state.duration, 1))
                            HStack {
                                WidgetMiniStat(title: "已播放", value: formatTime(state.currentTime))
                                Spacer()
                                WidgetMiniStat(title: "总时长", value: formatTime(state.duration))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct LargeNowPlayingView: View {
    let state: PlaybackState

    var body: some View {
        ZStack {
            WidgetArtworkBackdrop(coverImageName: state.coverImageName, blurRadius: 32, shadeOpacity: 0.52)

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    WidgetCoverImageView(
                        coverImageName: state.coverImageName,
                        cornerRadius: 24,
                        placeholderIndex: 0
                    )
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.26), radius: 16, x: 0, y: 8)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            WidgetSectionEyebrow(text: "正在播放")
                            Spacer()
                            WidgetStatusPill(
                                text: state.isPlaying ? "播放中" : "暂停中",
                                systemImage: state.isPlaying ? "waveform" : "pause.fill",
                                tint: state.isPlaying ? WidgetDesign.cyan : WidgetDesign.coral
                            )
                        }

                        Text(state.songTitle ?? "未知歌曲")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(2)

                        Text(state.artistName ?? "未知艺术家")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)

                        if let albumTitle = state.albumTitle, !albumTitle.isEmpty {
                            Text(albumTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 18) {
                            WidgetMiniStat(title: "已播放", value: formatTime(state.currentTime))
                            WidgetMiniStat(title: "总时长", value: formatTime(state.duration))
                            WidgetMiniStat(title: "队列", value: "\(max(0, state.queueSongIDs.count))")
                        }
                    }
                }

                WidgetPanel(padding: 14, cornerRadius: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("播放进度")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(WidgetDesign.secondaryText)
                            Spacer()
                            Text(progressCaption)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                        }

                        WidgetProgressBar(
                            value: state.currentTime,
                            total: max(state.duration, 1),
                            height: 7
                        )

                        HStack {
                            playbackSymbol(systemName: "backward.fill")
                            Spacer()
                            playbackSymbol(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill", filled: true)
                            Spacer()
                            playbackSymbol(systemName: "forward.fill")
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var progressCaption: String {
        guard state.duration > 0 else { return "等待同步" }
        let percent = Int((state.currentTime / state.duration) * 100)
        return "\(max(0, min(100, percent)))%"
    }

    private func playbackSymbol(systemName: String, filled: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: filled ? 22 : 18, weight: .semibold))
            .foregroundStyle(filled ? WidgetDesign.strongText : WidgetDesign.secondaryText)
    }
}

private struct SmallEmptyStateView: View {
    var body: some View {
        WidgetCanvas(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetEmptyStateIcon(systemName: "waveform.path.ecg", size: 56)
                Spacer(minLength: 0)
                Text("开始播放")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetDesign.strongText)
                Text("点开猿音，继续你的音乐旅程")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetDesign.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct MediumEmptyStateView: View {
    var body: some View {
        WidgetCanvas(padding: 18) {
            HStack(spacing: 16) {
                WidgetEmptyStateIcon(systemName: "waveform", size: 78)

                VStack(alignment: .leading, spacing: 6) {
                    Text("把音乐放到桌面上")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                    Text("开始播放后，当前歌曲和进度会直接出现在这里。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct LargeEmptyStateView: View {
    var body: some View {
        WidgetCanvas(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetSectionEyebrow(text: "猿音")
                    Text("桌面上的私人音乐角落")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                }

                Spacer(minLength: 0)

                HStack(alignment: .top, spacing: 18) {
                    WidgetEmptyStateIcon(systemName: "waveform.path", size: 96)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("把音乐放到桌面上")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text("连接你的音乐源后，这里会显示当前歌曲、播放进度和最近聆听。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
