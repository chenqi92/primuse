import SwiftUI
import PrimuseKit

/// 播放页上标出这首歌来自哪个音乐源用的图标与名字。
struct NowPlayingSourceLabel: Equatable {
    let iconName: String
    let name: String
}

/// 播放页的小标签:细描边的小牌,单色,跟两端的时间数字同一灰阶 —— 不用音质色,
/// 免得一块橙色在整页低饱和的灰里跳出来。「Hi-Res ▏24/96」这种前后两截的,
/// 粗的一截是等级,细的一截是规格,中间一道细竖线。
struct NowPlayingAudioTag: View {
    var symbol: String? = nil
    var title: String? = nil
    var detail: String? = nil
    let tint: Color
    var pulsesSymbol = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .symbolEffect(.pulse, options: .repeating, isActive: pulsesSymbol)
            }
            if let title {
                Text(verbatim: title)
                    .fontWeight(.semibold)
            }
            if title != nil, detail != nil {
                Capsule()
                    .fill(tint.opacity(0.45))
                    .frame(width: 1, height: 8)
                    .accessibilityHidden(true)
            }
            if let detail {
                Text(verbatim: detail)
                    .fontWeight(.medium)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.08), in: shape)
        .overlay { shape.strokeBorder(tint.opacity(0.5), lineWidth: 0.75) }
    }
}

/// 进度条下、两个时间中间那组标签:音质(带规格简写),版面底下没有状态行时再加来源
/// (不止一个音乐源时)。起播前在 iCloud 云盘下载时整组换成下载提示。
///
/// 轻点打开「音频信息」小卡:等级、完整规格、实际输出的采样率与来源。放不下两枚时只留音质那枚。
struct NowPlayingAudioTagRow: View {
    let song: Song
    /// 按设置的档位要不要标音质;有声内容不标。
    let showsAudio: Bool
    let isDownloadingFromICloud: Bool
    let source: NowPlayingSourceLabel?
    /// 来源要不要也挂成一枚标签。有底部状态行的版面把来源写在那一行,这里只在小卡里列出。
    var showsSourceTag = true
    /// 输出设备此刻的采样率(Hz),拿不到为 0。
    let outputSampleRate: Double
    /// Apple Music 目录曲由系统播放器出声,输出采样率说不准,卡片里不写。
    let allowsOutputDetail: Bool
    let tint: Color

    @State private var showsDetails = false

    /// 来源名最宽到这里,再长就截断。
    static let sourceMaxWidth: CGFloat = 96
    #if DEBUG
    /// 取证用:启动时带 `PRIMUSE_DEBUG_AUDIO_INFO_OUTPUT=1` 就一出现便打开信息卡。
    private static let debugOpensDetails =
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_AUDIO_INFO_OUTPUT"] == "1"
    #endif

