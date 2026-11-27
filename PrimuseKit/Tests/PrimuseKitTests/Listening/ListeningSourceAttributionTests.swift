import Foundation
import Testing
@testable import PrimuseKit

struct ListeningSourceAttributionTests {
    private func nas(_ id: String, host: String = "192.168.1.20", share: String = "music", deleted: Bool = false) -> MusicSource {
        MusicSource(id: id, name: "客厅 NAS", type: .smb, host: host, shareName: share, isDeleted: deleted)
    }

    @Test func aRecreatedSourceIsFoundByItsAddressAndShare() {
        let old = nas("old", host: " 192.168.1.20 ", share: "/Music/", deleted: true)
        let recreated = nas("new")
        let otherShare = nas("other", share: "podcasts")
        #expect(ListeningSourceAttribution.connectionMatch(for: old, among: [otherShare, recreated]) == "new")

        // 同一台机器上两个同类源都对得上，说不清是哪个。
        let twin = nas("twin")
        #expect(ListeningSourceAttribution.connectionMatch(for: old, among: [recreated, twin]) == nil)

        // 类型不同不比。
        let webdav = MusicSource(id: "dav", name: "NAS", type: .webdav, host: "192.168.1.20", basePath: "music")
        #expect(ListeningSourceAttribution.connectionMatch(for: old, among: [webdav]) == nil)
    }

    @Test func cloudDrivesMatchByAccountAndLocalLibrariesByPath() {
        let oldDrive = MusicSource(id: "a", name: "百度网盘", type: .baiduPan, isDeleted: true, cloudAccountID: "acct-1")
        let newDrive = MusicSource(id: "b", name: "百度网盘", type: .baiduPan, cloudAccountID: "acct-1")
        let otherAccount = MusicSource(id: "c", name: "百度网盘 2", type: .baiduPan, cloudAccountID: "acct-2")
        #expect(ListeningSourceAttribution.connectionMatch(for: oldDrive, among: [otherAccount, newDrive]) == "b")

        let oldLocal = MusicSource(id: "l1", name: "本地音乐", type: .local, isDeleted: true)
        let newLocal = MusicSource(id: "l2", name: "本地音乐", type: .local)
        #expect(ListeningSourceAttribution.connectionMatch(for: oldLocal, among: [newLocal]) == "l2")
    }

    @Test func songVotesNeedEnoughSongsAndAClearMajority() {
        let keys = (1...6).compactMap { ListeningSourceAttribution.songKey(title: "Song \($0)", artist: "Band") }
        let library = Dictionary(uniqueKeysWithValues: keys.map { ($0, Set(["nas"])) })
        #expect(ListeningSourceAttribution.songVote(played: Set(keys), librarySources: library) == "nas")

        // 只比上两首，不够。
        #expect(ListeningSourceAttribution.songVote(played: Set(keys.prefix(2)), librarySources: library) == nil)

        // 一半在 NAS、一半在网盘：说不清。
        var split = library
        for key in keys.prefix(3) { split[key] = ["cloud"] }
        #expect(ListeningSourceAttribution.songVote(played: Set(keys), librarySources: split) == nil)

        // 六首里四首在网盘：认网盘。
        split[keys[3]] = ["cloud"]
        #expect(ListeningSourceAttribution.songVote(played: Set(keys), librarySources: split) == "cloud")

        // 每首歌在两个源上都有（两份一样的曲库）：平票，说不清。
        let mirrored = Dictionary(uniqueKeysWithValues: keys.map { ($0, Set(["nas", "cloud"])) })
        #expect(ListeningSourceAttribution.songVote(played: Set(keys), librarySources: mirrored) == nil)

        // 歌名大小写、首尾空白不同也算同一首；没有歌名的不参与。
        #expect(ListeningSourceAttribution.songKey(title: " song 1 ", artist: "BAND") == keys[0])
        #expect(ListeningSourceAttribution.songKey(title: "  ", artist: "Band") == nil)
    }

    @Test func resolutionPrefersLiveThenAddressThenSongsThenTheDeletedName() {
        let live = [nas("new"), MusicSource(id: "cloud", name: "OneDrive", type: .oneDrive, cloudAccountID: "x")]
        let deleted = [
            nas("old", deleted: true),
            MusicSource(id: "gone", name: "旧 WebDAV", type: .webdav, host: "dav.example.com", isDeleted: true),
            MusicSource(id: "voted", name: "旧网盘", type: .aliyunDrive, isDeleted: true, cloudAccountID: "y"),
        ]
        let result = ListeningSourceAttribution.resolve(
            playedSourceIDs: ["new", "old", "gone", "voted", "lost", "lost-voted"],
            live: live,
            deleted: deleted,
            songVotes: ["voted": "cloud", "lost-voted": "new", "gone": "missing-source"]
        )
        #expect(result["new"] == .live("new"))
        #expect(result["old"] == .live("new"))
        #expect(result["voted"] == .live("cloud"))
        #expect(result["lost-voted"] == .live("new"))
        // 投到一个已经不在的源上不算。
        #expect(result["gone"] == .deleted(name: "旧 WebDAV", type: .webdav))
        #expect(result["lost"] == .unknown)
    }
}
