import Foundation
import PrimuseKit

/// 把专辑 / 艺人简介写回音乐源,也把音乐源上已有的简介读回来:
/// - 文件类音乐源:专辑文件夹的 `album.nfo`、艺人文件夹的 `artist.nfo`;
/// - Jellyfin、Emby、Plex:专辑与艺人的「简介」字段;
/// - 开了开关时,专辑简介再写进每首歌的「注释」(整首下载、改写、替换、回读)。
/// 判断不了该写到哪儿就不写;读不懂的 nfo 不覆盖。
@MainActor
enum LibraryInsightWriteback {
    struct Report: Equatable, Sendable {
        var written: [String] = []
        var failed: [String] = []

        var isEmpty: Bool { written.isEmpty && failed.isEmpty }
    }

    /// 本次运行里已经去音乐源找过简介的专辑 / 艺人,不再重复读。
    private static var importAttemptedIDs: Set<String> = []

    // MARK: - 写回

    /// 简介保存、生成或删除之后调用。`songs` 是这张专辑 / 这位艺人在曲库里的歌。
    static func write(
        _ record: LibraryInsightRecord?,
        subject: LibraryInsightSubject,
        songs: [Song],
        library: MusicLibrary,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> Report {
        var report = Report()
        guard record?.permitsSourceWriteback != false else { return report }
        let writesFiles = LibraryInsightWritebackPolicy.writesFiles()
        let embedsComment = subject.kind == .album && LibraryInsightWritebackPolicy.embedsComment()
        guard writesFiles || embedsComment else { return report }
        let live = record.flatMap { $0.isDeleted ? nil : $0 }
        let summary = live?.summary ?? ""
        let tags = live?.tags ?? []

        for (sourceID, sourceSongs) in Dictionary(grouping: playable(songs), by: \.sourceID)
            .sorted(by: { $0.key < $1.key }) {
            guard let source = sourcesStore.source(id: sourceID), let first = sourceSongs.first else { continue }
            if writesFiles {
                if Self.isMediaServer(source.type) {
                    // 删掉简介时不去清服务器上的:那里原本的简介可能是服务器自己抓来的。
                    if live?.hasContent == true {
                        await writeServerOverview(
                            summary: summary, tags: tags, subject: subject, song: first,
                            source: source, sourceManager: sourceManager, report: &report
                        )
                    }
                } else {
                    await writeNFO(
                        summary: summary, tags: tags, subject: subject, songs: sourceSongs,
                        source: source, library: library, sourceManager: sourceManager, report: &report
                    )
                }
            }
            if embedsComment, !summary.isEmpty {
                await embedComment(
                    summary, in: sourceSongs, source: source,
                    library: library, sourceManager: sourceManager, report: &report
                )
            }
        }
        if !report.isEmpty {
            plog("📝 Library insight writeback kind=\(subject.kind.rawValue) written=\(report.written.count) failed=\(report.failed.count)")
        }
        return report
    }

    private static func writeServerOverview(
        summary: String,
        tags: [String],
        subject: LibraryInsightSubject,
        song: Song,
        source: MusicSource,
        sourceManager: SourceManager,
        report: inout Report
    ) async {
        do {
            guard let connector = try await sourceManager.connectorForSong(song) as? any LibraryInsightServerConnector else {
                return
            }
            try await connector.writeCollectionOverview(summary, tags: tags, collection: subject.kind, for: song)
            report.written.append(source.name)
        } catch {
            plog("⚠️ Library insight server write failed source=\(source.type.rawValue): \(error.localizedDescription)")
            report.failed.append(source.name)
        }
    }

    private static func writeNFO(
        summary: String,
        tags: [String],
        subject: LibraryInsightSubject,
        songs: [Song],
        source: MusicSource,
        library: MusicLibrary,
        sourceManager: SourceManager,
        report: inout Report
    ) async {
        guard let first = songs.first else { return }
        guard let folder = folder(for: subject, songs: songs, source: source, library: library) else {
            // 不写的原因写进诊断日志:文件夹判断不了时界面上不提示。
            plog("ℹ️ Library insight: no \(subject.kind.rawValue) folder for nfo source=\(source.type.rawValue) songs=\(songs.count)")
            return
        }
        let fileName = LibraryInsightNFO.fileName(for: subject.kind)
        let path = LibraryInsightFolderPolicy.filePath(in: folder, kind: subject.kind)
        // album.nfo 里还有评分评论那一段(`LibraryFolderMarksService`),读改写和它排成一队。
        let lockKey = source.id + "|" + path
        await SidecarFileWriteLocks.shared.acquire(lockKey)
        defer { SidecarFileWriteLocks.shared.release(lockKey) }
        do {
            let connector = try await sourceManager.sidecarWriteConnector(for: first)
            guard connector.supportsSidecarWriting else {
                plog("ℹ️ Library insight: source cannot take sidecar files source=\(source.type.rawValue)")
                return
            }
            let existing = try await readText(at: path, in: folder, using: connector)
            // 没有文件、也没东西可写(删除简介)时,不为它新建一份空 nfo。
            if existing == nil, summary.isEmpty, tags.isEmpty { return }
            guard let document = LibraryInsightNFO.updatedDocument(
                existing: existing?.text,
                kind: subject.kind,
                title: subject.albumTitle,
                artist: subject.artistName,
                summary: summary,
                tags: tags
            ) else {
                plog("ℹ️ Library insight: \(fileName) exists but is not a \(subject.kind.rawValue) nfo; left untouched")
                report.failed.append(fileName)
                return
            }
            guard document != existing?.text else { return }
            // 已有的文件(可能是 Album.nfo)就写回它,不另建一份。
            let destination = existing?.path ?? path
            let data = Data(document.utf8)
            try await connector.writeFile(data: data, to: destination, priority: .background)
            try await connector.verifySidecarWrite(data: data, at: destination)
            report.written.append(fileName)
        } catch {
            plog("⚠️ Library insight nfo write failed source=\(source.type.rawValue): \(error.localizedDescription)")
            report.failed.append(fileName)
        }
    }

    private static func embedComment(
        _ summary: String,
        in songs: [Song],
        source: MusicSource,
        library: MusicLibrary,
        sourceManager: SourceManager,
        report: inout Report
    ) async {
        var written = 0
        var failed = 0
        for song in songs {
            guard await sourceManager.supportsEmbeddedTagWrite(for: song) else { continue }
            // 冲突判断按库里记的文件身份做。
            var target = song
            if let latest = library.storedSong(id: song.id) {
                target.filePath = latest.filePath
                target.fileSize = latest.fileSize
                target.lastModified = latest.lastModified
                target.revision = latest.revision
            }
            do {
                let updated = try await sourceManager.writeEmbeddedComment(.set(summary), for: target)
                library.flushPendingAssetReferencePatches()
                if var latest = library.storedSong(id: song.id) {
                    latest.filePath = updated.filePath
                    latest.fileSize = updated.fileSize
                    latest.lastModified = updated.lastModified
                    latest.revision = updated.revision
                    library.replaceSong(latest)
                }
                written += 1
            } catch {
                plog("⚠️ Library insight comment write failed songID=\(song.id): \(error.localizedDescription)")
                failed += 1
            }
        }
        let label = String(format: String(localized: "library_insight_writeback_comments_format"), written)
        if written > 0 { report.written.append(label) }
        if failed > 0 {
            report.failed.append(String(format: String(localized: "library_insight_writeback_comments_format"), failed))
        }
    }

    // MARK: - 读回

    /// 曲库里还没有这张专辑 / 这位艺人的简介(也没被删过)时,去音乐源找:
    /// 文件夹里的 nfo,或服务器上的简介。找到就存成一份「来自 …」的简介。
    /// `persistAfter` 见 `MusicLibrary.saveLibraryInsightRecord`。
    static func importIfAvailable(
        subject: LibraryInsightSubject,
        songs: [Song],
        library: MusicLibrary,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        persistAfter: TimeInterval = 0.2
    ) async {
        let id = LibraryInsightStore.shared.recordID(for: subject)
        guard library.storedLibraryInsightRecord(id: id) == nil,
              importAttemptedIDs.insert(id).inserted else { return }
        for (sourceID, sourceSongs) in Dictionary(grouping: playable(songs), by: \.sourceID)
            .sorted(by: { $0.key < $1.key }) {
            guard let source = sourcesStore.source(id: sourceID), let first = sourceSongs.first else { continue }
            var found: (summary: String, tags: [String], label: String)?
            if isMediaServer(source.type) {
                if let connector = try? await sourceManager.connectorForSong(first) as? any LibraryInsightServerConnector,
                   let overview = try? await connector.collectionOverview(subject.kind, for: first) {
                    let summary = LibraryInsightEditing.normalizedSummary(
                        LibraryInsightNFO.plainText(fromMarkup: overview)
                    )
                    if !summary.isEmpty { found = (summary, [], source.name) }
                }
            } else {
                // Navidrome 等 Subsonic 服务器自己抓过的简介(Last.fm、插件):只读回来,不往服务器写。
                if isSubsonicServer(source.type),
                   let reader = try? await sourceManager.connectorForSong(first) as? any ServerInsightReadingConnector,
                   let overview = try? await reader.serverInsightOverview(
                       subject.kind,
                       subjectName: subject.kind == .artist ? subject.artistName : subject.albumTitle,
                       for: first
                   ) {
                    let summary = LastFmLibraryInsight.plainText(overview)
                    if !summary.isEmpty { found = (summary, [], source.name) }
                }
                if found == nil,
                   let folder = folder(for: subject, songs: sourceSongs, source: source, library: library),
                   let connector = try? await sourceManager.auxiliaryConnector(for: first) {
                    let path = LibraryInsightFolderPolicy.filePath(in: folder, kind: subject.kind)
                    if let existing = try? await readText(at: path, in: folder, using: connector),
                       let read = LibraryInsightNFO.read(existing.text, kind: subject.kind) {
                        found = (read.summary, read.tags, LibraryInsightNFO.fileName(for: subject.kind))
                    }
                }
            }
            guard let found else { continue }
            // 读的这一会儿用户可能已经自己写了一份。
            guard library.storedLibraryInsightRecord(id: id) == nil,
                  let record = LibraryInsightEditing.recordFromImport(
                    summary: found.summary,
                    tags: found.tags,
                    subject: subject,
                    id: id,
                    sourceLabel: found.label,
                    now: Date()
                  ) else { return }
            plog("📥 Library insight imported kind=\(subject.kind.rawValue) from=\(isMediaServer(source.type) || isSubsonicServer(source.type) ? "server" : "nfo")")
            library.saveLibraryInsightRecord(record, persistAfter: persistAfter)
            return
        }
    }

    // MARK: - Helpers

    static func isMediaServer(_ type: MusicSourceType) -> Bool {
        type == .jellyfin || type == .emby || type == .plex
    }

    /// 只能读回简介、不能写的 Subsonic 一族。
    static func isSubsonicServer(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily
    }

    /// 只看真的文件:流地址与 CUE 分轨的虚拟路径不算。
    private static func playable(_ songs: [Song]) -> [Song] {
        songs.filter { !$0.isStreamDescriptor && !$0.filePath.isEmpty }
    }

    /// 这张专辑 / 这位艺人在这个音乐源上的文件夹;判断不了返回 nil。
    private static func folder(
        for subject: LibraryInsightSubject,
        songs: [Song],
        source: MusicSource,
        library: MusicLibrary
    ) -> String? {
        switch subject.kind {
        case .album:
            let paths = songs.map(\.filePath)
            guard let candidate = LibraryInsightFolderPolicy.candidateAlbumFolder(trackPaths: paths),
                  let sourceID = songs.first?.sourceID else { return nil }
            let albumIDs = Set(songs.compactMap(\.albumID))
            let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
            let others = library.visibleSongs.lazy
                .filter { $0.sourceID == sourceID && $0.filePath.hasPrefix(prefix) }
                .filter { song in song.albumID.map { !albumIDs.contains($0) } ?? true }
                .map(\.filePath)
            return LibraryInsightFolderPolicy.albumFolder(trackPaths: paths, otherAlbumTrackPaths: Array(others))
        case .artist:
            let albumFolders = Dictionary(grouping: songs, by: { $0.albumID ?? $0.albumTitle ?? "" })
                .values
                .compactMap { LibraryInsightFolderPolicy.candidateAlbumFolder(trackPaths: $0.map(\.filePath)) }
            // 本地文件夹源只选了一个文件夹时,它在 `/` 下展开,名字不在路径里。
            let rootFolderName = source.type == .local
                ? LocalBookmarkStore.rootFolderName(sourceID: source.id) : nil
            return LibraryInsightFolderPolicy.artistFolder(
                albumFolders: albumFolders,
                artistName: subject.artistName,
                rootFolderName: rootFolderName
            )
        }
    }

    /// 读文件夹里的 nfo;不存在返回 nil。读不了(太大、读失败、不是 UTF-8)时抛错,调用方不覆盖它。
    static func readText(
        at path: String,
        in folder: String,
        using connector: any MusicSourceConnector
    ) async throws -> (text: String, size: Int64, path: String)? {
        let name = (path as NSString).lastPathComponent
        let files = try await connector.listFiles(at: folder).filter { !$0.isDirectory }
        // 区分大小写的存储上可能同时有 Album.nfo 和 album.nfo:先认原样的那个;返回读的是哪个,写回同一个。
        guard let item = files.first(where: { $0.path == path })
            ?? files.first(where: { $0.name == name })
            ?? files.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        guard item.size <= Int64(LibraryInsightNFO.maximumReadBytes) else {
            throw SourceError.connectionFailed("nfo too large")
        }
        let data = try await connector.fetchRange(
            path: item.path,
            offset: 0,
            length: max(item.size, 1),
            priority: .background
        )
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SourceError.connectionFailed("nfo is not UTF-8")
        }
        return (text, item.size, item.path)
    }
}

