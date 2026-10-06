import Foundation
import Observation
import PrimuseKit

/// 批量补简介里的一个:专辑页、艺人页按当前列表的顺序交来,曲目、风格这些轮到它时才收集。
struct LibraryInsightBatchItem: Sendable {
    /// 只用名字认出是哪张专辑 / 哪位艺人。
    var subject: LibraryInsightSubject
    var albumID: String?
    var artistID: String?

    static func album(_ album: Album) -> LibraryInsightBatchItem {
        let artist = album.artistName ?? ""
        return LibraryInsightBatchItem(
            subject: .album(
                title: album.title,
                artist: artist == String(localized: "unknown_artist") ? "" : artist,
                year: album.year,
                genres: [],
                tracks: []
            ),
            albumID: album.id
        )
    }

    static func artist(_ artist: Artist) -> LibraryInsightBatchItem {
        LibraryInsightBatchItem(
            subject: .artist(name: artist.name, genres: [], albums: [], tracks: []),
            artistID: artist.id
        )
    }
}

/// 专辑页、艺人页右上角的「补全缺少的简介」:按列表顺序逐个问 AI,写好就存进曲库、照常写回
/// 音乐源。先读音乐源上已有的(album.nfo、媒体服务器),读到就不问 AI。
///
/// 内置 AI 一次只问一个、两次之间隔 2 秒(免费档每台设备同一时刻只放行一个请求);额度用完时
/// 有自己的服务就改问它,没有就停下。服务让等就整批等,等不起或连着出错就停,别把额度耗在
/// 出了毛病的服务上。同一时刻只跑一批,离开页面也接着补。
@MainActor
@Observable
final class LibraryInsightBatchFill {
    static let shared = LibraryInsightBatchFill()

    enum StopReason: Equatable {
        case completed
        case cancelled
        /// 额度用完、服务用不了这些问下一个也一样的情况。
        case failure(AILibraryContentFailure)
        /// 连着几个都没成。
        case repeatedFailures
    }

    struct Progress: Equatable {
        var kind: LibraryInsightKind
        var total: Int
        var done = 0
        var filled = 0
        var imported = 0
        var unknown = 0
        var failed = 0
        /// 最近一次答上来的服务。
        var providerName: String?
        /// 内置 AI 的额度用完了,后面改问自己的服务。
        var switchedToOwnService = false
        /// 服务让等,等到这时再接着问。
        var waitingUntil: Date?
        /// 还在补时为 nil。
        var stopReason: StopReason?

        var isRunning: Bool { stopReason == nil }
        var left: Int { max(0, total - done) }
    }

    private(set) var progress: Progress?

    private struct Context {
        let library: MusicLibrary
        let intelligence: MusicIntelligenceService
        let sourceManager: SourceManager
        let sourcesStore: SourcesStore
    }

    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: ArraySlice<LibraryInsightBatchItem> = []
    @ObservationIgnored private var albumSongIDs: [String: [String]] = [:]
    @ObservationIgnored private var skipsBuiltIn = false
    @ObservationIgnored private var spacing: TimeInterval = 0
    @ObservationIgnored private var nextStartAt = Date.distantPast
    @ObservationIgnored private var resumeAt = Date.distantPast
    @ObservationIgnored private var consecutiveFailures = 0
    /// 这批存过简介:收尾时把合并着的那次整库写盘提前做掉。
    @ObservationIgnored private var savedAny = false
    /// 每批一个号:停下后马上再开一批时,上一批还在收尾的任务认得出自己已经过时。
    @ObservationIgnored private var runID = 0

    var isRunning: Bool { progress?.isRunning == true }

