#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrimuseKit

/// macOS 批量添加电台。跟 `MacRadioStationEditorView` 同一套弹框骨架，
/// 解析和判重复用 `RadioImportParser`，只是把 iOS 那套控件换成 PM token。
struct MacRadioBatchAddView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

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

    /// `startsWithPlaylistLink` 为真时直接停在「清单链接」—— 订阅管理页的
    /// 「添加订阅」从这里进来。
    init(startsWithPlaylistLink: Bool = false) {
        _entry = State(initialValue: startsWithPlaylistLink ? .url : .paste)
    }

    private var playableCount: Int { candidates.filter(\.isPlayable).count }
    private var duplicateCount: Int { candidates.filter { $0.status == .duplicate }.count }
    private var invalidCount: Int { candidates.filter { $0.status == .invalid }.count }

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

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            entryPicker

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: PMSpace.m14) {
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
                .padding(.horizontal, PMSpace.l24)
                .padding(.vertical, PMSpace.l)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            footer
        }
        .frame(width: 620, height: 620)
        .background(PMColor.bg)
        .foregroundStyle(PMColor.text)
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

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: PMSpace.m) {
            Text("radio_batch_add_title")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Spacer()
        }
        .padding(.horizontal, PMSpace.m16)
        .padding(.vertical, PMSpace.m14)
    }

    private var footer: some View {
        HStack(spacing: PMSpace.s10) {
            Text("radio_batch_add_footer")
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textFaint)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("cancel")
                    .font(PMFont.bodyM)
                    .foregroundStyle(PMColor.text)
                    .frame(height: 26)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(isAdding)

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
                        ProgressView().controlSize(.small)
                    } else {
                        Text(addButtonTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 26)
                .padding(.horizontal, 16)
                .background(
                    canAdd ? PMColor.brand : PMColor.textFaint.opacity(0.45),
                    in: .rect(cornerRadius: PMRadius.s)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdd || isAdding)
        }
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.m)
    }

    /// 订阅时一个都不勾也可以：以后清单新增的照样会加进来。
    private var canAdd: Bool {
        !selection.isEmpty || isSubscribing
    }

    private var addButtonTitle: String {
        if isSubscribing {
            return selection.isEmpty
                ? String(localized: "radio_subscription_subscribe_only")
                : String(format: String(localized: "radio_subscription_add_count %lld"), selection.count)
        }
        return selection.isEmpty
            ? String(localized: "radio_batch_add_none")
            : String(format: String(localized: "radio_batch_add_count %lld"), selection.count)
    }

    // MARK: - Entry picker

    private var entryPicker: some View {
        HStack(spacing: PMSpace.s) {
            ForEach(Entry.allCases) { item in
                Button {
                    guard entry != item else { return }
                    entry = item
                    candidates = []
                    selection = []
                    directorySearched = false
                    fetchedPlaylistURL = nil
                    subscribesToList = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(String(localized: item.titleKey))
                            .font(PMFont.bodyM)
                    }
                    .foregroundStyle(entry == item ? .white : PMColor.text)
                    .frame(height: 26)
                    .padding(.horizontal, 12)
                    .background(
                        entry == item ? PMColor.brand : PMColor.glassBtn,
                        in: .rect(cornerRadius: PMRadius.s)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                            .strokeBorder(entry == item ? .clear : PMColor.cardBorder, lineWidth: 0.5)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.s10)
    }

    // MARK: - Inputs

    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: PMSpace.s) {
            Text("radio_batch_paste_hint")
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textMuted)

            TextEditor(text: $pastedText)
                .font(PMFont.mono)
                .foregroundStyle(PMColor.text)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(PMSpace.s8)
                .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }
                .onChange(of: pastedText) { _, newValue in reparse(newValue) }

            HStack(spacing: PMSpace.s) {
                secondaryButton("radio_batch_paste_from_clipboard", icon: "doc.on.clipboard") {
                    pasteFromClipboard()
                }
                if !pastedText.isEmpty {
                    Button {
                        pastedText = ""
                        candidates = []
                        selection = []
                    } label: {
                        Text("radio_batch_clear")
                            .font(PMFont.bodyM)
                            .foregroundStyle(PMColor.bad)
                            .frame(height: 24)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fileInput: some View {
        VStack(alignment: .leading, spacing: PMSpace.s10) {
            Text("radio_batch_file_hint")
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textMuted)

            secondaryButton("radio_batch_pick_file", icon: "folder") {
                pickFile()
            }
        }
    }

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: PMSpace.s10) {
            Text("radio_batch_url_hint")
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textMuted)

            HStack(spacing: PMSpace.s) {
                TextField(
                    text: $playlistURLString,
                    prompt: Text(verbatim: "https://example.com/radio.m3u")
                ) {
                    Text("radio_batch_entry_url")
                }
                .textFieldStyle(.plain)
                .font(PMFont.mono)
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, PMSpace.s10)
                .frame(height: 28)
                .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }
                .onSubmit { fetchPlaylist() }

                Button {
                    fetchPlaylist()
                } label: {
                    Group {
                        if isFetchingPlaylist {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("radio_batch_url_fetch")
                                .font(PMFont.bodyM)
                                .foregroundStyle(PMColor.text)
                        }
                    }
                    .frame(height: 28)
                    .padding(.horizontal, 12)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                    .overlay {
                        RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
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

    private var subscriptionCard: some View {
        RadioSubscriptionOfferCard(
            existingSubscription: existingSubscription,
            entryCount: uniqueValidEntryCount,
            isOn: $subscribesToList,
            onManage: { showingManagedSubscription = true }
        )
        .toggleStyle(.switch)
        .padding(.horizontal, PMSpace.s10)
        .padding(.vertical, PMSpace.s10)
        .background(
            isSubscribing ? PMColor.brand.opacity(0.10) : PMColor.card,
            in: .rect(cornerRadius: PMRadius.m)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(
                    isSubscribing ? PMColor.brand.opacity(0.45) : PMColor.cardBorder,
                    lineWidth: 0.5
                )
        }
    }

    private var directoryInput: some View {
        VStack(alignment: .leading, spacing: PMSpace.s10) {
            Text("radio_batch_directory_hint")
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textMuted)

            HStack(spacing: PMSpace.s) {
                TextField(
                    String(localized: "radio_batch_directory_placeholder"),
                    text: $directoryQuery
                )
                .textFieldStyle(.plain)
                .font(PMFont.bodyS)
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, PMSpace.s10)
                .frame(height: 28)
                .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }
                .onSubmit { Task { await searchDirectory() } }

                Button {
                    Task { await searchDirectory() }
                } label: {
                    Group {
                        if isSearchingDirectory {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PMColor.text)
                        }
                    }
                    .frame(width: 30, height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                    .overlay {
                        RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSearchingDirectory || directoryQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if directorySearched, candidates.isEmpty, !isSearchingDirectory {
                Text("radio_batch_directory_empty")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textFaint)
            }
        }
    }

    private func secondaryButton(
        _ titleKey: String.LocalizationValue,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(String(localized: titleKey)).font(PMFont.bodyM)
            }
            .foregroundStyle(PMColor.text)
            .frame(height: 26)
            .padding(.horizontal, 12)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results

    private var resultHeader: some View {
        HStack(spacing: PMSpace.s) {
            statusPill(playableCount, "radio_batch_status_playable", PMColor.ok)
            if duplicateCount > 0 {
                statusPill(duplicateCount, "radio_batch_status_duplicate", PMColor.warn)
            }
            if invalidCount > 0 {
                statusPill(invalidCount, "radio_batch_status_invalid", PMColor.bad)
            }

            Spacer()

            importFolderPicker

            Button {
                selection = Set(candidates.filter(\.isPlayable).map(\.id))
            } label: {
                Text("radio_batch_select_playable")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
            }
            .buttonStyle(.plain)
            .disabled(playableCount == 0)
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
        case .ungrouped: return String(localized: "radio_batch_import_into")
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
            Button("radio_folder_ungrouped", systemImage: "tray") { destination = .ungrouped }
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
            HStack(spacing: 5) {
                Image(systemName: destinationIcon)
                    .font(.system(size: 10.5))
                Text(destinationLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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

    private func statusPill(_ count: Int, _ key: String.LocalizationValue, _ tint: Color) -> some View {
        Text(verbatim: "\(count) \(String(localized: key))")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: PMRadius.xs))
    }

    private var candidateList: some View {
        // 订阅时要分清「已在电台库」和清单里自己的重复行，库里的判重键算一次就够。
        let libraryKeys = isSubscribing
            ? Set(store.stations.compactMap { RadioImportParser.streamIdentityKey($0.streamURL) })
            : []
        return VStack(spacing: PMSpace.xs) {
            ForEach(candidates) { candidate in
                candidateRow(candidate, libraryKeys: libraryKeys)
            }
        }
    }

    private func candidateRow(_ candidate: RadioImportCandidate, libraryKeys: Set<String>) -> some View {
        let isSelected = selection.contains(candidate.id)
        let disabled = !isSelectable(candidate)
        let inLibrary = isSubscribing
            && candidate.status == .duplicate
            && RadioImportParser.streamIdentityKey(candidate.urlString).map { libraryKeys.contains($0) } == true

        return Button {
            guard !disabled else { return }
            if isSelected { selection.remove(candidate.id) } else { selection.insert(candidate.id) }
        } label: {
            HStack(spacing: PMSpace.s10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? PMColor.brand : PMColor.textFaint)

                RadioCandidateLogoView(urlString: candidate.logoURLString, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(PMFont.bodyS)
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(candidate.urlString)
                        .font(PMFont.monoXS)
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let group = candidate.groupTitle {
                        Label(group, systemImage: "folder")
                            .font(PMFont.captionS)
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                    if let duplicateOfName = candidate.duplicateOfName {
                        Text(String(
                            format: String(localized: "radio_batch_duplicate_of %@"),
                            duplicateOfName
                        ))
                        .font(PMFont.captionS)
                        .foregroundStyle(PMColor.warn)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Text(inLibrary
                     ? String(localized: "radio_subscription_in_library")
                     : String(localized: statusKey(candidate.status)))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusTint(candidate.status))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        statusTint(candidate.status).opacity(0.16),
                        in: .rect(cornerRadius: PMRadius.xs)
                    )
            }
            .padding(.horizontal, PMSpace.s10)
            .padding(.vertical, PMSpace.s8)
            .background(
                isSelected ? PMColor.brand.opacity(0.10) : PMColor.card,
                in: .rect(cornerRadius: PMRadius.m)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                    .strokeBorder(
                        isSelected ? PMColor.brand.opacity(0.45) : PMColor.cardBorder,
                        lineWidth: 0.5
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func statusKey(_ status: RadioImportCandidate.Status) -> String.LocalizationValue {
        switch status {
        case .playable: return "radio_batch_status_playable"
        case .duplicate: return "radio_batch_status_duplicate"
        case .invalid: return "radio_batch_status_invalid"
        }
    }

    private func statusTint(_ status: RadioImportCandidate.Status) -> Color {
        switch status {
        case .playable: return PMColor.ok
        case .duplicate: return PMColor.warn
        case .invalid: return PMColor.bad
        }
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            errorMessage = String(localized: "radio_batch_clipboard_empty")
            return
        }
        pastedText = text
        reparse(text)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .text, .data]
        for ext in ["m3u", "m3u8", "pls"] {
            if let type = UTType(filenameExtension: ext) { types.insert(type, at: 0) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
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

    private func searchDirectory() async {
        let query = directoryQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isSearchingDirectory else { return }
        isSearchingDirectory = true
        defer { isSearchingDirectory = false }
        do {
            let results = try await RadioDirectoryClient.search(name: query)
            directorySearched = true
            applyCandidates(RadioDirectoryClient.candidates(from: results, existing: store.stations))
        } catch {
            directorySearched = true
            errorMessage = error.localizedDescription
        }
    }

    private func reparse(_ text: String) {
        applyCandidates(RadioImportParser.parse(text, existing: store.stations))
    }

    private func applyCandidates(_ next: [RadioImportCandidate]) {
        candidates = next
        selection = Set(next.filter(\.isPlayable).map(\.id))

        // 清单自带分组时默认就按它分；换了一批没有分组的清单再退回不分组，
        // 免得标签停在一个空选项上。
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
        Task {
            for station in added {
                guard let url = station.url else { continue }
                if case .failure = await player.testRadioStream(url: url) {
                    plog("📻 subscription add: stream unreachable — \(station.name)")
                }
            }
        }
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
        // 清单/目录没给台标的，交给后台自己去找一张。
        RadioLogoDiscoveryService.shared.discoverIfNeeded(for: added)
        // 探测每个流要几秒，放到关窗之后跑，不让用户干等。
        Task {
            for station in added {
                guard let url = station.url else { continue }
                if case .failure = await player.testRadioStream(url: url) {
                    plog("📻 batch add: stream unreachable — \(station.name)")
                }
            }
        }
    }
}
#endif
