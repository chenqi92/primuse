import Foundation
import PrimuseKit

/// P2 过渡规则:目录可读(`catalogHost.revisions.isReadable`)时播放器、队列、首页读目录,
/// 否则照旧读内存模型。读目录出错也退回内存模型。
enum PlaybackCatalogAccess {
    /// 目录现在能读就给读接口,否则 nil。
    @MainActor
    static func reader(for library: MusicLibrary?) -> LibraryCatalogReader? {
        guard let host = library?.catalogHost, host.revisions.isReadable else { return nil }
        return host.reader
    }
}

extension AudioPlayerService {
    // MARK: - Whole-library requests from the catalog

    /// 整库播放(播放全部、随机全部、从这首开始、点歌接整库)在目录上排队:id 列表在目录里拼、
    /// 在主线程外过滤与打乱,只物化装进播放器的那一窗(`QueueWindowPolicy`),其余照旧记在续接里。
    /// 与 `play(queueIDs:)` 的内存路径给出同一张列表、同一套顺序规则(见 `planLibraryQueue`)。
    ///
    /// - Parameter willInstall: 确实要装队列时、装之前在主线程上调用(关随机、捐 Siri 交互)。
    ///   列表一首能放的都没有、请求被后来的取代时不调用,和原来「没有歌就什么也不动」一致。
    /// - Returns: false 表示目录不能用(还没迁完、读失败),调用方照旧走 `play(queueIDs:)`;
    ///   true 表示这次请求已经处理(放了、被取代、或者没有可放的歌)。
    @discardableResult
    func playLibraryFromCatalog(
        _ request: CatalogLibraryQueueRequest,
        caller: String = #fileID,
        callerLine: Int = #line,
        willInstall: () -> Void = {}
    ) async -> Bool {
        guard let library, let reader = PlaybackCatalogAccess.reader(for: library) else { return false }
        if !request.leadingIDs.isEmpty {
            let present: [String: Song]
            do {
                present = try await reader.songsByID(request.leadingIDs, visibility: .visible)
            } catch {
                return false
            }
            // 目录跟写内存有一小段滞后:前面那几首(点的那首、最近播放)内存里可见、目录里还没有时,
            // 整个请求走内存路径,免得点的歌被当成「不在曲库」挑掉、从别的歌开始放。
            if request.leadingIDs.contains(where: { present[$0] == nil && library.visibleSong(id: $0) != nil }) {
                plog("🎶 Catalog queue request: leading songs not in the catalog yet; using the in-memory library")
                return false
            }
            // 点的那首已经不在可见曲库里:什么也不做,也不打断别的还在准备的请求(同原来先查再排队)。
            if request.requiresFirstLeadingSong, let first = request.leadingIDs.first, present[first] == nil {
                plog("🎶 Catalog queue request: the requested song is not in the visible library")
                return true
            }
        }
        queueRequestToken &+= 1
        let token = queueRequestToken
        // 随机的整库请求也按抽歌偏好(#332)排,连着放的歌(#335)排在一起 —— 同 `play(queueIDs:)`。
        let isShuffled = !(request.order == .asGiven || request.order == .rotatedToStart)
        let weighting = isShuffled ? shuffleWeighting() : nil
        let linkGraph = isShuffled ? shuffleLinkGraph() : .empty
        let neighborIDs = linkGraph.isEmpty ? [] : Self.shuffleLinkNeighborIDs(in: library, graph: linkGraph)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let plan: CatalogLibraryQueuePlan
        do {
            plan = try await reader.planLibraryQueue(
                request, weighting: weighting, linkGraph: linkGraph, linkNeighborIDs: neighborIDs
            )
        } catch {
            // 等目录的这段时间里又来了新的请求:这一个作废,不再退回内存路径去盖掉它。
            guard queueRequestToken == token else { return true }
            plog("🎶 Catalog queue request failed (\(error)); using the in-memory library")
            return false
        }
        guard queueRequestToken == token else {
            plog("🎶 Catalog queue request superseded while preparing")
            return true
        }
        let prepareMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        switch plan {
        case .missingFirstLeadingSong:
            plog("🎶 Catalog queue request: the requested song is not in the visible library")
            return true
        case .empty(let requestedCount):
            plog("🎶 Catalog queue request of \(requestedCount) ids resolved to nothing")
            return true
        case .prepared(let prepared, let requestedCount):
            plog("🎶 Catalog queue request ids=\(requestedCount) order=\(request.order) installed=\(prepared.items.count) continuation=\(prepared.continuation?.requestedCount ?? 0) prepare=\(prepareMS)ms")
            willInstall()
            await play(prepared: prepared, caller: caller, callerLine: callerLine)
            return true
        }
    }