// MARK: - 评分、评论与红心写进 album.nfo

/// 同一个文件的读改写一次只走一个:简介和评分评论都写 album.nfo,两边交错会互相盖掉。
@MainActor
final class SidecarFileWriteLocks {
    static let shared = SidecarFileWriteLocks()

    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if busy.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    /// 有人在等就直接交给下一个(键一直占着),否则放开。
    func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            busy.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

/// 评分、评论与红心写进专辑文件夹的 album.nfo(`LibraryFolderMarksNFO`,和简介同一个文件),
/// 某个音乐源扫描成功后从那里读回。只管路径按「/」分层的文件类音乐源;写要源能写伴随文件,读不要求。
/// 卸载重装、换设备、删源重加之后评分评论都还找得回来。
@MainActor
final class LibraryFolderMarksService {
    /// 还没写进文件的改动(在外面连不上 NAS、写失败、等着写的时候 App 被关了),下次启动接着写。
    static let pendingWritesKey = "primuse.sidecar.marksPendingWrites.v1"
    private static let flushDelay: Duration = .seconds(4)
    /// 写失败后的重试间隔。用完就等下一次改动或下次启动,不在连不上的源上一直试。
    private static let retryDelays: [Duration] = [.seconds(60), .seconds(120), .seconds(300), .seconds(600)]

