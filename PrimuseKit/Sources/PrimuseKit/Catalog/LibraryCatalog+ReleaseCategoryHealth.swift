import Foundation
import GRDB

/// 专辑发行类别(RC-a 的两列)记着「算齐了」时还靠不靠得住(RC-b)。v4 的写入方从不留下没写过的行:标题那一条
/// 至少是「专辑」(`AlbumReleaseCategoryRule.titleFlags` 不为空),各源统计行总带着「写过了」那一位
/// (`GroupingMaintenance.releaseFlagsWritten`)。降级后旧版打开 v4 的目录照常写,新插的专辑行、重写的统计行用的是
/// 列的默认值 0 —— 这样的行在就说明「算齐了」已经不对了,退回补算。
extension GroupingMaintenance {
    /// 各源统计行 `releaseFlags` 里「这一行的发行类别写过了」的那一位。类别本身只占低三位,读的时候按位取。
    static let releaseFlagsWritten = 8
}

extension LibraryCatalog {
    /// 同 `releaseCategoriesAreComplete()`。`checkingRows`(镜像本次进程第一次看的时候)为真时先查一遍有没有发行类别
    /// 从没写过的专辑行或统计行(降级后旧版写的):记着「算齐了」又有这样的行,就把状态退回「待补算」(从头补,
    /// 补的时候把这些行一并补上),返回 false。查的是两个 `EXISTS`(没有这样的行时把 `album`、`albumSourceStat`
    /// 各扫一遍,50 万首约 4 万张专辑),只在状态是「算齐了」时查。
    public func releaseCategoriesAreComplete(checkingRows: Bool) throws -> Bool {
        guard checkingRows else { return try releaseCategoriesAreComplete() }
        let unwritten = try pool.read { db -> Bool in
            guard try Self.releaseCategoriesComplete(in: db) else { return false }
            return try Self.hasUnwrittenReleaseCategoryRows(in: db)
        }
        guard unwritten else { return try releaseCategoriesAreComplete() }
        return try pool.write { db in
            guard try Self.releaseCategoriesComplete(in: db) else { return false }
            guard try Self.hasUnwrittenReleaseCategoryRows(in: db) else { return true }
            try Self.setMeta(MetaKey.releaseCategories, ReleaseCategoryState.backfill(after: 0).metaValue, in: db)
            return false
        }
    }

    static func hasUnwrittenReleaseCategoryRows(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM album WHERE releaseTitleFlags = 0)
                OR EXISTS (SELECT 1 FROM albumSourceStat WHERE (releaseFlags & \(GroupingMaintenance.releaseFlagsWritten)) = 0)
            """) ?? false
    }

    /// 目录此刻的修订号(每次提交加一):按它记住整库查询的结果,修订号没变就不重算。
    public func currentRevision() throws -> Int64 {
        try reader.read { db in try Self.revision(in: db) }
    }

    #if DEBUG
    /// 测试:像降级后旧版写过一样 —— 键最小的 `count` 张专辑的标题那一条清零(旧版新插的专辑行),接下来的 `count` 张
    /// 的各源统计行整行回到默认值(旧版重写的统计行,标签认出的类别也没了)。「算齐了」的记号不动。
    public func simulateRowsWrittenByAnOlderBuildForTesting(count: Int) throws {
        try pool.write { db in
            let keys = try Int64.fetchAll(db, sql: "SELECT key FROM album ORDER BY key LIMIT ?", arguments: [count * 2])
            for (offset, key) in keys.enumerated() {
                if offset < count {
                    try db.execute(sql: "UPDATE album SET releaseTitleFlags = 0 WHERE key = ?", arguments: [key])
                } else {
                    try db.execute(sql: "UPDATE albumSourceStat SET releaseFlags = 0 WHERE albumKey = ?", arguments: [key])
                }
            }
        }
    }
    #endif
}
