import CryptoKit
import Foundation
import PrimuseKit

extension Notification.Name {
    /// 手改标签的同步记录变了:本机手改、恢复文件标签,或并进 iCloud 送来的那份之后本机
    /// 还有更新的。userInfo["ids"] 是歌曲 id,同步服务据此上传。
    static let primuseSongTagEditsDidChange = Notification.Name("primuse.songTagEditsDidChange")
    /// 手改的封面图:userInfo["ids"] 要上传的内容哈希,["deleted"] 已经没有歌在用、云端那份可以删。
    static let primuseSongTagEditCoversDidChange = Notification.Name("primuse.songTagEditCoversDidChange")
}

/// iPhone、iPad、Mac 之间同步手改的标签(见 `SongTagEdit`)。
///
/// 本机手改时(曲库报来 `userMetadataEditedAt` 变了的行)记下改了哪些字段、什么时候改的;
/// 收到别的设备的记录逐字段取新的,再套到本机那一行上并打上「用户编辑」标记,之后本机的
/// 重扫、补读照旧保留这些字段。「恢复文件标签」由补读服务明说(`recordRestore`),记成恢复
/// 时刻,别的设备收到后撤掉标记并按文件重读;行上的标记无缘无故没了(拿旧行写回的)不当恢复。
///
/// 还没读过标签的行先不套:套上标记之后补读读到的标题、专辑、封面会被当成手改保护起来而
/// 丢掉,所以等本机读完再套。封面只在用户亲手换图(标签编辑、批量编辑、单曲刮削)时上传,
/// 去重后单独一条记录;别的设备已经有同一份内容时直接指过去。只换了封面不打标记,与本机一致。
@MainActor
final class SongTagEditStore {
    static let shared = SongTagEditStore()

    private struct Storage: Codable, Sendable {
        var entries: [SongTagEdit]
        /// 歌曲 id → 已经套到本机那一行上的记录版本(`SongTagEdit.revisionStamp`)。
        var appliedRevisions: [String: String]
        /// 别的设备恢复了文件标签、本机还没按文件重读成功的歌。
        var pendingRestoreIDs: [String]?
    }

    private(set) var entries: [String: SongTagEdit] = [:]
    /// 每条记录的 `revisionStamp`,记录变时一起算好,整库对一遍时不必每条重算。
    private var stamps: [String: String] = [:]
    private var appliedRevisions: [String: String] = [:]
    /// 传到 iCloud 的封面图被哪些歌用着,空了云端那份就可以删。
    private var portableUsers: [String: Set<String>] = [:]
    /// 别的设备恢复了文件标签、本机要按文件重读的歌。只换过封面的行没有标记,单靠标记认不出来;
    /// 重读成功(或这首歌读不了文件)才去掉,没读成下次再来。
    private var pendingRestoreIDs: Set<String> = []
    private var restoreInFlightIDs: Set<String> = []
    /// 别的设备的改动到了、但本机还没读完这首歌的标签,读完再套。
    private var pendingApplySongIDs: Set<String> = []
    /// 套用时封面图还没从 iCloud 到的歌,按图的内容哈希挂着。
    private var awaitingPortableCovers: [String: Set<String>] = [:]
    /// 记录名里是哈希的歌曲 id 的反查表(歌曲 id 基本都是十六进制,几乎用不上)。
    private var cloudKeyMap: [String: String]?
    private var isApplyingToLibrary = false
    private var didLoad = false
    private var persistTask: Task<Void, Never>?
    private var reconcileAllTask: Task<Void, Never>?
    /// iCloud 一批送来好几百条:攒一下再一起套,曲库只发布一次。
    private var queuedReconcileIDs: Set<String> = []
    private var queuedReconcileTask: Task<Void, Never>?
    private static let writeQueue = DispatchQueue(label: "primuse.songTagEdits.write", qos: .utility)

    private weak var library: MusicLibrary?
    private let fileURL: URL?

    /// 这一行现在能不能套别的设备的改动(第二个参数:改动里有没有本机套得上的封面)。由补读
    /// 服务回答:还在等读标签、或在等读内嵌封面的行先不套。
    var readinessProvider: ((Song, Bool) -> Bool)?
    /// 别的设备恢复了文件标签:本机已经撤掉这些歌的标记,交给补读按文件重读;返回读完了
    /// (或这首歌读不了文件、不必再等)的歌。
    var restoreHandler: (([String]) async -> Set<String>)?