    private struct PendingWrites: Codable {
        var songIDs: Set<String> = []
        var albumIDs: Set<String> = []
        /// 红心变过的歌和变的时刻(秒)。
        var likedChangedAt: [String: Double] = [:]
    }

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let sourcesStore: SourcesStore
    private let defaults: UserDefaults
    private let signaturesURL: URL?
    private var observers: [NSObjectProtocol] = []
    /// 上一次看到的「我喜欢」。nil 是还没记过(曲库还没装载完),第一次只记不比。
    private var likedSnapshot: Set<String>?
    /// 红心变过的歌和变的时刻:写进文件时带上时间,别的设备据此取新。写进文件后删掉。
    private var likedChangedAt: [String: Date] = [:]
    private var dirtySongIDs: Set<String> = []
    private var dirtyAlbumIDs: Set<String> = []
    /// 正在写的那一批:写完之前也算没写,一起存进待写记录。
    private var writingSongIDs: Set<String> = []
    private var writingAlbumIDs: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var waitingToRetry = false
    private var retryAttempt = 0
    private var importTasks: [String: Task<Void, Never>] = [:]
    /// 刚从文件读回、在曲库里真的变了的评分键:通知回来时不用再写回同一个文件。
    private var importedReviewKeys: Set<String> = []

    init(
        library: MusicLibrary,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        defaults: UserDefaults = .standard,
        signaturesURL: URL? = LibraryFolderMarksSignatures.defaultURL()
    ) {
        self.library = library
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.defaults = defaults
        self.signaturesURL = signaturesURL
    }

