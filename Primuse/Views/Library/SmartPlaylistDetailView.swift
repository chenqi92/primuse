import SwiftUI
import PrimuseKit

/// 智能歌单详情页 ── 实时跑 SmartPlaylistEngine.match 拿匹配的歌, 复用
/// SongRowView 显示。规则变化 / library 变化时会自动重算。
struct SmartPlaylistDetailView: View {
    /// 用 ID 查找而不是直接持值, 让规则编辑后 detail 能跟着 library 状态刷新。
    let smartPlaylistID: String

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService

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
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
    }

    private var legacyBody: some View {
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
                        HStack(spacing: 12) {
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

                            Button {
                                sourceManager.downloadForOffline(songs: matched)
                            } label: {
                                Label("offline_download", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(matched.filteredPlayable().isEmpty)
                        }
                        .padding(.horizontal)

                        // Songs
                        if matched.isEmpty {
                            EmptyStateView(
                                titleKey: "smart_playlist_no_matches",
                                descriptionKey: "smart_playlist_no_matches_desc",
                                systemImage: "magnifyingglass"
                            )
                            .padding(.top, 24)
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

    #if os(macOS)
    private var macBody: some View {
        Group {
            if let smart {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        macHeader(smart)

                        VStack(alignment: .leading, spacing: PMSpace.l) {
                            macRuleCard(smart)
                            macToolbar(smart)

                            if matched.isEmpty {
                                EmptyStateView(
                                    titleKey: "smart_playlist_no_matches",
                                    descriptionKey: "smart_playlist_no_matches_desc",
                                    systemImage: "magnifyingglass"
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                            } else {
                                macSongTable
                            }
                        }
                        .padding(.horizontal, PMSpace.xxxl)
                        .padding(.top, PMSpace.l)
                    }
                    .padding(.bottom, 112)
                }
                .background(PMColor.bg.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showEditor) {
                    SmartPlaylistEditorView(existing: smart)
                }
            } else {
                ContentUnavailableView(
                    "smart_playlist_unavailable",
                    systemImage: "questionmark.circle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PMColor.bg.ignoresSafeArea())
            }
        }
    }

    private func macHeader(_ smart: SmartPlaylist) -> some View {
        MacLibraryHeader(
            eyebrow: "smart_playlists_section",
            title: smart.name,
            subtitle: "\(matched.count) \(String(localized: "songs_count")) · \(rulesSummary(smart))",
            iconSystemName: "sparkles",
            coverSong: matched.first(where: { $0.coverArtFileName?.isEmpty == false }) ?? matched.first,
            accent: Color(red: 0.62, green: 0.44, blue: 0.90),
            darkAccent: Color(red: 0.22, green: 0.24, blue: 0.42),
            onPlay: playAll,
            onShuffle: {
                player.shuffleEnabled = true
                playAll()
            },
            moreMenu: smartMoreMenu(smart)
        )
    }

    /// header 右上角"更多"菜单: 编辑规则 / 离线 / 删除。删除走这里 + 侧栏右键,
    /// 不再放在规则编辑器弹框里。
    private func smartMoreMenu(_ smart: SmartPlaylist) -> AnyView {
        let playable = matched.filteredPlayable()
        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "play.fill", title: String(localized: "play_all"),
                      enabled: !playable.isEmpty, action: playAll),
                .init(icon: "shuffle", title: String(localized: "shuffle"),
                      enabled: !playable.isEmpty) {
                    player.shuffleEnabled = true
                    playAll()
                },
                .init(icon: "text.line.last.and.arrowtriangle.forward", title: String(localized: "add_to_queue"),
                      enabled: !playable.isEmpty) {
                    player.appendToQueue(playable)
                },
                .init(icon: "text.line.first.and.arrowtriangle.forward", title: String(localized: "up_next"),
                      enabled: !playable.isEmpty) {
                    player.insertNextInQueue(playable)
                },
            ],
            [
                .init(icon: "slider.horizontal.3", title: "编辑规则") { showEditor = true },
                .init(icon: "arrow.down.circle", title: String(localized: "offline_download"),
                      enabled: !playable.isEmpty) {
                    sourceManager.downloadForOffline(songs: matched)
                },
                .init(icon: "wand.and.stars", title: String(localized: "scrape_missing_metadata"),
                      trailing: matched.count.formatted(),
                      enabled: !matched.isEmpty && !scraperService.isScraping) {
                    scraperService.scrapeMissingMetadata(songs: matched, in: library)
                },
            ],
            [
                .init(icon: "trash", title: String(localized: "delete"),
                      isDestructive: true) { deleteSmart(smart) },
            ],
        ]))
    }

    private func deleteSmart(_ smart: SmartPlaylist) {
        library.deleteSmartPlaylist(id: smart.id)
        // 删完回到首页 (歌单总览页已移除), 同时清详情栈避免压着空详情。
        NotificationCenter.default.post(name: .primuseSelectPlaylists, object: nil)
    }

    private func macRuleCard(_ smart: SmartPlaylist) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PMColor.brand)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "智能规则")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(rulesSummary(smart))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                showEditor = true
            } label: {
                Text(verbatim: "编辑规则")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .pmGlass(cornerRadius: PMRadius.m10)
    }

    private func macToolbar(_ smart: SmartPlaylist) -> some View {
        // 只留"歌曲"小标题。下载 / 编辑入口都在上方: 编辑在"智能规则"卡片的
        // "编辑规则"按钮, 下载/编辑/删除在 header 右上角"更多"菜单, 不再重复。
        HStack(spacing: 8) {
            Text("songs_count")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            Spacer()
        }
        .padding(.top, -2)
    }

    private var macSongTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: PMSpace.s10) {
                Text("#").frame(width: 28, alignment: .center)
                Color.clear.frame(width: 36)
                Text("sort_title").frame(maxWidth: .infinity, alignment: .leading)
                Text("sort_artist").frame(width: 180, alignment: .leading)
                Text("sort_album").frame(width: 180, alignment: .leading)
                Text("sort_format").frame(width: 64, alignment: .leading)
                Text("track_duration_short").frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, PMSpace.s8)
            .padding(.vertical, 6)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVStack(spacing: 1) {
                ForEach(Array(matched.enumerated()), id: \.element.id) { index, song in
                    macSongRow(song, index: index)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func macSongRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return Button { playSong(song) } label: {
            HStack(spacing: PMSpace.s10) {
                ZStack {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 28, alignment: .center)

                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 32, cornerRadius: PMRadius.xs,
                    sourceID: song.sourceID, filePath: song.filePath
                )

                Text(song.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(song.artistName ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                Text(song.albumTitle ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                PMFormatPill.forFormat(song.fileFormat.displayName)
                    .frame(width: 64, alignment: .leading)

                Text(song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, PMSpace.s8)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

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
        let groups = smart.effectiveRuleGroups
        if groups.isEmpty {
            return String(localized: "smart_playlist_no_rules")
        }
        return groups.map { group in
            let join = group.combinator == .and
                ? String(localized: "smart_playlist_combinator_and")
                : String(localized: "smart_playlist_combinator_or")
            let body = group.rules
                .map { ruleLabel($0) }
                .joined(separator: " \(join) ")
            if group.isExcluded {
                return "\(String(localized: "smart_rule_group_excluded")): \(body)"
            }
            return body
        }
        .joined(separator: " · ")
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
