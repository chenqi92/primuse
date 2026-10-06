import Foundation
import PrimuseKit

/// Keeps the two things spoken-word listening needs that music does not: which
/// items are spoken word, and where each one was left off.
///
/// Classification itself is inference (`SpokenWordContentPolicy`) and is not
/// stored — only the listener's explicit corrections are, so a re-scan or a
/// genre fix never fights a stale flag. Positions are per item rather than per
/// session: a book is listened to across days with music in between, and the
/// single playback-session snapshot cannot express that.
///
/// Positions, finished marks, bookmarks, per-book speeds and kind corrections
/// follow the listener to their other devices through the key-value store
/// (`SpokenWordSyncPolicy` merges; every entry is last-writer-wins with
/// tombstones for removals). The local JSON file stays the source of truth.
@MainActor
@Observable
final class SpokenWordStore {
    struct StoredPosition: Codable, Equatable, Sendable {
        var position: TimeInterval
        var duration: TimeInterval
        var updatedAt: Date

        var fractionComplete: Double {
            guard duration > 0, position.isFinite else { return 0 }
            return min(1, max(0, position / duration))
        }
    }

    private struct Payload: Codable {
        var overrides: [String: String]
        var positions: [String: StoredPosition]
        // Optional so files written before bookmarks existed still decode.
        var bookmarks: [String: [SpokenWordBookmark]]?
        var finishedAt: [String: Date]?
        var bookRates: [String: Float]?
        var archivedAt: [String: Date]?
        /// Songs whose `overrides` entry (written as spoken word) is a podcast.
        var podcastSongIDs: [String]?
        var ledger: SpokenWordSyncLedger?
    }

    /// How soon a change should reach the other devices.
    private enum CloudUrgency: Int, Comparable {
        /// Only a resume position moved: batched, it changes every 15 s.
        case relaxed
        /// Something the listener did on purpose.
        case prompt

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Key-value store key for the synced document.
    static let cloudStorageKey = "primuse_spoken_word_sync_v1"
    private static let promptCloudPushDelay: Duration = .seconds(3)
    private static let relaxedCloudPushDelay: Duration = .seconds(90)

    static let shared = SpokenWordStore()

    /// Explicit per-song corrections. Absent means "whatever the file says".
    private(set) var overrides: [String: ListeningContentKind] = [:]
    private(set) var positions: [String: StoredPosition] = [:]
    /// Marks the listener set inside items, ordered by position.
    private(set) var bookmarks: [String: [SpokenWordBookmark]] = [:]
    /// Items listened to the end (or marked so by hand). A book's shelf
    /// progress and "continue from" are built from this and `positions`.
    private(set) var finishedAt: [String: Date] = [:]
    /// Speeds the listener picked for single books, by `SpokenWordBook.id`.
    /// Absent means the global spoken-word speed.
    private(set) var bookRates: [String: Float] = [:]
    /// Books the listener archived, by `SpokenWordBook.id`. They stay on the
    /// library's shelf in a section of their own and leave every home and
    /// continue-listening list.
    private(set) var archivedAt: [String: Date] = [:]
    /// When removals and edits happened, so they survive a merge with a
    /// device that has not seen them yet.
    @ObservationIgnored private var ledger = SpokenWordSyncLedger()
    /// Bumped on every change so views and the library aggregation can depend
    /// on one cheap value instead of observing two dictionaries.
    @ObservationIgnored private(set) var revision = 0

    private let storeURL: URL
    private var saveTask: Task<Void, Never>?
    private let syncsThroughICloud: Bool
    @ObservationIgnored private var cloudPushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCloudUrgency: CloudUrgency?
    @ObservationIgnored private var isRegisteredWithCloud = false

    /// `storeURL` is for tests; the app uses `shared`, the only instance that
    /// syncs.
    init(storeURL: URL? = nil) {
        syncsThroughICloud = storeURL == nil
        if let storeURL {
            self.storeURL = storeURL
        } else {
            #if os(tvOS)
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            #else
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            #endif
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("spoken_word.json")
        }
        load()
        loadTaggedFolderFiles()
        if syncsThroughICloud {
            CloudKVSSync.shared.register(key: Self.cloudStorageKey) { [weak self] in
                guard let self else { return }
                if self.isRegisteredWithCloud {
                    self.mergeCloudCopy()
                } else {
                    // The first reload runs inside `register`, i.e. while
                    // `shared` is still being created; a change notification
                    // from here would reach observers that read `shared`.
                    Task { @MainActor [weak self] in self?.mergeCloudCopy() }
                }
            }
            isRegisteredWithCloud = true
        }
    }

    // MARK: - Classification