    func start() {
        guard observers.isEmpty else { return }
        if library.isReady { likedSnapshot = library.likedSongIDSnapshot() }
        loadPending()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .primuseLibraryReviewsDidChange, object: nil, queue: .main) {
            [weak self] note in
            let keys = (note.userInfo?["keys"] as? [String]) ?? []
            Task { @MainActor in self?.reviewsChanged(keys) }
        })
        // iCloud 送来的(比如电视上打的分)也写进专辑文件夹;电视自己不写文件。
        observers.append(center.addObserver(forName: .primuseLibraryRemoteReviewsDidApply, object: nil, queue: .main) {
            [weak self] note in
            let keys = (note.userInfo?["keys"] as? [String]) ?? []
            Task { @MainActor in self?.reviewsChanged(keys) }
        })
        observers.append(center.addObserver(forName: .primusePlaylistsDidChange, object: nil, queue: .main) {
            [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            guard ids.contains(MusicLibrary.likedSongsPlaylistID) else { return }
            Task { @MainActor in self?.likesMayHaveChanged() }
        })
        scheduleFlush()
    }

    /// 音乐源扫描成功:读回各专辑文件夹 album.nfo 里的评分、评论与红心。
    func sourceScanSucceeded(sourceID: String) {
        guard importTasks[sourceID] == nil else { return }
        importTasks[sourceID] = Task { [weak self] in
            await self?.importMarks(sourceID: sourceID)
            self?.importTasks[sourceID] = nil
        }
    }

