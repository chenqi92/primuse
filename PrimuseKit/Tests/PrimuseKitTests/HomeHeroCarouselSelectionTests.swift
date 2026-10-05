import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home Hero Carousel Selection")
struct HomeHeroCarouselSelectionTests {
    private typealias Candidate = HomeHeroCarouselSelection.Candidate

    private func candidates(_ prefix: String, albums: Int, songsPerAlbum: Int = 1) -> [Candidate] {
        (0..<albums).flatMap { album in
            (0..<songsPerAlbum).map { song in
                Candidate(songID: "\(prefix)-a\(album)-s\(song)", albumKey: "\(prefix)-album-\(album)")
            }
        }
    }

    private func pool(
        _ songs: [(id: String, album: String, track: Int?)],
        played: Set<String> = [],
        dayStamp: Int = 20261004,
        limit: Int = 32
    ) -> [Candidate] {
        var pool = HomeHeroCarouselSelection.RediscoveryPool(
            dayStamp: dayStamp,
            playedAlbumKeys: played,
            limit: limit
        )
        for song in songs {
            pool.consider(songID: song.id, albumKey: song.album, trackNumber: song.track)
        }
        return pool.candidates()
    }

    @Test("三组各占名额,一张专辑只出一张卡,总数 8")
    func quotasAndAlbumDedup() {
        let recent = candidates("r", albums: 10, songsPerAlbum: 3)
        let added = candidates("n", albums: 10, songsPerAlbum: 3)
        let rediscovery = candidates("o", albums: 10)
        let picked = HomeHeroCarouselSelection.pick(
            recent: recent, added: added, rediscovery: rediscovery, dayStamp: 20261004,
            count: HomeHeroCarouselSelection.featuredCount
        )
        #expect(picked.count == HomeHeroCarouselSelection.featuredCount)
        #expect(picked.filter { $0.hasPrefix("r-") }.count == 3)
        #expect(picked.filter { $0.hasPrefix("o-") }.count == 3)
        #expect(picked.filter { $0.hasPrefix("n-") }.count == 2)
        let albums = picked.map { $0.split(separator: "-").prefix(2).joined(separator: "-") }
        #expect(Set(albums).count == picked.count)
    }

    @Test("一圈摆满:正中 8 张仍按配额,往外三组轮流接着摆,专辑不重复")
    func fullLapKeepsFeaturedCenter() {
        let picked = HomeHeroCarouselSelection.pick(
            recent: candidates("r", albums: 30),
            added: candidates("n", albums: 30),
            rediscovery: candidates("o", albums: 30),
            dayStamp: 20261004
        )
        #expect(picked.count == HomeHeroCarouselSelection.cardCount)
        #expect(Set(picked).count == picked.count)
        // 前 8 张从正中往两边摆,落在 [正中 - 3, 正中 + 4]。
        let center = HomeHeroCarouselSelection.initialIndex(count: picked.count)
        let featured = picked[(center - 3)...(center + 4)]
        #expect(featured.filter { $0.hasPrefix("r-") }.count == 3)
        #expect(featured.filter { $0.hasPrefix("o-") }.count == 3)
        #expect(featured.filter { $0.hasPrefix("n-") }.count == 2)
        for prefix in ["r-", "o-", "n-"] {
            #expect(picked.filter { $0.hasPrefix(prefix) }.count >= 15)
        }
    }

    @Test("一圈里某一组用完时其余组接着轮,候选不够就有多少摆多少")
    func fullLapWithUnevenGroups() {
        let picked = HomeHeroCarouselSelection.pick(
            recent: candidates("r", albums: 2),
            added: [],
            rediscovery: candidates("o", albums: 100),
            dayStamp: 20261004
        )
        #expect(picked.count == HomeHeroCarouselSelection.cardCount)
        #expect(picked.filter { $0.hasPrefix("r-") }.count == 2)

        let few = HomeHeroCarouselSelection.pick(
            recent: candidates("r", albums: 4),
            added: candidates("n", albums: 4),
            rediscovery: candidates("o", albums: 4),
            dayStamp: 20261004
        )
        #expect(few.count == 12)
        #expect(Set(few).count == 12)
    }

