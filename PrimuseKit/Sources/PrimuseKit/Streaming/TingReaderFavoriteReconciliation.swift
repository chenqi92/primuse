import Foundation

/// Ting Reader 的「收藏」(按书)和书架收藏的双向对账。
///
/// 书架收藏只存「收了哪些书」,没有时间戳,所以按上一次对账后两边一致的那份(基线)做三方合并:
/// 服务端比基线多了就在本机收藏,少了就在本机取消;本机比基线多了就推到服务端,少了就在服务端取消。
/// 第一次对账没有基线,两边取并集。
///
/// 以本机的书为单位判断:服务端几本书可能被本机分到同一本里,一本一本看会互相打架
/// (一本被服务端取消、另一本还收藏着,下一轮就会把还收藏着的那本也取消掉)。
/// 基线里记着当时对应的本机书 id:书改了标签被重新分组、换了 id,收藏挂在旧 id 上,
/// 这不是用户取消,按服务端的状态把新 id 收藏上。
public enum TingReaderFavoriteReconciliation {
    public struct Baseline: Codable, Equatable, Sendable {
        /// 服务端书 id → 当时对应的本机书 id;本机还没有这本书时是空串。
        public var books: [String: String]

        public init(books: [String: String] = [:]) {
            self.books = books
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 本机要收藏 / 取消收藏的书(本机书 id)。
        public var collectLocally: [String] = []
        public var uncollectLocally: [String] = []
        /// 要在服务端收藏 / 取消收藏的书(服务端书 id)。
        public var favoriteOnServer: [String] = []
        public var unfavoriteOnServer: [String] = []
        /// 服务端操作全部成功时的新基线;有失败的用 `baseline(_:failedFavorites:failedUnfavorites:localBooks:)` 修正。
        public var baseline = Baseline()
    }

    /// - Parameters:
    ///   - serverFavorites: 服务端收藏着的书。
    ///   - localBooks: 这个源在本机曲库里的书:服务端书 id → 本机书 id。本机没有的书不在里面,对账不动它们。
    ///   - collectedLocalBookIDs: 书架上收藏着的书(本机书 id)。
    ///   - baseline: 上一次对账后的基线;第一次是 nil。
    public static func plan(
        serverFavorites: Set<String>,
        localBooks: [String: String],
        collectedLocalBookIDs: Set<String>,
        baseline: Baseline?
    ) -> Plan {
        var plan = Plan()
        var serverBooksByLocal: [String: [String]] = [:]
        for (serverID, localID) in localBooks where !localID.isEmpty {
            serverBooksByLocal[localID, default: []].append(serverID)
        }

        for localID in serverBooksByLocal.keys.sorted() {
            let serverIDs = serverBooksByLocal[localID, default: []].sorted()
            let favorited = serverIDs.filter { serverFavorites.contains($0) }
            let isServerFavorite = !favorited.isEmpty
            let isLocalFavorite = collectedLocalBookIDs.contains(localID)
            // 上一轮就是在这本本机的书上对齐的。
            let wasAgreedHere = serverIDs.contains { baseline?.books[$0] == localID }

            // 对账之后两边都收藏着的服务端书。
            let agreed: [String]
            switch (wasAgreedHere, isServerFavorite, isLocalFavorite) {
            case (_, true, true):
                agreed = favorited
            case (_, false, false):
                agreed = []
            case (true, false, true):
                // 别的客户端取消了。
                plan.uncollectLocally.append(localID)
                agreed = []
            case (true, true, false):
                // 本机取消了。
                plan.unfavoriteOnServer.append(contentsOf: favorited)
                agreed = []
            case (false, true, false):
                // 别的客户端收藏的,或者本机这本书换了 id。
                plan.collectLocally.append(localID)
                agreed = favorited
            case (false, false, true):
                // 本机收藏的。
                plan.favoriteOnServer.append(contentsOf: serverIDs)
                agreed = serverIDs
            }
            for serverID in agreed { plan.baseline.books[serverID] = localID }
        }

        // 本机没有的书:不动它,只记着服务端收藏过,等它出现在本机时按「服务端收藏的」收进来。
        for serverID in serverFavorites where localBooks[serverID] == nil {
            plan.baseline.books[serverID] = baseline?.books[serverID] ?? ""
        }
        return plan
    }

    /// 服务端操作有失败时的基线:收藏没推上去的当作从没对齐过,下一轮还推;
    /// 取消没推上去的照旧留在基线里,下一轮还取消。
    public static func baseline(
        _ planned: Baseline,
        failedFavorites: Set<String>,
        failedUnfavorites: Set<String>,
        localBooks: [String: String]
    ) -> Baseline {
        var result = planned
        for serverID in failedFavorites { result.books.removeValue(forKey: serverID) }
        for serverID in failedUnfavorites {
            result.books[serverID] = localBooks[serverID] ?? ""
        }
        return result
    }
}
