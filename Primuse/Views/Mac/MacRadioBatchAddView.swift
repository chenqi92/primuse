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
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var directoryQuery = ""
    @State private var isSearchingDirectory = false
    @State private var directorySearched = false

    private var playableCount: Int { candidates.filter(\.isPlayable).count }
    private var duplicateCount: Int { candidates.filter { $0.status == .duplicate }.count }
    private var invalidCount: Int { candidates.filter { $0.status == .invalid }.count }

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
                    case .directory: directoryInput
                    }

                    if !candidates.isEmpty {
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
    }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: PMSpace.m) {
            PMWindowTrafficLights(closeOnly: true)
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
                Task { await addSelected() }
            } label: {
                Group {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(selection.isEmpty
                             ? String(localized: "radio_batch_add_none")
                             : String(format: String(localized: "radio_batch_add_count %lld"), selection.count))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 26)
                .padding(.horizontal, 16)
                .background(
                    selection.isEmpty ? PMColor.textFaint.opacity(0.45) : PMColor.brand,
                    in: .rect(cornerRadius: PMRadius.s)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty || isAdding)
        }
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.m)
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

    private func statusPill(_ count: Int, _ key: String.LocalizationValue, _ tint: Color) -> some View {
        Text(verbatim: "\(count) \(String(localized: key))")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: PMRadius.xs))
    }

    private var candidateList: some View {
        VStack(spacing: PMSpace.xs) {
            ForEach(candidates) { candidate in
                candidateRow(candidate)
            }
        }
    }

    private func candidateRow(_ candidate: RadioImportCandidate) -> some View {
        let isSelected = selection.contains(candidate.id)
        let disabled = candidate.status == .invalid

        return Button {
            guard !disabled else { return }
            if isSelected { selection.remove(candidate.id) } else { selection.insert(candidate.id) }
        } label: {
            HStack(spacing: PMSpace.s10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? PMColor.brand : PMColor.textFaint)

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

                Text(String(localized: statusKey(candidate.status)))
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