    var body: some View {
        ZStack {
            if isDownloadingFromICloud {
                NowPlayingAudioTag(
                    symbol: "icloud.and.arrow.down",
                    title: String(localized: "playback_icloud_downloading"),
                    tint: tint,
                    pulsesSymbol: true
                )
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            } else if audioTag != nil || taggedSource != nil {
                Button { showsDetails = true } label: {
                    tags
                        // 牌子只有 17pt 高,命中区往下补到够手指点;上面紧挨着进度条,不往上补。
                        .padding(.horizontal, 6)
                        .padding(.top, 3)
                        .padding(.bottom, 10)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -6)
                        .padding(.top, -3)
                        .padding(.bottom, -10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: accessibilityText))
                .accessibilityHint(Text("now_playing_audio_info_hint"))
                // 往上弹,盖在进度条与歌名上,不挡下面的播放键。
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    detailsCard
                        .presentationCompactAdaptation(.popover)
                }
                .transition(.opacity)
            }
        }
        .pmAnimation(.trackChange, value: song.id)
        .pmAnimation(.control, value: isDownloadingFromICloud)
        #if DEBUG
        .task {
            guard Self.debugOpensDetails else { return }
            try? await Task.sleep(for: .seconds(1))
            showsDetails = true
        }
        #endif
    }

    /// 两枚放不下(窄屏、大字号)时只留音质那枚。
    private var tags: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                audioTag
                sourceTag
            }
            if let audioTag {
                audioTag
            } else {
                sourceTag
            }
        }
    }

    private var audioTag: NowPlayingAudioTag? {
        guard showsAudio else { return nil }
        let detail = tagDetail ?? (song.audioVariants?.offersDolbyAtmos == true
            ? PMString(AudioVariant.dolbyAtmos.localizationKey)
            : nil)
        guard qualityLabel != nil || detail != nil else { return nil }
        return NowPlayingAudioTag(title: qualityLabel, detail: detail, tint: tint)
    }

    private var taggedSource: NowPlayingSourceLabel? {
        showsSourceTag ? source : nil
    }

    @ViewBuilder
    private var sourceTag: some View {
        if let source = taggedSource {
            NowPlayingWidthCap(maxWidth: Self.sourceMaxWidth) {
                NowPlayingAudioTag(symbol: source.iconName, title: nil, detail: source.name, tint: tint)
            }
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: qualityLabel ?? song.audioQuality.displayName)
                .font(.headline)
            if !specText.isEmpty {
                Text(verbatim: specText)
                    .font(.subheadline.monospacedDigit())
            }
            if let outputText {
                Text(verbatim: outputText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let source {
                Label {
                    Text(verbatim: source.name)
                } icon: {
                    Image(systemName: source.iconName)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize()
    }

    /// Apple Music 曲目标它提供的档位;其余按音质等级,有损的不写等级。
    private var qualityLabel: String? {
        if let variants = song.audioVariants, !variants.isEmpty {
            return variants.bestLosslessTier.map { PMString($0.localizationKey) }
        }
        return song.audioQuality == .standard ? nil : song.audioQuality.displayName
    }

    private var tagDetail: String? {
        NowPlayingAudioInfoTextPolicy.tagDetail(
            formatName: song.codecFormat.displayName,
            sampleRate: song.sampleRate,
            bitDepth: song.bitDepth,
            bitRate: song.bitRate,
            isDSD: song.audioQuality == .dsd,
            isLossless: song.audioQuality != .standard
        )
    }

    private var specText: String {
        var parts = NowPlayingAudioInfoTextPolicy.specParts(
            formatName: song.codecFormat.displayName,
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
        var parts: [String] = []
        if let audioTag {
            parts.append(contentsOf: [audioTag.title, audioTag.detail].compactMap { $0 })
        }
        if let taggedSource { parts.append(taggedSource.name) }
        return parts.joined(separator: ", ")
    }
}

/// 给孩子的宽度封顶:不管外面给多宽 —— 包括 `ViewThatFits` 问理想尺寸的时候 —— 都只给它
/// 这么宽,文字自己截断。`.frame(maxWidth:)` 在问理想尺寸时不封顶,来源名会把标签撑出去。
private struct NowPlayingWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: capped(ProposedViewSize(bounds.size)))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}

/// 有声书版面最下面那行:「MP3 · 44.1kHz │ 家里的 NAS」。音乐的播放页改用进度条下的标签,
/// 见 `NowPlayingAudioTagRow`。
///
/// 格式与来源是同一行淡色小字,中间一道细竖线分开;放不下时先截来源名。行高固定:换歌时
/// 规格长短、下载提示进出都不改变高度。
struct NowPlayingFooterInfoRow: View {
    let song: Song
    /// 设置里关掉音频信息时只留来源。
    let showsAudioDetail: Bool
    /// 起播前正在从 iCloud 云盘下载这首歌:音频信息那段换成下载提示。
    let isDownloadingFromICloud: Bool
    /// 不止一个音乐源时才标来源。
    let source: NowPlayingSourceLabel?
    /// 输出设备此刻的采样率(Hz),拿不到为 0。
    let outputSampleRate: Double
    let infoColor: Color
    /// 来源比音频信息再淡一档。
    let sourceColor: Color
    /// 下载提示比常驻信息醒目一档。
    let noticeColor: Color

    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            if showsAudioSegment {
                // 下载提示与音频信息在 ZStack 里互换,交叉淡入时两支叠在一起,不把来源推来推去。
                ZStack {
                    if isDownloadingFromICloud {
                        downloadNotice
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
    }

    private var showsAudioSegment: Bool {
        isDownloadingFromICloud || (showsAudioDetail && briefText != nil)
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

    /// 格式,再加采样率(输出被重采样时写成「44.1 → 48 kHz」)。
    private var briefText: String? {
        var parts: [String] = []
        let format = song.codecFormat.displayName
        if !format.isEmpty, format != "—" { parts.append(format) }
        if let rate = OutputSampleRateTextPolicy.text(
            sourceSampleRate: song.sampleRate,
            outputSampleRate: outputSampleRate
        ) {
            parts.append(rate)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
