import Foundation
import PrimuseKit

/// 播放记录里按原 ID 在本机找不到的歌(别的设备上播的、源重建过的),认回本机的副本。
/// 排期与结果在 `PlayHistoryStore` 本体里(`scheduleMissingSongResolution`),这里是依据与真正去认的那一步。
extension PlayHistoryStore {
    /// 补认的依据。目录读得了时是目录的成员修订号与「全部失效」修订号,读不了时是内存里可见歌曲的成员修订号;
    /// 再加上停用的源。依据没变,认过的历史 ID 不再认;变了(歌增删、导入、换配置、停用源)整份重认。
    /// 只改了标签不算:补全、刮削期间每写一批都会动目录,按它重认就是每一批都把整库歌名扫一遍。
    struct SongResolutionBasis: Equatable {
        let libraryID: ObjectIdentifier
        let catalogMembership: UInt64?
        let catalogEverything: UInt64?
        let modelCollection: Int?
        let disabledSourceIDs: Set<String>
    }

    struct SongResolutionWork: Equatable {
        let basis: SongResolutionBasis
        /// 这一轮要认的历史歌曲 ID,上界为 maxRetainedEntries (5000)。
        let historyIDs: Set<String>
        let isFull: Bool
    }

    static func songResolutionBasis(for library: MusicLibrary) -> SongResolutionBasis? {
        guard library.isUsable else { return nil }
        if P2cCatalogAccess.reader(for: library) != nil, let revisions = library.catalogHost?.revisions {
            return SongResolutionBasis(
                libraryID: ObjectIdentifier(library), catalogMembership: revisions.membership,
                catalogEverything: revisions.everything, modelCollection: nil,
                disabledSourceIDs: library.disabledSourceIDs
            )
        }
        // 目录读不了时只能按内存里的歌曲模型认,它不在内存里就答不了。
        guard library.isReady else { return nil }
        return SongResolutionBasis(
            libraryID: ObjectIdentifier(library), catalogMembership: nil, catalogEverything: nil,
            modelCollection: library.visibleSongCollectionRevision, disabledSourceIDs: library.disabledSourceIDs
        )
    }

    /// 离主线程解析一批记录里找不到原 ID 的曲目，结果只含缺失 ID 的本机可见候选。
    /// 目录读得了就问目录(歌曲模型放掉时也一样,只按 id 取与流式扫两列);读不了时只有歌曲模型在内存里才按内存找。
    /// 两边都答不了时是 nil,不是「没有」。
    static func resolveMissingSongIDs(
        for entries: [Entry],
        in library: MusicLibrary
    ) async -> [String: [String]]? {
        guard library.isUsable else { return nil }
        let disabledSourceIDs = library.disabledSourceIDs
        if let reader = P2cCatalogAccess.reader(for: library) {
            do {
                return try await reader.resolveMissingHistorySongIDs(
                    events: entries.map(\.listeningEvent), disabledSourceIDs: disabledSourceIDs
                )
            } catch is CancellationError {
                return nil
            } catch {
                plog("PlayHistoryStore: catalog candidate lookup failed: \(error.localizedDescription)")
            }
        }
        // 放掉时内存里那张表是空的,对着它认出来的「没有」不算数。
        guard library.isReady else { return nil }
        var missingIDs = Set<String>()
        for id in Set(entries.map(\.songID)) where library.unobservedVisibleSong(id: id) == nil {
            missingIDs.insert(id)
        }
        guard !missingIDs.isEmpty else { return [:] }
        let missingEvents = entries.filter { missingIDs.contains($0.songID) }.map(\.listeningEvent)
        let requirements = ListeningSongIdentity.candidateFilterRequirements(for: missingEvents)
        guard !requirements.isEmpty else { return [:] }
        guard let lookup = loadedSongLookup(for: library) else { return nil }
        let worker = Task.detached(priority: .utility) { () -> [String: [String]]? in
            let filtered = requirements.filteringDisabledSources(disabledSourceIDs)
            var candidates: [Song] = []
            lookup.forEachSong { song in
                guard !Task.isCancelled, !disabledSourceIDs.contains(song.sourceID), filtered.matches(song) else { return }
                candidates.append(song)
            }
            return Task.isCancelled ? nil : ListeningSongIdentity.libraryCandidates(events: missingEvents, songs: candidates)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