    // MARK: 写回

    private func reviewsChanged(_ keys: [String]) {
        var changed = false
        for key in keys {
            if importedReviewKeys.remove(key) != nil { continue }
            if key.hasPrefix("song:") {
                changed = dirtySongIDs.insert(String(key.dropFirst("song:".count))).inserted || changed
            } else if key.hasPrefix("album:") {
                changed = dirtyAlbumIDs.insert(String(key.dropFirst("album:".count))).inserted || changed
            }
        }
        guard changed else { return }
        savePending()
        scheduleFlush(cancellingRetry: true)
    }

    private func likesMayHaveChanged() {
        let current = library.likedSongIDSnapshot()
        guard let previous = likedSnapshot else {
            likedSnapshot = current
            return
        }
        likedSnapshot = current
        let changed = current.symmetricDifference(previous)
        guard !changed.isEmpty else { return }
        let now = Date()
        for id in changed {
            likedChangedAt[id] = now
            dirtySongIDs.insert(id)
        }
        savePending()
        scheduleFlush(cancellingRetry: true)
    }

    /// 本机有新改动时不必等失败重试的长间隔。
    private func scheduleFlush(
        after delay: Duration = LibraryFolderMarksService.flushDelay,
        cancellingRetry: Bool = false
    ) {
        if cancellingRetry, waitingToRetry, let task = flushTask {
            task.cancel()
            flushTask = nil
            waitingToRetry = false
        }
        guard flushTask == nil, !dirtySongIDs.isEmpty || !dirtyAlbumIDs.isEmpty else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.waitingToRetry = false
            guard self.library.isReady else {
                // 启动时曲库还没装载完,查不到歌,等一会儿再写。
                self.flushTask = nil
                self.scheduleFlush()
                return
            }
            let failed = await self.flush()
            self.flushTask = nil
            if !failed {
                self.retryAttempt = 0
                self.scheduleFlush()
            } else if self.retryAttempt < Self.retryDelays.count {
                let retryDelay = Self.retryDelays[self.retryAttempt]
                self.retryAttempt += 1
                self.scheduleFlush(after: retryDelay)
                self.waitingToRetry = self.flushTask != nil
            }
        }
    }

    /// 写一批改动,返回有没有没写成的(没写成的放回待写记录)。
    private func flush() async -> Bool {
        guard LibraryFolderMarksPolicy.writesMarks(defaults: defaults) else {
            dirtySongIDs = []
            dirtyAlbumIDs = []
            likedChangedAt = [:]
            savePending()
            return false
        }
        let songIDs = dirtySongIDs
        let albumIDs = dirtyAlbumIDs
        dirtySongIDs = []
        dirtyAlbumIDs = []
        writingSongIDs = songIDs
        writingAlbumIDs = albumIDs
        defer {
            writingSongIDs = []
            writingAlbumIDs = []
            savePending()
        }
        var wanted: [String: Set<String>] = [:]  // sourceID → albumIDs
        for id in songIDs {
            guard let song = library.storedSong(id: id), let albumID = song.albumID else { continue }
            wanted[song.sourceID, default: []].insert(albumID)
        }
        let sourceIDs = Set(sourcesStore.sources.filter {
            $0.isEnabled && LibraryFolderMarksPolicy.supports($0.type)
        }.map(\.id))
        let snapshot = library.visibleSongs
        let targets = await Task.detached(priority: .utility) {
            MusicLibrary.folderMarkTargets(songs: snapshot, wanted: wanted, albumIDs: albumIDs, sourceIDs: sourceIDs)
        }.value
        // 落不到哪个专辑文件夹上的歌(没有专辑、源不支持、歌已经删了):红心时间也不用留着了。
        var covered = Set<String>()
        for target in targets {
            for song in target.songs { covered.insert(song.id) }
        }
        for id in songIDs where !covered.contains(id) { likedChangedAt[id] = nil }
        var failed = false
        for target in targets {
            guard await !write(target) else { continue }
            failed = true
            dirtySongIDs.formUnion(target.songs.lazy.map(\.id).filter { songIDs.contains($0) })
            if albumIDs.contains(target.albumID) { dirtyAlbumIDs.insert(target.albumID) }
        }
        return failed
    }

    /// 写一个文件夹。返回 false 是没写成、要重试;写不了也不必再试(源不能写伴随文件、
    /// album.nfo 是别的软件的格式)时返回 true。
    private func write(_ target: FolderMarkTarget) async -> Bool {
        guard let first = target.songs.first, let source = sourcesStore.source(id: target.sourceID),
              !source.isDeleted else { return true }
        let path = LibraryInsightFolderPolicy.filePath(in: target.folder, kind: .album)
        let lockKey = target.sourceID + "|" + path
        await SidecarFileWriteLocks.shared.acquire(lockKey)
        defer { SidecarFileWriteLocks.shared.release(lockKey) }
        do {
            let connector = try await sourceManager.sidecarWriteConnector(for: first)
            guard connector.supportsSidecarWriting else { return true }
            let existing = try await LibraryInsightWriteback.readText(at: path, in: target.folder, using: connector)
            let local = localMarks(for: target)
            let merged = LibraryFolderMarksPolicy.merged(
                file: existing.flatMap { LibraryFolderMarksNFO.read($0.text) },
                local: local.marks
            )
            // 没有文件、也没东西可写时不为它新建一份 nfo。
            guard existing != nil || !merged.isEmpty else { return true }
            guard let document = LibraryFolderMarksNFO.updatedDocument(
                existing: existing?.text,
                title: first.albumTitle ?? "",
                artist: first.albumArtistName ?? first.artistName ?? "",
                marks: merged
            ) else {
                plog("ℹ️ Library marks: album.nfo exists but is not an album nfo; left untouched")
                return true
            }
            if document != existing?.text {
                // 已有的文件(可能是 Album.nfo)就写回它,不另建一份。
                let destination = existing?.path ?? path
                let data = Data(document.utf8)
                try await connector.writeFile(data: data, to: destination, priority: .background)
                try await connector.verifySidecarWrite(data: data, at: destination)
                plog("📝 Library marks written tracks=\(merged.tracks.count) source=\(source.type.rawValue)")
            }
            // 红心的时间已经在文件里了;写的这一会儿又变过的留着下次写。
            for (id, date) in local.likeDates where likedChangedAt[id] == date { likedChangedAt[id] = nil }
            return true
        } catch {
            plog("⚠️ Library marks nfo write failed source=\(source.type.rawValue): \(error.localizedDescription)")
            return false
        }
    }

    /// 本机这张专辑每首歌的评分、评论与红心,和其中带时间的红心。没记过的项不写(合并时不会抹掉文件里的)。
    /// 评论开关关着时只是不写本机的评论,文件里已有的(别的设备写的)照样留着。
    private func localMarks(for target: FolderMarkTarget) -> (marks: LibraryFolderMarks, likeDates: [String: Date]) {
        let writesComments = LibraryFolderMarksPolicy.writesComments(defaults: defaults)
        var tracks: [LibraryFolderMarks.Track] = []
        var likeDates: [String: Date] = [:]
        for song in target.songs {
            guard let file = LibraryFolderMarksPolicy.relativePath(of: song.filePath, inFolder: target.folder) else {
                continue
            }
            var mark = MusicLibrary.folderMark(from: library.storedLibraryReview(for: .song(song.id)))
            if !writesComments { mark = mark.withoutComment }
            if let changedAt = likedChangedAt[song.id] {
                mark.liked = library.isLiked(songID: song.id)
                mark.likedModifiedAt = changedAt
                likeDates[song.id] = changedAt
            } else if library.isLiked(songID: song.id) {
                mark.liked = true
            }
            guard !mark.isEmpty else { continue }
            tracks.append(LibraryFolderMarks.Track(
                key: LibraryFolderMarks.Key(file: file, cueTrack: MusicLibrary.folderMarkCueTrack(of: song)),
                title: song.title,
                duration: song.duration > 0 ? Int(song.duration.rounded()) : nil,
                mark: mark
            ))
        }
        var album = MusicLibrary.folderMark(from: library.storedLibraryReview(for: .album(target.albumID)))
        if !writesComments { album = album.withoutComment }
        return (LibraryFolderMarks(album: album.isEmpty ? nil : album, tracks: tracks), likeDates)
    }

    private func loadPending() {
        guard let data = defaults.data(forKey: Self.pendingWritesKey),
              let saved = try? JSONDecoder().decode(PendingWrites.self, from: data) else { return }
        dirtySongIDs.formUnion(saved.songIDs)
        dirtyAlbumIDs.formUnion(saved.albumIDs)
        for (id, seconds) in saved.likedChangedAt where likedChangedAt[id] == nil {
            likedChangedAt[id] = Date(timeIntervalSince1970: seconds)
        }
    }

    private func savePending() {
        let pending = PendingWrites(
            songIDs: dirtySongIDs.union(writingSongIDs),
            albumIDs: dirtyAlbumIDs.union(writingAlbumIDs),
            likedChangedAt: likedChangedAt.mapValues(\.timeIntervalSince1970)
        )
        if pending.songIDs.isEmpty, pending.albumIDs.isEmpty, pending.likedChangedAt.isEmpty {
            defaults.removeObject(forKey: Self.pendingWritesKey)
        } else if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: Self.pendingWritesKey)
        }
    }

    // MARK: 读回

    /// 每个专辑文件夹记一个歌曲 id 签名(`LibraryFolderMarksSignatures`),没变就不再读:
    /// 重装后第一次扫描全读一遍,之后只在歌曲 id 变了(删源重加、改了连接)时重读。
    private func importMarks(sourceID: String) async {
        guard library.isReady, let source = sourcesStore.source(id: sourceID), !source.isDeleted, source.isEnabled,
              LibraryFolderMarksPolicy.supports(source.type) else { return }
        let snapshot = library.visibleSongs
        let layout = await Task.detached(priority: .utility) {
            MusicLibrary.folderMarkLayout(of: snapshot, sourceID: sourceID)
        }.value
        let stored = signaturesURL.map(LibraryFolderMarksSignatures.load(from:)) ?? [:]
        var updates: [String: String] = [:]
        var connector: (any MusicSourceConnector)?
        var importedSongs = 0
        var readFiles = 0
        for (albumID, folder) in layout.folders.sorted(by: { $0.value < $1.value }) {
            if Task.isCancelled { break }
            guard let songs = layout.groups[albumID], let first = songs.first else { continue }
            let key = LibraryFolderMarksSignatures.key(sourceID: sourceID, folder: folder)
            let signature = MusicLibrary.folderMarksSignature(of: songs)
            guard stored[key] != signature else { continue }
            if connector == nil { connector = try? await sourceManager.auxiliaryConnector(for: first) }
            guard let connector else { break }
            let path = LibraryInsightFolderPolicy.filePath(in: folder, kind: .album)
            do {
                if let existing = try await LibraryInsightWriteback.readText(at: path, in: folder, using: connector) {
                    readFiles += 1
                    if Task.isCancelled { break }
                    if let marks = LibraryFolderMarksNFO.read(existing.text) {
                        importedSongs += apply(marks, songs: songs, folder: folder, albumID: albumID)
                    }
                }
                updates[key] = signature
            } catch {
                // 读不了(网络断了、文件太大):签名不记,下次扫描再读。
                continue
            }
        }
        if let signaturesURL {
            LibraryFolderMarksSignatures.update(
                at: signaturesURL, sourceID: sourceID,
                currentFolders: Set(layout.folders.values), setting: updates
            )
        }
        if readFiles > 0 {
            plog("📥 Library marks read nfo=\(readFiles) songs=\(importedSongs) source=\(source.type.rawValue)")
        }
    }

    /// 把一个文件夹的标记合进曲库(`MusicLibrary.applyFolderMarks`),返回对上的歌数。
    private func apply(_ marks: LibraryFolderMarks, songs: [Song], folder: String, albumID: String) -> Int {
        // 先记进名单:「我喜欢」与评分变了的通知回来时,不把这些当成本机的新改动再写回同一个文件。
        let likes = songs.filter { song in
            guard let file = LibraryFolderMarksPolicy.relativePath(of: song.filePath, inFolder: folder) else { return false }
            let key = LibraryFolderMarks.Key(file: file, cueTrack: MusicLibrary.folderMarkCueTrack(of: song))
            return marks.track(for: key, duration: song.duration)?.mark.liked == true
        }.map(\.id)
        likedSnapshot?.formUnion(likes)
        let result = library.applyFolderMarks(marks, songs: songs, folder: folder, albumID: albumID)
        importedReviewKeys.formUnion(result.changedReviewKeys)
        return result.matchedSongs
    }
}
