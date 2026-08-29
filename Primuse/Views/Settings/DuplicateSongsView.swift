import SwiftUI
import PrimuseKit

/// 重复歌曲管理 — 找 library 里 title+artist+duration 一致的多版本歌曲,
/// 让用户保留一个 (推荐: 最高音质), 其他从 library 移除。
///
/// 支持删除的源会同步删源端音频；同名歌词/封面 sidecar 只有在没有保留歌曲
/// 继续使用时才删除。本地库记录、tombstone 和缓存统一由 SourceManager/MusicLibrary 链路处理。
struct DuplicateSongsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(DuplicateCleanupService.self) private var cleaner
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = false
    @State private var expandedGroupID: String?
    @State private var showCleanAllConfirm = false
    @State private var cleanedCount: Int = 0
    @State private var lastActionMessage: String?
    @State private var showAllGroups = false
    @State private var scanGeneration = 0
    #if os(macOS)
    @State private var retentionStrategy: MacDuplicateRetentionStrategy = .highestBitrate
    @State private var macKeptSongIDsByGroup: [String: Set<String>] = [:]
    #endif

    /// 一次性最多渲染多少个 Section, 超过后下面给个「显示全部」按钮。
    /// SwiftUI Form 大量 Section + DisclosureGroup 会让 macOS 渲染掉帧,
    /// 100 是经验值: 用户该清的早就用「一键清理」按钮处理了, 看完整列表
    /// 是相对边缘的需求, 显式展开避免默认 paint 卡。
    private static let initialGroupRenderCap = 100

    #if os(macOS)
    private static let macVisibleDuplicateColumns = 3
    private static let macDuplicateCardSpacing: CGFloat = 10
    private static let macDuplicateCardMinWidth: CGFloat = 224
    #endif

    #if os(macOS)
    private enum MacDuplicateRetentionStrategy: String, CaseIterable, Hashable {
        case highestBitrate, largestFile, newest

        var title: String {
            switch self {
            case .highestBitrate: return String(localized: "dup_keep_highest_bitrate")
            case .largestFile: return String(localized: "dup_keep_largest_file")
            case .newest: return String(localized: "dup_keep_newest")
            }
        }
    }
    #endif

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private var iosBody: some View {
        Form {
            // 内嵌进度条 (而不是 overlay), 这样切到其他菜单再回来仍能看到,
            // 因为状态在 DuplicateCleanupService 里, 不绑 view 生命周期。
            if let p = cleaner.progress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(String(format: String(localized: "dup_cleaning_progress_format"),
                                        p.done, p.total))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                            Spacer()
                        }
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .progressViewStyle(.linear)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !isScanning && groups.isEmpty {
                emptyStateSection
            } else {
                if isScanning {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("dup_scanning").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    summarySection
                    cleanAllSection

                    ForEach(visibleGroups) { group in
                        groupSection(group)
                    }

                    if !showAllGroups, groups.count > Self.initialGroupRenderCap {
                        Section {
                            Button {
                                showAllGroups = true
                            } label: {
                                HStack {
                                    Image(systemName: "list.bullet.indent")
                                    Text(String(format: String(localized: "dup_show_all_format"),
                                                groups.count - Self.initialGroupRenderCap))
                                }
                            }
                        } footer: {
                            Text("dup_show_all_hint")
                        }
                    }
                }
            }
        }
        .navigationTitle("dup_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await rescan() }
        .refreshable { await rescan() }
        // 用 alert 而非 confirmationDialog: iOS 26 在 Form 内的
        // confirmationDialog 会按 popover 锚到触发按钮, 看起来像悬浮
        // 气泡且位置不固定; alert 居中显示更明显, destructive button
        // 也清楚。
        .alert(
            "dup_clean_all_confirm",
            isPresented: $showCleanAllConfirm
        ) {
            Button("dup_keep_best_action_short", role: .destructive) {
                cleanAll()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "dup_clean_all_message_format"), totalRedundantCount))
        }
        .overlay(alignment: .bottom) {
            if let msg = lastActionMessage {
                Text(msg)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: cleaner.completionRevision) { _, _ in
            // 后台完成后顺便 rescan + 给个总结提示, 即便用户切走又回来也成。
            showCleanupResult()
            Task { await rescan() }
        }
    }

    #if os(macOS)
    private var macBody: some View {
        duplicateCleanupArtboard
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PMColor.bg.ignoresSafeArea())
            .navigationTitle("dup_title")
            .task { await rescan() }
            .alert(
                "dup_clean_all_confirm",
                isPresented: $showCleanAllConfirm
            ) {
                Button("dup_mac_delete", role: .destructive) {
                    cleanAll()
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text(String(
                    format: String(localized: "dup_mac_delete_footer_format"),
                    totalRedundantCount,
                    recoverableSizeText
                ))
            }
            .overlay(alignment: .bottom) {
                if let msg = lastActionMessage {
                    Text(msg)
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: cleaner.completionRevision) { _, _ in
                showCleanupResult()
                Task { await rescan() }
            }
            .onChange(of: retentionStrategy) { _, _ in
                macKeptSongIDsByGroup.removeAll(keepingCapacity: true)
            }
    }

    private var duplicateCleanupArtboard: some View {
        VStack(spacing: 0) {
            duplicateMacHeader

            duplicateSummaryCard
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            duplicateGroupsScroll

            cleanAllCard
        }
        .frame(width: 820, height: 680)
        .background(PMColor.bg)
        .clipped()
    }

    private var duplicateMacHeader: some View {
        HStack(spacing: 12) {
            Text(verbatim: String(localized: "Duplicate Song Cleanup"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)

            Spacer(minLength: 0)

            // 跟「导入歌单 / Scrobble」一致: 右上角 X 关闭, 不再用左侧红绿灯。
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 26, height: 26)
                    .background(PMColor.glassBtn, in: .circle)
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var duplicateGroupsScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            duplicateGroupsContent
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await rescan() }
    }

    @ViewBuilder
    private var duplicateGroupsContent: some View {
        if let p = cleaner.progress {
            cleanupProgressCard(p)
                .padding(.bottom, 14)
        }

        if isScanning {
            scanningCard
        } else if groups.isEmpty {
            emptyMacCard
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(visibleGroups) { group in
                    macGroupRow(group)
                }

                if !showAllGroups, groups.count > Self.initialGroupRenderCap {
                    showAllDuplicateGroupsButton
                }
            }
        }
    }

    private var showAllDuplicateGroupsButton: some View {
        Button {
            showAllGroups = true
        } label: {
            Label(String(format: String(localized: "dup_show_all_format"),
                         groups.count - Self.initialGroupRenderCap),
                  systemImage: "list.bullet.indent")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var duplicateSummaryCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: String(format: String(localized: "dup_mac_summary_format"), groups.count, totalDuplicateFileCount))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                Text(verbatim: duplicateMatchCriteriaText)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Picker("", selection: $retentionStrategy) {
                ForEach(MacDuplicateRetentionStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 170)
        }
        .padding(14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var cleanAllCard: some View {
        Group {
            // 清理在 DuplicateCleanupService 里跑, 不绑这个窗口的生命周期 —— 清理
            // 过程中底栏换成"在后台继续", 用户可以直接关掉窗口去用 app, 清理照常
            // 进行; 重新打开本工具还能看到进度。
            if let progress = cleaner.progress {
                cleaningFooter(progress)
            } else {
                idleFooter
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var idleFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Text(verbatim: String(format: String(localized: "dup_mac_delete_footer_format"), totalRedundantCount, recoverableSizeText))
                    .foregroundStyle(PMColor.textMuted)
            }
            .font(.system(size: 12))

            Spacer()

            Button("cancel") { dismiss() }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))

            Button(role: .destructive) {
                showCleanAllConfirm = true
            } label: {
                Text(verbatim: String(localized: "dup_clean_all_action"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.bad, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(totalRedundantCount == 0 || cleaner.progress != nil)
        }
    }

    private func cleaningFooter(_ progress: DuplicateCleanupService.Progress) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            HStack(spacing: 0) {
                Text(verbatim: String(format: String(localized: "dup_mac_cleaning_footer_format"), progress.done, progress.total))
                    .foregroundStyle(PMColor.textMuted)
            }
            .font(.system(size: 12))

            Spacer()

            Button("dup_mac_continue_background") { dismiss() }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(PMColor.brand, in: .rect(cornerRadius: 6))
        }
    }

    private func cleanupProgressCard(_ progress: DuplicateCleanupService.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(String(format: String(localized: "dup_cleaning_progress_format"),
                            progress.done, progress.total))
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.text)
                Spacer()
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .tint(PMColor.brand)
        }
        .padding(14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var scanningCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("dup_scanning")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
            Spacer()
        }
        .padding(14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
    }

    private var emptyMacCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 42))
                .foregroundStyle(PMColor.ok)
            Text("dup_none_title")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("dup_none_desc")
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func macGroupRow(_ group: DuplicateGroup) -> some View {
        let deletableSourceIDs = deletableSourceIDsSnapshot
        let keptSongIDs = macKeptSongIDs(
            in: group,
            deletableSourceIDs: deletableSourceIDs
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CachedArtworkView(
                    coverRef: group.bestSong.coverArtFileName,
                    songID: group.bestSong.id,
                    size: 34,
                    cornerRadius: 6,
                    sourceID: group.bestSong.sourceID,
                    filePath: group.bestSong.filePath,
                    fileFormat: group.bestSong.fileFormat
                )

                Text(group.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                Text(verbatim: "· \(group.artist.isEmpty ? "—" : group.artist)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)

                Text(verbatim: String(format: String(localized: "dup_mac_copies_format"), group.count))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(PMColor.brand.opacity(0.14), in: .capsule)

                Spacer()
            }

            GeometryReader { proxy in
                let cardWidth = macDuplicateCardWidth(
                    availableWidth: proxy.size.width,
                    songCount: group.songs.count
                )

                if group.songs.count <= Self.macVisibleDuplicateColumns {
                    HStack(alignment: .top, spacing: Self.macDuplicateCardSpacing) {
                        macSongCards(
                            in: group,
                            deletableSourceIDs: deletableSourceIDs,
                            keptSongIDs: keptSongIDs,
                            cardWidth: cardWidth
                        )
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(alignment: .top, spacing: Self.macDuplicateCardSpacing) {
                            macSongCards(
                                in: group,
                                deletableSourceIDs: deletableSourceIDs,
                                keptSongIDs: keptSongIDs,
                                cardWidth: cardWidth
                            )
                        }
                    }
                }
            }
            .frame(height: 104)
        }
        .padding(12)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func macDuplicateCardWidth(availableWidth: CGFloat, songCount: Int) -> CGFloat {
        let visibleColumns = min(max(songCount, 1), Self.macVisibleDuplicateColumns)
        let spacing = CGFloat(max(visibleColumns - 1, 0)) * Self.macDuplicateCardSpacing
        let fittedWidth = (availableWidth - spacing) / CGFloat(visibleColumns)
        return max(Self.macDuplicateCardMinWidth, fittedWidth)
    }

    @ViewBuilder
    private func macSongCards(
        in group: DuplicateGroup,
        deletableSourceIDs: Set<String>,
        keptSongIDs: Set<String>,
        cardWidth: CGFloat
    ) -> some View {
        ForEach(group.songs, id: \.id) { song in
            let isReadOnly = !deletableSourceIDs.contains(song.sourceID)
            macSongCard(
                song: song,
                group: group,
                isKept: keptSongIDs.contains(song.id),
                isReadOnly: isReadOnly
            )
            .frame(width: cardWidth, height: 104)
        }
    }

    @ViewBuilder
    private func macSongCard(
        song: Song,
        group: DuplicateGroup,
        isKept: Bool,
        isReadOnly: Bool
    ) -> some View {
        let action = isReadOnly
            ? String(localized: "dup_mac_keep_read_only")
            : String(localized: isKept ? "dup_mac_keep" : "dup_mac_delete")
        let accessibilityLabel = Text(verbatim: "\(action) · \(duplicateSourceName(song))")

        if isReadOnly {
            macSongCardContent(
                song: song,
                action: action,
                isKept: true,
                isReadOnly: true
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        } else {
            Button {
                toggleMacSongKept(song, in: group)
            } label: {
                macSongCardContent(
                    song: song,
                    action: action,
                    isKept: isKept,
                    isReadOnly: false
                )
            }
            .buttonStyle(.plain)
            .disabled(cleaner.progress != nil)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(Text(verbatim: action))
            .accessibilityAddTraits(isKept ? [] : .isSelected)
        }
    }

    private func macSongCardContent(
        song: Song,
        action: String,
        isKept: Bool,
        isReadOnly: Bool
    ) -> some View {
        let statusColor = isReadOnly ? PMColor.textMuted : (isKept ? PMColor.brand : PMColor.bad)
        let statusIcon = isReadOnly
            ? "lock.fill"
            : (isKept ? "circle" : "checkmark.circle.fill")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))

                Text(verbatim: action)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                macFormatLabel(song)
            }
            .foregroundStyle(statusColor)

            HStack(spacing: 6) {
                Image(systemName: isReadOnly ? "music.note" : "externaldrive.fill")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(PMColor.textFaint)

                Text(verbatim: duplicateSourceName(song))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 8) {
                macQualityMetric("smart_field_bitRate", value: bitrateText(song))
                macQualityMetric("sample_rate_label", value: sampleRateText(song))
                macQualityMetric("file_size_label", value: fileSizeText(song))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PMColor.bg, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .overlay(alignment: .top) {
            if !isKept && !isReadOnly {
                Capsule()
                    .fill(PMColor.bad)
                    .frame(width: 34, height: 2)
                    .padding(.top, 1)
            }
        }
        .contentShape(Rectangle())
        .help(Text(verbatim: sourceDescription(song)))
    }

    private func macQualityMetric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(verbatim: value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macFormatLabel(_ song: Song) -> some View {
        let format = song.fileFormat.displayName.uppercased()
        let text = format.isEmpty ? "—" : format
        let isLossless = ["FLAC", "ALAC", "APE", "WAV", "AIFF"].contains(format)
        let foreground = isLossless ? PMColor.flac : PMColor.textMuted
        return Text(verbatim: text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(foreground.opacity(0.10), in: .capsule)
    }
    #endif

    // MARK: - Sections

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("dup_none_title").font(.headline)
                Text("dup_none_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private var summarySection: some View {
        Section {
            HStack {
                Label("dup_groups_count", systemImage: "square.stack.3d.up")
                Spacer()
                Text("\(groups.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Label("dup_redundant_count", systemImage: "trash")
                Spacer()
                Text("\(totalRedundantCount)").foregroundStyle(.secondary).monospacedDigit()
            }
        } footer: {
            Text("dup_summary_footer")
        }
    }

    private var cleanAllSection: some View {
        Section {
            Button(role: .destructive) {
                showCleanAllConfirm = true
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("dup_clean_all_action")
                }
            }
            .disabled(totalRedundantCount == 0 || cleaner.progress != nil)
        }
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup) -> some View {
        let writableSourceIDs = deletableSourceIDsSnapshot
        let groupRemovableSongs = removableSongs(
            in: group,
            deletableSourceIDs: writableSourceIDs
        )
        let removableSongIDs = Set(groupRemovableSongs.map(\.id))
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroupID == group.id },
                    set: { isExpanded in expandedGroupID = isExpanded ? group.id : nil }
                )
            ) {
                ForEach(group.songs, id: \.id) { song in
                    songRow(
                        song: song,
                        isBest: song.id == group.bestSong.id,
                        group: group,
                        canDelete: removableSongIDs.contains(song.id)
                    )
                }

                Button {
                    keepBest(of: group)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text(String(format: String(localized: "dup_keep_best_action_format"), groupRemovableSongs.count))
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 4)
                .disabled(groupRemovableSongs.isEmpty || cleaner.progress != nil)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(group.artist.isEmpty ? "—" : group.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(group.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func songRow(song: Song, isBest: Bool, group: DuplicateGroup, canDelete: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(song.fileFormat.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(formatBadgeColor(song).opacity(0.18)))
                        .foregroundStyle(formatBadgeColor(song))
                    if isBest {
                        Text("dup_best_badge")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                }
                Text(qualityDescription(song))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(sourceDescription(song))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer()

            Button(role: .destructive) {
                deleteSingle(song: song, in: group)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(group.songs.count <= 1 || !canDelete || cleaner.progress != nil)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func rescan() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        defer {
            if generation == scanGeneration {
                isScanning = false
            }
        }
        // 主线程只负责拍 snapshot, 实际 Dictionary(grouping:) + folding
        // + sort 全部到后台跑。10k+ 库主线程跑要 1-3s 直接卡 UI。
        let snapshot = library.visibleSongs
        let detected = await Task.detached(priority: .userInitiated) {
            DuplicateDetector.detect(in: snapshot)
        }.value
        // A pull-to-refresh may have captured the pre-cleanup library while
        // the completion-triggered scan starts later with committed data.
        // Only the newest scan may publish, so an older detached result can
        // never restore the stale duplicate count.
        guard generation == scanGeneration else { return }
        groups = detected
        expandedGroupID = nil
        showAllGroups = false
        #if os(macOS)
        macKeptSongIDsByGroup.removeAll(keepingCapacity: true)
        #endif
    }

    private func keepBest(of group: DuplicateGroup) {
        let toRemove = removableSongs(
            in: group,
            deletableSourceIDs: deletableSourceIDsSnapshot
        )
        guard !toRemove.isEmpty else { return }
        startCleanup(toRemove)
    }

    private func deleteSingle(song: Song, in group: DuplicateGroup) {
        let removableSongIDs = Set(removableSongs(
            in: group,
            deletableSourceIDs: deletableSourceIDsSnapshot
        ).map(\.id))
        guard removableSongIDs.contains(song.id) else { return }
        startCleanup([song])
    }

    private func cleanAll() {
        let writableSourceIDs = deletableSourceIDsSnapshot
        let toRemove = groups.flatMap {
            removableSongs(in: $0, deletableSourceIDs: writableSourceIDs)
        }
        startCleanup(toRemove)
    }

    /// Keep the completion-revision observer for cleanups that outlive this
    /// view, but also await a cleanup started by the visible view and rescan
    /// directly. In practice SwiftUI can coalesce the observable revision with
    /// the large library mutation, leaving the already-rendered duplicate
    /// groups on screen until the user navigates away and back even though the
    /// files and library rows were deleted successfully.
    private func startCleanup(_ songs: [Song]) {
        guard let cleanupTask = cleaner.cleanup(songs) else { return }
        Task {
            await cleanupTask.value
            await rescan()
        }
    }

    private func showCleanupResult() {
        let failedCount = cleaner.lastFailedTitles.count
        if failedCount > 0 {
            flashAction(String(format: String(localized: "dup_clean_failed_format"), failedCount))
        } else if cleaner.lastCompletedCount > 0 {
            flashAction(String(
                format: String(localized: "dup_clean_all_done_format"),
                cleaner.lastCompletedCount
            ))
        }
    }

    private func flashAction(_ msg: String) {
        withAnimation { lastActionMessage = msg }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { lastActionMessage = nil }
        }
    }

    // MARK: - Display helpers

    private var totalRedundantCount: Int {
        let writableSourceIDs = deletableSourceIDsSnapshot
        return groups.reduce(0) {
            $0 + removableSongs(in: $1, deletableSourceIDs: writableSourceIDs).count
        }
    }

    #if os(macOS)
    private var totalDuplicateFileCount: Int {
        groups.reduce(0) { $0 + $1.songs.count }
    }

    private var duplicateMatchCriteriaText: String {
        [
            String(localized: "title"),
            String(localized: "artist_label"),
            String(localized: "duration_label"),
        ].joined(separator: " + ")
    }

    private var recoverableBytes: Int64 {
        let writableSourceIDs = deletableSourceIDsSnapshot
        return groups
            .flatMap { removableSongs(in: $0, deletableSourceIDs: writableSourceIDs) }
            .reduce(Int64(0)) { $0 + max(Int64(0), $1.fileSize) }
    }

    private var recoverableSizeText: String {
        ByteCountFormatter.string(fromByteCount: recoverableBytes, countStyle: .file)
    }

    private func preferredSong(in songs: [Song]) -> Song? {
        guard !songs.isEmpty else { return nil }
        switch retentionStrategy {
        case .highestBitrate:
            return songs.max { lhs, rhs in
                let leftQuality = (
                    lhs.bitRate ?? 0,
                    lhs.sampleRate ?? 0,
                    lhs.bitDepth ?? 0,
                    lhs.fileSize
                )
                let rightQuality = (
                    rhs.bitRate ?? 0,
                    rhs.sampleRate ?? 0,
                    rhs.bitDepth ?? 0,
                    rhs.fileSize
                )
                return leftQuality < rightQuality
            }
        case .largestFile:
            return songs.max { $0.fileSize < $1.fileSize }
        case .newest:
            return songs.max { newestDate($0) < newestDate($1) }
        }
    }

    private func macKeptSongIDs(
        in group: DuplicateGroup,
        deletableSourceIDs: Set<String>
    ) -> Set<String> {
        let readOnlySongIDs = Set(group.songs.lazy
            .filter { !deletableSourceIDs.contains($0.sourceID) }
            .map(\.id))
        let writableSongs = group.songs.filter {
            deletableSourceIDs.contains($0.sourceID)
        }
        let writableSongIDs = writableSongs.map(\.id)
        let writableSongIDSet = Set(writableSongIDs)

        if let overriddenSongIDs = macKeptSongIDsByGroup[group.id] {
            let validSongIDs = readOnlySongIDs.union(writableSongIDSet)
            var normalizedSongIDs = overriddenSongIDs.intersection(validSongIDs)
            normalizedSongIDs.formUnion(readOnlySongIDs)
            if !writableSongIDs.isEmpty,
               writableSongIDSet.isDisjoint(with: normalizedSongIDs),
               let fallbackSongID = preferredSong(in: writableSongs)?.id {
                normalizedSongIDs.insert(fallbackSongID)
            }
            return normalizedSongIDs
        }

        return DuplicateCleanupSelectionPolicy.defaultKeptSongIDs(
            readOnlySongIDs: readOnlySongIDs,
            writableSongIDs: writableSongIDs,
            preferredWritableSongID: preferredSong(in: writableSongs)?.id
        )
    }

    private func toggleMacSongKept(_ song: Song, in group: DuplicateGroup) {
        let deletableSourceIDs = deletableSourceIDsSnapshot
        guard deletableSourceIDs.contains(song.sourceID) else { return }

        let readOnlySongIDs = Set(group.songs.lazy
            .filter { !deletableSourceIDs.contains($0.sourceID) }
            .map(\.id))
        let writableSongIDs = group.songs.lazy
            .filter { deletableSourceIDs.contains($0.sourceID) }
            .map(\.id)
        let currentKeptSongIDs = macKeptSongIDs(
            in: group,
            deletableSourceIDs: deletableSourceIDs
        )
        macKeptSongIDsByGroup[group.id] = DuplicateCleanupSelectionPolicy.toggledKeptSongIDs(
            currentKeptSongIDs: currentKeptSongIDs,
            toggledSongID: song.id,
            readOnlySongIDs: readOnlySongIDs,
            writableSongIDs: Array(writableSongIDs)
        )
    }

    private func macRemovableSongs(
        in group: DuplicateGroup,
        deletableSourceIDs: Set<String>
    ) -> [Song] {
        let writableSongIDs = group.songs.lazy
            .filter { deletableSourceIDs.contains($0.sourceID) }
            .map(\.id)
        let removableSongIDs = DuplicateCleanupSelectionPolicy.removableSongIDs(
            writableSongIDs: Array(writableSongIDs),
            keptSongIDs: macKeptSongIDs(
                in: group,
                deletableSourceIDs: deletableSourceIDs
            )
        )
        return group.songs.filter { removableSongIDs.contains($0.id) }
    }

    private func newestDate(_ song: Song) -> Date {
        song.lastModified ?? song.dateAdded
    }

    private func duplicateSourceName(_ song: Song) -> String {
        let name = sourcesStore.allSources.first(where: { $0.id == song.sourceID })?.name
            ?? String(localized: "Unknown Source")
        return localizedSourceNameForMac(name)
    }

    private func localizedSourceNameForMac(_ name: String) -> String {
        guard Locale.preferredLanguages.first?.hasPrefix("zh") != true else { return name }
        switch name.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "百度网盘":
            return String(localized: "Baidu Netdisk")
        case "群晖", "群晖 NAS", "Synology NAS":
            return "Synology"
        case "阿里云盘":
            return "Aliyun Drive"
        case "本地", "本地文件":
            return "Local Files"
        default:
            return name
        }
    }

    private func bitrateText(_ song: Song) -> String {
        song.formattedBitRate ?? "—"
    }

    private func sampleRateText(_ song: Song) -> String {
        guard let sampleRate = song.sampleRate, sampleRate > 0 else { return "—" }
        let value = Double(sampleRate) / 1000
        return value.rounded() == value ? "\(Int(value))k" : String(format: "%.1fk", value)
    }

    private func fileSizeText(_ song: Song) -> String {
        guard song.fileSize > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file)
    }
    #endif

    /// Read-only catalogues are never candidates for source deletion. Every
    /// group also preserves at least one writable copy so a streaming catalogue
    /// entry can never cause the user's only local/NAS copy to be removed.
    private var deletableSourceIDsSnapshot: Set<String> {
        Set(sourcesStore.sources.lazy
            .filter { $0.type.supportsFileDeletion }
            .map(\.id))
    }

    private func removableSongs(
        in group: DuplicateGroup,
        deletableSourceIDs: Set<String>
    ) -> [Song] {
        let writable = group.songs.filter { deletableSourceIDs.contains($0.sourceID) }
        #if os(macOS)
        return macRemovableSongs(in: group, deletableSourceIDs: deletableSourceIDs)
        #else
        guard writable.count > 1,
              let keptWritableID = group.songs.first(where: {
                  deletableSourceIDs.contains($0.sourceID)
              })?.id else { return [] }
        return writable.filter { $0.id != keptWritableID }
        #endif
    }

    private var visibleGroups: [DuplicateGroup] {
        if showAllGroups || groups.count <= Self.initialGroupRenderCap {
            return groups
        }
        return Array(groups.prefix(Self.initialGroupRenderCap))
    }

    private func qualityDescription(_ song: Song) -> String {
        var parts = [song.formattedBitRate, song.formattedSampleRate, song.formattedBitDepth]
            .compactMap { $0 }
        if song.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func sourceDescription(_ song: Song) -> String {
        let src = sourcesStore.allSources.first(where: { $0.id == song.sourceID })
        let sourceName = src?.name ?? "?"
        return "\(sourceName)  \(song.filePath)"
    }

    private func formatBadgeColor(_ song: Song) -> Color {
        switch song.fileFormat {
        case .flac, .alac, .wav, .aiff, .aif, .ape, .wv: return .purple
        case .dsf, .dff: return .pink
        default: return .blue
        }
    }
}
