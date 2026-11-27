import Foundation
import Testing
@testable import PrimuseKit

@Suite("收藏的 iCloud 同步")
struct FavoriteCollectionSyncPolicyTests {
    typealias Policy = FavoriteCollectionSyncPolicy
    typealias State = FavoriteCollectionSyncState

    private let liked = "playlist:primuse.system.liked"
    private let road = "playlist:road-trip"
    private let jazz = "playlist:jazz"
    private let book = "book:book:三体\u{1F}刘慈欣"
    private let folder = "folder:nas\u{1F}folder\u{1F}music/live"
    private let localFolder = "folder:phone\u{1F}folder\u{1F}inbox"
    private let album = "album:abc123"

    private func initial(
        collected: Set<String>,
        removed: Set<String> = [],
        order: [String],
        folderOrder: [String]? = nil,
        localOnly: Set<String> = []
    ) -> State {
        Policy.initialState(
            collected: collected,
            removed: removed,
            order: order,
            folderOrder: folderOrder,
            localOnly: localOnly
        )
    }

    @Test("条目 id 还原成收藏条目，书 id 里的冒号不拆")
    func pinIdentifierRoundTrip() {
        let pin = QuickAccessPinReference(kind: .book, itemID: "book:三体\u{1F}刘慈欣")
        #expect(QuickAccessPinReference(id: pin.id) == pin)
        #expect(QuickAccessPinReference(id: "unknown:x") == nil)
        #expect(QuickAccessPinReference(id: "no-colon") == nil)
        #expect(Policy.tracksMembership(road))
        #expect(Policy.tracksMembership(book))
        #expect(Policy.tracksMembership(folder))
        #expect(!Policy.tracksMembership(album))
    }

    @Test("第一次碰面取并集，谁的收藏都不被冲掉")
    func firstSyncTakesTheUnion() {
        let phone = initial(collected: [liked, road, book], order: [liked, road, album, book])
        let mac = initial(collected: [liked, jazz], order: [liked, jazz])
        let merged = Policy.merge(phone, mac)
        #expect(Policy.merge(mac, phone) == merged)
        for id in [liked, road, book, jazz] {
            #expect(merged.members[id]?.isCollected == true, "\(id)")
        }
        // 同一时刻条目多的那份顺序赢；另一台独有的收藏排到「我喜欢」后面。
        #expect(merged.order?.ids == [liked, road, album, book])
        #expect(Policy.liveOrder(merged, current: [liked, jazz], anchor: liked) == [liked, jazz, road, album, book])
    }

    @Test("新装设备默认带着的「我喜欢」顶不回另一台拿掉的")
    func removedLikedSongsStaysRemoved() {
        let fresh = initial(collected: [liked], order: [liked])
        let edited = initial(collected: [road], removed: [liked], order: [road])
        let merged = Policy.merge(fresh, edited)
        #expect(merged.members[liked]?.isCollected == false)
        #expect(Policy.liveOrder(merged, current: [liked], anchor: liked) == [road])
        // 时刻 0 的墓碑不过期。
        let later = Policy.retained(merged, now: 400 * 24 * 60 * 60)
        #expect(later.members[liked]?.isCollected == false)
    }

    @Test("取消收藏传到别的设备，旧列表带不回来")
    func removalPropagates() {
        let phone = initial(collected: [liked, road], order: [liked, road])
        let mac = phone
        let edited = Policy.recording(
            phone, collected: [liked], localOnly: [], order: [liked], folderOrder: nil, now: 1_000
        )
        #expect(edited.members[road] == .init(isCollected: false, stamp: 1_000))
        let macMerged = Policy.merge(mac, edited)
        #expect(macMerged.members[road]?.isCollected == false)
        #expect(Policy.liveOrder(macMerged, current: [liked, road], anchor: liked) == [liked])
        // Mac 上还留着旧列表也一样：合并是幂等的，再合一次不变。
        #expect(Policy.merge(macMerged, mac) == macMerged)
    }

