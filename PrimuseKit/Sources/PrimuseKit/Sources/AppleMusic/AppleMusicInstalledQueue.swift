import Foundation

/// The semantic identity of a queue that MusicKit successfully prepared.
public struct AppleMusicInstalledQueue: Sendable {
    private let songIDs: [String]
    private let entryIDs: [UUID]
    private let nativeEntryIDs: [String]

    public init?(songIDs: [String], entryIDs: [UUID], nativeEntryIDs: [String]) {
        guard !entryIDs.isEmpty, songIDs.count == entryIDs.count,
              Set(entryIDs).count == entryIDs.count,
              !nativeEntryIDs.isEmpty, nativeEntryIDs.count <= entryIDs.count,
              Set(nativeEntryIDs).count == nativeEntryIDs.count else { return nil }
        self.songIDs = songIDs
        self.entryIDs = entryIDs
        self.nativeEntryIDs = nativeEntryIDs
    }

    /// Native entry IDs can change during MusicKit resolution without changing
    /// the successfully installed songs or their Primuse queue occurrences.
    public func matches(songIDs: [String], entryIDs: [UUID], nativeEntryIDs: [String]) -> Bool {
        nativeEntryIDs == self.nativeEntryIDs
            && self.entryIDs == entryIDs
            && self.songIDs == songIDs
    }
}

public struct AppleMusicQueueInstallationCache: Sendable {
    private var attemptID: UUID?
    private var installed: AppleMusicInstalledQueue?

    public init() {}

    @discardableResult
    public mutating func begin() -> UUID {
        let id = UUID()
        attemptID = id
        installed = nil
        return id
    }

    public mutating func complete(attemptID: UUID, songIDs: [String], entryIDs: [UUID], nativeEntryIDs: [String]) {
        guard self.attemptID == attemptID else { return }
        installed = AppleMusicInstalledQueue(songIDs: songIDs, entryIDs: entryIDs, nativeEntryIDs: nativeEntryIDs)
    }

    public mutating func reset() {
        attemptID = nil
        installed = nil
    }

    public func matches(songIDs: [String], entryIDs: [UUID], nativeEntryIDs: [String]) -> Bool {
        installed?.matches(songIDs: songIDs, entryIDs: entryIDs, nativeEntryIDs: nativeEntryIDs) == true
    }
}

/// Primuse 托管 Apple Music 队列时按下一首 / 上一首(#94): 要去的那条正好紧挨着当前这条时,
/// 让系统播放器 skipToNext/PreviousEntry, 不必把整段(常有几百首)队列重新交给 MusicKit。
/// Primuse 这边要装的那段和系统里已经装着的那段都得是这样 —— 随机顺序换过、队列改过、
/// 下一首是本地歌、停止点只留了当前这一条时, 照旧整段重装。
public enum AppleMusicManagedSkipPolicy {
    public enum Direction: String, Equatable, Sendable {
        case forward
        case backward
    }

    /// - Parameters:
    ///   - entryIDs: 队列里每一条对应的 Primuse 队列条目, 按播放顺序; 系统队列里认不出的那条为 nil。
    ///   - currentIndex: 当前这条在 `entryIDs` 里的位置。
    public static func canSkipNatively(
        entryIDs: [UUID?],
        currentIndex: Int?,
        currentEntryID: UUID,
        targetEntryID: UUID,
        direction: Direction
    ) -> Bool {
        guard currentEntryID != targetEntryID,
              let currentIndex,
              entryIDs.indices.contains(currentIndex),
              entryIDs[currentIndex] == currentEntryID else { return false }
        let neighbour = direction == .forward ? currentIndex + 1 : currentIndex - 1
        // 不绕回队首 / 队尾: 系统那段的循环与 Primuse 的循环不一定一致, 交给重装。
        guard entryIDs.indices.contains(neighbour) else { return false }
        return entryIDs[neighbour] == targetEntryID
    }
}