    /// 开始补这一批。`items` 已按「缺简介」筛过;`skipsBuiltIn` 是用户选了这次只用自己的服务。
    func start(
        _ items: [LibraryInsightBatchItem],
        kind: LibraryInsightKind,
        skipsBuiltIn: Bool,
        library: MusicLibrary,
        intelligence: MusicIntelligenceService,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) {
        guard !isRunning, !items.isEmpty else { return }
        context = Context(
            library: library,
            intelligence: intelligence,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        )
        pending = items[...]
        albumSongIDs = kind == .album ? Self.songIDsByAlbum(items, library: library) : [:]
        self.skipsBuiltIn = skipsBuiltIn
        let usesBuiltIn = !skipsBuiltIn && intelligence.libraryInsightAsksBuiltIn
        spacing = LibraryInsightBatchPolicy.minimumSpacing(usesBuiltIn: usesBuiltIn)
        nextStartAt = .distantPast
        resumeAt = .distantPast
        consecutiveFailures = 0
        savedAny = false
        progress = Progress(
            kind: kind,
            total: items.count,
            providerName: usesBuiltIn
                ? String(localized: "ai_primuse_relay_name")
                : intelligence.libraryInsightOwnServiceName
        )
        runID += 1
        let run = runID
        let workers = LibraryInsightBatchPolicy.concurrency(usesBuiltIn: usesBuiltIn)
        plog("✨ Library insight batch start kind=\(kind.rawValue) items=\(items.count) builtIn=\(usesBuiltIn) workers=\(workers)")
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask { await self?.work(run) }
                }
            }
            guard let self, self.runID == run else { return }
            self.finish(.completed)
        }
    }

    /// 停下;正在问的那一个也取消(内置 AI 会退还这次的次数)。
    func stop() {
        guard isRunning else { return }
        finish(.cancelled)
    }

    /// 收起补完 / 停下后的结果。
    func dismiss() {
        guard !isRunning else { return }
        progress = nil
    }

    private func finish(_ reason: StopReason) {
        guard progress?.isRunning == true else { return }
        progress?.stopReason = reason
        progress?.waitingUntil = nil
        task?.cancel()
        task = nil
        pending = []
        albumSongIDs = [:]
        if savedAny { context?.library.persistNow() }
        savedAny = false
        context = nil
        if let progress {
            plog("✨ Library insight batch end reason=\(reason) done=\(progress.done)/\(progress.total)"
                 + " filled=\(progress.filled) imported=\(progress.imported) unknown=\(progress.unknown)"
                 + " failed=\(progress.failed) switched=\(progress.switchedToOwnService)")
        }
    }

    // MARK: - 逐个补

    private func work(_ run: Int) async {
        while !Task.isCancelled, isRunning, runID == run, let item = pending.popFirst() {
            await fill(item)
        }
    }

    private func fill(_ item: LibraryInsightBatchItem) async {
        guard let context else { return }
        let store = LibraryInsightStore.shared
        let library = context.library
        let id = store.recordID(for: item.subject)
        // 排队这一会儿可能已经有了:详情页读回来的、用户自己写的、别的设备同步来的。
        guard LibraryInsightBatchPolicy.needsFill(library.storedLibraryInsightRecord(id: id)) else {
            progress?.done += 1
            return
        }
        let songs = songs(for: item, library: library)
        await LibraryInsightWriteback.importIfAvailable(
            subject: item.subject,
            songs: songs,
            library: library,
            sourceManager: context.sourceManager,
            sourcesStore: context.sourcesStore,
            persistAfter: Self.persistDelay
        )
        guard !Task.isCancelled, isRunning else { return }
        if let stored = library.storedLibraryInsightRecord(id: id) {
            if stored.importedFrom != nil {
                progress?.imported += 1
                savedAny = true
            }
            progress?.done += 1
            return
        }

        let details = details(for: item, songs: songs, library: library)
        let languageCode = LibraryInsightStore.languageCode
        guard let request = LibraryInsightAIExchange.request(for: details, languageCode: languageCode) else {
            progress?.failed += 1
            progress?.done += 1
            return
        }
        guard store.beginBatchGeneration(item.subject) else {
            // 卡片上正在为它生成,交给那边。
            progress?.done += 1
            return
        }
        let saved = await ask(request, details: details, id: id, languageCode: languageCode, context: context)
        store.endBatchGeneration(item.subject)
        guard let saved, saved.hasContent else { return }
        let report = await LibraryInsightWriteback.write(
            saved,
            subject: details,
            songs: songs,
            library: library,
            sourceManager: context.sourceManager,
            sourcesStore: context.sourcesStore
        )
        store.setWritebackNote(written: report.written, failed: report.failed, for: item.subject)
    }

    /// 问到答上来、跳过或整批停下为止。存下了就返回那份记录。
    private func ask(
        _ request: LibraryInsightAIExchange.Request,
        details: LibraryInsightSubject,
        id: String,
        languageCode: String,
        context: Context
    ) async -> LibraryInsightRecord? {
        var attempt = 1
        while true {
            await waitForTurn()
            guard !Task.isCancelled, isRunning else { return nil }
            let usedBuiltIn = !skipsBuiltIn
            let (outcome, builtInStopped) = await context.intelligence.libraryInsightInBatch(
                request,
                skipsBuiltIn: skipsBuiltIn
            )
            guard !Task.isCancelled, isRunning else { return nil }
            if usedBuiltIn, builtInStopped, !skipsBuiltIn,
               context.intelligence.libraryInsightOwnServiceName != nil {
                skipsBuiltIn = true
                spacing = LibraryInsightBatchPolicy.minimumSpacing(usesBuiltIn: false)
                progress?.switchedToOwnService = true
            }
            switch outcome {
            case .success(let answer, let providerName):
                consecutiveFailures = 0
                if progress?.providerName != providerName { progress?.providerName = providerName }
                progress?.done += 1
                // 问的这一会儿用户可能自己写了一份,或别的设备同步来了一份:不覆盖。
                guard LibraryInsightBatchPolicy.needsFill(context.library.storedLibraryInsightRecord(id: id)) else {
                    return nil
                }
                let record = LibraryInsightEditing.recordAfterAIFill(
                    answer,
                    subject: details,
                    id: id,
                    providerName: providerName,
                    languageCode: languageCode,
                    previous: nil,
                    now: Date()
                )
                context.library.saveLibraryInsightRecord(record, persistAfter: Self.persistDelay)
                savedAny = true
                if answer.known {
                    progress?.filled += 1
                } else {
                    progress?.unknown += 1
                }
                return record
            case .failed(let failure, let retryAt):
                let kind = Self.batchFailure(failure)
                switch LibraryInsightBatchPolicy.step(after: kind, attempt: attempt, retryAt: retryAt, now: Date()) {
                case .retry(let wait):
                    attempt += 1
                    resumeAt = max(resumeAt, Date().addingTimeInterval(wait))
                    plog("✨ Library insight batch wait=\(Int(wait))s reason=\(failure)")
                case .skip:
                    progress?.failed += 1
                    progress?.done += 1
                    consecutiveFailures += 1
                    if consecutiveFailures >= LibraryInsightBatchPolicy.maximumConsecutiveFailures {
                        finish(.repeatedFailures)
                    }
                    return nil
                case .stop:
                    finish(.failure(failure))
                    return nil
                }
            }
        }
    }

    /// 等到能开问:两次开问之间留出间隔,服务让等时整批一起等。
    private func waitForTurn() async {
        while !Task.isCancelled, isRunning {
            let now = Date()
            let start = max(nextStartAt, resumeAt)
            if start <= now {
                nextStartAt = now.addingTimeInterval(spacing)
                if progress?.waitingUntil != nil { progress?.waitingUntil = nil }
                return
            }
            if resumeAt > now, progress?.waitingUntil != resumeAt { progress?.waitingUntil = resumeAt }
            try? await Task.sleep(for: .seconds(start.timeIntervalSince(now)))
        }
    }

    /// 存简介后的落盘延迟:一次落盘是整库快照,连着补几百个时不能每个都写一遍。
    private static let persistDelay: TimeInterval = 20

    nonisolated static func batchFailure(_ failure: AILibraryContentFailure) -> LibraryInsightBatchPolicy.Failure {
        switch failure {
        case .notConfigured, .needsConsent, .builtInNotOffered:
            return .unavailable
        case .noTasteProfile:
            return .itemFailed
        case .failed(let reason):
            switch reason {
            case .dailyLimit, .monthlyLimit: return .quotaExhausted
            case .minuteLimit: return .rateLimited
            case .busy: return .busy
            case .network: return .network
            case .regionRestricted, .deviceRegistration, .authentication: return .unavailable
            case .empty, .unavailable, .upstream: return .itemFailed
            }
        }
    }

    // MARK: - 收集资料

    /// 整库只走一遍,记下要补的专辑各有哪些歌(`songs(forAlbum:)` 每次都要扫整库)。
    private static func songIDsByAlbum(
        _ items: [LibraryInsightBatchItem],
        library: MusicLibrary
    ) -> [String: [String]] {
        let wanted = Set(items.compactMap(\.albumID))
        guard !wanted.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        let songs = library.visibleSongs
        // 按下标读字段,不把整首歌逐个拷出来。
        for index in songs.indices {
            guard let albumID = songs[index].albumID, wanted.contains(albumID) else { continue }
            result[albumID, default: []].append(songs[index].id)
        }
        return result
    }

    private func songs(for item: LibraryInsightBatchItem, library: MusicLibrary) -> [Song] {
        if let albumID = item.albumID {
            let songs = (albumSongIDs[albumID] ?? []).compactMap { library.visibleSong(id: $0) }
            return AlbumTrackOrder.sorted(songs)
        }
        if let artistID = item.artistID {
            return library.songs(forArtist: artistID)
        }
        return []
    }

    /// 和详情页「生成简介」收集的一样:专辑是按曲序的曲名和最常见的风格,艺人是出现过的专辑、
    /// 前几十首歌和最常见的风格。
    private func details(
        for item: LibraryInsightBatchItem,
        songs: [Song],
        library: MusicLibrary
    ) -> LibraryInsightSubject {
        let subject = item.subject
        let genres = LibraryInsightSubject.topGenres(songs.map(\.genre))
        switch subject.kind {
        case .album:
            return .album(
                title: subject.albumTitle,
                artist: subject.artistName,
                year: subject.year,
                genres: genres,
                tracks: songs.map(\.title)
            )
        case .artist:
            var seen: Set<String> = []
            let albums = songs.compactMap { song -> LibraryInsightSubject.AlbumReference? in
                guard let albumID = song.albumID, seen.insert(albumID).inserted,
                      let album = library.visibleAlbum(id: albumID) else { return nil }
                return .init(title: album.title, year: album.year)
            }
            return .artist(
                name: subject.artistName,
                genres: genres,
                albums: albums,
                tracks: songs.prefix(40).map(\.title)
            )
        }
    }
}
