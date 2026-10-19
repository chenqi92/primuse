import SwiftUI
import PrimuseKit

/// 把歌单复制到一台音乐服务器上(例如 Apple Music 的歌单放进 Navidrome)。
///
/// 先选服务器(和要传的歌单), 每首歌对到那台服务器的曲库上, 给人看服务器上有几首、没有哪些,
/// 确认后才写。只复制一个歌单时可以选写进哪个服务端歌单、改新歌单的名字; 好几个时按同名
/// 自动决定。写入只往里加, 服务器上没有的歌不写。
struct PlaylistCopyToServerSheet: View {
    /// 预选的歌单。为空时先让人勾选: 从歌单页进来要能一次挑好几个, 包括 Apple Music 的。
    let playlistIDs: [String]
    /// 写完、用户点「完成」后回调。
    var onFinish: () -> Void = {}

    init(playlistIDs: [String], onFinish: @escaping () -> Void = {}) {
        self.playlistIDs = playlistIDs
        self.onFinish = onFinish
        _selectedIDs = State(initialValue: playlistIDs)
        _isChoosing = State(initialValue: playlistIDs.isEmpty)
    }

    @Environment(MusicLibrary.self) private var library
    // 可选: 与 AddToPlaylistSheet 一样, 独立宿主里未必注入。
    @Environment(SourcesStore.self) private var sourcesStore: SourcesStore?
    @Environment(SourceManager.self) private var sourceManager: SourceManager?
    @Environment(\.dismiss) private var dismiss

    @State private var targetSourceID: String?
    @State private var selectedIDs: [String]
    @State private var isChoosing: Bool
    @State private var plans: [ServerPlaylistCopyPlan] = []
    @State private var isMatching = false
    @State private var includesProbable = false
    /// 只复制一个歌单时用户选的去向; nil = 按同名自动决定。
    @State private var chosenDestination: ServerPlaylistCopyPolicy.Destination?
    @State private var newPlaylistName = ""
    @State private var isCopying = false
    @State private var copiedCount = 0
    @State private var outcomes: [Outcome]?

    private struct Outcome: Identifiable {
        let id = UUID()
        let playlistName: String
        let message: String
        let isFailure: Bool
    }

    private typealias Destination = ServerPlaylistCopyPolicy.Destination

    private struct CandidateGroup: Identifiable {
        let title: String
        var playlists: [Playlist]
        var id: String { title }
    }

    private struct PlanTrigger: Hashable {
        let targetSourceID: String?
        let isChoosing: Bool
        let selectedIDs: [String]
    }

    var body: some View {
        content
            .task(id: PlanTrigger(targetSourceID: targetSourceID, isChoosing: isChoosing, selectedIDs: selectedIDs)) {
                guard targetSourceID != nil else {
                    targetSourceID = targets.first?.id
                    return
                }
                guard !isChoosing else { return }
                await rebuildPlans()
            }
            .interactiveDismissDisabled(isCopying)
    }

    // MARK: - State

    private var isSingle: Bool { selectedIDs.count == 1 }

    /// 能写歌单的服务器源; 预选了歌单时, 去掉那些歌单全是它自己的服务器。
    private var targets: [MusicSource] {
        guard let sourcesStore else { return [] }
        let sources = ServerPlaylistCopyService.targetSources(sourcesStore: sourcesStore)
        guard !playlistIDs.isEmpty else { return sources }
        return sources.filter { source in
            playlistIDs.contains { ServerPlaylistCopyService.canCopy(playlistID: $0, to: source) }
        }
    }

