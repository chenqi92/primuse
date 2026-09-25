import SwiftUI
import PrimuseKit

// MARK: - 电台空间的颜色

/// 电台这个收听空间的颜色（浅色 #D9480F，深色 #FF8A4C），取自 `ListeningSpace.radio.tint`。
/// 只在电台自己的零件里用（直播点、「正在播」卡、收听按钮），不替换全局强调色。
enum RadioSpacePalette {
    static var accent: Color { ListeningSpace.radio.tint }
}

// MARK: - 起播

/// 电台页、首页电台条、详情页共用的起播/停播。
///
/// 明文 HTTP 的台要先问一次用户（`.pls` 包装除外 —— 它拆出来的真实主机由播放器在起播时再问），
/// 这一步需要一个弹框，所以这里只回答「要不要先问」，弹框由 `radioInsecureStationAlert` 挂。
@MainActor
enum RadioStationPlaybackAction {
    static func requiresInsecureApproval(_ station: RadioStation) -> Bool {
        guard !RadioImportParser.isPlaylistWrapper(station.streamURL),
              let url = station.url,
              TrustedHTTPTransport.requiresPlainSocket(for: url),
              let trustTarget = TrustedHTTPTransport.trustTarget(for: url) else { return false }
        return !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget)
    }

    static func isActive(_ station: RadioStation, player: AudioPlayerService) -> Bool {
        player.currentRadioStation?.id == station.id && (player.isPlaying || player.isLoading)
    }

    /// 正在播这个台就停，否则起播。已确认过（或不需要确认）明文 HTTP 时调用。
    static func toggle(_ station: RadioStation, player: AudioPlayerService, within stations: [RadioStation]) {
        if isActive(station, player: player) {
            player.pause()
        } else {
            SiriMediaInteractionDonor.donate(station: station)
            Task { await player.play(station: station, within: stations) }
        }
    }
}

private struct RadioInsecureStationAlert: ViewModifier {
    @Binding var pending: RadioStation?
    let onApproved: (RadioStation) -> Void

    func body(content: Content) -> some View {
        content.alert("insecure_http_warning_title", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            Button("cancel", role: .cancel) { pending = nil }
            Button("insecure_http_continue", role: .destructive) {
                guard let station = pending,
                      let url = station.url,
                      let trustTarget = TrustedHTTPTransport.trustTarget(for: url) else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: trustTarget)
                pending = nil
                onApproved(station)
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                pending?.url.flatMap(TrustedHTTPTransport.trustTarget(for:)) ?? ""
            ))
        }
    }
}

extension View {
    /// 明文 HTTP 电台起播前的确认框。`pending` 非空时弹出，用户同意后交给 `onApproved`。
    func radioInsecureStationAlert(
        pending: Binding<RadioStation?>,
        onApproved: @escaping (RadioStation) -> Void
    ) -> some View {
        modifier(RadioInsecureStationAlert(pending: pending, onApproved: onApproved))
    }
}

extension RadioStationRecencyPolicy {
    /// 听过的台，最近的在最前。`stations` 按全局优先级排好（`RadioStationsStore.stations`）。
    static func recentStations(_ stations: [RadioStation], limit: Int = recentLimit) -> [RadioStation] {
        recent(stations, limit: limit, lastPlayedAt: \.lastPlayedAt)
    }

    /// 首页电台条：最近听过的在前，再按优先级补满。
    static func stripStations(_ stations: [RadioStation], limit: Int = stripLimit) -> [RadioStation] {
        strip(stations, limit: limit, lastPlayedAt: \.lastPlayedAt)
    }
}

// MARK: - 方形台标格

/// 横排里的一格：方形台标、台名、正在播时的直播点。
///
/// 首页电台条、电台页「最近收听」、Mac 电台页的「最近收听」都用这一格。
/// 点一下起播/停播；iOS 上长按直接打开电台详情，Mac 上右键菜单里有「电台信息」。
/// 播放状态在格子自己的 body 里读，换台只重画新旧两格。
struct RadioStationStripTile: View {
    let station: RadioStation
    var width: CGFloat = 104
    let onPlay: () -> Void
    let onDetails: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @State private var isPressed = false