    func kind(for song: Song) -> ListeningContentKind {
        classificationSnapshot.kind(
            songID: song.id,
            sourceID: song.sourceID,
            filePath: song.filePath,
            genre: song.genre,
            serverLibraryID: song.serverLibraryID
        )
    }

    /// Played the spoken-word way: a book or one of the listener's podcast files.
    func isSpokenWord(_ song: Song) -> Bool { kind(for: song).isSpokenWordListening }

    func isPodcast(_ song: Song) -> Bool { kind(for: song) == .podcast }

    /// The kind the song falls back to once its own correction is removed:
    /// folder tags count, so "mark as music" inside a tagged folder must store
    /// an explicit correction rather than clear one.
    func inferredKind(for song: Song) -> ListeningContentKind {
        classificationSnapshot.inferredKind(
            sourceID: song.sourceID,
            filePath: song.filePath,
            genre: song.genre,
            serverLibraryID: song.serverLibraryID
        )
    }

    /// Whether this song's kind was set by hand rather than inferred.
    func hasOverride(songID: String) -> Bool { overrides[songID] != nil }

    /// Snapshot for the library aggregation, which classifies off the main
    /// actor and must not reach back into this object.
    var overrideSnapshot: [String: ListeningContentKind] { overrides }

    /// Per-song corrections plus folder tags, for the library's
    /// classification pass and for the player, which must agree with it.
    /// Also carries the songs that are only in a mirrored playlist, so every
    /// path that splits the library leaves them out of the music lists.
    var classificationSnapshot: SpokenWordClassificationInputs {
        SpokenWordClassificationInputs(
            overrides: overrides,
            folderRules: folderRules,
            collectionOnlySongIDs: CollectionOnlySongStore.shared.songIDs,
            catalogPathSourceIDs: reportedCatalogPathSourceIDs ?? []
        )
    }

    // MARK: - Folder tags

    /// How each source spells its paths, which folder rules need to match
    /// songs. Kept current by `AppServices` from the source list.
    @ObservationIgnored private var folderTagSources: [LibraryFolderSourceDescriptor] = []
    /// Sources whose type alone makes everything in them spoken word (an
    /// audiobook server); nothing in them needs tagging.
    @ObservationIgnored private var declaredSpokenWordSourceIDs: Set<String> = []
    @ObservationIgnored private var cachedFolderRules: (revision: Int, rules: SpokenWordFolderRules)?
    @ObservationIgnored private var folderTagRefreshTask: Task<Void, Never>?

    private var folderRules: SpokenWordFolderRules {
        if let cached = cachedFolderRules, cached.revision == revision { return cached.rules }
        let folders = SpokenWordFolderTag.spokenWordFolders(in: overrides)
        let rules = SpokenWordFolderRules(
            folders: folders,
            sources: folderTagSources,
            declaredSpokenWordSourceIDs: declaredSpokenWordSourceIDs,
            taggedFolderFiles: taggedFolderFiles(folders: folders)
        )
        cachedFolderRules = (revision, rules)
        return rules
    }

    // MARK: - Folder tags on item-id cloud drives

    /// 一个网盘源标签目录里的文件,连同算出它们时的标签目录。
    private struct TaggedFolderFiles: Codable, Equatable {
        var folders: [String]
        var files: Set<String>
    }

    /// 按文件 ID 寻址的网盘(`usesOpaqueDirectoryIdentifiers`)。
    @ObservationIgnored private var opaqueFolderSourceIDs: Set<String> = []
    /// 已经报给分书规则的「路径不是真实目录」的源; nil 表示还没报过(启动时那一次不必重新分类)。
    @ObservationIgnored private var reportedCatalogPathSourceIDs: Set<String>?
    /// 这些网盘的目录上下级,由宿主从扫描索引交来(手机 ScanService、电视 TVStore)。
    @ObservationIgnored private var folderTopologies: [String: SpokenWordFolderTopology] = [:]
    /// 标签目录里的文件。落在本机文件里(不同步):启动时扫描索引往往还没装载,曲库先按
    /// 上次的结论分,等目录交来算出一样的结果就不必整库重分一次。
    @ObservationIgnored private var taggedFolderFileCache: [String: TaggedFolderFiles] = [:]
    /// 本次运行里已按当前目录算过的源;目录一换就要重算。
    @ObservationIgnored private var freshTaggedFolderSources: Set<String> = []
    @ObservationIgnored private var taggedFolderFileSaveTask: Task<Void, Never>?

    private var taggedFolderFilesURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("spoken_word_folder_files.json")
    }