    init(fileURL: URL? = SongTagEditStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL() -> URL {
        FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("song-tag-edits.json")
    }

    // MARK: - 接线

    func attach(library: MusicLibrary) {
        self.library = library
        loadIfNeeded()
        library.userMetadataEditHandler = { [weak self] transitions in
            self?.localEditTransitions(transitions)
        }
        library.userMetadataEditRemapHandler = { [weak self] replacements in
            self?.remapSongIDs(replacements)
        }
        library.onReady { [weak self] in
            self?.recordLegacyEditsAndReconcile()
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        for entry in storage.entries {
            setEntry(SongTagEditPolicy.normalized(entry), previous: nil)
        }
        appliedRevisions = storage.appliedRevisions
        pendingRestoreIDs = Set(storage.pendingRestoreIDs ?? [])
    }

    // MARK: - 本机手改

    /// 用户亲手给这些歌换了封面图(标签编辑、批量编辑、单曲刮削),图已经存进本机缓存。读出来
    /// 缩成可以同步的 JPEG 记下并上传。缓存文件名按歌曲算,换图时名字常常不变,所以由编辑
    /// 界面明说,而不是从行的变化里猜。
    func recordUserChosenCovers(songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        let now = Date()
        let assets = MetadataAssetStore.shared
        let work = Set(songIDs).map { id in
            (songID: id, fileName: library?.storedSong(id: id)?.coverArtFileName ?? assets.expectedCoverFileName(for: id),
             clock: SongTagEditPolicy.editClock(existing: entries[id], at: now))
        }
        resolveCovers(work, uploading: true)
    }

    /// 「恢复文件标签」:之前的手改(连只换过的封面)在各设备上一起作废。没记过也没标记的歌不记。
    func recordRestore(songIDs: [String]) {
        guard let library else { return }
        let now = Date()
        var changedIDs: [String] = []
        for id in Set(songIDs) {
            let existing = entries[id]
            if let existing, !existing.hasActiveFields, existing.restoredAt != nil { continue }
            guard existing != nil || library.storedSong(id: id)?.userMetadataEditedAt != nil else { continue }
            let next = SongTagEditPolicy.restoring(existing: existing, songID: id, at: now)
            setEntry(next, previous: existing)
            // 本机这次就是恢复本身,由补读按文件重读,不必再套。
            appliedRevisions[id] = stamps[id]
            pendingApplySongIDs.remove(id)
            changedIDs.append(id)
        }
        guard !changedIDs.isEmpty else { return }
        plog("🏷️ tag edits restored locally songs=\(changedIDs.count)")
        postEntriesChanged(changedIDs)
        schedulePersist()
    }

    private func localEditTransitions(_ transitions: [(previous: Song, updated: Song)]) {
        guard !isApplyingToLibrary, !transitions.isEmpty else { return }
        var changedIDs: [String] = []
        var legacyCoverWork: [(songID: String, fileName: String, clock: TimeInterval)] = []
        for (previous, updated) in transitions {
            // 标记被清掉只有两种来源:「恢复文件标签」(已经由 `recordRestore` 记过),或者拿旧行
            // 写回(刮削、后台补全在改动之前取的行)。后一种不能当恢复传给别的设备,标记丢了的
            // 行在下次对账时重新套上。
            guard let marker = updated.userMetadataEditedAt else { continue }
            let id = updated.id
            let stored = entries[id]
            var existing = stored
            // 这个功能上线前就手改过的行先整行记一笔,不然这次只改一个字段时,当初改的那几个就丢了。
            // 当初的封面要读图算哈希,放到后台去记。
            if existing == nil, let previousMarker = previous.userMetadataEditedAt {
                existing = SongTagEditPolicy.legacyEdit(for: previous, cover: nil)
                if let reference = previous.coverArtFileName, !reference.isEmpty {
                    legacyCoverWork.append((id, reference, previousMarker.timeIntervalSince1970))
                }
            }
            let clock = SongTagEditPolicy.editClock(existing: existing, at: marker)
            var edit = SongTagEditPolicy.recordingEdit(
                previous: previous, updated: updated, existing: existing, clock: clock
            )
            // 换成缓存里的另一张图由编辑界面另外记(`recordUserChosenCovers`)。
            if let change = SongTagEditPolicy.referenceCoverChange(from: previous, to: updated) {
                edit = SongTagEditPolicy.recordingCover(change, songID: id, existing: edit, clock: clock)
            }
            guard let next = edit, next != stored else { continue }
            let previousStamp = stamps[id]
            setEntry(next, previous: stored)
            markAppliedIfCurrent(id, previousStamp: previousStamp)
            changedIDs.append(id)
        }
        if !legacyCoverWork.isEmpty { resolveCovers(legacyCoverWork, uploading: false) }
        guard !changedIDs.isEmpty else { return }
        plog("🏷️ tag edits recorded locally songs=\(changedIDs.count)")
        postEntriesChanged(changedIDs)
        schedulePersist()
    }

    /// 本机这一行就是这次改动本身,不必再套一遍 —— 前提是改之前这一行已经是上一版记录的样子。
    /// 别的设备的改动还在等本机读完标签时,这次本机改动不能顺手把它们也记成已套用。
    private func markAppliedIfCurrent(_ id: String, previousStamp: String?) {
        if appliedRevisions[id] == previousStamp {
            appliedRevisions[id] = stamps[id]
        }
    }

    /// 记下封面图的内容哈希。`uploading` 时(用户亲手换的图)另外缩成可以同步的 JPEG 存进
    /// 自选封面池,一起记下、上传;上线前手改过的行只记哈希 —— 说不清那张图是用户换的还是
    /// 读文件读到的,别的设备有同一份内容时才会换过去。读图和压缩不在主线程做,批量换同一张
    /// 图时只压一次。
    private func resolveCovers(
        _ work: [(songID: String, fileName: String, clock: TimeInterval)],
        uploading: Bool
    ) {
        Task.detached(priority: .utility) { [weak self] in
            var resolved: [(songID: String, cover: SongTagEditCover, clock: TimeInterval)] = []
            var portableByOriginal: [String: String?] = [:]
            for item in work {
                let cover: SongTagEditCover?
                if SongTagEditPolicy.isSourceFileReference(item.fileName) {
                    cover = .sourceFile(item.fileName)
                } else if let original = Self.contentHash(ofCoverNamed: item.fileName) {
                    if uploading {
                        let portable: String?
                        if let known = portableByOriginal[original] {
                            portable = known
                        } else {
                            portable = Self.portableContentID(ofCoverNamed: item.fileName)
                            portableByOriginal[original] = portable
                        }
                        cover = .image(original: original, portable: portable)
                    } else {
                        cover = .image(original: original, portable: nil)
                    }
                } else {
                    cover = nil
                }
                if let cover { resolved.append((item.songID, cover, item.clock)) }
            }
            guard !resolved.isEmpty else { return }
            await self?.coversResolved(resolved)
        }
    }

    /// 缩成可以同步的 JPEG(本来就合适的原样用),存进自选封面池,返回它的内容哈希。
    private nonisolated static func portableContentID(ofCoverNamed fileName: String) -> String? {
        let assets = MetadataAssetStore.shared
        guard let data = assets.readCoverData(named: fileName) else { return nil }
        let portableData = LibraryArtworkImageProcessor.isReusablePortableJPEG(data)
            ? data
            : LibraryArtworkImageProcessor.process(data)
        return portableData.flatMap { assets.storeCustomArtworkSync($0) }
    }

    /// 缓存封面的内容哈希:按内容存放的直接取指针里的哈希,老格式的原图现算。
    private nonisolated static func contentHash(ofCoverNamed fileName: String) -> String? {
        let assets = MetadataAssetStore.shared
        if let identity = assets.coverContentIdentifier(named: fileName), identity.hasPrefix("sha256:") {
            let hash = String(identity.dropFirst("sha256:".count))
            return PeerScanSeedPolicy.isContentKey(hash) ? hash : nil
        }
        guard let data = assets.readCoverData(named: fileName) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func coversResolved(_ resolved: [(songID: String, cover: SongTagEditCover, clock: TimeInterval)]) {
        var changedIDs: [String] = []
        var uploads: Set<String> = []
        for item in resolved {
            let previous = entries[item.songID]
            guard let next = SongTagEditPolicy.recordingCover(
                item.cover, songID: item.songID, existing: previous, clock: item.clock
            ), next != previous else { continue }
            let previousStamp = stamps[item.songID]
            setEntry(next, previous: previous)
            markAppliedIfCurrent(item.songID, previousStamp: previousStamp)
            changedIDs.append(item.songID)
            if case .image(_, let portable?) = item.cover { uploads.insert(portable) }
        }
        guard !changedIDs.isEmpty else { return }
        plog("🏷️ tag edits recorded covers songs=\(changedIDs.count) uploads=\(uploads.count)")
        if !uploads.isEmpty { postCoversChanged(uploads: Array(uploads), deleted: []) }
        postEntriesChanged(changedIDs)
        schedulePersist()
    }

    private func remapSongIDs(_ replacements: [String: String]) {
        var changedIDs: [String] = []
        for (old, new) in replacements where old != new {
            guard let entry = entries[old] else { continue }
            var moved = entry
            moved.songID = new
            let merged = entries[new].map { SongTagEditPolicy.merged($0, moved) } ?? moved
            // 先记上新的再去掉旧的:两边用着同一张封面图时用户集合不会先空掉。
            setEntry(merged, previous: entries[new])
            setEntry(nil, previous: entry, songID: old)
            appliedRevisions[old] = nil
            if pendingRestoreIDs.remove(old) != nil { pendingRestoreIDs.insert(new) }
            changedIDs.append(new)
        }
        guard !changedIDs.isEmpty else { return }
        postEntriesChanged(changedIDs)
        schedulePersist()
    }

    // MARK: - 上线前的手改、整库套用

    /// 曲库就绪时:上线前手改过、还没有记录的行补记一笔,再把记录套到本机各行上。
    private func recordLegacyEditsAndReconcile() {
        guard let library else { return }
        let songs = library.songs
        Task.detached(priority: .utility) { [weak self] in
            let edited = songs.filter { $0.userMetadataEditedAt != nil }
            await self?.recordLegacyEdits(edited)
        }
    }

    private func recordLegacyEdits(_ edited: [Song]) {
        var changedIDs: [String] = []
        for song in edited where entries[song.id] == nil {
            // 记录到之前这一行可能又变了,以现在的为准。
            guard let current = library?.storedSong(id: song.id), current.userMetadataEditedAt != nil,
                  let edit = SongTagEditPolicy.legacyEdit(for: current, cover: nil) else { continue }
            setEntry(edit, previous: nil)
            appliedRevisions[song.id] = stamps[song.id]
            changedIDs.append(song.id)
        }
        if !changedIDs.isEmpty {
            plog("🏷️ tag edits recorded from earlier hand edits songs=\(changedIDs.count)")
            recordLegacyCovers(changedIDs)
            postEntriesChanged(changedIDs)
            schedulePersist()
        }
        reconcile(songIDs: Array(entries.keys))
    }

    private func recordLegacyCovers(_ songIDs: [String]) {
        let work: [(songID: String, fileName: String, clock: TimeInterval)] = songIDs.compactMap { id in
            guard let song = library?.storedSong(id: id), let marker = song.userMetadataEditedAt,
                  let reference = song.coverArtFileName, !reference.isEmpty else { return nil }
            return (id, reference, marker.timeIntervalSince1970)
        }
        if !work.isEmpty { resolveCovers(work, uploading: false) }
    }

    /// 扫描交来新行、补读读完一批之后调用:等着的改动现在可能套得上了。不带 id 时整库对一遍,
    /// 几秒内的多次请求并成一次(不往后推,补读一直在跑时也照样会对)。
    func libraryRowsMayHaveChanged(songIDs: Set<String>? = nil) {
        if let songIDs {
            let ready = pendingApplySongIDs.intersection(songIDs)
            if !ready.isEmpty { reconcile(songIDs: Array(ready)) }
            return
        }
        guard reconcileAllTask == nil else { return }
        reconcileAllTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.reconcileAllTask = nil
            self.reconcile(songIDs: Array(self.entries.keys))
        }
    }

    // MARK: - 套到本机这一行上

    private func reconcile(songIDs: [String]) {
        guard let library, library.isReady, !songIDs.isEmpty else { return }
        var rows: [Song] = []
        var restoreIDs: [String] = []
        var coverWork: [(songID: String, cover: SongTagEditCover, currentReference: String?)] = []
        var revisionsChanged = false
        for id in songIDs {
            guard let entry = entries[id], let song = library.storedSong(id: id) else { continue }
            let stamp = stamps[id]
            if entry.hasActiveFields {
                // 恢复之后别处又改了:不用再按文件重读,套新的改动就行。
                if pendingRestoreIDs.remove(id) != nil { revisionsChanged = true }
                // 有文字字段的记录套上之后行上一定有标记;标记没了(文件换了、拿旧行写回)就再套一次。
                if appliedRevisions[id] == stamp,
                   song.userMetadataEditedAt != nil || !entry.hasActiveTextFields { continue }
                let cover = entry[.cover]?.cover
                guard readinessProvider?(song, Self.isResolvableHere(cover)) ?? true else {
                    pendingApplySongIDs.insert(id)
                    continue
                }
                var updated = SongTagEditPolicy.applyingTextFields(entry, to: song)
                if let cover {
                    switch cover {
                    case .removed: updated.coverArtFileName = nil
                    case .sourceFile(let path): updated.coverArtFileName = path
                    case .image: coverWork.append((id, cover, song.coverArtFileName))
                    }
                }
                if updated != song { rows.append(updated) }
                appliedRevisions[id] = stamp
                pendingApplySongIDs.remove(id)
                revisionsChanged = true
            } else if pendingRestoreIDs.contains(id) || SongTagEditPolicy.needsRestore(entry, song: song) {
                if SongTagEditPolicy.needsRestore(entry, song: song) {
                    var cleared = song
                    cleared.userMetadataEditedAt = nil
                    rows.append(cleared)
                }
                if pendingRestoreIDs.insert(id).inserted { revisionsChanged = true }
                if !restoreInFlightIDs.contains(id) { restoreIDs.append(id) }
                if appliedRevisions[id] != stamp {
                    appliedRevisions[id] = stamp
                    revisionsChanged = true
                }
            }
        }
        if !rows.isEmpty {
            isApplyingToLibrary = true
            library.replaceSongs(rows)
            isApplyingToLibrary = false
            plog("🏷️ tag edits applied from other devices rows=\(rows.count) restoring=\(restoreIDs.count)")
        }
        if !restoreIDs.isEmpty { rereadRestored(restoreIDs) }
        if !coverWork.isEmpty { applyCovers(coverWork) }
        if revisionsChanged { schedulePersist() }
    }

    /// 改动里的封面本机现在就能套上:去掉封面、音乐源里的图、传到 iCloud 的图。只记了内容
    /// 哈希的图要本机碰巧有同一份,套不上时这一行还得等自己的内嵌封面读完。
    private static func isResolvableHere(_ cover: SongTagEditCover?) -> Bool {
        switch cover {
        case nil: return false
        case .removed?, .sourceFile?: return true
        case .image(_, let portable)?: return portable != nil
        }
    }

    private func rereadRestored(_ songIDs: [String]) {
        guard restoreHandler != nil else { return }
        restoreInFlightIDs.formUnion(songIDs)
        Task { [weak self] in
            guard let handler = self?.restoreHandler else { return }
            let settled = await handler(songIDs)
            guard let self else { return }
            self.restoreInFlightIDs.subtract(songIDs)
            let before = self.pendingRestoreIDs.count
            self.pendingRestoreIDs.subtract(settled)
            if self.pendingRestoreIDs.count != before { self.schedulePersist() }
            if settled.count < songIDs.count {
                plog("🏷️ tag edit restores waiting to reread songs=\(songIDs.count - settled.count)")
            }
        }
    }

    /// 封面图:本机已经有同一份内容就指过去,否则用 iCloud 上那份;那份还没到就等它。
    private func applyCovers(_ work: [(songID: String, cover: SongTagEditCover, currentReference: String?)]) {
        Task.detached(priority: .utility) { [weak self] in
            let assets = MetadataAssetStore.shared
            var installed: [(songID: String, fileName: String)] = []
            var waiting: [(songID: String, portable: String)] = []
            for item in work {
                guard case .image(let original, let portable) = item.cover else { continue }
                if let reference = item.currentReference, !SongTagEditPolicy.isSourceFileReference(reference),
                   StoredArtworkOrigin.preservesLocalChoice(reference),
                   let identity = assets.coverContentIdentifier(named: reference),
                   identity == "sha256:\(original)" || portable.map({ identity == "sha256:\($0)" }) == true {
                    continue
                }
                if let fileName = assets.linkCoverContentIfPresent(original, forSongID: item.songID),
                   let data = assets.readCoverData(named: fileName),
                   let reference = await assets.storeAttributedCover(data, songID: item.songID, origin: .selected) {
                    installed.append((item.songID, reference))
                } else if let portable, let data = assets.customArtworkData(contentID: portable) {
                    if let reference = await assets.storeAttributedCover(data, songID: item.songID, origin: .selected) {
                        installed.append((item.songID, reference))
                    }
                } else if let portable {
                    waiting.append((item.songID, portable))
                }
            }
            await self?.coversApplied(installed: installed, waiting: waiting)
        }
    }

    private func coversApplied(
        installed: [(songID: String, fileName: String)],
        waiting: [(songID: String, portable: String)]
    ) {
        for item in waiting { awaitingPortableCovers[item.portable, default: []].insert(item.songID) }
        // 图可能正好在后台查找的那会儿到了:那时还没挂上等候,到货时没人接。
        let customDirectory = MetadataAssetStore.shared.customArtworkDirectoryURL
        for portable in Set(waiting.map(\.portable)) where FileManager.default.fileExists(
            atPath: customDirectory.appendingPathComponent("\(portable).jpg").path
        ) {
            portableCoverArrived(contentID: portable)
        }
        guard let library, !installed.isEmpty else { return }
        for item in installed {
            library.updateAssetReferences(songID: item.songID, coverRef: item.fileName)
        }
        // 缓存文件名按歌曲算,换图后名字常常不变,在屏的封面要按名字重新读。
        NotificationCenter.default.post(
            name: .primuseArtworkDidInvalidate,
            object: nil,
            userInfo: [
                "songIDs": installed.map(\.songID),
                "tokens": installed.map(\.fileName),
            ]
        )
        plog("🏷️ tag edit covers applied songs=\(installed.count) waiting=\(waiting.count)")
    }

    // MARK: - iCloud

    /// 全部记录的歌曲 id,同步通道打开时整批补传。
    var allSongIDs: [String] { Array(entries.keys) }

    /// 还有歌在用、要传到 iCloud 的封面图。
    var allPortableCoverIDs: [String] { Array(portableUsers.keys) }

    func entry(forCloudRecordKey key: String) -> SongTagEdit? {
        if CloudRecordNameEncoding.isPlain(key) { return entries[key] }
        if let cached = cloudKeyMap?[key], let entry = entries[cached] { return entry }
        var map: [String: String] = [:]
        for id in entries.keys where !CloudRecordNameEncoding.isPlain(id) {
            map[CloudRecordNameEncoding.recordName(for: id)] = id
        }
        cloudKeyMap = map
        return map[key].flatMap { entries[$0] }
    }

    /// 并进 iCloud 送来的一条。返回本机是否还有比它新的内容,需要传回去。
    @discardableResult
    func applyRemote(_ remote: SongTagEdit) -> Bool {
        loadIfNeeded()
        let incoming = SongTagEditPolicy.normalized(remote)
        let previous = entries[incoming.songID]
        var local = previous
        var legacyCoverWork: [(songID: String, fileName: String, clock: TimeInterval)] = []
        // 本机上线前就手改过、还没来得及补记的行:先按本机的改动记一笔再合并,不然别处的
        // 记录先到,本机当初(可能更晚)的改动就再也记不上了。
        if local == nil, let row = library?.storedSong(id: incoming.songID),
           let marker = row.userMetadataEditedAt {
            local = SongTagEditPolicy.legacyEdit(for: row, cover: nil)
            if let reference = row.coverArtFileName, !reference.isEmpty {
                legacyCoverWork.append((incoming.songID, reference, marker.timeIntervalSince1970))
            }
        }
        let merged = local.map { SongTagEditPolicy.merged($0, incoming) } ?? incoming
        if merged != previous {
            // 本机还生效的改动被别处的恢复清掉了:要按文件重读(只换过封面的行没有标记可查)。
            if local?.hasActiveFields == true, !merged.hasActiveFields {
                pendingRestoreIDs.insert(merged.songID)
            }
            setEntry(merged, previous: previous)
            schedulePersist()
            queueReconcile(merged.songID)
        }
        if !legacyCoverWork.isEmpty { resolveCovers(legacyCoverWork, uploading: false) }
        return merged != incoming
    }

    private func queueReconcile(_ songID: String) {
        queuedReconcileIDs.insert(songID)
        guard queuedReconcileTask == nil else { return }
        queuedReconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.queuedReconcileTask = nil
            let ids = Array(self.queuedReconcileIDs)
            self.queuedReconcileIDs.removeAll()
            self.reconcile(songIDs: ids)
        }
    }

    /// 云端那条记录没了(换了库区或被清空)。本机还有就传回去。
    func remoteEntryDeleted(cloudRecordKey key: String) -> Bool {
        entry(forCloudRecordKey: key) != nil
    }

    /// 用着这张封面图的歌。
    func songIDs(usingPortableCover contentID: String) -> Set<String> {
        portableUsers[contentID] ?? []
    }

    /// 上传一张封面图要用的字节;已经没有歌在用时返回 nil。
    func portableCoverData(contentID: String) -> Data? {
        guard portableUsers[contentID] != nil else { return nil }
        return MetadataAssetStore.shared.customArtworkData(contentID: contentID)
    }

    /// iCloud 送来的封面图:在后台核对内容哈希后存进自选封面池,再给等着它的歌套上。
    func applyRemotePortableCover(contentID: String, data: Data) {
        Task.detached(priority: .utility) { [weak self] in
            guard MetadataAssetStore.shared.storeCustomArtworkSync(data, expectedContentID: contentID) != nil else {
                return
            }
            await self?.portableCoverArrived(contentID: contentID)
        }
    }

    private func portableCoverArrived(contentID: String) {
        guard let songIDs = awaitingPortableCovers.removeValue(forKey: contentID), !songIDs.isEmpty else { return }
        let work: [(songID: String, cover: SongTagEditCover, currentReference: String?)] = songIDs.compactMap { id in
            guard let cover = entries[id]?[.cover]?.cover,
                  case .image(_, let portable) = cover, portable == contentID else { return nil }
            return (id, cover, library?.storedSong(id: id)?.coverArtFileName)
        }
        if !work.isEmpty { applyCovers(work) }
    }

    /// 云端的封面图被删了。本机还有歌在用、手里也有这张图就传回去。
    func remotePortableCoverDeleted(contentID: String) -> Bool {
        portableCoverData(contentID: contentID) != nil
    }

    /// 把还没落盘的改动现在写下去,并等到写完(同步服务存游标之前调用)。
    func flushPendingWrite() {
        if persistTask != nil {
            persistTask?.cancel()
            persistTask = nil
            writeNow()
        }
        Self.writeQueue.sync {}
    }

    // MARK: - 存储

    private func setEntry(_ entry: SongTagEdit?, previous: SongTagEdit?, songID: String? = nil) {
        let id = entry?.songID ?? songID ?? previous?.songID
        guard let id else { return }
        let oldPortable = previous.flatMap(Self.portableCoverID)
        let newPortable = entry.flatMap(Self.portableCoverID)
        entries[id] = entry
        stamps[id] = entry?.revisionStamp
        if !CloudRecordNameEncoding.isPlain(id) { cloudKeyMap = nil }
        guard oldPortable != newPortable else { return }
        if let newPortable { portableUsers[newPortable, default: []].insert(id) }
        if let oldPortable {
            portableUsers[oldPortable]?.remove(id)
            if portableUsers[oldPortable]?.isEmpty == true {
                portableUsers[oldPortable] = nil
                // 加载时 previous 为 nil,不会走到这里;运行中没有歌再用这张图了,云端那份删掉。
                postCoversChanged(uploads: [], deleted: [oldPortable])
            }
        }
    }

    private nonisolated static func portableCoverID(of entry: SongTagEdit) -> String? {
        guard case .image(_, let portable)? = entry[.cover]?.cover else { return nil }
        return portable
    }

    private func postEntriesChanged(_ ids: [String]) {
        NotificationCenter.default.post(
            name: .primuseSongTagEditsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func postCoversChanged(uploads: [String], deleted: [String]) {
        NotificationCenter.default.post(
            name: .primuseSongTagEditCoversDidChange,
            object: nil,
            userInfo: ["ids": uploads, "deleted": deleted]
        )
    }

    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistTask = nil
            self?.writeNow()
        }
    }

    private func writeNow() {
        guard let fileURL else { return }
        let storage = Storage(
            entries: Array(entries.values),
            appliedRevisions: appliedRevisions,
            pendingRestoreIDs: pendingRestoreIDs.isEmpty ? nil : Array(pendingRestoreIDs)
        )
        // 编码和写盘都在串行队列上:后发起的那次一定后落盘,主线程只拷一份值。
        Self.writeQueue.async {
            guard let data = try? JSONEncoder().encode(storage) else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