    var body: some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)

        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(width: width, height: width)
                .overlay {
                    RadioStationArtworkContent(
                        station: station,
                        decodeSize: width,
                        contentMode: .fit
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isCurrent ? RadioSpacePalette.accent : Color.secondary.opacity(0.15),
                            lineWidth: isCurrent ? 1.6 : 0.6
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RadioSpacePalette.accent)
                            .frame(width: 26, height: 26)
                            .background(.thinMaterial, in: Circle())
                            .padding(6)
                            .pmFadeTransition(motion: .control)
                    }
                }

            HStack(spacing: 4) {
                if isPlaying {
                    Circle()
                        .fill(RadioSpacePalette.accent)
                        .frame(width: 5, height: 5)
                }
                Text(station.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? RadioSpacePalette.accent : .primary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .scaleEffect(isPressed ? 0.96 : 1)
        .pmAnimation(.press, value: isPressed)
        .pmAnimation(.hover, value: isPlaying)
        .contentShape(Rectangle())
        .onTapGesture { onPlay() }
        #if os(iOS)
        .onLongPressGesture(minimumDuration: 0.45) {
            onDetails()
        } onPressingChanged: { pressing in
            isPressed = pressing
        }
        #else
        .contextMenu {
            Button("radio_details", systemImage: "info.circle") { onDetails() }
        }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPlay() }
        .accessibilityAction(named: Text("radio_details")) { onDetails() }
        .accessibilityValue(isPlaying ? Text("live_badge") : Text(verbatim: ""))
    }
}

/// 一排横滑的台标格。只负责排版，播放与详情交给调用方。
struct RadioStationTileRow: View {
    let stations: [RadioStation]
    var tileWidth: CGFloat = 104
    var horizontalInset: CGFloat = 16
    let onPlay: (RadioStation) -> Void
    let onDetails: (RadioStation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(stations) { station in
                    RadioStationStripTile(
                        station: station,
                        width: tileWidth,
                        onPlay: { onPlay(station) },
                        onDetails: { onDetails(station) }
                    )
                }
            }
            .padding(.horizontal, horizontalInset)
        }
    }
}

// MARK: - 首页电台条

/// 首页的电台条：最近听过的台在前，再按优先级补满，最多 12 个。
///
/// 自带起播（含明文 HTTP 确认）和电台详情页，调用方只需要放进去：
/// `RadioStationStrip()`。环境里要有 `RadioStationsStore`、`AudioPlayerService`
/// （以及台标用到的 `SourceManager`、`ThemeService`）—— 首页本来就都有。
/// 没有电台时什么都不画，调用方改放 `RadioAddStationCard()`。
/// 不带标题和「全部」入口，那是首页分区标题的事。
struct RadioStationStrip: View {
    var horizontalInset: CGFloat = 16

    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.pmHeightClass) private var heightClass
    @State private var pendingInsecureStation: RadioStation?
    @State private var detailStation: RadioStation?

    private var tileWidth: CGFloat {
        #if os(macOS)
        return 120
        #else
        return heightClass.value(104, compact: 88)
        #endif
    }

    var body: some View {
        let stations = RadioStationRecencyPolicy.stripStations(store.stations)
        if !stations.isEmpty {
            RadioStationTileRow(
                stations: stations,
                tileWidth: tileWidth,
                horizontalInset: horizontalInset,
                onPlay: play,
                onDetails: { detailStation = $0 }
            )
            .radioInsecureStationAlert(pending: $pendingInsecureStation) { station in
                RadioStationPlaybackAction.toggle(station, player: player, within: store.stations)
            }
            .sheet(item: $detailStation) { station in
                RadioStationDetailView(stationID: station.id)
            }
        }
    }

    private func play(_ station: RadioStation) {
        if RadioStationPlaybackAction.requiresInsecureApproval(station) {
            pendingInsecureStation = station
        } else {
            RadioStationPlaybackAction.toggle(station, player: player, within: store.stations)
        }
    }
}

