import PrimuseKit
import SwiftUI

/// 「评论 API 服务」设置页：用户自行配置评论接口地址与可选凭据，按列表顺序依次尝试。
/// 本应用不内置任何评论源；未配置启用源时，播放页不展示查看评论入口。
struct CommentAPIServersView: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var store: CommentAPIServerStore
    @State private var moderationStore: SongCommentModerationStore
    @State private var editorTarget: CommentAPIServerEditorTarget?
    @State private var isReordering = false
    @State private var showsClearModerationConfirm = false

    init(
        store: CommentAPIServerStore = .shared,
        moderationStore: SongCommentModerationStore = .shared
    ) {
        _store = State(initialValue: store)
        _moderationStore = State(initialValue: moderationStore)
    }

    var body: some View {
        #if os(macOS)
        macBody
            .sheet(item: $editorTarget) { target in
                CommentAPIServerEditorSheet(original: target.server, store: store, player: player)
            }
            .confirmationDialog(
                String(localized: "comments_moderation_clear_confirm"),
                isPresented: $showsClearModerationConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "comments_moderation_clear_all"), role: .destructive) {
                    moderationStore.clearAll()
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            }
        #else
        iosBody
            .sheet(item: $editorTarget) { target in
                CommentAPIServerEditorSheet(original: target.server, store: store, player: player)
            }
            .confirmationDialog(
                String(localized: "comments_moderation_clear_confirm"),
                isPresented: $showsClearModerationConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "comments_moderation_clear_all"), role: .destructive) {
                    moderationStore.clearAll()
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            }
        #endif
    }

    // MARK: - iOS

    #if !os(macOS)
    private var iosBody: some View {
        Form {
            Section {
                if store.servers.isEmpty {
                    Text("comments_server_none")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                        iosServerRow(server, index: index)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.remove(id: server.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
            } header: {
                HStack {
                    SettingsInfoHeader("comments_server_list") {
                        Text("comments_server_protocol_footer")
                    }
                    Spacer()
                    if store.servers.count > 1 {
                        Button(isReordering ? String(localized: "done") : String(localized: "reorder")) {
                            pmWithAnimation(.list) { isReordering.toggle() }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }

            Section {
                Button {
                    editorTarget = CommentAPIServerEditorTarget(server: nil)
                } label: {
                    Label("comments_server_add", systemImage: "plus.circle")
                }
            } footer: {
                Text("comments_server_privacy_footer")
            }

            #if os(iOS)
            if store.hasEnabledServers {
                Section {
                    NavigationLink {
                        NowPlayingControlsEditorView()
                    } label: {
                        Label("player_style_editor_title", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    NavigationLink {
                        NowPlayingCarouselSettingsView()
                    } label: {
                        Label("player_carousel_title", systemImage: "rotate.3d")
                    }
                } header: {
                    Text("comments_player_placement_header")
                } footer: {
                    Text("comments_player_placement_footer")
                }
            }
            #endif

            if !moderationStore.isEmpty {
                Section {
                    if moderationStore.hiddenCommentCount > 0 {
                        LabeledContent("comments_moderation_hidden_comments") {
                            Text("\(moderationStore.hiddenCommentCount)")
                                .monospacedDigit()
                        }
                    }
                    if !moderationStore.moderation.blockedAuthorKeys.isEmpty {
                        NavigationLink {
                            BlockedCommentAuthorsView(store: moderationStore)
                        } label: {
                            LabeledContent("comments_moderation_blocked_authors") {
                                Text("\(moderationStore.blockedAuthorCount)")
                                    .monospacedDigit()
                            }
                        }
                    }
                    Button("comments_moderation_clear_all", role: .destructive) {
                        showsClearModerationConfirm = true
                    }
                } header: {
                    Text("comments_moderation_section")
                }
            }
        }
        .navigationTitle("comments_service_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        #endif
    }

    private func iosServerRow(_ server: CommentAPIServer, index: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                editorTarget = CommentAPIServerEditorTarget(server: server)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: server.name.isEmpty
                                 ? String(format: String(localized: "comments_server_row_title_format"), index + 1)
                                 : server.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(server.isEnabled ? .primary : .secondary)
                            if let authorization = server.authorization, !authorization.isEmpty {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(Text("comments_server_auth"))
                            }
                        }
                        Text(verbatim: server.address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { store.setEnabled($0, id: server.id) }
            ))
            .labelsHidden()
        }
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("comments_server_protocol_footer")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                HStack {
                    Label(String(localized: "comments_server_list"), systemImage: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Spacer()
                    Button {
                        editorTarget = CommentAPIServerEditorTarget(server: nil)
                    } label: {
                        Label(String(localized: "comments_server_add"), systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().overlay(PMColor.divider)

                if store.servers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 24))
                            .foregroundStyle(PMColor.textFaint)
                        Text("comments_server_none")
                            .font(.system(size: 13))
                            .foregroundStyle(PMColor.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 {
                            Divider().overlay(PMColor.divider).padding(.leading, 14)
                        }
                        macServerRow(server, index: index)
                    }
                }
            }
            .background(PMColor.bgElev, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }

            if !moderationStore.isEmpty {
                macModerationCard
            }

            Text("comments_server_privacy_footer")
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macServerRow(_ server: CommentAPIServer, index: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: server.name.isEmpty
                         ? String(format: String(localized: "comments_server_row_title_format"), index + 1)
                         : server.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(server.isEnabled ? PMColor.text : PMColor.textMuted)
                    if let auth = server.authorization, !auth.isEmpty {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                Text(verbatim: server.address)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)

            if store.servers.count > 1 {
                HStack(spacing: 2) {
                    Button {
                        store.move(fromOffsets: IndexSet(integer: index), toOffset: max(0, index - 1))
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.35 : 0.85)

                    Button {
                        store.move(fromOffsets: IndexSet(integer: index), toOffset: min(store.servers.count, index + 2))
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == store.servers.count - 1)
                    .opacity(index == store.servers.count - 1 ? 0.35 : 0.85)
                }
            }

            Button {
                editorTarget = CommentAPIServerEditorTarget(server: server)
            } label: {
                Text("edit")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { store.setEnabled($0, id: server.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            Button(role: .destructive) {
                store.remove(id: server.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("delete"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var macModerationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "comments_moderation_section"), systemImage: "eye.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Button("comments_moderation_clear_all", role: .destructive) {
                    showsClearModerationConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(PMColor.divider)

            VStack(alignment: .leading, spacing: 8) {
                if moderationStore.hiddenCommentCount > 0 {
                    HStack {
                        Text("comments_moderation_hidden_comments")
                            .font(.system(size: 12.5))
                            .foregroundStyle(PMColor.textMuted)
                        Spacer()
                        Text("\(moderationStore.hiddenCommentCount)")
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(PMColor.text)
                    }
                }
                ForEach(moderationStore.moderation.blockedAuthorKeys, id: \.self) { key in
                    HStack {
                        Text(verbatim: moderationStore.moderation.blockedAuthorNames[key] ?? key)
                            .font(.system(size: 12.5))
                            .foregroundStyle(PMColor.text)
                        Spacer()
                        Button("comments_moderation_unblock") {
                            moderationStore.unblockAuthor(key: key)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PMColor.brand)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(PMColor.bgElev, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }
    #endif
}

private struct CommentAPIServerEditorTarget: Identifiable {
    let id = UUID()
    let server: CommentAPIServer?
}

/// 新增 / 编辑评论 API 服务表单（iOS 与 macOS 共用）。
private struct CommentAPIServerEditorSheet: View {
    let original: CommentAPIServer?
    let store: CommentAPIServerStore
    let player: AudioPlayerService

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var authorization: String
    @State private var probeResult: SongCommentProbeResult?
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?

    init(original: CommentAPIServer?, store: CommentAPIServerStore, player: AudioPlayerService) {
        self.original = original
        self.store = store
        self.player = player
        _name = State(initialValue: original?.name ?? "")
        _address = State(initialValue: original?.address ?? "")
        _authorization = State(initialValue: original?.authorization ?? "")
    }

    private var normalizedAddress: String? {
        CommentAPIServerPolicy.normalizedAddress(address)
    }

    private var trimmedAuthorization: String? {
        let value = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var showsInvalidAddress: Bool {
        normalizedAddress == nil && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            MacSheetHeader(
                Text(original == nil ? LocalizedStringKey("comments_server_add") : LocalizedStringKey("comments_server_edit")),
                systemImage: "bubble.left.and.text.bubble.right",
                onClose: close
            )
            formContent
                .formStyle(.grouped)
                .frame(maxHeight: .infinity)
            MacSheetFooter {
                Button("cancel", action: close)
                    .buttonStyle(.macSheet)
                    .keyboardShortcut(.cancelAction)
                Button("save", action: save)
                    .buttonStyle(.macSheetPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedAddress == nil)
            }
        }
        .frame(width: 520, height: 470)
        .background(PMColor.bg)
        .onDisappear { probeTask?.cancel() }
        #else
        NavigationStack {
            formContent
                .navigationTitle(original == nil
                                 ? String(localized: "comments_server_add")
                                 : String(localized: "comments_server_edit"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { close() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("save") { save() }
                            .disabled(normalizedAddress == nil)
                    }
                }
        }
        .onDisappear { probeTask?.cancel() }
        #endif
    }

    private var formContent: some View {
        Form {
            Section {
                TextField("comments_server_name_placeholder", text: $name)
            } header: {
                Text("comments_server_name")
            }

            Section {
                TextField("comments_server_address_placeholder", text: $address)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("comments_server_address")
            } footer: {
                if showsInvalidAddress {
                    Text("comments_server_invalid_address")
                        .foregroundStyle(.red)
                } else {
                    Text("comments_server_address_hint")
                }
            }

            Section {
                TextField("comments_server_auth_placeholder", text: $authorization)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                #if os(macOS)
                Text("comments_server_auth")
                #else
                SettingsInfoHeader("comments_server_auth") {
                    Text("comments_server_auth_footer")
                }
                #endif
            } footer: {
                #if os(macOS)
                Text("comments_server_auth_footer")
                #endif
            }

            Section {
                Button {
                    runProbe()
                } label: {
                    HStack {
                        Text("comments_server_test")
                        Spacer()
                        if isProbing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(player.currentSong == nil || normalizedAddress == nil || isProbing)

                if let probeResult {
                    probeResultText(probeResult)
                        .font(.footnote)
                }
            } footer: {
                if player.currentSong == nil {
                    Text("comments_server_test_needs_song")
                }
            }
        }
    }

    @ViewBuilder
    private func probeResultText(_ result: SongCommentProbeResult) -> some View {
        switch result {
        case .found(let total, let loadedCount):
            let count = total ?? loadedCount
            Label(
                String(format: String(localized: "comments_server_test_ok_format"), count),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .empty:
            Label("comments_server_test_empty", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(
                String(format: String(localized: "comments_server_test_failed_format"), message),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private func runProbe() {
        guard let song = player.currentSong, let normalized = normalizedAddress else { return }
        let server = CommentAPIServer(
            id: original?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: normalized,
            authorization: trimmedAuthorization
        )
        let query = SongCommentQuery(song: song)
        probeTask?.cancel()
        probeResult = nil
        isProbing = true
        probeTask = Task {
            let result = await SongCommentService.probe(server: server, query: query)
            guard !Task.isCancelled else { return }
            probeResult = result
            isProbing = false
        }
    }

    private func save() {
        guard let normalized = normalizedAddress else { return }
        let saved: Bool
        if let original {
            saved = store.update(
                id: original.id,
                name: name,
                address: normalized,
                authorization: trimmedAuthorization
            )
        } else {
            saved = store.add(
                name: name,
                address: normalized,
                authorization: trimmedAuthorization
            )
        }
        if saved { close() }
    }

    private func close() {
        probeTask?.cancel()
        dismiss()
    }
}

#if !os(macOS)
private struct BlockedCommentAuthorsView: View {
    let store: SongCommentModerationStore

    var body: some View {
        List {
            ForEach(store.moderation.blockedAuthorKeys, id: \.self) { key in
                HStack {
                    Text(verbatim: store.moderation.blockedAuthorNames[key] ?? key)
                    Spacer()
                    Button("comments_moderation_unblock") {
                        store.unblockAuthor(key: key)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("comments_moderation_blocked_authors")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
#endif
