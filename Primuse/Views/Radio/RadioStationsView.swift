import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RadioStationsView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @State private var editingStation: RadioStation?
    @State private var showingNewStation = false
    @State private var showingBatchAdd = false
    @State private var pendingInsecureStation: RadioStation?
    /// 管理态 —— 设计上用「先选后做」的多选替代每行一个 ⋯ 菜单。
    /// 进入即编辑态，没有中间的"看着像可选但没勾选圈"的过渡。
    @State private var isManaging = false
    @State private var selection: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var showExporter = false
    @State private var exportDocument = RadioPlaylistDocument()

    private let columns = [
        GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 16)
    ]

    private var selectedStations: [RadioStation] {
        store.stations.filter { selection.contains($0.id) && !$0.isServerMirror }
    }

    private var editableStationIDs: Set<String> {
        Set(store.stations.filter { !$0.isServerMirror }.map(\.id))
    }

    /// 管理态且有选中时，标题让位给计数 —— 批量操作藏在菜单里，选了几条
    /// 得有个地方看得见。
    private var navigationTitleText: String {
        guard isManaging, !selectedStations.isEmpty else {
            return String(localized: "radio_title")
        }
        return String(
            format: String(localized: "radio_manage_selected %lld"),
            selectedStations.count
        )
    }

    var body: some View {
        Group {
            if store.stations.isEmpty {
                ContentUnavailableView {
                    Label("radio_empty_title", systemImage: "radio")
                } description: {
                    Text("radio_empty_description")
                }
            } else if isManaging {
                manageList
            } else {
                stationGrid
            }
        }
        .navigationTitle(navigationTitleText)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingNewStation) {
            RadioStationEditorView(station: nil)
        }
        .sheet(isPresented: $showingBatchAdd) {
            RadioBatchAddView()
        }
        .sheet(item: $editingStation) { station in
            RadioStationEditorView(station: station)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .m3uPlaylist,
            defaultFilename: "primuse-radio"
        ) { _ in }
        .confirmationDialog(
            String(localized: "radio_manage_delete_confirm_title"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    format: String(localized: "radio_manage_delete_count %lld"),
                    selectedStations.count
                ),
                role: .destructive
            ) {
                deleteSelected()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("radio_manage_delete_confirm_message")
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { pendingInsecureStation != nil },
            set: { if !$0 { pendingInsecureStation = nil } }
        )) {
            Button("cancel", role: .cancel) {
                pendingInsecureStation = nil
            }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isManaging {
            ToolbarItem(placement: .cancellationAction) {
                Button("done") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isManaging = false
                        selection = []
                    }
                }
            }

            // 批量操作收进右上角菜单 —— 这个页面是 push 进 tab 里的，底部已经
            // 被系统 tab bar 和 mini player accessory 占满，任何自绘的底部条
            // 都会被盖住(mini player 是 zIndex overlay，不贡献安全区)。
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section {
                        Button {
                            if selection == editableStationIDs {
                                selection = []
                            } else {
                                selection = editableStationIDs
                            }
                        } label: {
                            Label(
                                selection == editableStationIDs
                                    ? String(localized: "radio_manage_deselect_all")
                                    : String(localized: "select_all"),
                                systemImage: selection == editableStationIDs
                                    ? "circle"
                                    : "checkmark.circle"
                            )
                        }
                        .disabled(editableStationIDs.isEmpty)
                    }

                    Section {
                        Button {
                            moveToTop(selection)
                        } label: {
                            Label("radio_manage_pin_top", systemImage: "arrow.up.to.line")
                        }
                        .disabled(selectedStations.isEmpty)

                        Button {
                            guard let station = selectedStations.first else { return }
                            editingStation = station
                        } label: {
                            Label("edit", systemImage: "pencil")
                        }
                        // 编辑是单条操作，多选时没有明确目标。
                        .disabled(selectedStations.count != 1)

                        Button {
                            exportSelected()
                        } label: {
                            Label("radio_manage_export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(selectedStations.isEmpty)
                    }

                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("delete", systemImage: "trash")
                        }
                        .disabled(selectedStations.isEmpty)
                    }
                } label: {
                    Label("radio_manage", systemImage: "ellipsis.circle")
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if !editableStationIDs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isManaging = true }
                    } label: {
                        Label("radio_manage", systemImage: "checklist")
                    }
                }

                Menu {
                    Button("radio_batch_add_title", systemImage: "square.and.arrow.down") {
                        showingBatchAdd = true
                    }
                    Button("radio_add", systemImage: "plus") {
                        showingNewStation = true
                    }
                    if !store.stations.isEmpty {
                        Divider()
                        Button("radio_priority_sort_by_name", systemImage: "arrow.up.arrow.down") {
                            store.sortStationsByName()
                        }
                    }
                } label: {
                    Label("radio_add", systemImage: "plus")
                }
            }
        }
    }

    private var stationGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(Array(store.stations.enumerated()), id: \.element.id) { index, station in
                    RadioStationCard(
                        station: station,
                        priority: index + 1,
                        isCurrent: player.currentRadioStation?.id == station.id,
                        isPlaying: player.currentRadioStation?.id == station.id
                            && (player.isPlaying || player.isLoading),
                        metadataTitle: player.currentRadioStation?.id == station.id
                            ? player.radioMetadataTitle
                            : nil,
                        canMoveUp: index > 0,
                        canMoveDown: index < store.stations.count - 1,
                        onPlay: { toggle(station) },
                        onEdit: { editingStation = station },
                        onDelete: { store.remove(id: station.id) },
                        onMoveUp: { store.moveStation(id: station.id, by: -1) },
                        onMoveDown: { store.moveStation(id: station.id, by: 1) }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - 管理态

    /// 管理态的多选列表。`editMode` 常开 —— 用户点「管理」就是来批量操作的，
    /// 再要求他去菜单里点一次「选择」才出现勾选圈，中间那个状态看着像坏了。
    /// 勾选圈、拖动柄、批量选中手势全由系统提供。
    ///
    /// 单条操作不在这里：网格态的卡片自带 ⋯ 菜单(编辑/上移/下移/删除)，
    /// 所以这一屏可以专心做多选，不必再兼顾左右滑 —— 编辑态下系统本来也会
    /// 吞掉滑动手势。
    private var manageList: some View {
        List(selection: $selection) {
            Section {
                ForEach(store.stations) { station in
                    manageRow(station: station)
                        .tag(station.id)
                        .selectionDisabled(station.isServerMirror)
                        .deleteDisabled(station.isServerMirror)
                }
                .onMove(perform: store.moveStations)
                .onDelete { offsets in
                    let ordered = store.stations
                    for index in offsets where ordered.indices.contains(index) {
                        store.remove(id: ordered[index].id)
                    }
                }
            } footer: {
                Text("radio_manage_footer")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func manageRow(station: RadioStation) -> some View {
        HStack(spacing: 12) {
            RadioStationArtworkView(station: station, size: 52, cornerRadius: 11)

            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(station.playbackSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(station.displayEndpoint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
    }

    /// 置顶保持选中项之间的相对顺序，其余的原样跟在后面。
    private func moveToTop(_ ids: Set<String>) {
        let ordered = store.stations
        let picked = ordered.filter { ids.contains($0.id) && !$0.isServerMirror }
        guard !picked.isEmpty else { return }
        let pickedIDs = Set(picked.map(\.id))
        let rest = ordered.filter { !pickedIDs.contains($0.id) }
        store.applyOrder((picked + rest).map(\.id))
    }

    private func exportSelected() {
        let stations = selectedStations
        guard !stations.isEmpty else { return }
        exportDocument = RadioPlaylistDocument(stations: stations)
        showExporter = true
    }

    private func deleteSelected() {
        for station in selectedStations { store.remove(id: station.id) }
        selection = []
    }

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
            SiriMediaInteractionDonor.donate(station: station)
            Task { await player.play(station: station, within: store.stations) }
        }
    }
}

/// 导出选中电台为 `.m3u`。带 `#EXTINF` 名字，导回来时 `RadioImportParser` 能还原。
struct RadioPlaylistDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.m3uPlaylist, .plainText] }

    var stations: [RadioStation]

    init(stations: [RadioStation] = []) {
        self.stations = stations
    }

    init(configuration: ReadConfiguration) throws {
        stations = []
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var lines = ["#EXTM3U"]
        for station in stations {
            lines.append("#EXTINF:-1,\(station.name)")
            lines.append(station.streamURL)
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// 系统没有内建 m3u 的常量；从扩展名解析，解不到就退回纯文本。
    static var m3uPlaylist: UTType {
        UTType(filenameExtension: "m3u") ?? .plainText
    }
}


private struct RadioStationCard: View {
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

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    RadioStationArtworkView(station: station, size: 72, cornerRadius: 16)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(station.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if station.isServerMirror {
                                Image(systemName: "server.rack")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text("#\(priority)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if isCurrent {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                Text("LIVE")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        Text(metadataTitle ?? station.playbackSubtitle)
                            .font(.caption)
                            .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                            .lineLimit(2)

                        Text(station.displayEndpoint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(.thinMaterial, in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                managementActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("radio_manage")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            isCurrent ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.1), lineWidth: 0.7)
        }
        .contextMenu {
            managementActions
        }
    }

    @ViewBuilder
    private var managementActions: some View {
        if station.isServerMirror {
            Label(station.displayEndpoint, systemImage: "server.rack")
                .foregroundStyle(.secondary)
        } else {
            Button("edit", systemImage: "pencil", action: onEdit)
        }
        Button("radio_priority_move_up", systemImage: "arrow.up", action: onMoveUp)
            .disabled(!canMoveUp)
        Button("radio_priority_move_down", systemImage: "arrow.down", action: onMoveDown)
            .disabled(!canMoveDown)
        if !station.isServerMirror {
            Divider()
            Button("delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

struct RadioStationArtworkView: View {
    let station: RadioStation
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let data = station.logoData, let image = PlatformRadioImage(data: data) {
                Image(platformRadioImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RadioStationPlaceholderArtwork()
                    if station.logoFileName?.isEmpty == false {
                        CachedArtworkView(
                            coverRef: station.logoFileName,
                            songID: station.playbackSong.id,
                            size: size,
                            cornerRadius: 0,
                            sourceID: station.sourceID,
                            filePath: station.sourcePlaybackPath ?? station.streamURL,
                            fileFormat: station.streamFormat.audioFormat,
                            placeholderIcon: "radio.fill",
                            showsPlaceholder: false
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 无台标时用当前主题色构成单色信号场，避免固定紫蓝色从整套外观里跳出来。
/// 同心环只承担“广播信号”的识别，不参与播放状态表达。
struct RadioStationPlaceholderArtwork: View {
    @Environment(ThemeService.self) private var theme

    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 1)

            ZStack {
                theme.uiDarkAccent

                LinearGradient(
                    colors: [
                        theme.uiAccentColor.opacity(0.82),
                        theme.uiAccentColor.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: max(1, side * 0.008))
                    .frame(width: side * 0.82, height: side * 0.82)

                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: max(1, side * 0.009))
                    .frame(width: side * 0.58, height: side * 0.58)

                Image(systemName: "radio.fill")
                    .font(.system(size: side * 0.31, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RadioStationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player

    let station: RadioStation?
    @State private var name: String
    @State private var urlString: String
    @State private var logoData: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var resultMessage: String?
    @State private var insecureHTTPHost: String?
    @State private var pendingTestAfterTrust = false

    init(station: RadioStation?) {
        self.station = station
        _name = State(initialValue: station?.name ?? "")
        _urlString = State(initialValue: station?.streamURL ?? "")
        _logoData = State(initialValue: station?.logoData)
    }

    private var canSave: Bool {
        RadioStationValidation.isValid(name: name, urlString: urlString) && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("radio_details") {
                    TextField("radio_name", text: $name)
                    TextField("radio_stream_url", text: $urlString)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }

                Section("radio_logo_optional") {
                    HStack(spacing: 16) {
                        RadioEditorArtwork(data: logoData)
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("radio_choose_logo", systemImage: "photo")
                            }
                            if logoData != nil {
                                Button("radio_remove_logo", role: .destructive) {
                                    pickerItem = nil
                                    logoData = nil
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        beginTest()
                    } label: {
                        HStack {
                            Label("radio_test_playback", systemImage: "waveform")
                            Spacer()
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!canSave || isTesting)

                    if let resultMessage {
                        Text(resultMessage)
                            .font(.caption)
                            .foregroundStyle(resultMessage == String(localized: "radio_test_success") ? .green : .secondary)
                    }
                } footer: {
                    Text("radio_test_description")
                }
            }
            .navigationTitle(station == nil ? "radio_add" : "radio_edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { save() }
                        .disabled(!canSave)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let processed = RadioLogoProcessor.process(data) else {
                        resultMessage = String(localized: "radio_logo_invalid")
                        return
                    }
                    logoData = processed
                }
            }
            .alert("insecure_http_warning_title", isPresented: Binding(
                get: { insecureHTTPHost != nil },
                set: { if !$0 { insecureHTTPHost = nil; pendingTestAfterTrust = false } }
            )) {
                Button("cancel", role: .cancel) {
                    insecureHTTPHost = nil
                    pendingTestAfterTrust = false
                }
                Button("insecure_http_continue", role: .destructive) {
                    guard let host = insecureHTTPHost else { return }
                    SSLTrustStore.shared.allowInsecureHTTP(domain: host)
                    insecureHTTPHost = nil
                    if pendingTestAfterTrust {
                        pendingTestAfterTrust = false
                        runTest()
                    }
                }
            } message: {
                Text(String(format: String(localized: "insecure_http_warning_message %@"), insecureHTTPHost ?? ""))
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 470)
        #endif
    }

    private func beginTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingTestAfterTrust = true
            insecureHTTPHost = trustTarget
            return
        }
        runTest()
    }

    private func runTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        isTesting = true
        resultMessage = nil
        Task {
            let result = await player.testRadioStream(url: url)
            isTesting = false
            switch result {
            case .success:
                resultMessage = String(localized: "radio_test_success")
            case .failure(let error):
                resultMessage = String(format: String(localized: "radio_test_failed %@"), error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let normalizedURL = RadioStationValidation.normalizedURLString(urlString) else { return }
        isSaving = true
        Task {
            let id = station?.id ?? UUID().uuidString
            let logoFileName: String?
            if let logoData {
                logoFileName = await MetadataAssetStore.shared.storeCover(logoData, for: "radio:\(id)")
            } else {
                logoFileName = nil
            }
            let value = RadioStation(
                id: id,
                name: RadioStationValidation.normalizedName(name),
                streamURL: normalizedURL,
                logoData: logoData,
                logoFileName: logoFileName,
                streamFormat: station?.streamFormat ?? RadioStreamFormat.inferred(from: URL(string: normalizedURL)!),
                bitRate: station?.bitRate,
                createdAt: station?.createdAt ?? Date(),
                modifiedAt: Date(),
                lastPlayedAt: station?.lastPlayedAt,
                sortOrder: station?.sortOrder
            )
            store.upsert(value)
            isSaving = false
            dismiss()
        }
    }
}

private struct RadioEditorArtwork: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = PlatformRadioImage(data: data) {
                Image(platformRadioImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "radio")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum RadioLogoProcessor {
    static func process(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        let maxDimension: CGFloat = 512
        let scale = min(1, maxDimension / max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(width, height) * scale),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              output.length <= RadioStationValidation.maximumLogoBytes else { return nil }
        return output as Data
    }
}

#if os(iOS)
private typealias PlatformRadioImage = UIImage

private extension Image {
    init(platformRadioImage image: UIImage) { self.init(uiImage: image) }
}
#elseif os(macOS)
private typealias PlatformRadioImage = NSImage

private extension Image {
    init(platformRadioImage image: NSImage) { self.init(nsImage: image) }
}
#endif
