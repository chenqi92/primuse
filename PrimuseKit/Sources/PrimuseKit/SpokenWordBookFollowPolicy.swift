import Foundation

/// 同一本书在别的设备上听到了另一条(服务端记进度的源同步回来的)时,播放器里停着的这一条
/// 要不要让位、换到哪一条。
///
/// 只比「最后一次动它」的时间:比本机最后一次动当前这一条更晚的那些里取最新的一条,
/// 它是听完的就接它的下一条。别处先听的、本机后来又选回来的,本机那次更晚,不换。
public enum SpokenWordBookFollowPolicy {
    public struct Record: Equatable, Sendable {
        public let itemID: String
        /// 最后一次动这一条时是把它听完了(而不是停在中间)。
        public let isFinished: Bool
        public let updatedAt: Date

        public init(itemID: String, isFinished: Bool, updatedAt: Date) {
            self.itemID = itemID
            self.isFinished = isFinished
            self.updatedAt = updatedAt
        }

        /// 一条的位置与听完时间里较晚的那个;都没有就是 nil。重听一条听完的,位置更晚,算停在中间。
        public init?(itemID: String, positionUpdatedAt: Date?, finishedAt: Date?) {
            switch (positionUpdatedAt, finishedAt) {
            case let (position?, finished?):
                self.init(itemID: itemID, isFinished: finished > position, updatedAt: max(position, finished))
            case let (position?, nil):
                self.init(itemID: itemID, isFinished: false, updatedAt: position)
            case let (nil, finished?):
                self.init(itemID: itemID, isFinished: true, updatedAt: finished)
            case (nil, nil):
                return nil
            }
        }
    }

    /// - Parameters:
    ///   - itemIDs: 这本书的条目,阅读顺序。
    ///   - currentItemID: 播放器里装着的那一条。
    ///   - anchor: 本机最后一次动当前这一条的时间(选中它、在它上面存位置);nil 表示不知道,任何记录都算更新。
    ///   - records: 这本书各条最后一次的改动,本机的和服务端带回来的都在里面。
    /// - Returns: 该换去的条目;nil 表示接着当前这一条。
    public static func target(
        itemIDs: [String],
        currentItemID: String,
        anchor: Date?,
        records: [Record]
    ) -> String? {
        var order: [String: Int] = [:]
        for (index, id) in itemIDs.enumerated() where order[id] == nil { order[id] = index }
        guard order[currentItemID] != nil else { return nil }
        var newest: (record: Record, index: Int)?
        for record in records {
            guard let index = order[record.itemID] else { continue }
            if let anchor, record.updatedAt <= anchor { continue }
            if let best = newest {
                // 同一时刻(Audiobookshelf 整本书一个时间戳)取书里靠后的那条。
                if record.updatedAt < best.record.updatedAt { continue }
                if record.updatedAt == best.record.updatedAt, index < best.index { continue }
            }
            newest = (record, index)
        }
        guard let newest else { return nil }
        let targetIndex = newest.record.isFinished ? newest.index + 1 : newest.index
        guard itemIDs.indices.contains(targetIndex) else { return nil }
        let targetID = itemIDs[targetIndex]
        return targetID == currentItemID ? nil : targetID
    }
}
