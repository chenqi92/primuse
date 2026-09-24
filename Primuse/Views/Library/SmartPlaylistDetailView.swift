import SwiftUI
import PrimuseKit

/// 智能歌单详情页。规则型会实时匹配资料库；AI 型按生成时保存的跨设备歌曲身份
/// 解析，并可从详情页继续输入描述追加歌曲。
struct SmartPlaylistDetailView: View {
    /// 用 ID 查找而不是直接持值, 让规则编辑后 detail 能跟着 library 状态刷新。
    let smartPlaylistID: String
    private let onMacInlineBack: (() -> Void)?

    init(smartPlaylistID: String, onMacInlineBack: (() -> Void)? = nil) {
        self.smartPlaylistID = smartPlaylistID
        self.onMacInlineBack = onMacInlineBack
    }

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    #endif

    @State private var showEditor = false
    @State private var showNoScraperSourceAlert = false

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
        // matched 是 computed property, 每次访问都完整跑一遍 SmartPlaylistEngine.match
        // (全库 filter + PlayStats 聚合 + 排序)。单次 body 渲染会被多处访问 6-8 次,
        // 这里取一次快照向下传递, 把每帧的全库扫描收敛成 1 次。
        let matched = self.matched
        #if os(macOS)
        return AnyView(macBody(matched).scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert))
        #else
        return AnyView(
            legacyBody(matched)
                // 整页底色取自第一首带封面的歌 —— 封面墙轮换时底色不跟着跳。
                .libraryDetailTint(
                    from: matched.first(where: { !($0.coverArtFileName ?? "").isEmpty }) ?? matched.first
                )
                .minimalNavigationDetail()
                .librarySearchContext {
                    LibrarySearchScope(
                        title: smart?.name ?? String(localized: "tab_playlists"),
                        songIDs: Set(self.matched.map(\.id)),
                        kind: .smartPlaylist
                    )
                }
                .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        )
        #endif
    }

    #if os(iOS)
    /// 「N 首 · 总时长」。
    private func smartPlaylistMetaText(_ matched: [Song]) -> String {
        let count = "\(matched.count) \(String(localized: "songs_count"))"
        let total = matched.reduce(0.0) { $0 + $1.duration }
        guard total > 0 else { return count }
        return "\(count) \u{00B7} \(total.formattedShort)"
    }

    private func kindSymbol(_ smart: SmartPlaylist) -> String {
        smart.effectiveKind == .ai ? "sparkles" : "slider.horizontal.3"
    }

    /// 两套基座共用的智能歌单页,骨架与普通歌单页一致:整页铺封面色,封面够多时是封面墙,
    /// 不够时是原来的渐变色块;下面是规则 / 描述摘要、「随机 · 播放全部 · 下载」、评分,
    /// AI 歌单再多一颗「继续添加歌曲」。
    private func legacyBody(_ matched: [Song]) -> some View {
        Group {
            if let smart {
                ImmersiveLibraryDetailScrollView(title: smart.name) { insets in
                    smartHero(smart, matched: matched, insets: insets)
                } content: {
                    VStack(spacing: 16) {
                        VStack(spacing: 14) {
                            LibraryReviewSection(
                                subject: .playlist(smart.id),
                                compact: true,
                                onArtwork: true
                            )

                            if smart.effectiveKind == .ai {
                                Button {
                                    showEditor = true
                                } label: {
                                    Label("ai_playlist_add_songs", systemImage: "sparkles")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .libraryDetailGlass(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)

                        // Songs
                        if matched.isEmpty {
                            EmptyStateView(
                                titleKey: "smart_playlist_no_matches",
                                descriptionKey: emptyDescriptionKey(for: smart),
                                systemImage: "magnifyingglass"
                            )
                            .padding(.top, 24)
                            .pmAppearFade(.contentAppear)
                        } else {
                            smartTrackList(matched)
                                // 只在"空态 ⇄ 曲目表"重建时淡入一次: 匹配结果变化不换
                                // 分支, 不会每次刷新都重放; 表内的行一律不动。
                                .pmAppearFade(.contentAppear)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, BottomChromeClearancePolicy.clearance(
                        legacyOverlayActive: legacyBottomChromeOverlayActive,
                        legacy: 64,
                        baseline: 16
                    ))
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showEditor = true
                        } label: {
                            Image(systemName: kindSymbol(smart))
                        }
                        // 三元表达式得到的是 String,会被当成原文显示;显式包成 LocalizedStringKey。
                        .accessibilityLabel(Text(smart.effectiveKind == .ai
                                                 ? LocalizedStringKey("ai_playlist_add_songs")
                                                 : LocalizedStringKey("smart_edit_rules")))
                    }
                }
                .sheet(isPresented: $showEditor) {
                    editor(for: smart)
                }
            } else {
                ContentUnavailableView(
                    "smart_playlist_unavailable",
                    systemImage: "questionmark.circle"
                )
            }
        }
    }

    private func smartHero(
        _ smart: SmartPlaylist,
        matched: [Song],
        insets: ImmersiveLibraryDetailInsets
    ) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let summaryLines = compact ? 2 : LibraryDetailHeroLayoutPolicy.smartSummaryLineLimit(hero.titleTier)
        return VStack(spacing: compact ? 10 : 14) {
            CollectionCoverWallHeader(
                title: smart.name,
                subtitle: smartPlaylistMetaText(matched),
                titleSymbol: kindSymbol(smart),
                songs: matched,
                nowPlaying: player.currentSong,
                topInset: insets.top,
                wallHeight: CGFloat(hero.smartPlaylistWallHeight),
                leadingInset: insets.leading,
                trailingInset: insets.trailing
            ) {
                smartSingleHeader(smart, matched: matched, insets: insets)
            }

            Text(playlistSummary(smart))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineLimit(summaryLines)
                .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
                // 横屏与折叠屏上左右安全区不一定相等,按侧让开。
                .padding(.leading, insets.leading + 28)
                .padding(.trailing, insets.trailing + 28)

            smartActionRow(matched, arrangement: hero.actionRow)
                .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
                .padding(.leading, insets.leading + 20)
                .padding(.trailing, insets.trailing + 20)
                .padding(.top, 4)
        }
        .padding(.bottom, compact ? 8 : 14)
        .frame(maxWidth: .infinity)
    }

    /// 封面不够铺一面墙时:原来那块渐变色块浮在整页底色上,标题与信息居中。
    /// 手机横屏缩到 112 并挪到左边。
    private func smartSingleHeader(
        _ smart: SmartPlaylist,
        matched: [Song],
        insets: ImmersiveLibraryDetailInsets
    ) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let tier = hero.titleTier
        let stacks = !compact || dynamicTypeSize.isAccessibilitySize
        let stack = compact
            ? LibraryDetailArtworkStack(ideal: 112, minimum: 112, budget: .infinity, spacing: 20)
            : hero.smartPlaylistCover
        let identityLayout = stacks
            ? AnyLayout(LibraryDetailArtworkStackLayout(stack: stack))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 18))

        return identityLayout {
            LibraryDetailArtworkSlot { size in
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: smart.effectiveKind == .ai
                                ? [.pink.opacity(0.78), .orange.opacity(0.72)]
                                : [.purple.opacity(0.7), .blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    // 图标跟着色块的边长走:原来 200 配 64、横屏 112 配 42。
                    Image(systemName: kindSymbol(smart))
                        .font(.system(size: compact ? 42 : max(32, size.width * 0.32)))
                        .foregroundStyle(.white)
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
            }
            .frame(width: compact ? 112 : nil, height: compact ? 112 : nil)
            .libraryDetailHeroMotion(.artwork)
            .accessibilityHidden(true)

            VStack(alignment: stacks ? .center : .leading, spacing: 5) {
                Text(smart.name)
                    .font(tier == .regular ? .title2.weight(.heavy) : .title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(compact ? 2 : LibraryDetailHeroLayoutPolicy.titleLineLimit(tier))
                    .libraryDetailHeroTitle()
                Text(verbatim: smartPlaylistMetaText(matched))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .multilineTextAlignment(stacks ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: stacks ? .center : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + (compact ? 12 : 16))
        .frame(maxWidth: .infinity)
    }

    /// 「随机 · 播放全部 · 下载」,与普通歌单页同一套按钮。
    private func smartActionRow(
        _ matched: [Song],
        arrangement: LibraryDetailActionRowArrangement
    ) -> some View {
        let playable = matched.filteredPlayable()
        return LibraryDetailActionRow(arrangement: arrangement) {
            LibraryDetailCircleButton(
                systemImage: "shuffle",
                label: "shuffle",
                disabled: matched.isEmpty
            ) {
                playAll(shuffled: true)
            }
            LibraryDetailPlayPill(title: "play_all", disabled: matched.isEmpty) {
                playAll()
            }
            .frame(maxWidth: arrangement.primaryMaxWidth)
            .libraryDetailPrimaryAction()
            LibraryDetailCircleButton(
                systemImage: "arrow.down",
                label: "offline_download",
                disabled: playable.isEmpty
            ) {
                sourceManager.downloadForOffline(songs: matched)
            }
        }
    }

    private func smartTrackList(_ matched: [Song]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(matched.enumerated()), id: \.element.id) { index, song in
                if index == 0 { trackSeparator(leading: 20) }
                SongRowView(
                    song: song,
                    isPlaying: player.currentSong?.id == song.id,
                    showsActions: false,
                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                )
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture { playSong(song) }

                trackSeparator(leading: index < matched.count - 1 ? 74 : 20)
            }
        }
        .songRowColumnsContainer()
    }

    private func trackSeparator(leading: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 0.5)
            .padding(.leading, leading)
            .padding(.trailing, 20)
    }
    #endif

    #if os(macOS)
    private func macBody(_ matched: [Song]) -> some View {
        Group {
            if let smart {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        macHeader(smart, matched: matched)

                        VStack(alignment: .leading, spacing: PMSpace.l) {
                            macDefinitionCard(smart)
                            LibraryReviewSection(subject: .playlist(smart.id))
                            macToolbar(smart)

                            if matched.isEmpty {
                                EmptyStateView(
                                    titleKey: "smart_playlist_no_matches",
                                    descriptionKey: emptyDescriptionKey(for: smart),
                                    systemImage: "magnifyingglass"
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                                .pmAppearFade(.contentAppear)
                            } else {
                                macSongTable(matched)
                                    .pmAppearFade(.contentAppear)
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
                    editor(for: smart)
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

    private func macHeader(_ smart: SmartPlaylist, matched: [Song]) -> some View {
        MacLibraryHeader(
            eyebrow: smart.effectiveKind == .ai
                ? "ai_smart_playlists_section"
                : "rule_smart_playlists_section",
            title: smart.name,
            subtitle: "\(matched.count) \(String(localized: "songs_count")) · \(playlistSummary(smart))",
            iconSystemName: smart.effectiveKind == .ai ? "sparkles" : "slider.horizontal.3",
            coverSong: matched.first(where: { $0.coverArtFileName?.isEmpty == false }) ?? matched.first,
            accent: Color(red: 0.62, green: 0.44, blue: 0.90),
            darkAccent: Color(red: 0.22, green: 0.24, blue: 0.42),
            onBack: onMacInlineBack,
            backAccessibilityIdentifier: "smartPlaylistInlineBack",
            onPlay: { playAll() },
            onShuffle: {
                playAll(shuffled: true)
            },
            moreMenu: smartMoreMenu(smart, matched: matched)
        )
    }

    /// header 右上角"更多"菜单: 编辑规则 / 离线 / 删除。删除走这里 + 侧栏右键,
    /// 不再放在规则编辑器弹框里。
    private func smartMoreMenu(_ smart: SmartPlaylist, matched: [Song]) -> AnyView {
        let playable = matched.filteredPlayable()
        let editTitle = smart.effectiveKind == .ai
            ? String(localized: "ai_playlist_add_songs")
            : String(localized: "smart_edit_rules")
        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "play.fill", title: String(localized: "play_all"),
                      enabled: !playable.isEmpty) { playAll() },
                .init(icon: "shuffle", title: String(localized: "shuffle"),
                      enabled: !playable.isEmpty) {
                    playAll(shuffled: true)
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
                .init(
                    icon: smart.effectiveKind == .ai ? "sparkles" : "slider.horizontal.3",
                    title: editTitle
                ) { showEditor = true },
                .init(icon: "arrow.down.circle", title: String(localized: "offline_download"),
                      enabled: !playable.isEmpty) {
                    sourceManager.downloadForOffline(songs: matched)
                },
                .init(icon: "wand.and.stars", title: String(localized: "scrape_missing_metadata"),
                      trailing: matched.count.formatted(),
                      enabled: !matched.isEmpty && !scraperService.isScraping) {
                    guard scraperSettings.hasEnabledSource else {
                        showNoScraperSourceAlert = true
                        return
                    }
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

    private func macDefinitionCard(_ smart: SmartPlaylist) -> some View {
        let isAI = smart.effectiveKind == .ai
        return HStack(spacing: 12) {
            Image(systemName: isAI ? "sparkles" : "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PMColor.brand)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(
                    isAI ? "ai_playlist_prompt_section" : "smart_rules_section"
                ))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(playlistSummary(smart))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                showEditor = true
            } label: {
                Text(LocalizedStringKey(
                    isAI ? "ai_playlist_add_songs" : "smart_edit_rules"
                ))
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

    private func macSongTable(_ matched: [Song]) -> some View {
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
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )

                Text(song.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(library.artistDisplayName(for: song) ?? "—")
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

    private func playAll(shuffled: Bool = false) {
        let playable = matched.filteredPlayable()
        let queue = shuffled ? playable.shuffled() : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func playSong(_ song: Song) {
        let queue = matched.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queue: queue, startingAt: index) }
    }

    // MARK: - Definition summary

    @ViewBuilder
    private func editor(for smart: SmartPlaylist) -> some View {
        if smart.effectiveKind == .ai {
            AIPlaylistEditorView(existing: smart)
        } else {
            SmartPlaylistEditorView(existing: smart)
        }
    }

    private func emptyDescriptionKey(for smart: SmartPlaylist) -> LocalizedStringKey {
        smart.effectiveKind == .ai
            ? "ai_playlist_no_suggestions"
            : "smart_playlist_no_matches_desc"
    }

    private func playlistSummary(_ smart: SmartPlaylist) -> String {
        if smart.effectiveKind == .ai {
            guard let prompt = smart.aiConfiguration?.lastPrompt, !prompt.isEmpty else {
                return String(localized: "ai_smart_playlists_section")
            }
            return String(
                format: String(localized: "ai_playlist_prompt_summary_format"),
                prompt
            )
        }
        return rulesSummary(smart)
    }

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
