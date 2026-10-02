import SwiftUI
import PrimuseKit

/// 高码率 / DSD 标签 — 当 Song.audioQuality 不是 .standard 时显示。
/// 用在 NowPlaying 主标题旁、SongRow 等位置。
struct AudioQualityBadge: View {
    let quality: AudioQuality
    var compact: Bool = false

    var body: some View {
        Text(quality.displayName)
            .font(compact ? .caption2 : .caption)
            .fontWeight(.semibold)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(badgeColor, lineWidth: 1)
            )
            .foregroundStyle(badgeColor)
            .accessibilityLabel(Text(quality.displayName))
    }

    private var badgeColor: Color { Self.color(for: quality) }

    static func color(for quality: AudioQuality) -> Color {
        switch quality {
        case .dsd: return .yellow
        case .hiRes: return .orange
        case .lossless: return .cyan
        case .standard: return .secondary
        }
    }
}

/// 播放页歌名下面那行音频信息:「Hi-Res  FLAC · 24bit/96kHz · 2304kbps」。
///
/// 轻点换成实际输出的采样率(「输出 48kHz · 重采样」),3 秒后换回。原地换字、
/// 不往下长出第二行:竖屏的封面区是弹性高度,多一行会把歌名整体顶上去。
struct NowPlayingAudioInfoCapsule: View {
    let song: Song
    /// 输出设备此刻的采样率(Hz),拿不到为 0。
    let outputSampleRate: Double
    /// Apple Music 目录曲由系统播放器出声,输出那一行说不准,不给点开。
    let allowsOutputDetail: Bool
    let textColor: Color
    let fillColor: Color

    @State private var showsOutput = false
    @State private var collapseTask: Task<Void, Never>?

    static let collapseDelay: Duration = .seconds(3)
    #if DEBUG
    /// 取证用:启动时带 `PRIMUSE_DEBUG_AUDIO_INFO_OUTPUT=1` 就一直显示输出那一行。
    private static let debugPinsOutput =
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_AUDIO_INFO_OUTPUT"] == "1"
    #endif

    var body: some View {
        Button(action: toggleOutput) {
            HStack(spacing: 6) {
                if let qualityLabel {
                    Text(verbatim: qualityLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(AudioQualityBadge.color(for: song.audioQuality))
                }
                Text(verbatim: showsOutput ? (outputText ?? specText) : specText)
                    .foregroundStyle(textColor)
                    .contentTransition(.opacity)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fillColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityHint(outputText == nil ? Text(verbatim: "") : Text("now_playing_audio_info_hint"))
        .onChange(of: song.id) { _, _ in collapse(animated: false) }
        .onDisappear { collapseTask?.cancel() }
        #if DEBUG
        .onAppear { if Self.debugPinsOutput { showsOutput = true } }
        #endif
    }

    /// Apple Music 曲目标它提供的档位;其余按音质等级,有损的不标。
    private var qualityLabel: String? {
        if let variants = song.audioVariants, !variants.isEmpty {
            return variants.bestLosslessTier.map { PMString($0.localizationKey) }
        }
        return song.audioQuality == .standard ? nil : song.audioQuality.displayName
    }

    private var specText: String {
        var parts = NowPlayingAudioInfoTextPolicy.specParts(
            formatName: song.fileFormat.displayName,
            sampleRate: song.sampleRate,
            bitDepth: song.bitDepth,
            bitRate: song.bitRate,
            isDSD: song.audioQuality == .dsd
        )
        if song.audioVariants?.offersDolbyAtmos == true {
            parts.append(PMString(AudioVariant.dolbyAtmos.localizationKey))
        }
        return parts.joined(separator: " · ")
    }

    private var outputText: String? {
        guard allowsOutputDetail,
              let output = NowPlayingAudioInfoTextPolicy.output(
                sourceSampleRate: song.sampleRate,
                outputSampleRate: outputSampleRate
              ) else { return nil }
        let format: String
        switch output.match {
        case .matched: format = String(localized: "now_playing_audio_output_matched")
        case .resampled: format = String(localized: "now_playing_audio_output_resampled")
        case .sourceUnknown: format = String(localized: "now_playing_audio_output_plain")
        }
        return String(format: format, output.rateText)
    }

    private var accessibilityText: String {
        let shown = showsOutput ? (outputText ?? specText) : specText
        return [qualityLabel, shown].compactMap { $0 }.joined(separator: ", ")
    }

    private func toggleOutput() {
        guard outputText != nil else { return }
        if showsOutput {
            collapse(animated: true)
            return
        }
        pmWithAnimation(.control) { showsOutput = true }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled else { return }
            collapse(animated: true)
        }
    }

    private func collapse(animated: Bool) {
        collapseTask?.cancel()
        collapseTask = nil
        guard showsOutput else { return }
        if animated {
            pmWithAnimation(.control) { showsOutput = false }
        } else {
            showsOutput = false
        }
    }
}

/// 起播前正在从 iCloud 云盘下载这首歌时,占歌名下那一行的位置。
struct NowPlayingICloudDownloadNotice: View {
    let textColor: Color
    let fillColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.and.arrow.down")
                .symbolEffect(.pulse, options: .repeating)
            Text("playback_icloud_downloading")
        }
        .font(.caption)
        .foregroundStyle(textColor)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(fillColor, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