    @Test("同一张专辑出现在两组里只算一次")
    func crossGroupDedup() {
        let shared = Candidate(songID: "recent-song", albumKey: "same-album")
        let again = Candidate(songID: "added-song", albumKey: "same-album")
        let picked = HomeHeroCarouselSelection.pick(
            recent: [shared], added: [again], rediscovery: [], dayStamp: 1
        )
        #expect(picked == ["recent-song"])
    }

    @Test("某一组不够时由其余组补满")
    func shortGroupsAreFilled() {
        let picked = HomeHeroCarouselSelection.pick(
            recent: [],
            added: candidates("n", albums: 3),
            rediscovery: candidates("o", albums: 20),
            dayStamp: 20261004,
            count: HomeHeroCarouselSelection.featuredCount
        )
        #expect(picked.count == 8)
        #expect(picked.filter { $0.hasPrefix("n-") }.count == 2)
        #expect(picked.filter { $0.hasPrefix("o-") }.count == 6)
    }

    @Test("同一天反复计算不变,候选顺序不影响结果,隔天换一组")
    func dailyStable() {
        let recent = candidates("r", albums: 12)
        let added = candidates("n", albums: 12)
        let rediscovery = candidates("o", albums: 12)
        let today = HomeHeroCarouselSelection.pick(
            recent: recent, added: added, rediscovery: rediscovery, dayStamp: 20261004
        )
        for _ in 0..<10 {
            #expect(HomeHeroCarouselSelection.pick(
                recent: recent, added: added, rediscovery: rediscovery, dayStamp: 20261004
            ) == today)
        }
        #expect(HomeHeroCarouselSelection.pick(
            recent: recent.reversed(), added: added.reversed(), rediscovery: rediscovery,
            dayStamp: 20261004
        ) == today)
        #expect(HomeHeroCarouselSelection.pick(
            recent: recent, added: added, rediscovery: rediscovery, dayStamp: 20261005
        ) != today)
    }

    @Test("从中间往两边摆:排第一的在正中,相邻两张不来自同一组")
    func centerOutArrangement() {
        #expect(HomeHeroCarouselSelection.centerOut(["0", "1", "2", "3", "4", "5", "6", "7"])
            == ["6", "4", "2", "0", "1", "3", "5", "7"])
        #expect(HomeHeroCarouselSelection.centerOut(["0", "1", "2"]) == ["2", "0", "1"])
        #expect(HomeHeroCarouselSelection.initialIndex(count: 8) == 3)
        #expect(HomeHeroCarouselSelection.initialIndex(count: 3) == 1)
        #expect(HomeHeroCarouselSelection.initialIndex(count: 0) == 0)

        let picked = HomeHeroCarouselSelection.pick(
            recent: candidates("r", albums: 5),
            added: candidates("n", albums: 5),
            rediscovery: candidates("o", albums: 5),
            dayStamp: 20261004,
            count: HomeHeroCarouselSelection.featuredCount
        )
        #expect(picked[HomeHeroCarouselSelection.initialIndex(count: picked.count)].hasPrefix("r-"))
        for index in picked.indices.dropLast() {
            #expect(picked[index].prefix(1) != picked[index + 1].prefix(1))
        }
    }

    @Test("专辑键:有专辑用专辑,没有专辑按封面,都没有不进候选")
    func albumKeys() {
        #expect(HomeHeroCarouselSelection.albumKey(albumID: "abc", coverRef: "x.jpg") == "abc")
        #expect(HomeHeroCarouselSelection.albumKey(albumID: "", coverRef: "x.jpg") == "cover:x.jpg")
        #expect(HomeHeroCarouselSelection.albumKey(albumID: nil, coverRef: nil) == nil)
    }

    @Test("整库扫描只留近期没放过的专辑,代表曲取轨号最小的那首且与遍历顺序无关")
    func rediscoveryPool() {
        let songs: [(id: String, album: String, track: Int?)] = (0..<200).flatMap { album in
            [
                (id: "a\(album)-t3", album: "album-\(album)", track: 3),
                (id: "a\(album)-t1", album: "album-\(album)", track: 1),
                (id: "a\(album)-none", album: "album-\(album)", track: nil),
            ]
        }
        let played = Set((0..<100).map { "album-\($0)" })
        let forward = pool(songs, played: played, limit: 16)
        let backward = pool(songs.reversed(), played: played, limit: 16)
        #expect(forward == backward)
        #expect(forward.count == 16)
        #expect(forward.allSatisfy { !played.contains($0.albumKey) })
        #expect(forward.allSatisfy { $0.songID.hasSuffix("-t1") })
    }

    @Test("整库扫描的结果等于对全部专辑按当天排名取前若干")
    func rediscoveryPoolMatchesFullRanking() {
        let songs: [(id: String, album: String, track: Int?)] = (0..<500).map {
            (id: "s\($0)", album: "album-\($0 % 250)", track: $0 / 250)
        }
        let picked = pool(songs, limit: 20).map(\.albumKey)
        let expected = HomeHeroCarouselSelection.ranked(
            (0..<250).map { Candidate(songID: "s\($0)", albumKey: "album-\($0)") },
            dayStamp: 20261004
        ).prefix(20).map(\.albumKey)
        #expect(picked == Array(expected))
    }

    @Test("近期放过的专辑哪怕当天排名靠前也不进")
    func playedAlbumsNeverEnter() {
        let songs: [(id: String, album: String, track: Int?)] = (0..<10).map {
            (id: "s\($0)", album: "album-\($0)", track: 1)
        }
        let all = Set((0..<10).map { "album-\($0)" })
        #expect(pool(songs, played: all, limit: 4).isEmpty)
        let picked = pool(songs, played: all.subtracting(["album-7"]), limit: 4)
        #expect(picked.map(\.albumKey) == ["album-7"])
    }
}

