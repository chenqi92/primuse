import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 批量添加电台 —— 把「粘贴一串 URL」「导入 m3u/pls」「在线目录搜索」三条路
/// 收进一个页面。三者产出同一种 `RadioImportCandidate` 列表，用户在同一张表上
/// 勾选后一次性入库。
///
/// 判重和合法性在解析阶段就算好并显示出来(可用 / 重复 / 无效)，默认只勾"可用"的。
/// 添加完成后逐个后台试连，失败的把码率清空，不阻塞用户。
struct RadioBatchAddView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    #endif

    /// 只有 iOS 的叠加式 mini player 需要列表自己让位；macOS 不走这条路径，沿用原值。
    private var bottomChromeClearance: CGFloat {
        #if os(iOS)
        let overlayActive = legacyBottomChromeOverlayActive
        #else
        let overlayActive = true
        #endif
        return BottomChromeClearancePolicy.clearance(
            legacyOverlayActive: overlayActive,
            legacy: 120,
            baseline: 16
        )
    }

    private enum Entry: String, CaseIterable, Identifiable {
        case paste, file, url, directory

        var id: String { rawValue }

        var titleKey: String.LocalizationValue {
            switch self {
            case .paste: return "radio_batch_entry_paste"
            case .file: return "radio_batch_entry_file"
            case .url: return "radio_batch_entry_url"
            case .directory: return "radio_batch_entry_directory"
            }
        }

        var icon: String {
            switch self {
            case .paste: return "doc.on.clipboard"
            case .file: return "doc.text"
            case .url: return "link"
            case .directory: return "globe"
            }
        }
    }

    /// 这一批电台归到哪里。`manifestGroups` 是清单自带的 `group-title` /
    /// `#EXTGRP:` —— 一份几百条的清单，它自己的分组比任何事后整理都准。
    private enum ImportDestination: Hashable {
        case ungrouped
        case manifestGroups
        case folder(String)
    }

    @State private var entry: Entry = .paste
    @State private var pastedText = ""
    @State private var candidates: [RadioImportCandidate] = []
    @State private var selection: Set<RadioImportCandidate.ID> = []
    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var directoryQuery = ""
    @State private var isSearchingDirectory = false
    @State private var directorySearched = false
    /// 这一批导进哪个文件夹。批量导入正是电台数量失控的起点，所以归类要在
    /// 这一步就能定，而不是导完再一个个挑出来。
    @State private var destination: ImportDestination = .ungrouped
    @State private var showFolderNamePrompt = false
    @State private var folderNameDraft = ""
    @State private var playlistURLString = ""
    @State private var isFetchingPlaylist = false
    @State private var insecurePlaylistHost: String?
    /// 当前结果表是从哪个清单地址取回的。只有「清单链接」这条路有它 ——
    /// 粘贴、文件和在线目录没有可以回头再取的地址，也就没法订阅。
    @State private var fetchedPlaylistURL: String?
    @State private var subscribesToList = false
    @State private var showingManagedSubscription = false

    private var playableCount: Int {
        candidates.filter(\.isPlayable).count
    }

    // MARK: - 订阅状态

    private var subscriptionListURL: String? {
        entry == .url ? fetchedPlaylistURL : nil
    }

    /// 这个地址已经订阅过了。
    private var existingSubscription: RadioSubscription? {
        subscriptionListURL
            .flatMap(RadioSubscriptionIdentity.subscriptionID(listURL:))
            .flatMap { RadioSubscriptionsStore.shared.subscription(id: $0) }
    }

    /// 清单里唯一有效条目的数量，订阅上限按它算。
    private var uniqueValidEntryCount: Int {
        Set(candidates.compactMap { candidate in
            candidate.status == .invalid ? nil : RadioImportParser.streamIdentityKey(candidate.urlString)
        }).count
    }

    private var showsSubscriptionCard: Bool {
        subscriptionListURL != nil && uniqueValidEntryCount > 0
    }

    /// 这一次是「订阅并添加」而不是一次性导入。
    private var isSubscribing: Bool {
        subscribesToList
            && showsSubscriptionCard
            && existingSubscription == nil
            && uniqueValidEntryCount <= RadioSubscriptionMergePolicy.maximumEntries
    }

    /// 订阅时「重复」的条目不可勾选：它们要么已在电台库，要么是清单里的重复行。
    private func isSelectable(_ candidate: RadioImportCandidate) -> Bool {
        switch candidate.status {
        case .invalid: return false
        case .duplicate: return !isSubscribing
        case .playable: return true
        }
    }

    private var duplicateCount: Int {
        candidates.filter { $0.status == .duplicate }.count
    }

    private var invalidCount: Int {
        candidates.filter { $0.status == .invalid }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                entryPicker

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch entry {
                        case .paste: pasteInput
                        case .file: fileInput
                        case .url: urlInput
                        case .directory: directoryInput
                        }

                        if !candidates.isEmpty {
                            if showsSubscriptionCard {
                                subscriptionCard
                            }
                            resultHeader
                            candidateList
                        }
                    }
                    .padding(16)
                    .padding(.bottom, bottomChromeClearance)
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
            .navigationTitle("radio_batch_add_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .disabled(isAdding)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: playlistContentTypes
            ) { result in
                handlePickedFile(result)
            }
            .alert(
                String(localized: "radio_batch_error_title"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingManagedSubscription) {
                if let id = existingSubscription?.id {
                    RadioSubscriptionDetailSheet(subscriptionID: id)
                }
            }
            .onChange(of: subscribesToList) { _, isOn in
                // 打开订阅时把不可勾选的「重复」条目从已选里拿掉。
                guard isOn else { return }
                let selectable = Set(candidates.filter(isSelectable).map(\.id))
                selection.formIntersection(selectable)
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    // MARK: - 入口切换

    private var entryPicker: some View {
        HStack(spacing: 8) {
            ForEach(Entry.allCases) { item in
                Button {
                    guard entry != item else { return }
                    entry = item
                    // 换入口就清空上一批结果，避免用户以为新结果里还混着旧的。
                    candidates = []
                    selection = []
                    directorySearched = false
                    fetchedPlaylistURL = nil
                    subscribesToList = false
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19))
                        Text(String(localized: item.titleKey))
                            .font(.caption2.weight(entry == item ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(entry == item ? Color.accentColor : .secondary)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(entry == item ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        entry == item ? Color.accentColor.opacity(0.5) : .clear,
                                        lineWidth: 1
                                    )
                            }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 粘贴

    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("radio_batch_paste_hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $pastedText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if pastedText.isEmpty {
                        Text(verbatim: "https://ice5.somafm.com/groovesalad-128")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: pastedText) { _, newValue in
                    reparse(newValue)
                }

            HStack(spacing: 12) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("radio_batch_paste_from_clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                if !pastedText.isEmpty {
                    Button(role: .destructive) {
                        pastedText = ""
                        candidates = []
                        selection = []
                    } label: {
                        Label("radio_batch_clear", systemImage: "xmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - 文件

    private var fileInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("radio_batch_file_hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                showFileImporter = true
            } label: {
                Label("radio_batch_pick_file", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    private var playlistContentTypes: [UTType] {
        // m3u / m3u8 / pls 没有统一的系统 UTType，audio playlist 覆盖前两者，
        // 纯文本兜住 pls 和被网盘改过 MIME 的文件。
        var types: [UTType] = [.text, .plainText, .data]
        if let m3u = UTType(filenameExtension: "m3u") { types.insert(m3u, at: 0) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.insert(m3u8, at: 0) }
        if let pls = UTType(filenameExtension: "pls") { types.insert(pls, at: 0) }
        return types
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            // 文件选择器给的是沙箱外的 URL，必须开安全作用域才读得到。
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = RadioPlaylistText.decode(data) else {
                    errorMessage = String(localized: "radio_batch_file_unreadable")
                    return
                }
                reparse(text)
                if candidates.isEmpty {
                    errorMessage = String(localized: "radio_batch_file_no_entries")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 清单链接

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("radio_batch_url_hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(
                    text: $playlistURLString,
                    prompt: Text(verbatim: "https://example.com/radio.m3u")
                ) {
                    Text("radio_batch_entry_url")
                }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    #endif
                    .onSubmit { fetchPlaylist() }

                Button {
                    fetchPlaylist()
                } label: {
                    if isFetchingPlaylist {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("radio_batch_url_fetch")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isFetchingPlaylist || playlistURLString.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
            }
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { insecurePlaylistHost != nil },
            set: { if !$0 { insecurePlaylistHost = nil } }
        )) {
            Button("cancel", role: .cancel) { insecurePlaylistHost = nil }
            Button("insecure_http_continue", role: .destructive) {
                guard let host = insecurePlaylistHost else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: host)
                insecurePlaylistHost = nil
                fetchPlaylist()
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                insecurePlaylistHost ?? ""
            ))
        }
    }

    private func fetchPlaylist() {
        guard !isFetchingPlaylist else { return }
        let address = playlistURLString
        isFetchingPlaylist = true
        Task {
            defer { isFetchingPlaylist = false }
            do {
                let text = try await RadioPlaylistDownloader.fetch(address)
                reparse(text)
                fetchedPlaylistURL = RadioStationValidation.normalizedURLString(address)
                subscribesToList = false
                if candidates.isEmpty {
                    errorMessage = String(localized: "radio_batch_file_no_entries")
                }
            } catch let error as TrustedHTTPTransportError {
                // 明文 http 的清单地址跟电台流一样，得先问过用户再连。
                guard case .permissionRequired(let host) = error else {
                    errorMessage = error.localizedDescription
                    return
                }
                insecurePlaylistHost = host
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 订阅卡片

    private var subscriptionCard: some View {
        RadioSubscriptionOfferCard(
            existingSubscription: existingSubscription,
            entryCount: uniqueValidEntryCount,
            isOn: $subscribesToList,
            onManage: { showingManagedSubscription = true }
        )
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSubscribing ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSubscribing ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.12),
                            lineWidth: 0.8
                        )
                }
        }
    }

    // MARK: - 在线目录

    private var directoryInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("radio_batch_directory_hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(String(localized: "radio_batch_directory_placeholder"), text: $directoryQuery)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit { Task { await searchDirectory() } }

                Button {
                    Task { await searchDirectory() }
                } label: {
                    if isSearchingDirectory {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    isSearchingDirectory
                        || directoryQuery.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }

            if directorySearched, candidates.isEmpty, !isSearchingDirectory {
                Text("radio_batch_directory_empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func searchDirectory() async {
        let query = directoryQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isSearchingDirectory else { return }
        isSearchingDirectory = true
        defer { isSearchingDirectory = false }

        do {
            let results = try await RadioDirectoryClient.search(name: query)
            directorySearched = true
            applyCandidates(
                RadioDirectoryClient.candidates(from: results, existing: store.stations)
            )
        } catch {
            directorySearched = true
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 结果表

    private var resultHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    statusPill(count: playableCount, key: "radio_batch_status_playable", tint: .green)
                    if duplicateCount > 0 {
                        statusPill(count: duplicateCount, key: "radio_batch_status_duplicate", tint: .orange)
                    }
                    if invalidCount > 0 {
                        statusPill(count: invalidCount, key: "radio_batch_status_invalid", tint: .red)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    selectAllPlayable()
                } label: {
                    Text("radio_batch_select_playable")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(playableCount == 0)
            }

            importFolderPicker
        }
    }

    /// 清单自带的分组名，按出现顺序去重。
    private var manifestGroups: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in candidates {
            guard let group = candidate.groupTitle else { continue }
            guard seen.insert(RadioStationOrganization.comparisonKey(group)).inserted else { continue }
            result.append(group)
        }
        return result
    }

    private var destinationLabel: String {
        switch destination {
        case .ungrouped: return String(localized: "radio_folder_ungrouped")
        case .manifestGroups: return String(localized: "radio_batch_import_by_group")
        case .folder(let name): return name
        }
    }

    private var destinationIcon: String {
        switch destination {
        case .ungrouped: return "tray"
        case .manifestGroups: return "square.grid.3x1.folder.badge.plus"
        case .folder: return "folder"
        }
    }

    private var importFolderPicker: some View {
        HStack(spacing: 6) {
            Text("radio_batch_import_into")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                let groups = manifestGroups
                if !groups.isEmpty {
                    Button {
                        destination = .manifestGroups
                    } label: {
                        Label(
                            String(
                                format: String(localized: "radio_batch_import_by_group_count %lld"),
                                groups.count
                            ),
                            systemImage: "square.grid.3x1.folder.badge.plus"
                        )
                    }
                    Divider()
                }
                Button("radio_folder_ungrouped", systemImage: "tray") {
                    destination = .ungrouped
                }
                if !store.folders.isEmpty {
                    Divider()
                    ForEach(store.folders) { folder in
                        Button(folder.name, systemImage: "folder") {
                            destination = .folder(folder.name)
                        }
                    }
                }
                Divider()
                Button("radio_folder_new", systemImage: "folder.badge.plus") {
                    folderNameDraft = ""
                    showFolderNamePrompt = true
                }
            } label: {
                Label(destinationLabel, systemImage: destinationIcon)
                    .font(.caption.weight(.semibold))
            }

            Spacer(minLength: 0)
        }
        .alert("radio_folder_new", isPresented: $showFolderNamePrompt) {
            TextField("radio_folder_name", text: $folderNameDraft)
            Button("cancel", role: .cancel) {}
            Button("save") {
                guard let name = store.createFolder(folderNameDraft) else { return }
                destination = .folder(name)
            }
        }
    }

    /// 一条候选最终进哪个文件夹。
    private func folderName(for candidate: RadioImportCandidate) -> String? {
        switch destination {
        case .ungrouped: return nil
        case .manifestGroups: return candidate.groupTitle
        case .folder(let name): return name
        }
    }

    private func statusPill(count: Int, key: String.LocalizationValue, tint: Color) -> some View {
        Text("\(count) \(String(localized: key))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var candidateList: some View {
        // 订阅时要分清「已在电台库」和清单里自己的重复行，库里的判重键算一次就够。
        let libraryKeys = isSubscribing
            ? Set(store.stations.compactMap { RadioImportParser.streamIdentityKey($0.streamURL) })
            : []
        return VStack(spacing: 8) {
            ForEach(candidates) { candidate in
                candidateRow(candidate, libraryKeys: libraryKeys)
            }
        }
    }

    private func candidateRow(_ candidate: RadioImportCandidate, libraryKeys: Set<String>) -> some View {
        let isSelected = selection.contains(candidate.id)
        let selectable = isSelectable(candidate)
        let inLibrary = isSubscribing
            && candidate.status == .duplicate
            && RadioImportParser.streamIdentityKey(candidate.urlString).map { libraryKeys.contains($0) } == true

        return Button {
            toggle(candidate)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

                RadioCandidateLogoView(urlString: candidate.logoURLString, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(candidate.urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let group = candidate.groupTitle {
                        Label(group, systemImage: "folder")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let duplicateOfName = candidate.duplicateOfName {
                        Text(String(
                            format: String(localized: "radio_batch_duplicate_of %@"),
                            duplicateOfName
                        ))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Text(inLibrary
                     ? String(localized: "radio_subscription_in_library")
                     : statusLabel(candidate.status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTint(candidate.status))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusTint(candidate.status).opacity(0.14), in: Capsule())
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.12),
                                lineWidth: 0.8
                            )
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .opacity(selectable ? 1 : 0.55)
    }

    private func statusLabel(_ status: RadioImportCandidate.Status) -> String {
        switch status {
        case .playable: return String(localized: "radio_batch_status_playable")
        case .duplicate: return String(localized: "radio_batch_status_duplicate")
        case .invalid: return String(localized: "radio_batch_status_invalid")
        }
    }

    private func statusTint(_ status: RadioImportCandidate.Status) -> Color {
        switch status {
        case .playable: return .green
        case .duplicate: return .orange
        case .invalid: return .red
        }
    }

    // MARK: - 底部添加

    private var addButtonTitle: String {
        if isSubscribing {
            // 订阅时一个都不勾也可以：以后清单新增的照样会加进来。
            return selection.isEmpty
                ? String(localized: "radio_subscription_subscribe_only")
                : String(format: String(localized: "radio_subscription_add_count %lld"), selection.count)
        }
        return selection.isEmpty
            ? String(localized: "radio_batch_add_none")
            : String(format: String(localized: "radio_batch_add_count %lld"), selection.count)
    }

    private var addBar: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    if isSubscribing {
                        await subscribeSelected()
                    } else {
                        await addSelected()
                    }
                }
            } label: {
                Group {
                    if isAdding {
                        ProgressView()
                    } else {
                        Label(
                            addButtonTitle,
                            systemImage: isSubscribing ? "arrow.triangle.2.circlepath" : "plus.circle"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .disabled((selection.isEmpty && !isSubscribing) || isAdding)

            Text("radio_batch_add_footer")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: - 动作

    private func pasteFromClipboard() {
        #if os(iOS)
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            errorMessage = String(localized: "radio_batch_clipboard_empty")
            return
        }
        #elseif os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            errorMessage = String(localized: "radio_batch_clipboard_empty")
            return
        }
        #else
        let text = ""
        #endif
        pastedText = text
        reparse(text)
    }

    private func reparse(_ text: String) {
        applyCandidates(RadioImportParser.parse(text, existing: store.stations))
    }

    /// 换一批结果就重置勾选 —— 默认只勾可用的，重复/无效留给用户主动决定。
    private func applyCandidates(_ next: [RadioImportCandidate]) {
        candidates = next
        selection = Set(next.filter(\.isPlayable).map(\.id))

        // 清单自带分组时默认就按它分，这是用户想要的结果里最可能的那个；
        // 换了一批没有分组的清单，再退回不分组，免得标签停在一个空选项上。
        let hasGroups = next.contains { $0.groupTitle != nil }
        switch destination {
        case .ungrouped where hasGroups:
            destination = .manifestGroups
        case .manifestGroups where !hasGroups:
            destination = .ungrouped
        default:
            break
        }
    }

    private func toggle(_ candidate: RadioImportCandidate) {
        guard isSelectable(candidate) else { return }
        if selection.contains(candidate.id) {
            selection.remove(candidate.id)
        } else {
            selection.insert(candidate.id)
        }
    }

    private func selectAllPlayable() {
        selection = Set(candidates.filter(\.isPlayable).map(\.id))
    }

    private func addSelected() async {
        guard !isAdding else { return }
        isAdding = true
        defer { isAdding = false }

        let chosen = candidates.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }

        var added: [RadioStation] = []
        for candidate in chosen {
            let station = RadioStation(
                name: candidate.name,
                streamURL: candidate.urlString,
                streamFormat: URL(string: candidate.urlString)
                    .map { RadioStreamFormat.inferred(from: $0) } ?? .automatic,
                homepageURL: candidate.homepageURLString,
                remoteLogoURL: candidate.logoURLString,
                remoteLogoSource: candidate.logoSource,
                folderName: folderName(for: candidate)
            )
            store.upsert(station)
            added.append(station)
        }
        // 清单分组也记进文件夹清单，这样即使用户随后把里面的台都移走，
        // 文件夹本身还在。
        for name in Set(added.compactMap(\.folderName)) {
            store.createFolder(name)
        }

        dismiss()
        // 试连放在关页之后跑：探测每个流要几秒，用户没必要为此等在这一屏。
        // 探测本身只用来把明确失败的流标出来，不改动用户已确认的添加结果。
        Task { await probe(added) }
        // 清单/目录没给台标的，交给后台自己去找一张。
        RadioLogoDiscoveryService.shared.discoverIfNeeded(for: added)
    }

    /// 订阅并添加。首轮合并直接用已经取回的这批候选，不再下载一遍；
    /// 用户没勾的可用条目记成排除，以后清单更新也不会加进来。
    private func subscribeSelected() async {
        guard !isAdding, let listURL = subscriptionListURL else { return }
        isAdding = true
        defer { isAdding = false }

        let excludedKeys = Set(candidates.compactMap { candidate -> String? in
            guard candidate.isPlayable, !selection.contains(candidate.id) else { return nil }
            return RadioImportParser.streamIdentityKey(candidate.urlString)
        })
        guard let result = RadioSubscriptionService.shared.subscribe(
            listURL: listURL,
            candidates: candidates,
            excludedEntryKeys: excludedKeys,
            usesListGroupsAsFolders: destination == .manifestGroups
        ) else {
            errorMessage = String(localized: "radio_subscription_error_empty")
            return
        }
        // 选了某个文件夹时，这一批新加的放进去；以后新加入的按订阅设置走。
        if case .folder(let name) = destination, !result.addedStationIDs.isEmpty {
            store.setFolder(name, forStationIDs: result.addedStationIDs)
        }
        let added = result.addedStationIDs.compactMap { store.station(id: $0) }
        for name in Set(added.compactMap(\.folderName)) {
            store.createFolder(name)
        }

        dismiss()
        Task { await probe(added) }
    }

    private func probe(_ stations: [RadioStation]) async {
        for station in stations {
            guard let url = station.url else { continue }
            if case .failure = await player.testRadioStream(url: url) {
                plog("📻 batch add: stream unreachable — \(station.name)")
            }
        }
    }
}