    /// 随机连播(#335)可能带进列表的歌:设了「接着放下一首」的歌的下一首、设了「先放上一首」的
    /// 歌的上一首。`ShuffleLinkPolicy.bringingLinkedSongs` 只会拿这些去问 `includes`。
    static func shuffleLinkNeighborIDs(in library: MusicLibrary, graph: ShuffleLinkGraph) -> [String] {
        var ids: [String] = []
        for songID in library.songIDs(forPlaylist: MusicLibrary.shuffleLinkNextPlaylistID) {
            if let next = graph.successor(of: songID) { ids.append(next) }
        }
        for songID in library.songIDs(forPlaylist: MusicLibrary.shuffleLinkPreviousPlaylistID) {
            if let previous = graph.predecessor(of: songID) { ids.append(previous) }
        }
        return ids
    }

    // MARK: - Continuation refill from the catalog

    /// 续接的下一批(`QueueWindowPolicy.refillBatch` 首)从目录按 id 取,主线程外;取到后与内存路径
    /// 一样接到队尾(`appendContinuation`)。返回 true 表示这一批交给目录了(或已经在取)。
    /// 目录读失败时退回内存路径。
    func refillQueueFromCatalog(_ continuation: QueueContinuation, library: MusicLibrary) -> Bool {
        guard let reader = PlaybackCatalogAccess.reader(for: library) else { return false }
        guard queueContinuationReadTask == nil else { return true }
        let repeatsAll = repeatMode == .all
        let token = continuation.token
        queueContinuationReadTask = Task { [weak self] in
            var remainder = continuation
            var additions: [Song] = []
            do {
                while additions.count < QueueWindowPolicy.refillBatch {
                    let ids = remainder.takeNext(
                        maxCount: QueueWindowPolicy.refillBatch - additions.count,
                        repeatsAll: repeatsAll
                    )
                    guard !ids.isEmpty else { break }
                    // 同内存路径:还在可见曲库里、能放的才接上,先后不变。
                    let found = try await reader.orderedSongs(ids: ids, visibility: .visible, playableOnly: true)
                    if found.count == ids.count {
                        additions.append(contentsOf: found)
                    } else {
                        // 目录跟写内存有一小段滞后:目录里没有的(刚加进来的歌)再问内存模型。
                        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        for id in ids {
                            if let song = byID[id] ?? library.visibleSong(id: id), song.isPlayable {
                                additions.append(song)
                            }
                        }
                    }
                }
            } catch {
                // 续接换过(`queueContinuation` 的 didSet 会取消这个任务)就不用再管。
                guard !Task.isCancelled, let self else { return }
                plog("🎶 Queue continuation catalog read failed (\(error)); reading the in-memory library")
                self.queueContinuationReadTask = nil
                self.refillQueueFromContinuationIfNeeded(allowsCatalog: false)
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.queueContinuation?.token == token else {
                self.queueContinuationReadTask = nil
                return
            }
            // `appendContinuation` 换掉 `queueContinuation`,它的 didSet 顺带清掉这个任务。
            self.appendContinuation(additions, remainder: remainder.isExhausted ? nil : remainder)
        }
        return true
    }

    // MARK: - Session restore lookups

    /// 恢复会话、恢复音乐队列时按 id 取能放的歌。目录可读时从目录取;nil 表示调用方照旧读内存模型。
    static func catalogPlayableSongs(
        ids: Set<String>,
        library: MusicLibrary,
        visibility: LibraryCatalogVisibility
    ) async -> [String: Song]? {
        guard let reader = PlaybackCatalogAccess.reader(for: library) else { return nil }
        guard !ids.isEmpty else { return [:] }
        do {
            let rows = try await reader.songsByID(ids, visibility: visibility, playableOnly: true)
            // 目录还没跟上内存(上次退出前刚加的歌还没写进目录)时,缺的那几首内存里能放就整批读内存,
            // 免得恢复出来的队列少歌、当前那首被当成不可用。
            let lagging = ids.contains { id in
                guard rows[id] == nil else { return false }
                let song = visibility.includesDisabledSources ? library.storedSong(id: id) : library.visibleSong(id: id)
                return song?.isPlayable == true
            }
            if lagging {
                plog("🎶 Playback restore: catalog is behind the library; using the in-memory library")
                return nil
            }
            return rows
        } catch {
            plog("🎶 Playback restore catalog read failed (\(error)); using the in-memory library")
            return nil
        }
    }
}