@Suite("Home Hero Carousel Loop")
struct HomeHeroCarouselLoopTests {
    private typealias Loop = HomeHeroCarouselLoop

    @Test("虚拟序列是整圈、圈数为奇数,长度不超过五千格")
    func slotCount() {
        for count in [1, 3, 7, 8, 48, 500, 5_000] {
            let total = Loop.slotCount(itemCount: count)
            #expect(total.isMultiple(of: count))
            #expect(!(total / count).isMultiple(of: 2))
            #expect(total / count >= 3)
            #expect(total <= max(5_000, count * 3))
        }
        #expect(Loop.slotCount(itemCount: 0) == 0)
    }

    @Test("正中那一圈的格子换算回原来的卡,负数格子也对")
    func slotIndexMapping() {
        let count = 48
        for index in [0, 1, 23, 47] {
            let slot = Loop.middleSlot(forIndex: index, itemCount: count)
            #expect(Loop.index(ofSlot: slot, itemCount: count) == index)
            #expect(Loop.index(ofSlot: slot + count * 5, itemCount: count) == index)
        }
        #expect(Loop.index(ofSlot: -1, itemCount: count) == 47)
        #expect(Loop.index(ofSlot: -48, itemCount: count) == 0)
        let middle = Loop.middleSlot(forIndex: 23, itemCount: count)
        let total = Loop.slotCount(itemCount: count)
        #expect(abs(middle - total / 2) < count)
    }

    @Test("中间一段不动,滑到外侧换回正中那一圈的同一张")
    func recentering() {
        let count = 48
        let total = Loop.slotCount(itemCount: count)
        let middle = Loop.middleSlot(forIndex: 10, itemCount: count)
        #expect(Loop.recenteredSlot(middle, itemCount: count) == nil)
        #expect(Loop.recenteredSlot(middle + count * 10, itemCount: count) == nil)
        for far in [5, total - 3, -20, total + 40] {
            let recentered = Loop.recenteredSlot(far, itemCount: count)
            #expect(recentered != nil)
            if let recentered {
                #expect(Loop.index(ofSlot: recentered, itemCount: count) == Loop.index(ofSlot: far, itemCount: count))
                #expect(Loop.recenteredSlot(recentered, itemCount: count) == nil)
            }
        }
        #expect(Loop.recenteredSlot(3, itemCount: 0) == nil)
    }
}
