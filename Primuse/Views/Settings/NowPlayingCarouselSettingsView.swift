#if os(iOS)
import PrimuseKit
import SwiftUI

/// 设置 › 播放器 › 转轮切换:总开关(默认关),播放器左右两侧各放哪几面、什么顺序,以及每一面里放哪几张卡片。
struct NowPlayingCarouselSettingsView: View {
    @AppStorage(NowPlayingCarouselConfiguration.enabledStorageKey)
    private var isEnabled = NowPlayingCarouselConfiguration.enabledByDefault
    @AppStorage(NowPlayingCarouselConfiguration.storageKey) private var storage = ""
    @AppStorage(NowPlayingCarouselCardSettings.storageKey) private var cardStorage = ""

    private var configuration: NowPlayingCarouselConfiguration { .decode(storage) }
    private var cardSettings: NowPlayingCarouselCardSettings { .decode(cardStorage) }

    var body: some View {
        Form {
            Section {
                NowPlayingCarouselPreview(configuration: configuration, isEnabled: isEnabled)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle("player_carousel_enabled", isOn: $isEnabled.pmAnimated())
            } footer: {
                Text("player_carousel_footer")
            }

            sideSection(.leading)
            sideSection(.trailing)

            if !configuration.unassigned.isEmpty {
                Section {
                    ForEach(configuration.unassigned) { panel in
                        HStack(spacing: 12) {
                            NowPlayingCarouselPanelIcon(panel: panel)
                            panelLabel(panel)
                            Spacer(minLength: 8)
                            Menu {
                                Button {
                                    update { $0.insert(panel, on: .leading) }
                                } label: {
                                    Label("player_carousel_add_leading", systemImage: "arrow.left.to.line")
                                }
                                .disabled(!configuration.canAdd(to: .leading))
                                Button {
                                    update { $0.insert(panel, on: .trailing) }
                                } label: {
                                    Label("player_carousel_add_trailing", systemImage: "arrow.right.to.line")
                                }
                                .disabled(!configuration.canAdd(to: .trailing))
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .accessibilityLabel(Text("player_carousel_add"))
                        }
                    }
                } header: {
                    Text("player_carousel_available")
                }
            }

            ForEach(NowPlayingCarouselPanel.allCases) { panel in
                cardSection(panel)
            }

            Section {
                Button("player_carousel_reset") {
                    update { $0 = .default }
                    withAnimation(.snappy) { cardStorage = "" }
                }
                .disabled(configuration == .default && cardSettings.isDefault)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("player_carousel_title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func panelLabel(_ panel: NowPlayingCarouselPanel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(panel.titleKey)
            Text(panel.summaryKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func sideSection(_ side: NowPlayingCarouselConfiguration.Side) -> some View {
        let panels = configuration.panels(on: side)
        Section {
            if panels.isEmpty {
                Text("player_carousel_side_empty")
                    .foregroundStyle(.secondary)
            }
            ForEach(panels) { panel in
                HStack(spacing: 12) {
                    NowPlayingCarouselPanelIcon(panel: panel)
                    panelLabel(panel)
                    Spacer(minLength: 8)
                    Menu {
                        let other: NowPlayingCarouselConfiguration.Side = side == .leading ? .trailing : .leading
                        Button {
                            update { $0.insert(panel, on: other) }
                        } label: {
                            Label(
                                other == .leading
                                    ? LocalizedStringKey("player_carousel_move_to_leading")
                                    : LocalizedStringKey("player_carousel_move_to_trailing"),
                                systemImage: other == .leading ? "arrow.left" : "arrow.right"
                            )
                        }
                        .disabled(!configuration.canAdd(to: other))
                        Button(role: .destructive) {
                            update { $0.remove(panel) }
                        } label: {
                            Label("player_carousel_remove", systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("player_carousel_more_actions"))
                }
            }
            .onMove { source, destination in
                update { $0.move(on: side, fromOffsets: source, toOffset: destination) }
            }
            .onDelete { offsets in
                let removing = offsets.compactMap { panels.indices.contains($0) ? panels[$0] : nil }
                update { configuration in removing.forEach { configuration.remove($0) } }
            }
        } header: {
            Text(side == .leading ? LocalizedStringKey("player_carousel_leading") : LocalizedStringKey("player_carousel_trailing"))
        } footer: {
            Text("player_carousel_order_hint \(NowPlayingCarouselConfiguration.maximumPanelsPerSide)")
        }
    }

    /// 一面里的卡片开关。编辑态下这些行不出删除、拖动把手(没挂 onMove / onDelete),开关照常拨。
    private func cardSection(_ panel: NowPlayingCarouselPanel) -> some View {
        Section {
            ForEach(panel.cards) { card in
                Toggle(isOn: Binding(
                    get: { cardSettings.isEnabled(card) },
                    set: { enabled in
                        var next = cardSettings
                        next.setEnabled(enabled, for: card)
                        withAnimation(.snappy) { cardStorage = next.storageValue }
                    }
                )) {
                    Label {
                        Text(card.titleKey)
                    } icon: {
                        Image(systemName: card.symbolName)
                            .foregroundStyle(panel.tint)
                    }
                }
            }
        } header: {
            Text("player_carousel_cards_header \(panel.localizedTitle)")
        } footer: {
            if panel == .sound {
                Text("player_carousel_cards_sound_footer")
            } else if panel == .stage {
                Text("player_carousel_cards_stage_footer")
            }
        }
    }

    private func update(_ change: (inout NowPlayingCarouselConfiguration) -> Void) {
        var next = configuration
        change(&next)
        withAnimation(.snappy) { storage = next.storageValue }
    }
}

private struct NowPlayingCarouselPanelIcon: View {
    let panel: NowPlayingCarouselPanel

    var body: some View {
        Image(systemName: panel.symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(panel.tint.gradient))
            .accessibilityHidden(true)
    }
}

/// 顶上的示意:播放器居中,两侧的面像立方体的侧面一样斜着排开,离播放器越远越小、越淡。
private struct NowPlayingCarouselPreview: View {
    let configuration: NowPlayingCarouselConfiguration
    let isEnabled: Bool

    var body: some View {
        let leading = Array(configuration.leading.reversed())
        let trailing = configuration.trailing
        VStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(Array(leading.enumerated()), id: \.element) { offset, panel in
                    card(panel, distance: leading.count - offset, side: -1)
                        .zIndex(Double(offset))
                }
                playerCard
                    .zIndex(10)
                ForEach(Array(trailing.enumerated()), id: \.element) { offset, panel in
                    card(panel, distance: offset + 1, side: 1)
                        .zIndex(Double(-offset))
                }
            }
            .frame(height: 140)
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.55)

            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                Text("player_carousel_preview_caption")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player_carousel_preview_caption"))
    }

    private var playerCard: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .semibold))
                    Text("player_carousel_player")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 76, height: 124)
            .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
    }

    /// `distance` 是离播放器第几面,`side` 为 -1 在左、1 在右。
    private func card(_ panel: NowPlayingCarouselPanel, distance: Int, side: Double) -> some View {
        let scale = max(0.62, 1 - Double(distance) * 0.12)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(panel.tint.gradient)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: panel.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                    Text(panel.titleKey)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 62, height: 108)
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(side * -38), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .opacity(1 - Double(distance - 1) * 0.16)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}
#endif
