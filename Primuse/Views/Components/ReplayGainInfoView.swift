import SwiftUI
import Observation
import PrimuseKit

@MainActor @Observable
private final class ReplayGainAnalysisPresentation {
    private var songKey: String?
    private var status: PrimuseKit.ReplayGainAnalysisStatus = .unavailable

    struct Identity: Equatable {
        let songKey: String?
        let needsAnalysis: Bool
    }

    static func identity(song: Song?, info: ReplayGainPlaybackInfo) -> Identity {
        Identity(songKey: song.map { ReplayGainAnalysisCache.key(for: $0) }, needsAnalysis: info.showsBadge && !info.isActive)
    }

    func state(song: Song?, info: ReplayGainPlaybackInfo) -> ReplayGainDisplayState {
        let key = song.map { ReplayGainAnalysisCache.key(for: $0) }
        return info.displayState(analysis: songKey == key ? status : .unavailable)
    }

    func observe(song: Song?, info: ReplayGainPlaybackInfo) async {
        guard !Task.isCancelled else { return }
        songKey = song.map { ReplayGainAnalysisCache.key(for: $0) }
        status = .unavailable
        guard info.showsBadge, !info.isActive, let song else { return }
        while !Task.isCancelled {
            let value = await ReplayGainAnalysisService.shared.status(for: song)
            guard !Task.isCancelled else { return }
            status = value
            if value == .cached { return }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}

struct ReplayGainBadge: View {
    let info: ReplayGainPlaybackInfo
    let song: Song?
    let tint: Color
    @State private var analysis = ReplayGainAnalysisPresentation()

    var body: some View {
        let state = analysis.state(song: song, info: info)
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        HStack(spacing: 4) {
            if state.isLoading {
                ProgressView().controlSize(.mini).tint(tint)
                    .frame(width: indicatorSize, height: indicatorSize)
            } else {
                Image(systemName: state.symbol).imageScale(.small)
                    .frame(width: indicatorSize, height: indicatorSize)
            }
            Text(verbatim: "RG").fontWeight(.semibold)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.08), in: shape)
        .overlay { shape.strokeBorder(tint.opacity(0.5), lineWidth: 0.75) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("replay_gain"))
        .accessibilityValue(Text(LocalizedStringKey(state.localizationKey)))
        .task(id: ReplayGainAnalysisPresentation.identity(song: song, info: info)) {
            await analysis.observe(song: song, info: info)
        }
    }

    private var indicatorSize: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
}

struct ReplayGainInfoView: View {
    let info: ReplayGainPlaybackInfo
    let song: Song?

    @State private var analysis = ReplayGainAnalysisPresentation()

    var body: some View {
        let state = analysis.state(song: song, info: info)
        VStack(alignment: .leading, spacing: 10) {
            Label("replay_gain", systemImage: "waveform")
                .font(.headline)
            Text(LocalizedStringKey(state.localizationKey))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("replayGain.status")
            if info.isActive, let snapshot = info.snapshot {
                row("rg_mode", value: String(localized: String.LocalizationValue(snapshot.mode.localizationKey)))
                row("rg_info_source", value: String(localized: snapshot.origin == .tags ? "rg_info_tags" : "rg_info_cache"))
                if let gain = info.appliedGainDB {
                    row("rg_info_gain", value: String(format: "%+.1f dB", gain))
                }
                row("rg_preamp", value: String(format: "%+.1f dB", info.preampDB))
                if info.isPeakLimited {
                    Text("rg_info_peak_limited").foregroundStyle(.secondary)
                }
            } else if state.isLoading {
                Text("rg_analysis_pending_detail").foregroundStyle(.secondary)
            } else if state == .cached {
                Text("rg_analysis_cached_detail").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: ReplayGainAnalysisPresentation.identity(song: song, info: info)) {
            await analysis.observe(song: song, info: info)
        }
    }

    private func row(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(verbatim: value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