// MARK: - 电台页「最近收听」

/// 电台页顶部的「最近收听」：标题 + 一排台标格。一个都没听过时不画。
/// 起播和详情交给页面，页面上已经挂着明文 HTTP 确认和详情页。
struct RadioRecentStationsSection: View {
    var horizontalInset: CGFloat = 16
    let onPlay: (RadioStation) -> Void
    let onDetails: (RadioStation) -> Void

    @Environment(RadioStationsStore.self) private var store

    #if os(macOS)
    private static let tileWidth: CGFloat = 112
    #else
    private static let tileWidth: CGFloat = 92
    #endif

    var body: some View {
        let recent = RadioStationRecencyPolicy.recentStations(store.stations)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("radio_recent_title")
                    .font(.headline)
                    .padding(.horizontal, horizontalInset)
                    .accessibilityAddTraits(.isHeader)
                RadioStationTileRow(
                    stations: recent,
                    tileWidth: Self.tileWidth,
                    horizontalInset: horizontalInset,
                    onPlay: onPlay,
                    onDetails: onDetails
                )
            }
        }
    }
}

// MARK: - 「正在播」卡

/// 电台页顶部的「正在播」：有台在播（或正在连）时出现。
/// 读播放状态的只有这张卡，节目标题一变不会让整页重算。
struct RadioNowPlayingCard: View {
    let onDetails: (RadioStation) -> Void

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if player.isLiveRadio,
           let station = player.currentRadioStation,
           player.isPlaying || player.isLoading {
            content(station)
                .pmFadeTransition(motion: .contentAppear)
        }
    }

    private func content(_ station: RadioStation) -> some View {
        HStack(spacing: 14) {
            Button {
                onDetails(station)
            } label: {
                HStack(spacing: 14) {
                    RadioStationArtworkView(station: station, size: 64, cornerRadius: 14)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(RadioSpacePalette.accent)
                                .frame(width: 6, height: 6)
                            Group {
                                if player.isLoading && !player.isPlaying {
                                    Text("radio_buffering")
                                } else {
                                    Text("live_badge")
                                }
                            }
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(RadioSpacePalette.accent)
                        }

                        Text(station.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(player.radioMetadataTitle ?? station.playbackSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .contentTransition(.opacity)
                            .pmAnimation(.trackChange, value: player.radioMetadataTitle)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("radio_details"))

            Button {
                player.pause()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RadioSpacePalette.accent, in: Circle())
            }
            .buttonStyle(.pmPressable)
            .accessibilityLabel(Text("radio_stop"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RadioSpacePalette.accent.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RadioSpacePalette.accent.opacity(0.3), lineWidth: 0.7)
        }
    }
}

// MARK: - 没有电台时的引导卡

/// 还没有电台时放在首页的一张卡：说明电台是什么，给出批量添加和手动添加两个入口。
/// 两个入口打开的就是电台页「+」菜单里的那两个页面。
/// 调用：`RadioAddStationCard()`，环境要求同 `RadioStationStrip`。
struct RadioAddStationCard: View {
    @State private var showingBatchAdd = false
    @State private var showingNewStation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(RadioSpacePalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("radio_add_card_title")
                        .font(.headline)
                    Text("radio_add_card_message")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button {
                    showingBatchAdd = true
                } label: {
                    Label("radio_batch_add_title", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(RadioSpacePalette.accent)

                Button {
                    showingNewStation = true
                } label: {
                    Label("radio_add", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(RadioSpacePalette.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RadioSpacePalette.accent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RadioSpacePalette.accent.opacity(0.25), lineWidth: 0.7)
        }
        .sheet(isPresented: $showingBatchAdd) {
            #if os(macOS)
            MacRadioBatchAddView()
            #else
            RadioBatchAddView()
            #endif
        }
        .sheet(isPresented: $showingNewStation) {
            #if os(macOS)
            MacRadioStationEditorView(station: nil)
            #else
            RadioStationEditorView(station: nil)
            #endif
        }
    }
}