    @Test("取消之后再收藏，比墓碑新，哪怕这台设备的时钟慢")
    func recollectBeatsTombstoneEvenWithSlowClock() {
        let removed = State(members: [road: .init(isCollected: false, stamp: 5_000)])
        let again = Policy.recording(
            removed, collected: [road], localOnly: [], order: nil, folderOrder: nil, now: 4_000
        )
        #expect(again.members[road]?.isCollected == true)
        #expect((again.members[road]?.stamp ?? 0) > 5_000)
        #expect(Policy.merge(removed, again).members[road]?.isCollected == true)
    }

    @Test("排序传播：新排的那份赢，别的设备刚收藏的排到前面")
    func newerOrderWins() {
        let base = initial(collected: [liked, road, jazz], order: [liked, road, jazz])
        let phone = Policy.recording(
            base, collected: [liked, road, jazz], localOnly: [], order: [jazz, liked, road], folderOrder: nil, now: 2_000
        )
        let mac = Policy.recording(
            base, collected: [liked, road, jazz, book], localOnly: [], order: nil, folderOrder: nil, now: 3_000
        )
        let merged = Policy.merge(phone, mac)
        #expect(merged.order?.ids == [jazz, liked, road])
        #expect(Policy.liveOrder(merged, current: [liked, road, jazz, book], anchor: liked) == [book, jazz, liked, road])
    }

    @Test("跟着喜欢自动挪的顺序不换新时刻，盖不掉另一台用户自己排的")
    func automaticReorderDoesNotBumpTheClock() {
        let base = initial(collected: [liked, road], order: [liked, road, album])
        let followed = Policy.recording(
            base, collected: [liked, road], localOnly: [], order: nil, folderOrder: nil, now: 9_000
        )
        #expect(followed == base)
    }

    @Test("只在本机有意义的收藏不进同步，落回时按原来的相对位置留着")
    func deviceBoundFavoritesStayLocal() {
        let state = initial(
            collected: [liked, folder, localFolder],
            order: [liked, localFolder, folder],
            folderOrder: [localFolder, folder],
            localOnly: [localFolder]
        )
        #expect(state.members[localFolder] == nil)
        #expect(state.order?.ids == [liked, folder])
        #expect(state.folderOrder?.ids == [folder])

        let remote = Policy.recording(
            state, collected: [liked, folder, road], localOnly: [], order: [road, liked, folder], folderOrder: nil, now: 1_000
        )
        let merged = Policy.merge(state, remote)
        #expect(Policy.liveOrder(merged, current: [liked, localFolder, folder], anchor: liked) == [road, liked, localFolder, folder])
        #expect(Policy.liveFolderOrder(merged, current: [localFolder, folder]) == [localFolder, folder])
        // 本机的那条不会因为不在同步里就被当成取消。
        let recorded = Policy.recording(
            merged, collected: [liked, folder, road, localFolder], localOnly: [localFolder], order: nil, folderOrder: nil, now: 2_000
        )
        #expect(recorded == merged)
    }

    @Test("已经在同步里的条目，本机判定变成「只在本机」也照常同步，不会被当成取消")
    func sharedEntriesStaySharedWhenClassificationFlips() {
        let state = initial(collected: [book], order: [book])
        let recorded = Policy.recording(
            state, collected: [book], localOnly: [book], order: [book], folderOrder: nil, now: 1_000
        )
        #expect(recorded == state)
    }

    @Test("目录：从没收藏过目录的设备在同步里也没有目录时继续自动推荐")
    func folderOrderLeavesAutomaticPicksAlone() {
        let state = initial(collected: [road], order: [road])
        #expect(Policy.liveFolderOrder(state, current: nil) == nil)

        let other = initial(collected: [folder], order: [folder], folderOrder: [folder])
        let merged = Policy.merge(state, other)
        #expect(Policy.liveFolderOrder(merged, current: nil) == [folder])

        // 另一台把收藏的目录都拿掉了：这边也变成「一个都不收藏」，而不是回到自动推荐。
        let cleared = Policy.recording(
            other, collected: [], localOnly: [], order: [], folderOrder: [], now: 1_000
        )
        #expect(Policy.liveFolderOrder(Policy.merge(merged, cleared), current: [folder]) == [])
    }

