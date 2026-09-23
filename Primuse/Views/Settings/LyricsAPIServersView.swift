import SwiftUI
import PrimuseKit

/// 「歌词 API 服务」刮削源的地址列表：用户自己填的歌词接口，按列表顺序依次请求。
/// 列表顺序就是请求顺序，所以这里也提供排序。
struct LyricsAPIServersView: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var store = LyricsAPIServerStore.shared
    @State private var editorTarget: LyricsAPIServerEditorTarget?
    @State private var isReordering = false

    var body: some View {
        SkinForm {
            Section {
                if store.servers.isEmpty {
                    Text("lyrics_server_none")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                        serverRow(server, index: index)
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
                    Text("lyrics_server_list")
                    Spacer()
                    if store.servers.count > 1 {
                        Button(isReordering ? String(localized: "done") : String(localized: "reorder")) {
                            pmWithAnimation(.list) { isReordering.toggle() }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            } footer: {
                Text("lyrics_server_protocol_footer")
            }

            Section {
                Button {
                    editorTarget = LyricsAPIServerEditorTarget(server: nil)
                } label: {
                    Label("lyrics_server_add", systemImage: "plus.circle")
                }
            } footer: {
                Text("lyrics_server_privacy_footer")
            }
        }
        .navigationTitle("scraper_lyrics_server_name")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        #endif
        // 挂在页面上而不是节上：Form 的节是懒加载的。
        .sheet(item: $editorTarget) { target in
            LyricsAPIServerEditorSheet(original: target.server, store: store, player: player)
        }
    }

    private func serverRow(_ server: LyricsAPIServer, index: Int) -> some View {
        Button {
            editorTarget = LyricsAPIServerEditorTarget(server: server)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: String(localized: "lyrics_server_row_title_format"), index + 1))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(verbatim: server.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let authorization = server.authorization, !authorization.isEmpty {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("lyrics_server_auth"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.sheet(item:)` 用：`server == nil` 表示新增。
private struct LyricsAPIServerEditorTarget: Identifiable {
    let id = UUID()
    let server: LyricsAPIServer?
}

/// 新增 / 编辑共用的表单。播放器和 store 以值传进来，不在 sheet 里读环境对象。
private struct LyricsAPIServerEditorSheet: View {
    let original: LyricsAPIServer?
    let store: LyricsAPIServerStore
    let player: AudioPlayerService

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var authorization: String
    @State private var probeResult: LyricsAPIServerProbeResult?
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?

    init(original: LyricsAPIServer?, store: LyricsAPIServerStore, player: AudioPlayerService) {
        self.original = original
        self.store = store
        self.player = player
        _address = State(initialValue: original?.address ?? "")
        _authorization = State(initialValue: original?.authorization ?? "")
    }

    private var normalizedAddress: String? {
        LyricsAPIServerPolicy.normalizedAddress(address)
    }

    private var trimmedAuthorization: String? {
        let value = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 地址框里有字但不合法时才提示；空白框不当成错误刷红字。
    private var showsInvalidAddress: Bool {
        normalizedAddress == nil && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            SkinForm {
                Section {
                    TextField("lyrics_server_address_placeholder", text: $address)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("lyrics_server_address")
                } footer: {
                    if showsInvalidAddress {
                        Text("lyrics_server_invalid_address")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("lyrics_server_auth_placeholder", text: $authorization)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("lyrics_server_auth")
                } footer: {
                    Text("lyrics_server_auth_footer")
                }

                Section {
                    Button {
                        runProbe()
                    } label: {
                        HStack {
                            Text("lyrics_server_test")
                            Spacer()
                            if isProbing {
                                ProgressView()
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
                        Text("lyrics_server_test_needs_song")
                    }
                }
            }
            .navigationTitle(original == nil
                             ? String(localized: "lyrics_server_add")
                             : String(localized: "lyrics_server_edit"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
    }

    @ViewBuilder
    private func probeResultText(_ result: LyricsAPIServerProbeResult) -> some View {
        switch result {
        case .found(let lineCount):
            Label(String(format: String(localized: "lyrics_server_test_ok_format"), lineCount),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notFound:
            Label("lyrics_server_test_not_found", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(String(format: String(localized: "lyrics_server_test_failed_format"), message),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func runProbe() {
        guard let song = player.currentSong, let normalized = normalizedAddress else { return }
        // 用输入框里的内容临时拼一个服务，不必先保存。
        let server = LyricsAPIServer(
            id: original?.id ?? UUID().uuidString,
            address: normalized,
            authorization: trimmedAuthorization
        )
        let title = song.title
        let artist = song.artistName
        let album = song.albumTitle
        let duration: TimeInterval? = song.duration > 0 ? song.duration : nil
        probeTask?.cancel()
        probeResult = nil
        isProbing = true
        probeTask = Task {
            let result = await LyricsAPIServerScraper.probe(
                server: server,
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
            guard !Task.isCancelled else { return }
            probeResult = result
            isProbing = false
        }
    }

    private func save() {
        guard let normalized = normalizedAddress else { return }
        let saved: Bool
        if let original {
            saved = store.update(id: original.id, address: normalized, authorization: trimmedAuthorization)
        } else {
            saved = store.add(address: normalized, authorization: trimmedAuthorization)
        }
        if saved { close() }
    }

    private func close() {
        probeTask?.cancel()
        dismiss()
    }
}
