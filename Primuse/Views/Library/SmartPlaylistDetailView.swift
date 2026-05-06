import SwiftUI
import PrimuseKit

/// 智能歌单详情页 ── 实时跑 SmartPlaylistEngine.match 拿匹配的歌, 复用
/// SongRowView 显示。规则变化 / library 变化时会自动重算。
struct SmartPlaylistDetailView: View {
    /// 用 ID 查找而不是直接持值, 让规则编辑后 detail 能跟着 library 状态刷新。
    let smartPlaylistID: String

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    @State private var showEditor = false

    private var smart: SmartPlaylist? {
        library.smartPlaylists.first(where: { $0.id == smartPlaylistID })
    }

    /// SmartPlaylistEngine.match 是 @MainActor 同步函数, 直接 computed 调用即可。
    /// 几千歌 + 几条规则在主线程几十 ms, 不需要 async / Task。
    private var matched: [Song] {
        guard let smart else { return [] }
        return SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared)
    }

    var body: some View {
        Group {
            if let smart {
                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(LinearGradient(
                                        colors: [.purple.opacity(0.7), .blue.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                Image(systemName: "sparkles")
                                    .font(.system(size: 60))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 180, height: 180)

                            Text(smart.name)
                                .font(.title2)
                                .fontWeight(.bold)

                            Text("\(matched.count) \(String(localized: "songs_count"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(rulesSummary(smart))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .lineLimit(3)
                        }
                        .padding(.top, 20)

                        // Action buttons
                        HStack(spacing: 16) {
                            Button {
                                playAll()
                            } label: {
                                Label("play_all", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(matched.isEmpty)

                            Button {
                                player.shuffleEnabled = true
                                playAll()
                            } label: {
                                Label("shuffle", systemImage: "shuffle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(matched.isEmpty)
                        }
                        .padding(.horizontal)

                        // Songs
                        if matched.isEmpty {
                            ContentUnavailableView(
                                "smart_playlist_no_matches",
                                systemImage: "magnifyingglass",
                                description: Text("smart_playlist_no_matches_desc")
                            )
                            .padding(.top, 40)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(matched) { song in
                                    SongRowView(
                                        song: song,
                                        isPlaying: player.currentSong?.id == song.id,
                                        showsActions: false,
                                        context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                    )
                                    .padding(.horizontal)
                                    .padding(.vertical, 8)
                                    .onTapGesture { playSong(song) }

                                    Divider().padding(.leading, 50)
                                }
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showEditor = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
                .sheet(isPresented: $showEditor) {
                    SmartPlaylistEditorView(existing: smart)
                }
            } else {
                ContentUnavailableView(
                    "smart_playlist_unavailable",
                    systemImage: "questionmark.circle"
                )
            }
        }
    }

    // MARK: - Playback

    private func playAll() {
        let queue = matched.filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        let queue = matched.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }

    // MARK: - Rule summary

    private func rulesSummary(_ smart: SmartPlaylist) -> String {
        if smart.rules.isEmpty {
            return String(localized: "smart_playlist_no_rules")
        }
        let join = smart.combinator == .and
            ? String(localized: "smart_playlist_combinator_and")
            : String(localized: "smart_playlist_combinator_or")
        return smart.rules
            .map { ruleLabel($0) }
            .joined(separator: " \(join) ")
    }

    private func ruleLabel(_ rule: SmartPlaylistRule) -> String {
        let field = fieldLabel(rule.field)
        let op = opLabel(rule.op)
        return "\(field) \(op) \(rule.value)"
    }

    private func fieldLabel(_ field: SmartPlaylistField) -> String {
        String(localized: LocalizedStringResource(stringLiteral: "smart_field_\(field.rawValue)"))
    }

    private func opLabel(_ op: SmartPlaylistOperator) -> String {
        switch op {
        case .equals: return "="
        case .notEquals: return "≠"
        case .contains: return "⊇"
        case .notContains: return "⊉"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .between: return "∈"
        }
    }
}
