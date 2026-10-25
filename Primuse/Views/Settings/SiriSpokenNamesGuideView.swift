import SwiftUI

/// The names Siri accepts for the app. They come from Info.plist (display name
/// plus `INAlternativeAppNames`) and are fixed when the app is built; nothing
/// at run time can add one, so the list is read back rather than repeated.
enum SiriSpokenAppNames {
    static func current(in bundle: Bundle = .main) -> [String] {
        let displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
        let alternatives = (bundle.infoDictionary?["INAlternativeAppNames"] as? [[String: Any]] ?? [])
            .compactMap { $0["INAlternativeAppName"] as? String }
        var seen = Set<String>()
        return ([displayName].compactMap { $0 } + alternatives).filter {
            !$0.isEmpty && seen.insert($0.lowercased()).inserted
        }
    }
}

struct SiriSpokenNamesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("siri_spoken_names_title")
                .font(.headline)
            Text(verbatim: SiriSpokenAppNames.current().joined(separator: " · "))
                .textSelection(.enabled)
            Text("siri_spoken_names_detail")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .settingsAnchor("siri.spokenNames")
    }
}

/// Spotlight 搜索结果里的封面(#346)。关掉后结果只显示默认图标,索引更小、建得更快;
/// 翻动时整库重新写一遍索引(每一项的签名都带着这个开关)。
struct SpotlightArtworkToggle: View {
    @Environment(MusicLibrary.self) private var library
    @AppStorage(SpotlightIndexService.showsArtworkKey) private var showsArtwork = true

    var body: some View {
        Toggle(isOn: $showsArtwork) {
            SettingsInfoLabel("spotlight_shows_artwork") {
                Text("spotlight_shows_artwork_detail")
            }
        }
        .onChange(of: showsArtwork) { _, _ in
            AppServices.shared.spotlightIndex.artworkPreferenceChanged(library: library)
        }
        .settingsAnchor("siri.spotlightArtwork")
    }
}

/// Spotlight 索引建到哪儿了(#346):收录了多少、在不在建、为什么停着;还没建完时可以在这一页前台接着建。
/// 曲库大时原来看不出进度,搜不到的歌是还没轮到还是根本不收录也分不清。
struct SpotlightIndexStatusRow: View {
    @Environment(MusicLibrary.self) private var library

    private var service: SpotlightIndexService { AppServices.shared.spotlightIndex }

    var body: some View {
        let status = service.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("spotlight_index_status")
                Spacer(minLength: 12)
                if let coverage = status.coverage {
                    Text(verbatim: String(
                        format: String(localized: "spotlight_index_count_format"),
                        coverage.searchable.formatted(),
                        coverage.total.formatted()
                    ))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            if let coverage = status.coverage, !coverage.isComplete || status.activity == .indexing {
                ProgressView(value: coverage.fraction)
            }
            ForEach(Array(details(status).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offersBuildNow(status) {
                Button("spotlight_index_build_now") {
                    service.synchronizeNow(library: library)
                }
                .buttonStyle(.borderless)
                #if os(iOS)
                Text("spotlight_index_build_now_footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .task { service.refreshStatus(library: library) }
        .onDisappear { service.endForegroundSynchronization() }
        .settingsAnchor("siri.spotlightIndex")
    }

    private func offersBuildNow(_ status: SpotlightIndexStatus) -> Bool {
        guard let coverage = status.coverage else { return false }
        return !coverage.isComplete && status.activity == .idle && !status.isHeldByDevice
    }

    private func details(_ status: SpotlightIndexStatus) -> [String] {
        var lines: [String] = []
        switch status.activity {
        case .measuring where status.coverage == nil:
            lines.append(String(localized: "spotlight_index_measuring"))
        case .indexing:
            lines.append(String(localized: "spotlight_index_indexing"))
        default:
            if status.isHeldByDevice {
                lines.append(String(localized: "spotlight_index_held"))
            } else if let coverage = status.coverage {
                if coverage.isComplete {
                    lines.append(String(localized: "spotlight_index_complete"))
                } else if coverage.remaining > 0 {
                    #if os(iOS)
                    let format = String(localized: "spotlight_index_remaining_background_format")
                    #else
                    let format = String(localized: "spotlight_index_remaining_format")
                    #endif
                    lines.append(String(format: format, coverage.remaining.formatted()))
                }
            }
        }
        if let coverage = status.coverage, coverage.awaitingArtwork > 0 {
            lines.append(String(
                format: String(localized: "spotlight_index_awaiting_artwork_format"),
                coverage.awaitingArtwork.formatted()
            ))
        }
        if status.exceedsSongLimit {
            lines.append(String(
                format: String(localized: "spotlight_index_song_limit_format"),
                SpotlightIndexService.maxIndexedSongs.formatted()
            ))
        }
        return lines
    }
}

/// A personal shortcut is the only phrase a listener can choose: Siri runs it
/// by its name alone, so the app name never has to be heard correctly.
struct SiriCustomPhraseGuideView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("siri_custom_phrase_title")
                .font(.headline)
            step(1, "siri_custom_phrase_step_create")
            step(2, "siri_custom_phrase_step_action")
            step(3, "siri_custom_phrase_step_name")
            Text("siri_custom_phrase_footer")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: "shortcuts://create-shortcut") {
                    openURL(url)
                }
            } label: {
                Label("siri_custom_phrase_create", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
        }
        .settingsAnchor("siri.customPhrase")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
    }
}