    @Test("别的设备收藏的目录排到首页目录最前")
    func remoteFolderGoesFirst() {
        let base = initial(collected: [folder], order: [folder], folderOrder: [folder])
        let other = "folder:nas\u{1F}folder\u{1F}music/classical"
        let remote = Policy.recording(
            base, collected: [folder, other], localOnly: [], order: nil, folderOrder: nil, now: 1_000
        )
        #expect(Policy.liveFolderOrder(Policy.merge(base, remote), current: [folder]) == [other, folder])
    }

    @Test("推上去的那份确定、云端已经是它就不推；过期墓碑按同一时刻整理后再比")
    func uploadIsStableAndSkipsEquivalentCloudCopy() throws {
        let day = 24.0 * 60 * 60
        let state = State(
            members: [
                road: .init(isCollected: false, stamp: 10 * day),
                jazz: .init(isCollected: true, stamp: 20 * day),
            ],
            order: .init(ids: [jazz], stamp: 20 * day)
        )
        let now = 200 * day
        let upload = Policy.uploadState(state, now: now)
        #expect(upload.members[road] == nil, "过期的墓碑忘掉")
        #expect(Policy.upload(state, over: upload, now: now) == nil)
        // 时钟慢一点的设备还推着那条墓碑：整理后一样，不再推回去。
        #expect(Policy.upload(state, over: state, now: now) == nil)
        #expect(Policy.upload(state, over: nil, now: now) == upload)
        let data = try #require(Policy.encode(upload))
        #expect(Policy.decode(data) == upload)
        #expect(Policy.encode(upload) == Policy.decode(data).flatMap(Policy.encode))
    }

    @Test("顺序太长只推前面那段，收到的设备不会再推回来")
    func longOrderIsTruncatedWithoutPingPong() throws {
        let ids = (0..<(Policy.maximumOrderLength + 50)).map { "album:\($0)" }
        let phone = Policy.recording(.empty, collected: [], localOnly: [], order: ids, folderOrder: nil, now: 1_000)
        let upload = try #require(Policy.upload(phone, over: nil, now: 1_000))
        #expect(upload.order?.ids.count == Policy.maximumOrderLength)
        // 本机留着整份：和推上去的那份合起来还是整份，云端已经是它的上传版本。
        #expect(Policy.merge(phone, upload) == phone)
        #expect(Policy.upload(Policy.merge(phone, upload), over: upload, now: 1_000) == nil)
        // 另一台收下截短的那份，再推也是同一份。
        let mac = Policy.merge(.empty, upload)
        #expect(Policy.upload(mac, over: upload, now: 1_000) == nil)
    }

    @Test("合并满足交换、结合、幂等")
    func mergeIsACRDT() {
        let a = Policy.recording(
            initial(collected: [liked, road], order: [liked, road]),
            collected: [liked], localOnly: [], order: [liked], folderOrder: nil, now: 100
        )
        let b = Policy.recording(
            initial(collected: [jazz, folder], order: [jazz, folder], folderOrder: [folder]),
            collected: [jazz, folder, book], localOnly: [], order: [book, jazz, folder], folderOrder: nil, now: 200
        )
        let c = initial(collected: [road], removed: [liked], order: [road])
        #expect(Policy.merge(a, b) == Policy.merge(b, a))
        #expect(Policy.merge(Policy.merge(a, b), c) == Policy.merge(a, Policy.merge(b, c)))
        #expect(Policy.merge(a, a) == a)
        let all = Policy.merge(Policy.merge(a, b), c)
        #expect(all.members[road]?.isCollected == false, "100 时刻的取消比时刻 0 的收藏新")
        #expect(all.members[liked]?.isCollected == false, "都在时刻 0 上：拿掉「我喜欢」的墓碑赢")
    }

    @Test("插回不在同步里的条目：跟在原来前面那条后面，前面没有的排最前")
    func reinsertingKeepsRelativePosition() {
        #expect(Policy.reinserting(["x"], from: ["x", "a", "b"], into: ["b", "a"]) == ["x", "b", "a"])
        #expect(Policy.reinserting(["x", "y"], from: ["a", "x", "b", "y"], into: ["b", "a", "c"]) == ["b", "y", "a", "x", "c"])
        #expect(Policy.reinserting([], from: ["a"], into: ["a"]) == ["a"])
    }
}
