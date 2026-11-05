import SwiftUI
import PrimuseKit

struct ReplayGainInfoView: View {
    let info: ReplayGainPlaybackInfo
    let song: Song?

    @State private var analysisStatus = ReplayGainAnalysisService.Status.unavailable
    @State private var analysisSongKey: String?

    private var songKey: String? { song.map { ReplayGainAnalysisCache.key(for: $0) } }
    private var status: ReplayGainAnalysisService.Status {
        analysisSongKey == songKey ? analysisStatus : .unavailable
    }

    private var statusKey: String {
        if !info.enabled { return "rg_status_disabled" }
        if !info.supported { return "rg_status_bypassed" }
        if info.isActive { return "rg_status_active" }
        switch status {
        case .cached: return "rg_status_cached"
        case .queued: return "rg_status_queued"
        case .analyzing: return "rg_status_analyzing"
        case .unavailable: return "rg_status_original"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("replay_gain", systemImage: "waveform")
                .font(.headline)
            Text(LocalizedStringKey(statusKey))
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
            } else if info.showsBadge, status == .queued || status == .analyzing {
                Text("rg_status_original").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: RefreshID(songKey: songKey, enabled: info.enabled && info.supported && !info.isActive)) {
            analysisStatus = .unavailable
            analysisSongKey = songKey
            guard info.showsBadge, !info.isActive, let song else { return }
            while !Task.isCancelled {
                let value = await ReplayGainAnalysisService.shared.status(for: song)
                guard !Task.isCancelled else { return }
                analysisStatus = value
                if value == .cached { return }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private struct RefreshID: Equatable {
        let songKey: String?
        let enabled: Bool
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
