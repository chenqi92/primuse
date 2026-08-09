#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS 原生电台页。跟 `MacSourcesView` 同一套骨架：eyebrow + 大标题 + 摘要行
/// 的 action bar，下面是 2 列卡片网格；卡片走 `pmCard`，按钮走 PM token，
/// 不用 iOS 那套 Form / ContentUnavailableView / .bordered。
struct MacRadioStationsView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player

    @State private var editingStation: RadioStation?
    @State private var showAddStation = false
    @State private var showBatchAdd = false
    @State private var stationToDelete: RadioStation?
    @State private var pendingInsecureStation: RadioStation?

    private let columns = [
        GridItem(.adaptive(minimum: 340, maximum: 520), spacing: PMSpace.m16)
    ]

    private var stations: [RadioStation] { store.stations }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showAddStation) {
            MacRadioStationEditorView(station: nil)
        }
        .sheet(item: $editingStation) { station in
            MacRadioStationEditorView(station: station)
        }
        .sheet(isPresented: $showBatchAdd) {
            MacRadioBatchAddView()
        }
        .confirmationDialog(
            Text("radio_manage_delete_confirm_title"),
            isPresented: Binding(
                get: { stationToDelete != nil },
                set: { if !$0 { stationToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: stationToDelete
        ) { station in
            Button(role: .destructive) {
                store.remove(id: station.id)
                stationToDelete = nil
            } label: {
                Text("delete")
            }
            Button(role: .cancel) { stationToDelete = nil } label: { Text("cancel") }
        } message: { _ in
            Text("radio_manage_delete_confirm_message")
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { pendingInsecureStation != nil },
            set: { if !$0 { pendingInsecureStation = nil } }
        )) {
            Button("cancel", role: .cancel) { pendingInsecureStation = nil }
            Button("insecure_http_continue", role: .destructive) {
                guard let station = pendingInsecureStation,
                      let url = station.url,
                      let trustTarget = TrustedHTTPTransport.trustTarget(for: url) else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: trustTarget)
                pendingInsecureStation = nil
                performToggle(station)
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                pendingInsecureStation?.url.flatMap(TrustedHTTPTransport.trustTarget(for:)) ?? ""
            ))
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: PMSpace.m16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Lz("Live Radio"))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(PMColor.textMuted)
                    Text("radio_title")
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(PMColor.text)
                }

                Spacer()

                if !stations.isEmpty {
                    Button {
                        store.sortStationsByName()
                    } label: {
                        Text("radio_priority_sort_by_name")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.m))
                            .overlay {
                                RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button("radio_add", systemImage: "plus") {
                        showAddStation = true
                    }
                    Button("radio_batch_add_title", systemImage: "square.and.arrow.down") {
                        showBatchAdd = true
                    }
                } label: {
                    Label("radio_add", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(PMColor.brand, in: .rect(cornerRadius: PMRadius.m))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Text(summaryText)
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private var summaryText: String {
        guard !stations.isEmpty else {
            return String(localized: "radio_empty_description")
        }
        var parts = [String(format: String(localized: "radio_mac_count %lld"), stations.count)]
        if let current = player.currentRadioStation,
           player.isPlaying || player.isLoading {
            parts.append(String(format: String(localized: "radio_mac_now_playing %@"), current.name))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if stations.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: PMSpace.m16) {
                    ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                        MacRadioStationCard(
                            station: station,
                            priority: index + 1,
                            isCurrent: player.currentRadioStation?.id == station.id,
                            isPlaying: player.currentRadioStation?.id == station.id
                                && (player.isPlaying || player.isLoading),
                            metadataTitle: player.currentRadioStation?.id == station.id
                                ? player.radioMetadataTitle
                                : nil,
                            canMoveUp: index > 0,
                            canMoveDown: index < stations.count - 1,
                            onPlay: { toggle(station) },
                            onEdit: { editingStation = station },
                            onDelete: { stationToDelete = station },
                            onMoveUp: { store.moveStation(id: station.id, by: -1) },
                            onMoveDown: { store.moveStation(id: station.id, by: 1) }
                        )
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: PMSpace.m14) {
            Spacer(minLength: 60)

            Image(systemName: "radio")
                .font(.system(size: 40))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 92, height: 92)
                .background(PMColor.card, in: .rect(cornerRadius: PMRadius.xxl))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }

            Text("radio_empty_title")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PMColor.text)

            Text("radio_empty_description")
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func toggle(_ station: RadioStation) {
        if let url = station.url,
           TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingInsecureStation = station
            return
        }
        performToggle(station)
    }

    private func performToggle(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            player.pause()
        } else {
            Task { await player.play(station: station, within: store.stations) }
        }
    }
}

// MARK: - Station card

private struct MacRadioStationCard: View {
    let station: RadioStation
    let priority: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let metadataTitle: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: PMSpace.m14) {
            RadioStationArtworkView(station: station, size: 64, cornerRadius: PMRadius.l)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(station.name)
                        .font(PMFont.cardTitle)
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)

                    if isPlaying {
                        HStack(spacing: 4) {
                            Circle().fill(PMColor.bad).frame(width: 5, height: 5)
                            Text(verbatim: "LIVE")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(PMColor.brand)
                        }
                    }

                    Spacer(minLength: 4)

                    Text(verbatim: "#\(priority)")
                        .font(PMFont.monoXS)
                        .foregroundStyle(PMColor.textFaint)
                }

                Text(metadataTitle ?? station.playbackSubtitle)
                    .font(PMFont.bodyS)
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.textMuted)
                    .lineLimit(1)

                Text(station.streamURL)
                    .font(PMFont.monoXS)
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            HStack(spacing: PMSpace.s) {
                // 悬停才露出管理按钮 —— 常驻会让卡片显得吵，这也是 Mac 上
                // 列表类界面的通行做法。
                if hover {
                    PMRoundBtn(icon: "arrow.up", size: PMSize.smallBtn, iconSize: 11, style: .glass) {
                        onMoveUp()
                    }
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 1 : 0.35)

                    PMRoundBtn(icon: "arrow.down", size: PMSize.smallBtn, iconSize: 11, style: .glass) {
                        onMoveDown()
                    }
                    .disabled(!canMoveDown)
                    .opacity(canMoveDown ? 1 : 0.35)

                    PMRoundBtn(icon: "pencil", size: PMSize.smallBtn, iconSize: 11, style: .glass) {
                        onEdit()
                    }
                }

                PMRoundBtn(
                    icon: isPlaying ? "stop.fill" : "play.fill",
                    size: PMSize.playBtn,
                    iconSize: 13,
                    style: isCurrent ? .accent : .glass
                ) {
                    onPlay()
                }
            }
        }
        .padding(PMSpace.m14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .pmCard(cornerRadius: PMRadius.l14)
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous)
                .strokeBorder(isCurrent ? PMColor.brand.opacity(0.55) : .clear, lineWidth: 1)
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            Button { onEdit() } label: { Label("edit", systemImage: "pencil") }
            Button { onMoveUp() } label: { Label("radio_priority_move_up", systemImage: "arrow.up") }
                .disabled(!canMoveUp)
            Button { onMoveDown() } label: { Label("radio_priority_move_down", systemImage: "arrow.down") }
                .disabled(!canMoveDown)
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("delete", systemImage: "trash")
            }
        }
    }
}
#endif
