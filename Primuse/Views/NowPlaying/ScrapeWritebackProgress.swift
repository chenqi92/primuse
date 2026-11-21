import SwiftUI
import PrimuseKit

/// 刮削结果点了保存之后的写入。弹出页立刻收起，写入在这里接着做，进度显示在 App 最上层的卡片里，
/// 点「后台写入」收成一枚胶囊，播放页照常可用。
///
/// 每个任务只认保存那一刻的歌曲 id 和快照：写歌词、存封面、改资料库那一行、写回音乐源都按这首歌的 id
/// 和文件走，和正在放哪一首无关，所以中途切歌、收起播放页都不影响写入。同一时间只跑一个任务，后保存的
/// 排在前一个后面，免得两次写入同时改同一个音频文件。
///
/// 播放页「暂无歌词」那颗按钮的自动刮削也用同一张卡片报结果，替掉原来写完才弹的提示框。
@MainActor
@Observable
final class ScrapeWritebackCenter {
    static let shared = ScrapeWritebackCenter()

    enum StepKind: Hashable {
        case lyrics, cover, metadata, source
    }

    enum StepState: Equatable {
        case waiting
        case running
        case done
        /// 自动刮削：和本地一样，没有改动。
        case unchanged
        /// 自动刮削：没找到。
        case notFound
        case failed(String)

        var isSettled: Bool {
            switch self {
            case .waiting, .running: false
            default: true
            }
        }
    }

    struct Step: Identifiable, Equatable {
        let kind: StepKind
        var state: StepState
        /// 额外的一行说明（自动刮削改了哪些字段）。
        var detail: String?
        var id: StepKind { kind }
    }

    enum Kind {
        /// 刮削结果页点保存。
        case manual
        /// 播放页「暂无歌词」那颗按钮：查找并直接写入。
        case automatic
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: Kind
        /// 卡片上显示的那首歌；写完后换成资料库里新的一行，小封面跟着换成新封面。
        var song: Song
        var steps: [Step]
        var isFinished = false

        var settledCount: Int { steps.filter { $0.state.isSettled }.count }
        var hasFailure: Bool {
            steps.contains { if case .failed = $0.state { true } else { false } }
        }
        /// 什么都没刮到也要让人看一眼，和出错一样等用户点「完成」。
        var foundNothing: Bool {
            kind == .automatic && !steps.isEmpty && steps.allSatisfy {
                $0.state == .notFound || $0.state == .unchanged
            }
        }
        var needsAcknowledgement: Bool { isFinished && (hasFailure || foundNothing) }
    }

    /// 卡片上的任务，最新的在后面。
    private(set) var jobs: [Job] = []
    /// 展开成卡片，还是收成胶囊在后台写。
    private(set) var isExpanded = false
    /// 写完时改一次，卡片按它给一下触感。
    private(set) var completionRevision = 0

    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    private init() {}

    var isRunning: Bool { jobs.contains { !$0.isFinished } }

    func expand() {
        guard !jobs.isEmpty else { return }
        isExpanded = true
    }

    /// 「后台写入」：收起卡片，写入照常进行。
    func moveToBackground() {
        isExpanded = false
        scheduleCleanupIfIdle()
    }

    /// 「完成」：收起卡片，清掉已经写完的任务。
    func acknowledge() {
        cleanupTask?.cancel()
        isExpanded = false
        jobs.removeAll { $0.isFinished }
    }

    // MARK: - 刮削结果页保存

    struct ManualWrite {
        let draft: ScrapeReviewDraft
        let images: ScrapeReviewImages
        let library: MusicLibrary
        let sourceManager: SourceManager
        let sourcesStore: SourcesStore
        let onApplied: @MainActor (Song) -> Void
    }

