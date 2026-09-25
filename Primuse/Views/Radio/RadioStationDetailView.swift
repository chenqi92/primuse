import SwiftUI
import PrimuseKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 电台详情：大台标、台名、文件夹与标签、格式码率、「收听」，
/// 这个台「刚播过」的标题，以及置顶/移到文件夹/编辑/复制流地址/分享。
///
/// 按 id 取电台而不是拿一份快照：在这里改了文件夹、编辑了台名，页面跟着变；
/// 电台在别处被删掉了，页面收起。电台页、首页电台条、Mac 电台页共用这一页。
struct RadioStationDetailView: View {
    let stationID: String

    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var pendingInsecureStation: RadioStation?
    @State private var editingStation: RadioStation?
    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showsCopiedConfirmation = false
    @State private var showsClearHistoryConfirm = false

    var body: some View {
        // 工具栏条目里不读环境（导航过渡时会读不到），关闭动作在这里先取出来。
        let close = dismiss
        return NavigationStack {
            Group {
                if let station = store.station(id: stationID), !station.isDeleted {
                    content(station)
                } else {
                    // 电台在别处被删掉了。
                    ContentUnavailableView {
                        Label("radio_empty_title", systemImage: "radio")
                    } description: {
                        Text("radio_detail_missing")
                    }
                }
            }
            .navigationTitle(Text("radio_details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { close() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 600, idealHeight: 680)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .radioInsecureStationAlert(pending: $pendingInsecureStation) { station in
            RadioStationPlaybackAction.toggle(station, player: player, within: store.stations)
        }
        .sheet(item: $editingStation) { station in
            #if os(macOS)
            MacRadioStationEditorView(station: station) { own in editingStation = own }
            #else
            RadioStationEditorView(station: station) { own in editingStation = own }
            #endif
        }
        .alert(String(localized: "radio_folder_new"), isPresented: $showingNewFolderPrompt) {
            TextField(String(localized: "radio_folder_name"), text: $newFolderName)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
            Button("cancel", role: .cancel) {}
            Button("save") {
                guard let name = store.createFolder(newFolderName) else { return }
                store.setFolder(name, forStationIDs: [stationID])
            }
        }
        .confirmationDialog(
            String(localized: "radio_detail_heard_clear_title"),
            isPresented: $showsClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("clear", role: .destructive) {
                RadioTitleHistoryStore.shared.clear(stationID: stationID)
            }
            Button("cancel", role: .cancel) {}
        }
    }

    // MARK: - 内容

    private func content(_ station: RadioStation) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                header(station)
                listenButton(station)
                actionsGroup(station)
                heardSection(station)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ station: RadioStation) -> some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isActive = RadioStationPlaybackAction.isActive(station, player: player)
        // 正在播时用播放器探到的格式与码率 —— 比电台记录里存的更新。
        let format = isCurrent ? player.radioStreamFormat : station.streamFormat
        let bitRate = isCurrent ? (player.radioBitRate ?? station.bitRate) : station.bitRate

        return VStack(spacing: 12) {
            Color.clear
                .frame(width: 168, height: 168)
                .overlay {
                    RadioStationArtworkContent(station: station, decodeSize: 168, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)

            Text(station.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if isActive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(RadioSpacePalette.accent)
                        .frame(width: 6, height: 6)
                    Text(player.radioMetadataTitle ?? String(localized: "live_badge"))
                        .font(.subheadline)
                        .foregroundStyle(RadioSpacePalette.accent)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .pmFadeTransition(motion: .contentAppear)
            }

            organizeLine(station)

            let facts = streamFacts(format: format, bitRate: bitRate)
            if !facts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(facts, id: \.self) { fact in
                        Text(verbatim: fact)
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Text(RadioSubscriptionText.stationSource(station) ?? station.displayEndpoint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .pmAnimation(.contentAppear, value: isActive)
    }

    /// 文件夹 + 标签一行。没归类时显示「未分组」，让用户知道可以归类。
    private func organizeLine(_ station: RadioStation) -> some View {
        HStack(spacing: 6) {
            Label(
                station.assignedFolderName ?? String(localized: "radio_folder_ungrouped"),
                systemImage: station.assignedFolderName == nil ? "tray" : "folder.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            ForEach(station.assignedTagNames.prefix(4), id: \.self) { tag in
                Text(tag)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RadioTagPalette.color(for: tag))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RadioTagPalette.color(for: tag).opacity(0.14), in: Capsule())
                    .lineLimit(1)
            }
        }
    }

    private func streamFacts(format: RadioStreamFormat, bitRate: Int?) -> [String] {
        var facts: [String] = []
        if format != .automatic { facts.append(format.displayName) }
        if let bitRate, bitRate > 0 { facts.append("\(bitRate / 1_000) kbps") }
        return facts
    }

    private func listenButton(_ station: RadioStation) -> some View {
        let isActive = RadioStationPlaybackAction.isActive(station, player: player)
        return Button {
            if !isActive, RadioStationPlaybackAction.requiresInsecureApproval(station) {
                pendingInsecureStation = station
            } else {
                RadioStationPlaybackAction.toggle(station, player: player, within: store.stations)
            }
        } label: {
            Group {
                if isActive {
                    Label("radio_stop", systemImage: "stop.fill")
                } else {
                    Label("radio_detail_listen", systemImage: "play.fill")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: 320)
            .frame(height: 48)
            .background(RadioSpacePalette.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pmPressable)
        .pmAnimation(.control, value: isActive)
    }

    // MARK: - 操作

    private func actionsGroup(_ station: RadioStation) -> some View {
        let priority = store.priorityByID[station.id] ?? 1
        return VStack(spacing: 0) {
            if priority > 1 {
                actionRow("radio_manage_pin_top", systemImage: "arrow.up.to.line") {
                    pmWithAnimation(.list) { store.moveToTop(ids: [station.id]) }
                }
            } else {
                actionRow("radio_detail_pinned", systemImage: "checkmark", isEnabled: false) {}
            }

            divider

            Menu {
                folderMenu(station)
            } label: {
                actionLabel("radio_folder_move", systemImage: "folder")
            }
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.button)
            #endif
            .buttonStyle(.plain)

            if !station.isServerMirror {
                divider
                actionRow("radio_edit", systemImage: "pencil") {
                    editingStation = station
                }

                divider
                actionRow(
                    showsCopiedConfirmation
                        ? LocalizedStringKey("Copied")
                        : LocalizedStringKey("radio_detail_copy_stream_url"),
                    systemImage: showsCopiedConfirmation ? "checkmark" : "doc.on.doc"
                ) {
                    copyStreamURL(station)
                }

                if let url = station.url {
                    divider
                    ShareLink(item: url, subject: Text(station.name), message: Text(station.name)) {
                        actionLabel("share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private func folderMenu(_ station: RadioStation) -> some View {
        Button("radio_folder_new", systemImage: "folder.badge.plus") {
            newFolderName = ""
            showingNewFolderPrompt = true
        }
        let folders = store.folders
        if !folders.isEmpty {
            Divider()
            ForEach(folders) { folder in
                let isCurrent = station.assignedFolderName.map {
                    RadioStationOrganization.isSameName($0, folder.name)
                } ?? false
                Button {
                    store.setFolder(folder.name, forStationIDs: [station.id])
                } label: {
                    Label(folder.name, systemImage: isCurrent ? "checkmark" : "folder")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        if station.assignedFolderName != nil {
            Divider()
            Button("radio_folder_remove_from", systemImage: "tray") {
                store.setFolder(nil, forStationIDs: [station.id])
            }
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 48)
    }

    private func actionRow(
        _ key: LocalizedStringKey,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(key, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private func actionLabel(_ key: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RadioSpacePalette.accent)
                .frame(width: 22)
            Text(key)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }

    private func copyStreamURL(_ station: RadioStation) {
        #if os(iOS)
        UIPasteboard.general.string = station.streamURL
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(station.streamURL, forType: .string)
        #endif
        pmWithAnimation(.control) { showsCopiedConfirmation = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            pmWithAnimation(.control) { showsCopiedConfirmation = false }
        }
    }

    // MARK: - 刚播过

    private func heardSection(_ station: RadioStation) -> some View {
        let entries = RadioTitleHistoryStore.shared.entries(forStationID: station.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("radio_detail_heard_title")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !entries.isEmpty {
                    Button("clear") { showsClearHistoryConfirm = true }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(RadioSpacePalette.accent)
                }
            }

            if entries.isEmpty {
                Text("radio_detail_heard_empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        heardRow(entry)
                    }
                }
                .padding(.horizontal, 14)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }

    private func heardRow(_ entry: RadioHeardTitle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = entry.title, let artist = entry.artist {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(entry.text)
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(Self.timeText(entry.heardAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// 今天的只写时刻；更早的带上日期。
    private static func timeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
