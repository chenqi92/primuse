import Foundation
import PrimuseKit

// MARK: - 服务端镜像刷新那一轮在歌曲模型不在内存里时要问的几件事(DL3)

extension MusicLibrary {
    /// 一张专辑的可见歌曲,只从曲库目录答:同 `songs(forAlbum:)` 在模型放掉之后答的那一份(碟号、曲号、标题的先后,
    /// 至多 `LibraryScale.maxMaterializedRows` 首)。nil:目录这条路此刻答不了(模型在内存里、目录读不了或读失败)——
    /// 不像 `songs(forAlbum:)` 那样退回内存、把「答不了」答成空。
    func songsFromTheCatalog(forAlbum albumID: String) -> [Song]? {
        guard let lookup = rangeLookupOutsideTheModel else { return nil }
        return songsOutsideTheModel(forAlbum: albumID, lookup: lookup)
    }

    /// 一位艺人署名的可见歌曲(库内顺序;只当过专辑艺人的取名下各张专辑的歌),只从曲库目录答,同上。
    func songsFromTheCatalog(forArtist artistID: String) -> [Song]? {
        guard let lookup = rangeLookupOutsideTheModel else { return nil }
        return songsOutsideTheModel(forArtist: artistID, lookup: lookup)
    }

    /// `restoreLocallyAuthoredServerRatings(reviews)` 此刻会不会改动任何一条评价:同它的判断 —— 这条评分绑着服务端
    /// 条目,而曲库里那条评价(按服务端条目取胜者,没有就按评分对象)不存在或评分时钟比它旧。只读小状态(评价),
    /// 不读歌,模型在不在内存里都答得出。胜者的评分时钟就是各条里最大的那个(`LibraryReviewReconciliationPolicy`
    /// 按评分时钟取胜),所以这里只记每个条目的最大时钟。
    func restoresAnyLocallyAuthoredServerRating(_ reviews: [LibraryReview]) -> Bool {
        guard reviews.contains(where: { $0.serverRatingTarget != nil }) else { return false }
        var newestByTarget: [ServerSongRatingTarget: TimeInterval] = [:]
        for key in libraryReviewStorageKeysForSync {
            guard let stored = libraryReviewForSync(storageKey: key), let target = stored.serverRatingTarget else { continue }
            newestByTarget[target] = max(newestByTarget[target] ?? -.infinity, stored.ratingVersion)
        }
        for review in reviews {
            guard let target = review.serverRatingTarget else { continue }
            let current = newestByTarget[target]
                ?? libraryReviewForSync(storageKey: review.subject.storageKey)?.ratingVersion
            if current.map({ $0 < review.ratingVersion }) ?? true { return true }
        }
        return false
    }
}