    func startManual(_ write: ManualWrite) {
        let draft = write.draft
        var steps: [Step] = []
        if draft.lyrics != nil { steps.append(Step(kind: .lyrics, state: .waiting)) }
        if draft.cover != nil { steps.append(Step(kind: .cover, state: .waiting)) }
        if draft.selected.keys.contains(where: { ScrapeField.tags.contains($0) }) {
            steps.append(Step(kind: .metadata, state: .waiting))
        }
        let job = Job(kind: .manual, song: draft.original, steps: steps)
        cleanupTask?.cancel()
        jobs.append(job)
        isExpanded = true
        let jobID = job.id
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            await self?.runManual(jobID: jobID, write: write)
        }
    }

    private func runManual(jobID: UUID, write: ManualWrite) async {
        let draft = write.draft
        let lib = write.library
        let sm = write.sourceManager
        // 排队期间前一个任务可能改过这一行（比如嵌入过歌词换了文件身份），从最新的那一行开始。
        let song = lib.storedSong(id: draft.original.id) ?? draft.original
        let songID = song.id
        let tagsSelected = draft.selected.keys.contains { ScrapeField.tags.contains($0) }

        let usesMediaServerWriteback = await sm.supportsMediaServerWriteback(for: song)
        var supportsSidecarCover = false
        if !usesMediaServerWriteback, draft.cover != nil {
            supportsSidecarCover = await sm.supportsSidecarWriting(for: song)
        }
        if (usesMediaServerWriteback && (tagsSelected || draft.cover != nil)) || supportsSidecarCover {
            update(jobID) { $0.steps.append(Step(kind: .source, state: .waiting)) }
        }

        var savedLyricsSong: Song?
        if let lines = draft.lyrics {
            setState(.running, for: .lyrics, in: jobID)
            let wordLevel = lines.filter { $0.isWordLevel }.count
            plog("👉 ScrapeWriteback lyrics=\(lines.count) wordLevelLines=\(wordLevel) firstSyllables=\(lines.first?.syllables?.count ?? -1)")
            switch await Self.writeLyrics(lines, for: song, write: write) {
            case .success(let updated):
                savedLyricsSong = updated
                setState(.done, for: .lyrics, in: jobID)
            case .failure(let failure):
                plog("⚠️ ScrapeWriteback lyrics writeback failed: \(failure.message)")
                setState(.failed(failure.message), for: .lyrics, in: jobID)
            }
        }

        var coverData: Data?
        var coverReference: String?
        if let cover = draft.cover {
            setState(.running, for: .cover, in: jobID)
            do {
                let data = try await write.images.data(for: cover)
                if let reference = await MetadataAssetStore.shared.storeAttributedCover(data, songID: songID, origin: .selected) {
                    coverData = data
                    coverReference = reference
                } else {
                    setState(.failed(String(localized: "scrape_song_failed")), for: .cover, in: jobID)
                }
            } catch {
                setState(.failed(error.localizedDescription), for: .cover, in: jobID)
            }
        }

        // 写回音乐源要花时间。选中的字段落到资料库里最新的那一行上。
        lib.flushPendingAssetReferencePatches()
        let current = lib.storedSong(id: songID) ?? savedLyricsSong ?? song
        var appliedFinal = current
        appliedFinal.applyScrapeFields(draft.proposedTags(on: current))
        if let coverReference {
            appliedFinal.coverArtFileName = coverReference
            CachedArtworkView.invalidateCache(for: songID)
            if let old = current.coverArtFileName { CachedArtworkView.invalidateCache(for: old) }
        }
        let tagsChanged = ScrapeField.tags.contains { $0.changed(from: current.scrapeFields, to: appliedFinal.scrapeFields) }
        if await sm.isServerLibrarySource(for: song) {
            if tagsChanged { appliedFinal.userMetadataEditedAt = Date() }
        } else {
            appliedFinal = SongUserMetadataPolicy.stampingUserEdit(original: current, updated: appliedFinal)
        }
        if tagsChanged || appliedFinal.userMetadataEditedAt != current.userMetadataEditedAt {
            lib.replaceSong(appliedFinal)
        } else if coverReference != nil {
            lib.updateAssetReferences(songID: songID, coverRef: appliedFinal.coverArtFileName, lyricsRef: appliedFinal.lyricsFileName)
        }
        if coverReference != nil {
            SongTagEditStore.shared.recordUserChosenCovers(songIDs: [songID])
            setState(.done, for: .cover, in: jobID)
        }
        if tagsSelected { setState(.done, for: .metadata, in: jobID) }
        update(jobID) { $0.song = appliedFinal }
        write.onApplied(appliedFinal)

        guard step(.source, in: jobID) != nil else {
            finish(jobID)
            return
        }
        let needsCover = coverData != nil
        if usesMediaServerWriteback, tagsChanged || needsCover {
            setState(.running, for: .source, in: jobID)
            let original = current
            let updated = appliedFinal
            let serverCover = coverData
            let result = await Task.detached(priority: .utility) {
                await sm.writeScrapedMetadataToMediaServer(
                    original: original,
                    updated: updated,
                    coverData: serverCover,
                    lyricsLines: nil
                )
            }.value
            if !result.unsupported.isEmpty {
                plog("ℹ️ Media-server writeback limitations for '\(updated.title)': \(result.unsupported)")
            }
            if result.errors.isEmpty {
                setState(.done, for: .source, in: jobID)
            } else {
                plog("⚠️ Media-server writeback errors for '\(updated.title)': \(result.errors)")
                setState(.failed(result.errors.joined(separator: "\n")), for: .source, in: jobID)
            }
        } else if supportsSidecarCover, let coverData {
            setState(.running, for: .source, in: jobID)
            let outcome = await Self.writeSidecarCover(coverData, for: appliedFinal, sourceManager: sm, library: lib)
            if let failure = outcome {
                setState(.failed(failure), for: .source, in: jobID)
            } else {
                setState(.done, for: .source, in: jobID)
            }
        } else {
            // 封面没准备好、标签也没变：没有要写回的东西。
            update(jobID) { $0.steps.removeAll { $0.kind == .source } }
        }
        finish(jobID)
    }

    private struct WriteFailure: Error {
        let message: String
    }

    private static func writeLyrics(_ lines: [LyricLine], for song: Song, write: ManualWrite) async -> Result<Song?, WriteFailure> {
        let sm = write.sourceManager
        let store = write.sourcesStore
        let payload: LyricsWriteback.EditablePayload
        let writebackMode: LyricsWriteback.Mode
        do {
            (payload, writebackMode) = try await AsyncOperationTimeout.run(seconds: 30) {
                let payload = await LyricsWriteback.loadEditablePayload(for: song, sourceManager: sm)
                try Task.checkCancellation()
                let mode = await LyricsWriteback.resolveMode(for: song, sourceManager: sm, sourcesStore: store)
                try Task.checkCancellation()
                return (payload, mode)
            }
        } catch {
            return .failure(WriteFailure(message: error.localizedDescription))
        }
        let outcome = await LyricsWriteback.save(
            text: LyricsContentParser.serialize(lines),
            for: song,
            mode: writebackMode,
            allowRemoval: false,
            structuredLines: lines,
            sourceSnapshot: payload.sourceSnapshot,
            cacheSnapshot: payload.cacheSnapshot,
            sourceManager: sm,
            library: write.library
        )
        guard outcome.succeeded else {
            return .failure(WriteFailure(message: outcome.errorMessage ?? String(localized: "scrape_song_failed")))
        }
        if let embeddedCopyError = outcome.embeddedCopyError {
            // 歌词文件与缓存都已落地，随身副本失败不算这次写入失败。
            plog("⚠️ ScrapeWriteback embedded lyrics copy failed: \(embeddedCopyError)")
        }
        return .success(outcome.updatedSong)
    }

    /// 封面写回音乐源旁的封面文件（选了嵌入时先嵌进音频文件）。返回 nil 表示写成了，否则是出错说明。
    ///
    /// 网络写入全在 detached 任务里跑，回到主线程的只有改资料库和刷新封面那几步：NAS 写到一半挂住时
    /// 主线程不被占着。旁路文件写入套 30 秒超时；嵌入要整首下载、改写、替换，不套超时，开始了就做完。
    private static func writeSidecarCover(
        _ coverData: Data,
        for song: Song,
        sourceManager sm: SourceManager,
        library lib: MusicLibrary
    ) async -> String? {
        let songID = song.id
        let coverEmbeddingMode = await sm.coverEmbeddingMode(for: song)
        return await Task.detached(priority: .utility) { () -> String? in
            // 有的网盘替换后文件换了 ID，封面文件要跟着新文件走。
            var embeddedSnapshot: Song?
            var embedFailed = false
            if coverEmbeddingMode != .off {
                embeddedSnapshot = await MusicScraperService.embedScrapedCover(
                    coverData,
                    for: song,
                    sourceManager: sm,
                    library: lib
                ).updatedSong
                embedFailed = embeddedSnapshot == nil
            }
            let sidecarSnapshot = embeddedSnapshot ?? song
            let createsCoverFile = coverEmbeddingMode != .embedOnly
            plog("📝 Sidecar: writing back to source for '\(song.title)'")
            do {
                let writeResult = try await writeSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sm,
                    song: sidecarSnapshot,
                    coverData: coverData,
                    lyricsLines: nil,
                    createsCoverFile: createsCoverFile
                )
                plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten)")
                if writeResult.coverWritten {
                    // 旁路文件已落盘，直接覆写本地缓存当可信副本；先清再写会留出空窗，期间界面回源
                    // 可能拿到 HTTP 缓存里的旧封面。
                    await MetadataAssetStore.shared.cacheCover(coverData, forSongID: songID)
                    await MainActor.run {
                        CachedArtworkView.invalidateCache(for: songID)
                        if let coverPath = MusicScraperService.sidecarReferencePath(for: sidecarSnapshot, suffix: "-cover.jpg") {
                            lib.updateAssetReferences(songID: sidecarSnapshot.id, coverRef: coverPath)
                        }
                    }
                }
                if !writeResult.errors.isEmpty {
                    plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                }
                if embedFailed { return String(localized: "scrape_progress_embed_failed") }
                if createsCoverFile, !writeResult.coverWritten {
                    return writeResult.coverError ?? writeResult.errors.first ?? String(localized: "scrape_song_failed")
                }
                return nil
            } catch is CancellationError {
                plog("⚠️ Sidecar write timed out (30s) for '\(song.title)' ── 本地缓存已是新的，只有音乐源上的封面文件没写成。")
                return String(localized: "scrape_progress_source_timeout")
            } catch {
                plog("⚠️ Sidecar write failed for '\(song.title)': \(error.localizedDescription)")
                return error.localizedDescription
            }
        }.value
    }

    private nonisolated static func writeSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        song: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        createsCoverFile: Bool
    ) async throws -> SidecarWriteService.WriteResult {
        try await withThrowingTaskGroup(of: SidecarWriteService.WriteResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                // 旁路写回用独立 connector，不复用正在播放或离线缓存的云盘 connector。
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                let writeResult = await SidecarWriteService.shared.writeSidecars(
                    for: song,
                    using: connector,
                    coverData: coverData,
                    lyricsLines: lyricsLines,
                    createsCoverFile: createsCoverFile
                )
                await sourceManager.invalidateReadCachesAfterSidecarWrite(
                    for: song,
                    paths: writeResult.touchedRemotePaths
                )
                if writeResult.coverWritten || writeResult.lyricsWritten {
                    await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
                }
                return writeResult
            }
            group.addTask {
                let nanoseconds = (seconds * 1_000_000_000).finiteUInt64(or: 30_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CancellationError()
            }
            // 先完成的那个说了算：写完了就取消计时；30 秒先到就取消写入并抛给外层。
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: - 自动刮削

    /// 还在等结果的自动刮削是哪几首。播放页按这些 id 去取结果，切了歌也取得到。
    var pendingAutomaticSongIDs: [String] {
        jobs.filter { $0.kind == .automatic && !$0.isFinished }.map(\.song.id)
    }

    func beginAutomatic(song: Song, lyricsOnly: Bool) {
        guard !jobs.contains(where: { $0.kind == .automatic && !$0.isFinished && $0.song.id == song.id }) else {
            isExpanded = true
            return
        }
        let kinds: [StepKind] = lyricsOnly ? [.lyrics] : [.metadata, .cover, .lyrics]
        cleanupTask?.cancel()
        jobs.append(Job(kind: .automatic, song: song, steps: kinds.map { Step(kind: $0, state: .running) }))
        isExpanded = true
    }

    struct AutomaticOutcome {
        let original: Song
        let updated: Song
        let coverFound: Bool
        let lyricsFound: Bool
    }

    /// 自动刮削有了结果。没有对应任务时（比如别处发起、播放页取到）补一个直接显示结果。
    func finishAutomatic(song: Song, lyricsOnly: Bool, outcome: AutomaticOutcome?, errorMessage: String?) {
        let jobID: UUID
        if let existing = jobs.last(where: { $0.kind == .automatic && !$0.isFinished && $0.song.id == song.id }) {
            jobID = existing.id
        } else {
            beginAutomatic(song: song, lyricsOnly: lyricsOnly)
            guard let created = jobs.last else { return }
            jobID = created.id
        }
        update(jobID) { job in
            for index in job.steps.indices {
                guard let outcome else {
                    job.steps[index].state = .failed(errorMessage ?? String(localized: "scrape_song_failed"))
                    continue
                }
                switch job.steps[index].kind {
                case .metadata:
                    let changes = Self.metadataChanges(original: outcome.original, updated: outcome.updated)
                    job.steps[index].state = changes.isEmpty ? .unchanged : .done
                    job.steps[index].detail = changes.isEmpty ? nil : changes.joined(separator: " · ")
                case .cover:
                    job.steps[index].state = outcome.coverFound ? .done : .notFound
                case .lyrics:
                    job.steps[index].state = outcome.lyricsFound ? .done : .notFound
                case .source:
                    break
                }
            }
        }
        finish(jobID)
    }

    private static func metadataChanges(original: Song, updated: Song) -> [String] {
        var changes: [String] = []
        if original.title != updated.title { changes.append(String(localized: "title_changed")) }
        if original.artistName != updated.artistName { changes.append(String(localized: "artist_changed")) }
        if original.albumTitle != updated.albumTitle { changes.append(String(localized: "album_changed")) }
        let otherChanged = original.year != updated.year
            || original.genre != updated.genre
            || original.trackNumber != updated.trackNumber
            || original.discNumber != updated.discNumber
        if changes.isEmpty, otherChanged { changes.append(String(localized: "scrape_metadata_updated")) }
        return changes
    }

    #if DEBUG
    /// 取证用：直接摆出一张卡片或胶囊，不碰任何数据。`mode`：running、capsule、failed、capsuleFailed、automatic。
    func debugShowSample(song: Song, mode: String) {
        var job: Job
        switch mode {
        case "failed", "capsuleFailed":
            job = Job(kind: .manual, song: song, steps: [
                Step(kind: .lyrics, state: .done),
                Step(kind: .cover, state: .done),
                Step(kind: .metadata, state: .done),
                Step(kind: .source, state: .failed(String(localized: "scrape_progress_source_timeout"))),
            ])
            job.isFinished = true
        case "automatic":
            job = Job(kind: .automatic, song: song, steps: [
                Step(kind: .metadata, state: .done,
                     detail: [String(localized: "title_changed"), String(localized: "album_changed")].joined(separator: " · ")),
                Step(kind: .cover, state: .notFound),
                Step(kind: .lyrics, state: .done),
            ])
            job.isFinished = true
        default:
            job = Job(kind: .manual, song: song, steps: [
                Step(kind: .lyrics, state: .done),
                Step(kind: .cover, state: .running),
                Step(kind: .metadata, state: .waiting),
                Step(kind: .source, state: .waiting),
            ])
        }
        cleanupTask?.cancel()
        jobs = [job]
        isExpanded = mode != "capsule" && mode != "capsuleFailed"
    }
    #endif

    // MARK: - 状态

    private func update(_ jobID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
    }

    private func step(_ kind: StepKind, in jobID: UUID) -> Step? {
        jobs.first { $0.id == jobID }?.steps.first { $0.kind == kind }
    }

    private func setState(_ state: StepState, for kind: StepKind, in jobID: UUID) {
        update(jobID) { job in
            guard let index = job.steps.firstIndex(where: { $0.kind == kind }) else { return }
            job.steps[index].state = state
        }
    }

    private func finish(_ jobID: UUID) {
        update(jobID) { job in
            // 走到这里还没定下来的（前面提早结束）一律算没写成，不留一直转圈的行。
            for index in job.steps.indices where !job.steps[index].state.isSettled {
                job.steps[index].state = .failed(String(localized: "scrape_song_failed"))
            }
            job.isFinished = true
        }
        completionRevision &+= 1
        scheduleCleanupIfIdle()
    }

    /// 都写完、没有要用户看的：卡片停一下让人看到全部打勾，然后自己收起。
    private func scheduleCleanupIfIdle() {
        cleanupTask?.cancel()
        guard !jobs.isEmpty, !isRunning, !jobs.contains(where: \.needsAcknowledgement) else { return }
        let delay: Duration = isExpanded ? .milliseconds(1600) : .milliseconds(2200)
        cleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard !self.isRunning, !self.jobs.contains(where: \.needsAcknowledgement) else { return }
            self.isExpanded = false
            self.jobs.removeAll { $0.isFinished }
        }
    }
}

