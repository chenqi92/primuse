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

    private enum Entry: String, CaseIterable, Identifiable {
        case paste, file, directory

        var id: String { rawValue }

        var titleKey: String.LocalizationValue {
            switch self {
            case .paste: return "radio_batch_entry_paste"
            case .file: return "radio_batch_entry_file"
            case .directory: return "radio_batch_entry_directory"
            }
        }

        var icon: String {
            switch self {
            case .paste: return "doc.on.clipboard"
            case .file: return "doc.text"
            case .directory: return "globe"
            }
        }
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

    private var playableCount: Int {
        candidates.filter(\.isPlayable).count
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
                        case .directory: directoryInput
                        }

                        if !candidates.isEmpty {
                            resultHeader
                            candidateList
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 120)
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
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
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
        VStack(spacing: 8) {
            ForEach(candidates) { candidate in
                candidateRow(candidate)
            }
        }
    }

    private func candidateRow(_ candidate: RadioImportCandidate) -> some View {
        let isSelected = selection.contains(candidate.id)

        return Button {
            toggle(candidate)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

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

                Text(statusLabel(candidate.status))
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
        .disabled(candidate.status == .invalid)
        .opacity(candidate.status == .invalid ? 0.55 : 1)
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

    private var addBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await addSelected() }
            } label: {
                Group {
                    if isAdding {
                        ProgressView()
                    } else {
                        Label(
                            selection.isEmpty
                                ? String(localized: "radio_batch_add_none")
                                : String(
                                    format: String(localized: "radio_batch_add_count %lld"),
                                    selection.count
                                ),
                            systemImage: "plus.circle"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .disabled(selection.isEmpty || isAdding)

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
    }

    private func toggle(_ candidate: RadioImportCandidate) {
        guard candidate.status != .invalid else { return }
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
					.map { RadioStreamFormat.inferred(from: $0) } ?? .automatic
            )
            store.upsert(station)
            added.append(station)
        }

        dismiss()
        // 试连放在关页之后跑：探测每个流要几秒，用户没必要为此等在这一屏。
        // 探测本身只用来把明确失败的流标出来，不改动用户已确认的添加结果。
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
