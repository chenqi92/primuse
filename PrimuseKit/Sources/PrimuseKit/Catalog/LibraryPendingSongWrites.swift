import Foundation

/// 目录跟着旧库写:内存模型的每批改动先提交进 `library-songs.sqlite`,目录再按旧库修订号跟上。
/// 这里登记还没跟到目录里的改动,按 id 读「这里 → 目录」(`resolve`)与内存模型此刻相同:
/// - 内存模型改动的同时 `record`,拿到这一批的序号;
/// - 旧库提交了那一批后 `bind`:这一批与之前所有批都在这个修订号里;
/// - 目录镜像到某个旧库修订号后 `catalogMirrored`,丢掉修订号不超过它的那些批。
///
/// 绑定与镜像谁先到都行(对账直接读旧库,可能先于绑定看到那个修订号)。
/// 整份替换旧库(恢复写入、外部快照)不逐首登记,用 `bindReplacement`:目录镜像到那里之前
/// `answersLikeMemory` 为 false。目录不再跟写(停下、出错)后 `suspend`:清空,不再登记也不再作答。
/// 各个线程都可以调用。
public final class LibraryPendingSongWrites: @unchecked Sendable {
    private struct Mark {
        /// 这一批及之前的所有批。
        var sequence: UInt64
        var storeRevision: Int64
    }

    private struct State {
        var overlay = LibrarySongOverlay()
        var marks: [Mark] = []
        var mirroredRevision: Int64?
        /// 还没镜像到的整份替换(最大的那个修订号)。
        var replacementRevision: Int64?
        var suspended = false
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    /// 记下内存模型刚做的一批改动(同一时刻、按改动的先后调用),返回序号;已停止跟写时为 nil。
    ///
    /// - Parameter catalogContains: 目录里此刻有没有这个 id,只对改名涉及的 id 问,在锁外问。
    @discardableResult
    public func record(
        upserts: [Song],
        deletingIDs: some Collection<String> = [String](),
        renaming: [String: String] = [:],
        catalogContains: (String) -> Bool = { _ in false }
    ) -> UInt64? {
        let present: Set<String> = renaming.isEmpty ? [] : Set(
            renaming.flatMap { [$0.key, $0.value] }.filter(catalogContains)
        )
        return lock.withLock {
            guard !state.suspended else { return nil }
            return state.overlay.record(
                upserts: upserts, deletingIDs: deletingIDs, renaming: renaming
            ) { present.contains($0) }
        }
    }

    /// 序号不超过 `sequence` 的批都已提交进旧库,在修订号 `storeRevision` 里。
    public func bind(throughSequence sequence: UInt64, storeRevision: Int64) {
        lock.withLock {
            guard !state.suspended else { return }
            if let mirrored = state.mirroredRevision, storeRevision <= mirrored {
                state.overlay.acknowledge(through: sequence)
            } else {
                state.marks.append(Mark(sequence: sequence, storeRevision: storeRevision))
            }
        }
    }

    /// 旧库被整份替换成内存模型的样子(序号不超过 `sequence` 的批都在里面)。目录镜像到
    /// `storeRevision` 之前,目录与这里答不出内存模型的样子。
    public func bindReplacement(throughSequence sequence: UInt64, storeRevision: Int64) {
        lock.withLock {
            guard !state.suspended else { return }
            if let mirrored = state.mirroredRevision, storeRevision <= mirrored {
                state.overlay.acknowledge(through: sequence)
                return
            }
            state.replacementRevision = max(state.replacementRevision ?? storeRevision, storeRevision)
            state.marks.append(Mark(sequence: sequence, storeRevision: storeRevision))
        }
    }

    /// 目录已经是旧库修订号 `storeRevision` 的样子。
    public func catalogMirrored(storeRevision: Int64) {
        lock.withLock {
            guard !state.suspended else { return }
            let mirrored = max(state.mirroredRevision ?? storeRevision, storeRevision)
            state.mirroredRevision = mirrored
            var acknowledged: UInt64?
            state.marks.removeAll { mark in
                guard mark.storeRevision <= mirrored else { return false }
                acknowledged = max(acknowledged ?? mark.sequence, mark.sequence)
                return true
            }
            if let acknowledged { state.overlay.acknowledge(through: acknowledged) }
            if let replacement = state.replacementRevision, replacement <= mirrored {
                state.replacementRevision = nil
            }
        }
    }

    /// 目录不再跟写:清空,之后不登记、不作答。
    public func suspend() {
        lock.withLock {
            state = State()
            state.suspended = true
        }
    }

    /// 目录(加上这里)此刻能不能答出内存模型的样子:没有等着镜像的整份替换、还在跟写。
    public var answersLikeMemory: Bool {
        lock.withLock { !state.suspended && state.replacementRevision == nil }
    }

    /// 最近登记的那一批的序号(整份替换时用它绑定)。
    public var lastSequence: UInt64 {
        lock.withLock { state.overlay.lastSequence }
    }

    /// 还没被目录确认的歌的条数。
    public var pendingCount: Int {
        lock.withLock { state.overlay.count }
    }

    public func lookup(_ id: String) -> LibrarySongOverlay.Lookup {
        lock.withLock { state.overlay.lookup(id) }
    }

    /// 这一首此刻的样子:这里有就用这里的,没有就读目录。由改名而来的那一首,目录还没改名时读旧 id
    /// 那一行换上新 id,已经改了就读新 id。
    public func resolve(_ id: String, catalogSong: (String) throws -> Song?) rethrows -> Song? {
        switch lookup(id) {
        case .unknown:
            return try catalogSong(id)
        case .present(let song):
            return song
        case .deleted:
            return nil
        case .renamed(let oldID):
            guard var moved = try catalogSong(oldID) else { return try catalogSong(id) }
            moved.id = id
            return moved
        }
    }
}
