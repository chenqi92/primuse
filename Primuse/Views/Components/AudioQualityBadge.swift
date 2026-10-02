import SwiftUI
import PrimuseKit

/// 音质小标:「无损」「Hi-Res」「DSD」。淡淡的同色底加一圈细描边,字用音质色。
/// 用在播放页底部那行、手机横屏的艺人行旁。
struct AudioQualityBadge: View {
    let text: String
    let tint: Color
    var compact: Bool = false

    init(quality: AudioQuality, compact: Bool = false) {
        self.init(text: quality.displayName, tint: Self.color(for: quality), compact: compact)
    }

    init(text: String, tint: Color, compact: Bool = false) {
        self.text = text
        self.tint = tint
        self.compact = compact
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
        Text(verbatim: text)
            .font(compact ? .caption2 : .caption)
            .fontWeight(.semibold)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(tint.opacity(0.14), in: shape)
            .overlay { shape.strokeBorder(tint.opacity(0.55), lineWidth: compact ? 0.75 : 1) }
            .foregroundStyle(tint)
            .accessibilityLabel(Text(verbatim: text))
    }

    static func color(for quality: AudioQuality) -> Color {
        switch quality {
        case .dsd: return .yellow
        case .hiRes: return .orange
        case .lossless: return .cyan
        case .standard: return .secondary
        }
    }
}

/// 播放页最下面那行:「[无损] FLAC · 24bit/96kHz · 2304kbps │ 家里的 NAS」。
///
/// 音质小标打头,规格与来源是同一行淡色小字,中间一道细竖线分开;放不下时先截来源名,
/// 再截规格。行高固定:换歌时小标出没、规格长短、下载提示进出都不改变高度 —— 竖屏的
/// 封面区是弹性高度,这一行一变高,上面的封面和歌名就跟着跳。
/// 轻点规格换成实际输出的采样率(「输出 48kHz · 已重采样」),3 秒后换回,原地换字。
struct NowPlayingFooterInfoRow: View {
    /// 音频信息这一段怎么写。
    enum AudioDetail: Equatable {
        /// 音质小标 + 完整规格,可点开看输出采样率。
        case summary
        /// 只写格式与采样率(重采样时是「44.1 → 48 kHz」),不带小标。
        case brief
        case hidden
    }

    struct SourceLabel: Equatable {
        let iconName: String
        let name: String
    }

    let song: Song
    let audioDetail: AudioDetail
    /// 起播前正在从 iCloud 云盘下载这首歌:音频信息那段换成下载提示。
    let isDownloadingFromICloud: Bool
    /// 不止一个音乐源时才标来源。
    let source: SourceLabel?
    /// 输出设备此刻的采样率(Hz),拿不到为 0。
    let outputSampleRate: Double
    /// Apple Music 目录曲由系统播放器出声,输出那一行说不准,不给点开。
    let allowsOutputDetail: Bool
    let infoColor: Color
    /// 来源比音频信息再淡一档。
    let sourceColor: Color
    /// 下载提示比常驻信息醒目一档。
    let noticeColor: Color

    @State private var showsOutput = false
    @State private var collapseTask: Task<Void, Never>?

    static let height: CGFloat = 24
    static let collapseDelay: Duration = .seconds(3)
    #if DEBUG
    /// 取证用:启动时带 `PRIMUSE_DEBUG_AUDIO_INFO_OUTPUT=1` 就一直显示输出那一行。
    private static let debugPinsOutput =
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_AUDIO_INFO_OUTPUT"] == "1"
    #endif

    var body: some View {
        HStack(spacing: 8) {
            if showsAudioSegment {
                // 下载提示与音频信息在 ZStack 里互换,交叉淡入时两支叠在一起,不把来源推来推去。
                ZStack {
                    if isDownloadingFromICloud {
                        downloadNotice
                            .transition(.opacity)
                    } else if audioDetail == .summary {
                        summaryButton
                            .transition(.opacity)
                    } else if let briefText {
                        Text(verbatim: briefText)
                            .foregroundStyle(infoColor)
                            .contentTransition(.opacity)
                            .transition(.opacity)
                    }
                }
                .layoutPriority(1)
            }
            if let source {
                if showsAudioSegment {
                    Capsule()
                        .fill(sourceColor.opacity(0.8))
                        .frame(width: 1, height: 10)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 3) {
                    Image(systemName: source.iconName)
                        .imageScale(.small)
                    Text(verbatim: source.name)
                        .contentTransition(.opacity)
                }
                .foregroundStyle(sourceColor)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .frame(height: Self.height)
        .pmAnimation(.trackChange, value: song.id)
        .pmAnimation(.control, value: isDownloadingFromICloud)
        .onChange(of: song.id) { _, _ in collapse(animated: false) }
        .onDisappear { collapseTask?.cancel() }
        #if DEBUG
        .onAppear { if Self.debugPinsOutput { showsOutput = true } }
        #endif
    }

    private var showsAudioSegment: Bool {
        if isDownloadingFromICloud { return true }
        switch audioDetail {
        case .summary: return true
        case .brief: return briefText != nil
        case .hidden: return false
        }
    }

    private var summaryButton: some View {
        Button(action: toggleOutput) {
            HStack(spacing: 6) {
                if let qualityLabel {
                    AudioQualityBadge(
                        text: qualityLabel,
                        tint: AudioQualityBadge.color(for: song.audioQuality),
                        compact: true
                    )
                    .fixedSize()
                    .transition(.opacity)
                }
                Text(verbatim: showsOutput ? (outputText ?? specText) : specText)
                    .foregroundStyle(infoColor)
                    .contentTransition(.opacity)
            }
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityHint(outputText == nil ? Text(verbatim: "") : Text("now_playing_audio_info_hint"))
    }

    private var downloadNotice: some View {
        HStack(spacing: 4) {
            Image(systemName: "icloud.and.arrow.down")
                .symbolEffect(.pulse, options: .repeating)
            Text("playback_icloud_downloading")
        }
        .foregroundStyle(noticeColor)
        .accessibilityElement(children: .combine)
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

    /// 简写档:格式,再加采样率(输出被重采样时写成「44.1 → 48 kHz」)。
    private var briefText: String? {
        var parts: [String] = []
        let format = song.fileFormat.displayName
        if !format.isEmpty, format != "—" { parts.append(format) }
        if let rate = OutputSampleRateTextPolicy.text(
            sourceSampleRate: song.sampleRate,
            outputSampleRate: outputSampleRate
        ) {
            parts.append(rate)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