// MARK: - 界面

/// 胶囊和卡片浮在哪儿。
enum ScrapeWritebackProgressPlacement {
    /// 胶囊贴着顶部安全区（iPhone、iPad）。
    case top
    /// 胶囊浮在底部播放条上面（Mac 主窗口）。
    case bottom(clearance: CGFloat)
}

extension View {
    /// 在这一层显示刮削写入的进度卡片和后台胶囊。挂在 App 根视图上，盖过播放页。
    func scrapeWritebackProgressHost(placement: ScrapeWritebackProgressPlacement = .top) -> some View {
        modifier(ScrapeWritebackProgressHost(placement: placement))
    }
}

private struct ScrapeWritebackProgressHost: ViewModifier {
    let placement: ScrapeWritebackProgressPlacement

    func body(content: Content) -> some View {
        content.overlay {
            ScrapeWritebackProgressStage(center: .shared, placement: placement)
        }
    }
}

/// 只有这一层读任务状态：进度变化只重画卡片自己，不牵动挂它的根视图。
private struct ScrapeWritebackProgressStage: View {
    let center: ScrapeWritebackCenter
    let placement: ScrapeWritebackProgressPlacement

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let showsCard = center.isExpanded && !center.jobs.isEmpty
        let showsCapsule = !center.isExpanded && !center.jobs.isEmpty
        ZStack {
            if showsCard {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissCard() }
                    .transition(.opacity)
                ScrapeWritebackCard(center: center, onDismiss: dismissCard)
                    .padding(.horizontal, 20)
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.92).combined(with: .opacity))
            }
        }
        // 空的 ZStack 没有尺寸，胶囊会按它对齐到正中；撑满后按顶部、底部对齐。frame 本身不接触摸。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: capsuleAlignment) {
            if showsCapsule {
                ScrapeWritebackCapsule(center: center)
                    .padding(capsuleEdge, capsulePadding)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: capsuleEdgeForMove).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.84), value: showsCard)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.84), value: showsCapsule)
        .sensoryFeedback(trigger: center.completionRevision) { _, _ in
            guard !center.isRunning else { return nil }
            return center.jobs.contains(where: \.hasFailure) ? .error : .success
        }
    }

    private func dismissCard() {
        if center.isRunning { center.moveToBackground() } else { center.acknowledge() }
    }

    private var capsuleAlignment: Alignment {
        switch placement {
        case .top: .top
        case .bottom: .bottom
        }
    }

    private var capsuleEdge: Edge.Set {
        switch placement {
        case .top: .top
        case .bottom: .bottom
        }
    }

    private var capsuleEdgeForMove: Edge {
        switch placement {
        case .top: .top
        case .bottom: .bottom
        }
    }

    private var capsulePadding: CGFloat {
        switch placement {
        case .top: 6
        case .bottom(let clearance): clearance
        }
    }
}

