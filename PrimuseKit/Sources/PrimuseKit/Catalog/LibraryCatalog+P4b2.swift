import Foundation
import GRDB

/// 目录变更流水(`catalogChange`)上的一个位置。别的索引(搜索库)记下自己跟到了哪儿,被杀后只补
/// 这之后改过的歌,不再整库对账。
///
/// `epoch` 标出这条流水属于哪一次导入:目录文件的建立时间、导入时旧库的内容修订号与导入条数。
/// 重新导入(`clearSongs` 清空流水、导入的行不记流水)或换了一份目录文件,`epoch` 就变,旧位置作废。
public struct LibraryCatalogChangeCursor: Codable, Sendable, Equatable {
    public let epoch: String
    public let seq: Int64

    public init(epoch: String, seq: Int64) {
        self.epoch = epoch
        self.seq = seq
    }
}

/// 一段变更:这段里改过的歌曲 id(去重,按第一次出现的先后)与读到的末尾位置。
public struct LibraryCatalogChangeBatch: Sendable, Equatable {
    // crash-pattern: allow song-id-collection-property 至多调用方给的 limit 条(搜索库补流水时 2 万)
    public let songIDs: [String]
    public let cursor: LibraryCatalogChangeCursor
    /// 还有更多(超出 `limit`),调用方应改走整库对账或接着读。
    public let isTruncated: Bool
}

extension LibraryCatalog {
    /// 现在的流水末尾。导入还没做完时为 nil(这时的目录不能当对账的依据)。
    public func changeCursor() throws -> LibraryCatalogChangeCursor? {
        let fileStamp = fileStamp()
        return try pool.read { db in
            guard let epoch = try Self.changeEpoch(fileStamp: fileStamp, in: db) else { return nil }
            let seq = try Int64.fetchOne(db, sql: "SELECT max(seq) FROM catalogChange") ?? 0
            return LibraryCatalogChangeCursor(epoch: epoch, seq: seq)
        }
    }

    /// `cursor` 之后改过的歌曲 id,至多 `limit` 个。`cursor` 不属于眼前这次导入(重新导入过、
    /// 换过目录文件)或流水往回够不到它时返回 nil。增、改、删都在里面:调用方按 id 现查,
    /// 查不到的就是删了。改名只记新 id(行号不变),旧 id 要调用方另行清理。
    public func changedSongIDs(since cursor: LibraryCatalogChangeCursor, limit: Int) throws -> LibraryCatalogChangeBatch? {
        let fileStamp = fileStamp()
        return try pool.read { db in
            guard let epoch = try Self.changeEpoch(fileStamp: fileStamp, in: db), epoch == cursor.epoch else { return nil }
            let maxSeq = try Int64.fetchOne(db, sql: "SELECT max(seq) FROM catalogChange") ?? 0
            // 流水只会在重新导入时清空(那时 epoch 已变);末尾比记下的还小,说明不是同一条流水。
            guard maxSeq >= cursor.seq else { return nil }
            // 流水只留最近 `changeFeedLimit` 条:记下的位置之后有一段已经剪掉了,接不上,调用方改走整库对账。
            if let minSeq = try Int64.fetchOne(db, sql: "SELECT min(seq) FROM catalogChange"), minSeq > cursor.seq + 1 {
                return nil
            }
            var ids: [String] = []
            var seen = Set<String>()
            var last = cursor.seq
            var truncated = false
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT seq, songID FROM catalogChange WHERE seq > ? ORDER BY seq",
                arguments: [cursor.seq]
            )
            while let row = try rows.next() {
                let songID: String = row[1]
                if !seen.contains(songID) {
                    guard ids.count < limit else {
                        truncated = true
                        break
                    }
                    seen.insert(songID)
                    ids.append(songID)
                }
                last = row[0]
            }
            return LibraryCatalogChangeBatch(
                songIDs: ids,
                cursor: LibraryCatalogChangeCursor(epoch: epoch, seq: last),
                isTruncated: truncated
            )
        }
    }

    /// 流水最多留这么多条。搜索库补流水超过 2 万首就改走整库对账,留得再多也用不上;
    /// 不剪的话每次全量重扫都给每首改了的歌记一条,只增不减。
    static let changeFeedLimit: Int64 = 50_000

    /// 每次写入之后剪掉最旧的那部分(按主键范围删,没有要剪的时候几乎不花时间)。
    static func trimChangeFeed(in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM catalogChange WHERE seq <= (SELECT max(seq) FROM catalogChange) - ?",
            arguments: [changeFeedLimit]
        )
    }

    /// 目录文件本身:文件号与建立时间。文件删了重建,这两个就变。
    private func fileStamp() -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(number)@\(created.bitPattern)"
    }

    private static func changeEpoch(fileStamp: String, in db: Database) throws -> String? {
        guard try metaValue(MetaKey.importState, in: db) == "complete" else { return nil }
        let revision = try metaValue(MetaKey.importStoreRevision, in: db) ?? ""
        let count = try metaValue(MetaKey.importedCount, in: db) ?? ""
        return "\(fileStamp)|\(revision)|\(count)"
    }
}
