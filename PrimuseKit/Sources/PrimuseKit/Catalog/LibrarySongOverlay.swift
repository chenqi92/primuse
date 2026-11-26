import Foundation

/// 目录成为曲库的权威之后,改动先记在这里、再交给目录写入队列。目录还没提交这一批之前,
/// 按 id 读先看这里(`lookup`),看不到的才读目录。列表查询不看这里:它们在目录提交后的修订号
/// 变化时才看到改动,同 P2 的读法。
///
/// 一批改动的先后同 `LibraryCatalog.apply`:先改名,再删,最后写入;同一批里后面的盖过前面的。
/// 每批有递增的序号;目录提交到第 n 批时(`acknowledge(through:)`)丢掉最后一次写在 n 批及以前的条目,
/// 之后的批写过的照留。条目数以还在路上的批为界。
public struct LibrarySongOverlay: Sendable {
    public enum Lookup: Equatable, Sendable {
        /// 这里没有,读目录。
        case unknown
        /// 这一首此刻的样子(目录可能还是旧的)。
        case present(Song)
        /// 已删除(或改名改走了);目录里可能还在。
        case deleted
        /// 由 `oldID` 改名而来、这一批没给新内容:读目录里 `oldID` 那一行(目录提交前还叫旧名)。
        case renamed(from: String)
    }

    private enum State: Sendable {
        case present(Song)
        case deleted
        case renamed(from: String)
    }

    private struct Entry: Sendable {
        var state: State
        var sequence: UInt64
    }

    private var entries: [String: Entry] = [:]
    public private(set) var lastSequence: UInt64 = 0
    public private(set) var acknowledgedSequence: UInt64 = 0

    public init() {}

    /// 还没被目录确认的条目数。
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// 记下一批改动,返回它的序号(交给目录写入队列,提交后据此 `acknowledge`)。
    ///
    /// - Parameter catalogContains: 目录里此刻有没有这个 id。只对这里没有条目的 id 问:路上的批
    ///   都没碰过它,目录轮到这一批时它还是现在的样子。改名要靠它判断目录会不会跳过(同 `apply`:
    ///   新 id 已有一首、旧 id 没有这一首时不改)。
    @discardableResult
    public mutating func record(
        upserts: [Song],
        deletingIDs: some Collection<String> = [String](),
        renaming: [String: String] = [:],
        catalogContains: (String) -> Bool = { _ in false }
    ) -> UInt64 {
        lastSequence &+= 1
        let sequence = lastSequence
        func exists(_ id: String) -> Bool {
            switch state(of: id) {
            case .present?, .renamed?: return true
            case .deleted?: return false
            case nil: return catalogContains(id)
            }
        }
        // 同 `LibraryCatalog.apply`:改名按旧 id 排序逐个做,新 id 已有一首、旧 id 没有这一首时不改。
        for (oldID, newID) in renaming.sorted(by: { $0.key < $1.key }) where oldID != newID {
            guard !exists(newID), exists(oldID) else { continue }
            let source: State
            switch state(of: oldID) {
            case .present(let song)?: source = .present(song.withID(newID))
            case .renamed(let from)?: source = .renamed(from: from)
            case .deleted?, nil: source = .renamed(from: oldID)
            }
            entries[oldID] = Entry(state: .deleted, sequence: sequence)
            entries[newID] = Entry(state: source, sequence: sequence)
        }
        for id in deletingIDs {
            entries[id] = Entry(state: .deleted, sequence: sequence)
        }
        for song in upserts {
            entries[song.id] = Entry(state: .present(song), sequence: sequence)
        }
        return sequence
    }

    public func lookup(_ id: String) -> Lookup {
        switch state(of: id) {
        case nil: return .unknown
        case .present(let song)?: return .present(song)
        case .deleted?: return .deleted
        case .renamed(let from)?: return .renamed(from: from)
        }
    }

    /// 目录已提交到第 `sequence` 批(含):最后一次写在这一批及以前的条目不再需要。
    public mutating func acknowledge(through sequence: UInt64) {
        guard sequence > acknowledgedSequence else { return }
        acknowledgedSequence = min(sequence, lastSequence)
        let acknowledged = acknowledgedSequence
        entries = entries.filter { $0.value.sequence > acknowledged }
    }

    /// 目录换了一份(重新导入、出错重建):路上的批都作废,按目录读。
    public mutating func removeAll() {
        entries.removeAll()
        acknowledgedSequence = lastSequence
    }

    private func state(of id: String) -> State? {
        entries[id]?.state
    }
}

private extension Song {
    /// 同一首歌换个 id(改名时目录保留整行,只换 id)。
    func withID(_ id: String) -> Song {
        guard id != self.id else { return self }
        var copy = self
        copy.id = id
        return copy
    }
}