    private func taggedFolderFiles(folders: [String: [String]]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        var cacheChanged = false
        for sourceID in opaqueFolderSourceIDs {
            let tagged = (folders[sourceID] ?? []).filter { !SpokenWordFolderTag.isReservedPath($0) }
            guard !tagged.isEmpty else {
                if taggedFolderFileCache.removeValue(forKey: sourceID) != nil { cacheChanged = true }
                continue
            }
            let cached = taggedFolderFileCache[sourceID]
            if let topology = folderTopologies[sourceID], !topology.isEmpty {
                if let cached, cached.folders == tagged, freshTaggedFolderSources.contains(sourceID) {
                    result[sourceID] = cached.files
                    continue
                }
                let entry = TaggedFolderFiles(folders: tagged, files: topology.files(inside: Set(tagged)))
                freshTaggedFolderSources.insert(sourceID)
                if entry != cached {
                    taggedFolderFileCache[sourceID] = entry
                    cacheChanged = true
                }
                result[sourceID] = entry.files
            } else if let cached, cached.folders == tagged {
                // 还没有目录(启动中、同步状态刚作废):沿用上次的结论,不让书先掉回音乐。
                result[sourceID] = cached.files
            }
        }
        for sourceID in taggedFolderFileCache.keys where !opaqueFolderSourceIDs.contains(sourceID) {
            taggedFolderFileCache.removeValue(forKey: sourceID)
            cacheChanged = true
        }
        if cacheChanged { scheduleTaggedFolderFileSave() }
        return result
    }

    /// 宿主在扫描索引变化时(扫描提交、同步状态作废)交来各网盘源的目录上下级。
    /// 交来的是全部网盘源:不在里面的源算作暂时没有目录,沿用上次的结论。
    func updateFolderTopologies(_ topologies: [String: SpokenWordFolderTopology]) {
        let previous = folderTopologies
        folderTopologies = topologies
        var affectsTags = false
        for sourceID in Set(previous.keys).union(topologies.keys) where previous[sourceID] != topologies[sourceID] {
            freshTaggedFolderSources.remove(sourceID)
            if taggedFolderFileCache[sourceID] != nil || hasFolderTags(sourceID: sourceID) { affectsTags = true }
        }
        guard affectsTags else { return }
        cachedFolderRules = nil
        scheduleFolderTagReclassification()
    }

    private func hasFolderTags(sourceID: String) -> Bool {
        overrides.contains { key, kind in
            guard kind == .spokenWord, let tag = SpokenWordFolderTag.parse(overrideKey: key) else { return false }
            return tag.sourceID == sourceID && !SpokenWordFolderTag.isReservedPath(tag.path)
        }
    }

    private func loadTaggedFolderFiles() {
        guard let data = try? Data(contentsOf: taggedFolderFilesURL),
              let cache = try? JSONDecoder().decode([String: TaggedFolderFiles].self, from: data) else { return }
        taggedFolderFileCache = cache
    }