/// 弹框：每首歌一块，逐项显示等待、写入中、打勾、失败。
private struct ScrapeWritebackCard: View {
    let center: ScrapeWritebackCenter
    let onDismiss: () -> Void

    var body: some View {
        let jobs = Array(center.jobs.suffix(3))
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                jobList(jobs)
                ScrollView { jobList(jobs) }
            }
            footer(jobs)
        }
        .frame(maxWidth: 380)
        .background { ScrapeWritebackSurface(cornerRadius: 26) }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("scrape.writeback.card")
    }

    private func jobList(_ jobs: [ScrapeWritebackCenter.Job]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { offset, job in
                if offset > 0 { Divider().padding(.horizontal, 18) }
                ScrapeWritebackJobSection(job: job)
            }
        }
    }

    @ViewBuilder
    private func footer(_ jobs: [ScrapeWritebackCenter.Job]) -> some View {
        VStack(spacing: 12) {
            if jobs.contains(where: { $0.kind == .automatic }) {
                Text("scrape_accuracy_notice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onDismiss) {
                Text(center.isRunning ? LocalizedStringKey("scrape_progress_background") : LocalizedStringKey("done"))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("scrape.writeback.dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }
}

private struct ScrapeWritebackJobSection: View {
    let job: ScrapeWritebackCenter.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ScrapeWritebackArtwork(song: job.song, isRunning: !job.isFinished)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .contentTransition(.opacity)
                    Text(verbatim: [job.song.title, job.song.artistName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                ForEach(job.steps) { step in
                    ScrapeWritebackStepRow(step: step, kind: job.kind)
                }
            }
        }
        .padding(18)
        .animation(.snappy(duration: 0.28), value: job.steps)
    }

    private var title: LocalizedStringKey {
        if !job.isFinished { return job.kind == .automatic ? "scrape_progress_title_searching" : "scrape_progress_title_writing" }
        if job.hasFailure { return "scrape_progress_title_failed" }
        if job.foundNothing { return "scrape_progress_title_nothing" }
        return job.kind == .automatic ? "scrape_progress_title_found" : "scrape_progress_title_done"
    }
}

private struct ScrapeWritebackStepRow: View {
    let step: ScrapeWritebackCenter.Step
    let kind: ScrapeWritebackCenter.Kind

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ScrapeWritebackBreathing(isActive: step.state == .running) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.medium))
                Text(verbatim: stateText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            stateGlyph
                .frame(width: 22, height: 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(String(localized: label)), \(stateText)"))
    }

    @ViewBuilder
    private var stateGlyph: some View {
        switch step.state {
        case .waiting:
            Image(systemName: "circle.dashed")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .unchanged, .notFound:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.secondary)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.red)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    private var isFailed: Bool {
        if case .failed = step.state { true } else { false }
    }

    private var label: LocalizedStringResource {
        switch step.kind {
        case .lyrics: "lyrics_word"
        case .cover: "cover"
        case .metadata: "scrape_step_metadata"
        case .source: "scrape_step_source"
        }
    }

    private var symbol: String {
        switch step.kind {
        case .lyrics: "quote.bubble.fill"
        case .cover: "photo.fill"
        case .metadata: "music.note"
        case .source: "externaldrive.fill"
        }
    }

    /// 等待、写入中跟随 App 的主题色（`.tint`），不用资源里的 AccentColor。
    private var tint: AnyShapeStyle {
        switch step.state {
        case .failed: AnyShapeStyle(Color.red)
        case .done: AnyShapeStyle(Color.green)
        case .unchanged, .notFound: AnyShapeStyle(Color.secondary)
        case .waiting, .running: AnyShapeStyle(.tint)
        }
    }

    private var stateText: String {
        switch step.state {
        case .waiting: String(localized: "scrape_state_waiting")
        case .running:
            kind == .automatic ? String(localized: "scrape_state_searching") : String(localized: "scrape_state_writing")
        case .done:
            step.detail ?? (kind == .automatic ? String(localized: "scrape_metadata_updated") : String(localized: "scrape_state_written"))
        case .unchanged: String(localized: "unchanged")
        case .notFound: String(localized: "no_results")
        case .failed(let message): message.isEmpty ? String(localized: "scrape_state_failed") : message
        }
    }
}

/// 弹框收起后的胶囊：写入中呼吸，写完打勾一会儿自己消失，失败时变红等点开。
private struct ScrapeWritebackCapsule: View {
    let center: ScrapeWritebackCenter

    var body: some View {
        let running = center.isRunning
        let failed = !running && center.jobs.contains(where: \.hasFailure)
        Button { center.expand() } label: {
            HStack(spacing: 8) {
                ZStack {
                    if running {
                        ScrapeWritebackBreathing(isActive: true) {
                            Circle().fill(.tint).frame(width: 9, height: 9)
                        }
                        .transition(.opacity)
                    } else {
                        Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(failed ? Color.white : Color.green)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(width: 18, height: 18)
                Text(verbatim: message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(failed ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            // 胶囊按内容定宽，挂在哪儿都不把字截掉。
            .fixedSize()
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background {
                if failed {
                    Capsule().fill(Color.red.opacity(0.86))
                } else {
                    ScrapeWritebackSurface(cornerRadius: 20)
                }
            }
            .background {
                if running {
                    ScrapeWritebackBreathing(isActive: true) {
                        Capsule().fill(.tint.opacity(0.32)).blur(radius: 10)
                    }
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.26), value: message)
        .accessibilityIdentifier("scrape.writeback.capsule")
    }

    private var message: String {
        if center.isRunning {
            let running = center.jobs.filter { !$0.isFinished }
            if running.allSatisfy({ $0.kind == .automatic }) {
                return String(localized: "scrape_progress_title_searching")
            }
            let total = running.reduce(0) { $0 + $1.steps.count }
            let settled = running.reduce(0) { $0 + $1.settledCount }
            return String(format: String(localized: "scrape_progress_capsule_format"), settled, max(total, 1))
        }
        if center.jobs.contains(where: \.hasFailure) { return String(localized: "scrape_progress_capsule_failed") }
        return String(localized: "scrape_progress_capsule_done")
    }
}

/// 卡片里歌曲的小封面；写入中外圈一道呼吸的光。
private struct ScrapeWritebackArtwork: View {
    let song: Song
    let isRunning: Bool

    var body: some View {
        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 46, cornerRadius: 10,
                          sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat)
            .frame(width: 46, height: 46)
            .background {
                if isRunning {
                    ScrapeWritebackBreathing(isActive: true) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.tint.opacity(0.45))
                            .blur(radius: 8)
                            .padding(-4)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: isRunning)
    }
}

/// 一明一暗、轻轻放大缩小的呼吸。减少动态效果时不动。
private struct ScrapeWritebackBreathing<Content: View>: View {
    let isActive: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isActive && !reduceMotion {
            content.phaseAnimator([false, true]) { view, inhale in
                view
                    .opacity(inhale ? 1 : 0.45)
                    .scaleEffect(inhale ? 1 : 0.9)
            } animation: { _ in
                .easeInOut(duration: 1.05)
            }
        } else {
            content
        }
    }
}

/// 卡片和胶囊的底：iOS 26 / macOS 26 起用玻璃，之前用材质加细边。
private struct ScrapeWritebackSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
        }
    }
}