    /// 勾选那一步列出的歌单, 按来源分组: 自己的歌单、Apple Music、各个音乐源同步来的。
    private var candidateGroups: [CandidateGroup] {
        guard let target else { return [] }
        var groups: [CandidateGroup] = []
        for playlist in library.playlists
        where ServerPlaylistCopyService.canCopy(playlistID: playlist.id, to: target)
            && library.songCount(forPlaylist: playlist.id) > 0 {
            let title = originTitle(of: playlist)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].playlists.append(playlist)
            } else {
                groups.append(CandidateGroup(title: title, playlists: [playlist]))
            }
        }
        return groups
    }

    private func originTitle(of playlist: Playlist) -> String {
        if AppleMusicLibraryIdentity.isMirrorPlaylist(playlist.id) { return "Apple Music" }
        let folderSourceID = playlist.folderBinding?.sourceID
        if folderSourceID != nil || ServerPlaylistIdentity.isMirrorPlaylist(playlist.id),
           let source = sourcesStore?.sources.first(where: { source in
               source.id == folderSourceID
                   || playlist.id.hasPrefix(ServerPlaylistIdentity.playlistIDPrefix(sourceID: source.id))
           }) {
            return source.name
        }
        return String(localized: "playlists_title")
    }

    private func toggleSelection(_ playlistID: String) {
        if let index = selectedIDs.firstIndex(of: playlistID) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(playlistID)
        }
    }

    /// 勾选好以后按歌单列表的顺序往下走。
    private func finishChoosing() {
        let order = library.playlists.map(\.id)
        selectedIDs = order.filter(selectedIDs.contains)
        newPlaylistName = ""
        isChoosing = false
    }

    private var target: MusicSource? {
        targets.first { $0.id == targetSourceID }
    }

    private var canCreate: Bool {
        target.map { ServerPlaylistWritebackPolicy.supportsCreating($0.type) } ?? false
    }

    private var writablePlaylists: [Playlist] {
        guard let target else { return [] }
        return ServerPlaylistAppendService.writablePlaylists(sourceID: target.id, library: library)
    }

    private func destination(for plan: ServerPlaylistCopyPlan) -> Destination {
        if isSingle, let chosenDestination { return chosenDestination }
        guard let target else { return .needsServerPlaylist }
        return ServerPlaylistCopyService.destination(forName: plan.name, target: target, library: library)
    }

    private func name(for plan: ServerPlaylistCopyPlan) -> String {
        guard isSingle else { return plan.name }
        return newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 不会写的原因; nil = 能写。
    private func skipReason(for plan: ServerPlaylistCopyPlan) -> String? {
        if plan.songs(includingProbable: includesProbable).isEmpty {
            return String(localized: "server_playlist_copy_nothing")
        }
        switch destination(for: plan) {
        case .needsServerPlaylist:
            return String(localized: "server_playlist_copy_needs_playlist")
        case .create where name(for: plan).isEmpty:
            return String(localized: "server_playlist_copy_needs_name")
        case .create, .append:
            return nil
        }
    }

    private var copyablePlans: [ServerPlaylistCopyPlan] {
        plans.filter { skipReason(for: $0) == nil }
    }

    private var canStartCopy: Bool {
        !isChoosing && !isMatching && !isCopying && outcomes == nil && target != nil && !copyablePlans.isEmpty
    }

    private var confirmTitle: String {
        if isChoosing {
            return String(format: String(localized: "server_playlist_copy_next_format"), selectedIDs.count)
        }
        if isSingle, let plan = plans.first {
            return String(
                format: String(localized: "server_playlist_copy_confirm_format"),
                plan.songs(includingProbable: includesProbable).count
            )
        }
        return String(format: String(localized: "server_playlist_copy_batch_confirm_format"), copyablePlans.count)
    }

    private var subtitle: String {
        if isSingle, let id = selectedIDs.first, let playlist = library.playlist(id: id) { return playlist.name }
        return String(format: String(localized: "batch_playlists_selected_count_format"), selectedIDs.count)
    }

    /// 底栏 / 工具栏的主按钮: 勾选那一步是「下一步」, 之后是「复制」。
    private var primaryEnabled: Bool {
        isChoosing ? !selectedIDs.isEmpty && target != nil : canStartCopy
    }

    private func primaryAction() {
        if isChoosing {
            finishChoosing()
        } else {
            startCopy()
        }
    }

    private var destinationBinding: Binding<Destination> {
        Binding(
            get: { plans.first.map(destination(for:)) ?? .needsServerPlaylist },
            set: { chosenDestination = $0 }
        )
    }

    private func rebuildPlans() async {
        guard let target else {
            plans = []
            return
        }
        let requested = target.id
        isMatching = true
        chosenDestination = nil
        let requestedIDs = selectedIDs
        let rebuilt = await ServerPlaylistCopyService.plans(for: requestedIDs, target: target, library: library)
        // 对照途中换了服务器或改了勾选: 这一份作废, 由新的那一轮接手。
        guard targetSourceID == requested, selectedIDs == requestedIDs, !isChoosing else { return }
        plans = rebuilt
        if isSingle, newPlaylistName.isEmpty, let plan = rebuilt.first { newPlaylistName = plan.name }
        isMatching = false
    }

    // MARK: - Copy

    private func startCopy() {
        guard canStartCopy, let target, let sourceManager else { return }
        let jobs = copyablePlans.map { (plan: $0, name: name(for: $0), destination: destination(for: $0)) }
        let skipped = plans.compactMap { plan -> Outcome? in
            guard let reason = skipReason(for: plan) else { return nil }
            return Outcome(playlistName: plan.name, message: reason, isFailure: true)
        }
        let includesProbable = includesProbable
        let isSingle = isSingle
        isCopying = true
        copiedCount = 0
        Task { @MainActor in
            var results: [Outcome] = []
            for job in jobs {
                // 好几个歌单时去向在写之前再算一次: 前一个刚新建的同名歌单, 后一个就往里加。
                let destination = isSingle
                    ? job.destination
                    : ServerPlaylistCopyService.destination(forName: job.plan.name, target: target, library: library)
                do {
                    if let result = try await ServerPlaylistCopyService.copy(
                        job.plan,
                        named: job.name,
                        to: destination,
                        includingProbable: includesProbable,
                        target: target,
                        library: library,
                        sourceManager: sourceManager
                    ) {
                        results.append(Outcome(playlistName: job.plan.name, message: message(for: result), isFailure: false))
                    }
                } catch is CancellationError {
                    results.append(Outcome(
                        playlistName: job.plan.name,
                        message: String(localized: "server_playlist_copy_cancelled"),
                        isFailure: true
                    ))
                } catch {
                    results.append(Outcome(playlistName: job.plan.name, message: error.localizedDescription, isFailure: true))
                }
                copiedCount += 1
            }
            outcomes = results + skipped
            isCopying = false
        }
    }

    private func message(for result: ServerPlaylistCopyResult) -> String {
        let key: String.LocalizationValue = result.created
            ? "server_playlist_copy_created_format"
            : "server_playlist_copy_appended_format"
        var text = String(format: String(localized: key), result.serverPlaylistName, result.trackCount)
        if result.skippedCount > 0 {
            // 分隔符写在各语言的文案里(中文是全角逗号, 英文是空格加括号)。
            text += String(
                format: String(localized: "server_playlist_copy_skipped_suffix_format"),
                result.skippedCount
            )
        }
        return text
    }

    private func finish() {
        onFinish()
        dismiss()
    }

    // MARK: - Form

    @ViewBuilder
    private var formSections: some View {
        if targets.isEmpty {
            Section {
                Text("server_playlist_copy_no_targets")
                    .foregroundStyle(.secondary)
            }
        } else if let outcomes {
            Section {
                ForEach(outcomes) { outcome in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: outcome.playlistName)
                            .font(.subheadline.weight(.medium))
                        Text(verbatim: outcome.message)
                            .font(.caption)
                            .foregroundStyle(outcome.isFailure ? Color.orange : Color.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("server_playlist_copy_results_header")
            }
        } else if isChoosing {
            serverSection
            chooserSections
        } else {
            serverSection
            if isMatching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("server_playlist_copy_matching")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isSingle, let plan = plans.first {
                singleSections(plan)
            } else if !plans.isEmpty {
                batchSections
            }
        }
    }

    @ViewBuilder
    private var chooserSections: some View {
        let groups = candidateGroups
        if groups.isEmpty {
            Section {
                Text("server_playlist_copy_no_candidates")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(groups) { group in
            Section {
                ForEach(group.playlists) { playlist in
                    Button {
                        toggleSelection(playlist.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIDs.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedIDs.contains(playlist.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: playlist.name)
                                    .lineLimit(1)
                                Text(verbatim: String(
                                    format: String(localized: "carplay_playlist_song_count_format"),
                                    library.songCount(forPlaylist: playlist.id)
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedIDs.contains(playlist.id) ? .isSelected : [])
                }
            } header: {
                Text(verbatim: group.title)
            }
        }
    }

    private var serverSection: some View {
        Section {
            if targets.count > 1 {
                Picker("server_playlist_copy_server", selection: $targetSourceID) {
                    ForEach(targets) { source in
                        Text(verbatim: source.name).tag(Optional(source.id))
                    }
                }
                .disabled(isCopying)
            } else if let target {
                LabeledContent("server_playlist_copy_server") {
                    Text(verbatim: target.name)
                }
            }
            // 从歌单页挑的, 复制前还能回去改选。
            if playlistIDs.isEmpty, !isChoosing {
                Button {
                    plans = []
                    isChoosing = true
                } label: {
                    LabeledContent {
                        Text(verbatim: String(
                            format: String(localized: "batch_playlists_selected_count_format"),
                            selectedIDs.count
                        ))
                    } label: {
                        Text("server_playlist_copy_change_selection")
                    }
                }
                .disabled(isCopying)
            }
        }
    }

    @ViewBuilder
    private func singleSections(_ plan: ServerPlaylistCopyPlan) -> some View {
        Section {
            countRow("server_playlist_copy_on_server", count: plan.matchedCount,
                     systemImage: "checkmark.circle.fill", color: .green)
            if plan.probableCount > 0 {
                countRow("server_playlist_copy_probable", count: plan.probableCount,
                         systemImage: "questionmark.diamond", color: .accentColor)
                Toggle("server_playlist_copy_include_probable", isOn: $includesProbable)
            }
            countRow("server_playlist_copy_missing", count: plan.missingCount,
                     systemImage: "questionmark.circle", color: plan.missingCount > 0 ? .orange : .secondary)
        } footer: {
            Text("server_playlist_copy_footer")
        }

        Section {
            Picker("server_playlist_copy_destination", selection: destinationBinding) {
                if canCreate {
                    Text("new_playlist").tag(Destination.create)
                } else if writablePlaylists.isEmpty || destinationBinding.wrappedValue == .needsServerPlaylist {
                    Text("server_playlist_copy_choose").tag(Destination.needsServerPlaylist)
                }
                ForEach(writablePlaylists) { playlist in
                    Text(verbatim: playlist.name).tag(Destination.append(playlistID: playlist.id))
                }
            }
            .disabled(isCopying)
            if destinationBinding.wrappedValue == .create {
                TextField("playlist_name", text: $newPlaylistName)
                    .disabled(isCopying)
            }
        } footer: {
            if let reason = skipReason(for: plan) {
                Text(verbatim: reason)
            }
        }

        let missing = plan.entries.filter { $0.match == nil && $0.probable == nil }
        if !missing.isEmpty {
            Section {
                ForEach(missing) { entry in
                    entryText(title: entry.title, artist: entry.artist)
                }
            } header: {
                Text("server_playlist_copy_missing_header")
            }
        }

        let probable = plan.entries.filter { $0.match == nil && $0.probable != nil }
        if !probable.isEmpty {
            Section {
                ForEach(probable) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        entryText(title: entry.title, artist: entry.artist)
                        if let song = entry.probable {
                            Label {
                                Text(verbatim: [song.title, song.artistName ?? ""]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " — "))
                            } icon: {
                                Image(systemName: "arrow.turn.down.right")
                            }
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("server_playlist_copy_probable_header")
            }
        }
    }

    @ViewBuilder
    private var batchSections: some View {
        Section {
            Text(verbatim: String(
                format: String(localized: "server_playlist_copy_batch_summary_format"),
                plans.count,
                plans.reduce(0) { $0 + $1.matchedCount }
            ))
            if plans.contains(where: { $0.probableCount > 0 }) {
                Toggle("server_playlist_copy_include_probable", isOn: $includesProbable)
                    .disabled(isCopying)
            }
        } footer: {
            Text("server_playlist_copy_footer")
        }

        Section {
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: plan.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: batchDetail(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let reason = skipReason(for: plan) {
                        Text(verbatim: reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("server_playlist_copy_playlists_header")
        }
    }

    private func batchDetail(_ plan: ServerPlaylistCopyPlan) -> String {
        var parts = [String(
            format: String(localized: "server_playlist_copy_batch_row_format"),
            plan.matchedCount,
            plan.entries.count
        )]
        switch destination(for: plan) {
        case .create:
            parts.append(String(format: String(localized: "server_playlist_copy_new_format"), plan.name))
        case .append(let playlistID):
            let name = library.playlist(id: playlistID)?.name ?? plan.name
            parts.append(String(format: String(localized: "server_playlist_copy_append_format"), name))
        case .needsServerPlaylist:
            break
        }
        return parts.joined(separator: " · ")
    }

    private func countRow(
        _ titleKey: LocalizedStringKey,
        count: Int,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack {
            Label(titleKey, systemImage: systemImage)
                .foregroundStyle(color)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func entryText(title: String, artist: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.subheadline)
                .lineLimit(1)
            if let artist, !artist.isEmpty {
                Text(verbatim: artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var progressText: String {
        String(
            format: String(localized: "server_playlist_copy_progress_format"),
            min(copiedCount + 1, max(copyablePlans.count, 1)),
            max(copyablePlans.count, 1)
        )
    }

    // MARK: - Shells

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("server_playlist_copy_title")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: subtitle)
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                PMRoundBtn(icon: "xmark", size: 26, iconSize: 11, style: .glass,
                           help: "cancel") { dismiss() }
                    .disabled(isCopying)
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            Form { formSections }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                if isCopying {
                    ProgressView().controlSize(.small)
                    Text(verbatim: progressText)
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                if outcomes != nil {
                    macButton(String(localized: "done"), primary: true, enabled: true) { finish() }
                } else {
                    macButton(String(localized: "cancel"), primary: false, enabled: !isCopying) { dismiss() }
                    macButton(confirmTitle, primary: true, enabled: primaryEnabled) { primaryAction() }
                }
            }
            .padding(18)
        }
        .frame(width: 520, height: 620)
        .background(PMColor.bg)
    }

    private func macButton(
        _ title: String,
        primary: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? Color.white : PMColor.text)
                .padding(.horizontal, primary ? 16 : 14)
                .frame(height: 28)
                .background(
                    primary ? (enabled ? PMColor.brand : PMColor.textFaint) : PMColor.glassBtn,
                    in: .rect(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
    #else
    private var content: some View {
        NavigationStack {
            Form { formSections }
                .navigationTitle(Text("server_playlist_copy_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if outcomes != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("done") { finish() }
                                .fontWeight(.semibold)
                        }
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("cancel") { dismiss() }
                                .disabled(isCopying)
                        }
                        ToolbarItem(placement: .principal) {
                            VStack(spacing: 1) {
                                Text("server_playlist_copy_title")
                                    .font(.headline)
                                Text(verbatim: isCopying ? progressText : subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if isCopying {
                                ProgressView()
                            } else {
                                Button { primaryAction() } label: { Text(verbatim: confirmTitle) }
                                    .fontWeight(.semibold)
                                    .disabled(!primaryEnabled)
                            }
                        }
                    }
                }
        }
    }
    #endif
}