    private func scheduleTaggedFolderFileSave() {
        taggedFolderFileSaveTask?.cancel()
        taggedFolderFileSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let cache = self.taggedFolderFileCache
            let url = self.taggedFolderFilesURL
            await Task.detached(priority: .utility) {
                if cache.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else if let data = try? JSONEncoder().encode(cache) {
                    try? data.write(to: url, options: .atomic)
                }
            }.value
        }
    }

    /// Whether `path` of a source is tagged as spoken word.
    func isSpokenWordFolder(sourceID: String, path: String) -> Bool {
        overrides[SpokenWordFolderTag.overrideKey(sourceID: sourceID, path: path)] == .spokenWord
    }

    /// Tags (or untags) a scanned folder. The library is reclassified shortly
    /// after, once for a burst of changes.
    func setSpokenWordFolder(_ isSpokenWord: Bool, sourceID: String, path: String) {
        setFolderTag(isSpokenWord ? .spokenWord : nil, sourceID: sourceID, path: path)
    }

    private func setFolderTag(_ kind: ListeningContentKind?, sourceID: String, path: String) {
        let key = SpokenWordFolderTag.overrideKey(sourceID: sourceID, path: path)
        guard overrides[key] != kind else { return }
        overrides[key] = kind
        ledger.overrideChangedAt[key] = Date()
        didChange(cloud: .prompt)
        scheduleFolderTagReclassification()
    }

    // MARK: - Whole-source and server-library tags

    /// id 寻址、没有目录可标的源(Navidrome…):整个来源都是有声内容。
    func isWholeSourceSpokenWord(sourceID: String) -> Bool {
        isSpokenWordFolder(sourceID: sourceID, path: SpokenWordFolderTag.wholeSourcePath)
    }

    func setWholeSourceSpokenWord(_ isSpokenWord: Bool, sourceID: String) {
        setSpokenWordFolder(isSpokenWord, sourceID: sourceID, path: SpokenWordFolderTag.wholeSourcePath)
    }

    /// 按库组织的服务器(Jellyfin/Emby/Plex…):这一库归有声。
    func isSpokenWordLibrary(sourceID: String, libraryID: String) -> Bool {
        isSpokenWordFolder(sourceID: sourceID, path: SpokenWordFolderTag.libraryPath(libraryID: libraryID))
    }

    /// 这一库的归属有没有定过(用户选的,或第一次见到时的默认)。
    func hasSpokenWordLibraryDecision(sourceID: String, libraryID: String) -> Bool {
        let key = SpokenWordFolderTag.overrideKey(
            sourceID: sourceID,
            path: SpokenWordFolderTag.libraryPath(libraryID: libraryID)
        )
        return overrides[key] != nil || ledger.overrideChangedAt[key] != nil
    }

    /// 按库选「音乐 / 有声」。两种选择都存成显式值:选了「音乐」的库之后再见到也不会再
    /// 按「服务端说是有声书就默认归有声」处理。
    func setSpokenWordLibrary(_ isSpokenWord: Bool, sourceID: String, libraryID: String) {
        setFolderTag(
            isSpokenWord ? .spokenWord : .music,
            sourceID: sourceID,
            path: SpokenWordFolderTag.libraryPath(libraryID: libraryID)
        )
    }

    /// 服务端自己标成有声书的库第一次见到就归到有声;用户动过的(含改回音乐的)不碰。
    func registerDefaultSpokenWordLibraries(sourceID: String, libraryIDs: [String]) {
        var changed = false
        let now = Date()
        for libraryID in libraryIDs
        where !hasSpokenWordLibraryDecision(sourceID: sourceID, libraryID: libraryID) {
            let key = SpokenWordFolderTag.overrideKey(
                sourceID: sourceID,
                path: SpokenWordFolderTag.libraryPath(libraryID: libraryID)
            )
            overrides[key] = .spokenWord
            ledger.overrideChangedAt[key] = now
            changed = true
        }
        guard changed else { return }
        didChange(cloud: .prompt)
        scheduleFolderTagReclassification()
    }

    /// Takes the current source list: path spelling for the rules, and tags
    /// on folders a source no longer scans are dropped, so a tag never keeps
    /// acting through a folder that was deselected. A source whose folders
    /// are still being chosen (none saved yet) keeps its tags.
    ///
    /// `pruningStaleTags: false` 只更新路径写法、不清标签:Apple TV 各源自己扫描,
    /// 扫的目录可以和手机不同,在那里按本机目录清标签会把手机上的标签同步删掉。
    func updateFolderTagSources(_ sources: [MusicSource], pruningStaleTags: Bool = true) {
        let descriptors = sources.filter { !$0.isDeleted }.map(LibraryFolderSourceDescriptor.init(source:))
        let scanned = Dictionary(
            sources.map { ($0.id, (type: $0.type, directories: $0.scannedDirectories)) },
            uniquingKeysWith: { first, _ in first }
        )
        var removed = false
        let now = Date()
        for key in overrides.keys where pruningStaleTags && SpokenWordFolderTag.isFolderKey(key) {
            // 标签所在目录仍在某个扫描目录之下(勾了它的上级,它显示为「已包含」)就留着;
            // 只有整棵都不再扫描才清掉。按文件 ID 寻址的网盘从 ID 看不出上下级,目录标签
            // 一律留着 —— 不在扫描范围里的目录本来就匹配不到歌。
            guard let tag = SpokenWordFolderTag.parse(overrideKey: key),
                  let entry = scanned[tag.sourceID],
                  !entry.directories.isEmpty,
                  !(entry.type.usesOpaqueDirectoryIdentifiers && !SpokenWordFolderTag.isReservedPath(tag.path)),
                  !entry.directories.contains(where: {
                      SourceDirectorySelectionPolicy.covers($0, tag.path, for: entry.type)
                  }) else { continue }
            overrides.removeValue(forKey: key)
            ledger.overrideChangedAt[key] = now
            removed = true
        }
        let descriptorsChanged = descriptors != folderTagSources
        folderTagSources = descriptors
        let declared = Set(
            sources.lazy
                .filter { !$0.isDeleted && $0.type.declaredListeningContentKind == .spokenWord }
                .map(\.id)
        )
        let declaredChanged = declared != declaredSpokenWordSourceIDs
        declaredSpokenWordSourceIDs = declared
        let opaque = Set(
            sources.lazy
                .filter { !$0.isDeleted && $0.type.usesOpaqueDirectoryIdentifiers }
                .map(\.id)
        )
        let opaqueChanged = opaque != opaqueFolderSourceIDs
        opaqueFolderSourceIDs = opaque
        // 曲库型服务器按条目 id 合成路径, 分书时不能拿它当文件夹。曲库第一次分书之前就要报上去;
        // 之后源有增减, 书要按新的认法重新分。
        let catalogPaths = Set(
            sources.lazy
                .filter { !$0.isDeleted && !$0.type.itemPathsNameFolders }
                .map(\.id)
        )
        let catalogPathsChanged = reportedCatalogPathSourceIDs != nil
            && reportedCatalogPathSourceIDs != catalogPaths
        reportedCatalogPathSourceIDs = catalogPaths
        SpokenWordBookSourcePaths.update(catalogSourceIDs: catalogPaths)
        if removed {
            didChange(cloud: .prompt)
        } else if descriptorsChanged || declaredChanged || opaqueChanged {
            cachedFolderRules = nil
        }
        let hasTags = overrides.keys.contains(where: SpokenWordFolderTag.isFolderKey)
        if removed || ((descriptorsChanged || opaqueChanged) && hasTags) || declaredChanged
            || catalogPathsChanged {
            scheduleFolderTagReclassification()
        }
    }

    private func scheduleFolderTagReclassification() {
        folderTagRefreshTask?.cancel()
        folderTagRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .primuseSpokenWordClassificationDidChange, object: nil)
        }
    }

    /// Applies an explicit kind to whole selections (a song, an album, a
    /// folder). Passing nil returns those songs to inference.
    func setKind(_ kind: ListeningContentKind?, forSongIDs songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        var changed = false
        let now = Date()
        for songID in songIDs where overrides[songID] != kind {
            let wasPodcast = overrides[songID] == .podcast
            overrides[songID] = kind
            // Stamped so a later correction on another device wins, and a
            // return to inference is not undone by an older override.
            ledger.overrideChangedAt[songID] = now
            if wasPodcast || kind == .podcast { ledger.podcastMarkChangedAt[songID] = now }
            changed = true
        }
        // Music does not carry a resume position, so dropping it here keeps a
        // reclassified item from resuming mid-file later.
        if kind == .music {
            for songID in songIDs {
                if removePosition(songID, at: now) { changed = true }
                if removeFinished(songID, at: now) { changed = true }
            }
        }
        guard changed else { return }
        didChange(cloud: .prompt)
    }

    /// Moves songs to `kind` the way a song's own menu does: a song whose tags
    /// or folder already say `kind` just drops its correction and keeps
    /// following them; the rest get one.
    func move(_ songs: [Song], to kind: ListeningContentKind) {
        let inputs = classificationSnapshot
        var corrected: [String] = []
        var inferred: [String] = []
        for song in songs {
            let inferredKind = inputs.inferredKind(
                sourceID: song.sourceID,
                filePath: song.filePath,
                genre: song.genre,
                serverLibraryID: song.serverLibraryID
            )
            if inferredKind == kind {
                inferred.append(song.id)
            } else {
                corrected.append(song.id)
            }
        }
        setKind(kind, forSongIDs: corrected)
        setKind(nil, forSongIDs: inferred)
    }

    // MARK: - Positions

    func position(forSongID songID: String) -> StoredPosition? { positions[songID] }

    func resumePosition(for song: Song) -> TimeInterval? {
        SpokenWordProgressPolicy.resumePosition(
            stored: positions[song.id]?.position,
            duration: resolvedDuration(for: song)
        )
    }

    /// Records where playback is. Called on pause, track change, seek,
    /// backgrounding and on a timer while playing.
    func rememberPosition(
        _ position: TimeInterval,
        duration: TimeInterval,
        forSongID songID: String
    ) {
        guard SpokenWordProgressPolicy.shouldRemember(
            position: position,
            duration: duration
        ) else {
            // Inside the closing stretch the item counts as heard: the
            // position goes and the item is marked finished, so the book
            // moves on to the next chapter.
            if duration > 0, position.isFinite,
               position > duration - SpokenWordProgressPolicy.completionTailThreshold {
                markFinished(true, songIDs: [songID])
            } else {
                clearPosition(forSongID: songID)
            }
            return
        }
        let stored = StoredPosition(
            position: position,
            duration: duration,
            updatedAt: Date()
        )
        guard positions[songID] != stored else { return }
        positions[songID] = stored
        ledger.positionClearedAt.removeValue(forKey: songID)
        // Listening again to a finished item keeps it finished, like a song
        // played twice; only "mark as unfinished" reopens it. The position
        // is still kept, so the replay continues where it stopped.
        evictOldestIfNeeded()
        didChange(cloud: .relaxed)
    }

    /// 采纳服务端记的进度(Audiobookshelf 这类自己记进度的源)。和 iCloud 一样按最后写入者获胜:
    /// 本机对这一条的任何更晚的决定(位置、听完、清掉、取消听完)都留着,服务端更新才按它改。
    /// 存下的时间戳就用服务端的,这样再经 iCloud 合并时顺序不乱。返回有没有改动本机。
    @discardableResult
    func adoptServerProgress(
        songID: String,
        position: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool,
        updatedAt: Date
    ) -> Bool {
        let localStamps = [
            positions[songID]?.updatedAt,
            finishedAt[songID],
            ledger.positionClearedAt[songID],
            ledger.unfinishedAt[songID],
        ].compactMap { $0 }
        if let newest = localStamps.max(), newest >= updatedAt { return false }
        var changed = false
        if isFinished {
            // Only a newly finished item ends its position; one already
            // finished here keeps the place it is being heard again from.
            if finishedAt[songID] == nil {
                finishedAt[songID] = updatedAt
                ledger.unfinishedAt.removeValue(forKey: songID)
                if removePosition(songID, at: updatedAt) { changed = true }
                changed = true
            }
        } else if SpokenWordProgressPolicy.shouldRemember(position: position, duration: duration) {
            // A position never reopens a finished item; it is where hearing
            // it again continues.
            let stored = StoredPosition(position: position, duration: duration, updatedAt: updatedAt)
            guard positions[songID] != stored else { return false }
            positions[songID] = stored
            ledger.positionClearedAt.removeValue(forKey: songID)
            changed = true
        }
        guard changed else { return false }
        evictOldestIfNeeded()
        didChange(cloud: .relaxed)
        return true
    }

    // MARK: - Finished

    func isFinished(songID: String) -> Bool { finishedAt[songID] != nil }

    func finishedDate(forSongID songID: String) -> Date? { finishedAt[songID] }

    /// Marks items heard (or not). Marking heard drops the resume position;
    /// marking unheard only clears the mark, so an item being heard again
    /// continues from where that stopped. Nothing else reopens an item.
    func markFinished(_ finished: Bool, songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        var changed = false
        let now = Date()
        for songID in songIDs {
            if finished {
                // Heard to the end again: the finish moves to now, so the
                // book sorts by when it was last heard through.
                if finishedAt[songID] == nil || positions[songID] != nil {
                    finishedAt[songID] = now
                    ledger.unfinishedAt.removeValue(forKey: songID)
                    changed = true
                }
                if removePosition(songID, at: now) { changed = true }
            } else if removeFinished(songID, at: now) {
                changed = true
            }
        }
        guard changed else { return }
        evictOldestIfNeeded()
        didChange(cloud: .prompt)
    }

    /// Removes a position as a listener's decision (a tombstone goes with
    /// it), unlike eviction or pruning, which only forget locally.
    @discardableResult
    private func removePosition(_ songID: String, at date: Date) -> Bool {
        guard positions.removeValue(forKey: songID) != nil else { return false }
        ledger.positionClearedAt[songID] = date
        return true
    }

    @discardableResult
    private func removeFinished(_ songID: String, at date: Date) -> Bool {
        guard finishedAt.removeValue(forKey: songID) != nil else { return false }
        ledger.unfinishedAt[songID] = date
        return true
    }

    // MARK: - Bookmarks

    func bookmarks(forSongID songID: String) -> [SpokenWordBookmark] {
        bookmarks[songID] ?? []
    }

    @discardableResult
    func addBookmark(_ bookmark: SpokenWordBookmark) -> Bool {
        let existing = bookmarks[bookmark.songID] ?? []
        let updated = SpokenWordBookmarkPolicy.inserting(bookmark, into: existing)
        guard updated != existing else { return false }
        bookmarks[bookmark.songID] = updated
        let now = Date()
        // The policy drops the oldest past its limit; that is a deletion too.
        let kept = Set(updated.map(\.id))
        for dropped in existing where !kept.contains(dropped.id) {
            ledger.bookmarkEditedAt.removeValue(forKey: dropped.id.uuidString)
            ledger.bookmarkDeletedAt[dropped.id.uuidString] = now
        }
        didChange(cloud: .prompt)
        return true
    }

    func removeBookmark(id: UUID, songID: String) {
        guard var list = bookmarks[songID] else { return }
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return }
        bookmarks[songID] = list.isEmpty ? nil : list
        ledger.bookmarkEditedAt.removeValue(forKey: id.uuidString)
        ledger.bookmarkDeletedAt[id.uuidString] = Date()
        didChange(cloud: .prompt)
    }

    func renameBookmark(id: UUID, songID: String, title: String) {
        guard var list = bookmarks[songID],
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, list[index].title != trimmed else { return }
        list[index].title = trimmed
        bookmarks[songID] = list
        ledger.bookmarkEditedAt[id.uuidString] = Date()
        didChange(cloud: .prompt)
    }

    func clearPosition(forSongID songID: String) {
        guard removePosition(songID, at: Date()) else { return }
        didChange(cloud: .prompt)
    }

    // MARK: - Per-book speed

    /// The speed the listener picked for this book, nil when it follows the
    /// global spoken-word speed.
    func playbackRate(forBookID bookID: String) -> Float? { bookRates[bookID] }

    /// Stores (or with nil, forgets) a book's own speed.
    func setPlaybackRate(_ rate: Float?, forBookID bookID: String) {
        let value = rate.map(SpokenWordPlaybackRatePolicy.clamped)
        guard bookRates[bookID] != value else { return }
        bookRates[bookID] = value
        ledger.rateChangedAt[bookID] = Date()
        didChange(cloud: .prompt)
    }

    // MARK: - Archive

    var archivedBookIDs: Set<String> { Set(archivedAt.keys) }

    func isArchived(bookID: String) -> Bool { archivedAt[bookID] != nil }

    /// Archives books (or takes them back out). Listening to an archived book
    /// does not take it out; only this does.
    func setArchived(_ archived: Bool, bookIDs: [String]) {
        let now = Date()
        var changed = false
        for bookID in bookIDs {
            if archived {
                guard archivedAt[bookID] == nil else { continue }
                archivedAt[bookID] = now
                ledger.unarchivedAt.removeValue(forKey: bookID)
            } else {
                guard archivedAt.removeValue(forKey: bookID) != nil else { continue }
                ledger.unarchivedAt[bookID] = now
            }
            changed = true
        }
        guard changed else { return }
        didChange(cloud: .prompt)
    }

    private func resolvedDuration(for song: Song) -> TimeInterval {
        // A bare row can still have a remembered duration from when it played.
        song.duration > 0 ? song.duration : (positions[song.id]?.duration ?? 0)
    }

    private func evictOldestIfNeeded() {
        let limit = SpokenWordProgressPolicy.maximumRememberedItems
        if positions.count > limit {
            let ordered = positions.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for (songID, _) in ordered.prefix(positions.count - limit) {
                positions.removeValue(forKey: songID)
            }
        }
        if finishedAt.count > limit * 4 {
            let ordered = finishedAt.sorted { $0.value < $1.value }
            for (songID, _) in ordered.prefix(finishedAt.count - limit * 4) {
                finishedAt.removeValue(forKey: songID)
                // A replay position left without its finished mark would
                // read as the item being half heard.
                positions.removeValue(forKey: songID)
            }
        }
    }

    // MARK: - Persistence

    private func didChange(cloud urgency: CloudUrgency?) {
        revision &+= 1
        scheduleSave()
        if let urgency { scheduleCloudPush(urgency) }
        NotificationCenter.default.post(name: .primuseSpokenWordDidChange, object: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        overrides = Self.overrides(from: payload.overrides, podcastSongIDs: Set(payload.podcastSongIDs ?? []))
        positions = payload.positions
        bookmarks = payload.bookmarks ?? [:]
        finishedAt = payload.finishedAt ?? [:]
        bookRates = payload.bookRates ?? [:]
        archivedAt = payload.archivedAt ?? [:]
        ledger = payload.ledger ?? SpokenWordSyncLedger()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the local file now, without the two-second debounce and without
    /// touching iCloud. The player calls it with each listening position, so
    /// a crash loses at most one autosave interval, not that plus the debounce.
    func persistLocally() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    /// Writes immediately. Used when the app is about to lose the foreground,
    /// where a debounced save would never run.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
        if pendingCloudUrgency != nil { pushToCloudNow() }
    }

    private func saveNow() {
        let payload = Payload(
            overrides: storedOverrideValues,
            positions: positions,
            bookmarks: bookmarks,
            finishedAt: finishedAt,
            bookRates: bookRates,
            archivedAt: archivedAt,
            podcastSongIDs: podcastOverrideIDs.sorted(),
            ledger: ledger
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - iCloud

    private var localRecords: SpokenWordLocalRecords {
        SpokenWordLocalRecords(
            positions: positions.mapValues {
                .init(position: $0.position, duration: $0.duration, updatedAt: $0.updatedAt)
            },
            finishedAt: finishedAt,
            bookmarks: bookmarks,
            overrides: storedOverrideValues,
            bookRates: bookRates,
            archivedAt: archivedAt,
            podcastSongIDs: podcastOverrideIDs,
            ledger: ledger
        )
    }

    /// Kind corrections as they are written to disk and to iCloud. A podcast
    /// goes down as spoken word — all a version without podcasts knows, so it
    /// keeps the item off its music lists instead of dropping the correction —
    /// with the podcast part kept apart (`podcastOverrideIDs`).
    private var storedOverrideValues: [String: String] {
        overrides.mapValues { $0 == .podcast ? ListeningContentKind.spokenWord.rawValue : $0.rawValue }
    }

    private var podcastOverrideIDs: Set<String> {
        Set(overrides.lazy.filter { $0.value == .podcast }.map(\.key))
    }

    private static func overrides(
        from stored: [String: String],
        podcastSongIDs: Set<String>
    ) -> [String: ListeningContentKind] {
        var result = stored.compactMapValues(ListeningContentKind.init(rawValue:))
        for songID in podcastSongIDs where result[songID] == .spokenWord {
            result[songID] = .podcast
        }
        return result
    }

    /// Batches pushes: a position alone waits up to a minute and a half (it
    /// moves every 15 s while a book plays), a deliberate change goes within
    /// seconds. `flush()` sends whatever is pending right away.
    private func scheduleCloudPush(_ urgency: CloudUrgency) {
        guard syncsThroughICloud else { return }
        if let pending = pendingCloudUrgency, pending >= urgency, cloudPushTask != nil { return }
        pendingCloudUrgency = max(pendingCloudUrgency ?? urgency, urgency)
        cloudPushTask?.cancel()
        let delay = urgency == .prompt ? Self.promptCloudPushDelay : Self.relaxedCloudPushDelay
        cloudPushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pushToCloudNow()
        }
    }

    /// Merges with whatever the cloud copy holds first, so a push never
    /// replaces another device's entries it has not seen.
    private func pushToCloudNow() {
        cloudPushTask?.cancel()
        cloudPushTask = nil
        pendingCloudUrgency = nil
        guard syncsThroughICloud else { return }
        let remote = SpokenWordSyncPolicy.decode(
            UserDefaults.standard.data(forKey: Self.cloudStorageKey)
        ) ?? .empty
        settle(SpokenWordSyncPolicy.merge(SpokenWordSyncPolicy.state(from: localRecords), remote), over: remote)
    }

    /// The cloud copy changed (another device pushed, or sync was switched
    /// on): take what it has that this device does not, and push back only
    /// if this device has something it lacks.
    private func mergeCloudCopy() {
        guard let remote = SpokenWordSyncPolicy.decode(
            UserDefaults.standard.data(forKey: Self.cloudStorageKey)
        ) else { return }
        settle(SpokenWordSyncPolicy.merge(SpokenWordSyncPolicy.state(from: localRecords), remote), over: remote)
    }

    /// Keeps the merge here and uploads it within the key-value store's room.
    /// Only the upload is cut to size: cutting this device's own copy to the
    /// upload's limits deleted the oldest kind corrections on every device.
    private func settle(_ merged: SpokenWordSyncState, over remote: SpokenWordSyncState) {
        let now = Date()
        adopt(SpokenWordSyncPolicy.retained(merged, now: now))
        publish(SpokenWordSyncPolicy.pruned(merged, now: now), over: remote)
    }

    /// Replaces the local dictionaries with a merged state when it differs.
    private func adopt(_ merged: SpokenWordSyncState) {
        let records = SpokenWordSyncPolicy.records(from: merged)
        let nextPositions = records.positions.mapValues {
            StoredPosition(position: $0.position, duration: $0.duration, updatedAt: $0.updatedAt)
        }
        let nextOverrides = Self.overrides(from: records.overrides, podcastSongIDs: records.podcastSongIDs)
        let contentChanged = nextPositions != positions
            || records.finishedAt != finishedAt
            || records.bookmarks != bookmarks
            || nextOverrides != overrides
            || records.bookRates != bookRates
            || records.archivedAt != archivedAt
        let overridesChanged = nextOverrides != overrides
        guard contentChanged || records.ledger != ledger else { return }
        positions = nextPositions
        finishedAt = records.finishedAt
        bookmarks = records.bookmarks
        overrides = nextOverrides
        bookRates = records.bookRates
        archivedAt = records.archivedAt
        ledger = records.ledger
        guard contentChanged else {
            scheduleSave()
            return
        }
        didChange(cloud: nil)
        if overridesChanged {
            NotificationCenter.default.post(name: .primuseSpokenWordClassificationDidChange, object: nil)
        }
    }

    /// Writes the upload document and pushes it, unless the cloud already
    /// holds exactly that.
    private func publish(_ merged: SpokenWordSyncState, over remote: SpokenWordSyncState) {
        let upload = SpokenWordSyncPolicy.uploadState(merged)
        guard upload != remote, let data = SpokenWordSyncPolicy.encode(upload) else { return }
        UserDefaults.standard.set(data, forKey: Self.cloudStorageKey)
        CloudKVSSync.shared.markChanged(key: Self.cloudStorageKey)
    }
}

extension Notification.Name {
    static let primuseSpokenWordDidChange = Notification.Name("primuse.spokenWordDidChange")
    /// Posted when kind corrections arrived from another device, so the
    /// library can re-run the music / spoken-word split.
    static let primuseSpokenWordClassificationDidChange =
        Notification.Name("primuse.spokenWordClassificationDidChange")
}
