import Foundation
import Testing
@testable import PrimuseKit

@Suite struct ExternalPlaylistLinkTests {
    private func playlist(_ text: String) -> ExternalPlaylistLink? {
        if case .playlist(let link) = ExternalPlaylistLink.detect(in: text) { return link }
        return nil
    }

    @Test func netEaseLinksAndShareText() {
        #expect(playlist("https://music.163.com/playlist?id=3778678&userid=1") == .init(platform: .netease, playlistID: "3778678"))
        #expect(playlist("https://music.163.com/#/playlist?id=19723756") == .init(platform: .netease, playlistID: "19723756"))
        #expect(playlist("https://y.music.163.com/m/playlist?id=123&uct2=x") == .init(platform: .netease, playlistID: "123"))
        #expect(playlist("分享Crabbit创建的歌单「深夜」: https://music.163.com/playlist?id=42 (来自@网易云音乐)")
            == .init(platform: .netease, playlistID: "42"))
        // 单曲链接不是歌单。
        #expect(playlist("https://music.163.com/song?id=1973665667") == nil)
    }

    @Test func shortLinksAskForRedirect() {
        guard case .needsRedirect(let url, .netease) = ExternalPlaylistLink.detect(in: "看看这个 http://163cn.tv/zoIxm3") else {
            Issue.record("163cn.tv should need a redirect")
            return
        }
        #expect(url.absoluteString == "http://163cn.tv/zoIxm3")
        guard case .needsRedirect(_, .qqMusic) = ExternalPlaylistLink.detect(in: "https://c6.y.qq.com/base/fcgi-bin/u?__=AbCd") else {
            Issue.record("QQ short link should need a redirect")
            return
        }
    }

    @Test func qqMusicLinks() {
        #expect(playlist("https://y.qq.com/n/ryqq/playlist/8416213779") == .init(platform: .qqMusic, playlistID: "8416213779"))
        #expect(playlist("https://i.y.qq.com/n2/m/share/details/taoge.html?platform=11&appshare=iphone&hosteuin=abc&id=7256912512&ADTAG=wxfshare")
            == .init(platform: .qqMusic, playlistID: "7256912512"))
        #expect(playlist("https://y.qq.com/w/taoge.html?id=3602407677") == .init(platform: .qqMusic, playlistID: "3602407677"))
    }

    @Test func kuwoAndBodianLinks() {
        #expect(playlist("https://www.kuwo.cn/playlist_detail/3567349593") == .init(platform: .kuwo, playlistID: "3567349593"))
        #expect(playlist("https://m.kuwo.cn/newh5app/playlist_detail/3567349593?from=ip") == .init(platform: .kuwo, playlistID: "3567349593"))
        #expect(playlist("https://bodian.kuwo.cn/share/playlist?pid=99") == .init(platform: .bodian, playlistID: "99"))
        guard case .needsRedirect(_, .bodian) = ExternalPlaylistLink.detect(in: "https://bodian.kuwo.cn/s/xyz") else {
            Issue.record("an unrecognised bodian link should be followed")
            return
        }
    }

    @Test func kugouLinks() {
        #expect(playlist("https://www.kugou.com/yy/special/single/6914288.html") == .init(platform: .kugou, playlistID: "6914288"))
        #expect(playlist("https://m.kugou.com/plist/list/6914288?json=true") == .init(platform: .kugou, playlistID: "6914288"))
        let share = "https://m.kugou.com/share/zlist.html?listid=4&type=0&uid=44232344&global_collection_id=collection_3_44232344_4_0&sign=0883e935&chain=1ulezd0CTV2"
        let link = playlist("分享歌单 \(share)")
        #expect(link?.platform == .kugou)
        #expect(link?.playlistID == "collection_3_44232344_4_0")
        // 签名只对原样的整串参数有效。
        #expect(link?.parameters["shareQuery"] == "listid=4&type=0&uid=44232344&global_collection_id=collection_3_44232344_4_0&sign=0883e935&chain=1ulezd0CTV2")
        guard case .needsRedirect(_, .kugou) = ExternalPlaylistLink.detect(in: "https://t4.kugou.com/8IhBCd0wiV2") else {
            Issue.record("kugou short link should be followed")
            return
        }
    }

    @Test func miguSodaAppleSpotifyLinks() {
        #expect(playlist("https://music.migu.cn/v3/music/playlist/228114498") == .init(platform: .migu, playlistID: "228114498"))
        #expect(playlist("https://h5.nf.migu.cn/app/v4/p/share/playlist/index.html?id=179730639") == .init(platform: .migu, playlistID: "179730639"))
        #expect(playlist("https://m.music.migu.cn/v4/#/playlist?playlistId=213964542") == .init(platform: .migu, playlistID: "213964542"))
        #expect(playlist("https://music.douyin.com/qishui/share/playlist?playlist_id=7608993469403234344&sec_sharer_id=x") == .init(platform: .soda, playlistID: "7608993469403234344"))
        #expect(playlist("https://www.douyin.com/qishui/playlist/7461037960796833826") == .init(platform: .soda, playlistID: "7461037960796833826"))
        guard case .needsRedirect(_, .soda) = ExternalPlaylistLink.detect(in: "https://qishui.douyin.com/s/i9gReGfB/") else {
            Issue.record("soda short link should be followed")
            return
        }
        #expect(playlist("https://music.apple.com/cn/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb") == .init(platform: .appleMusic, playlistID: "pl.f4d106fed2bd41149aaacabb233eb5eb"))
        #expect(playlist("https://music.apple.com/us/playlist/mine/pl.u-a1b2c3?l=zh") == .init(platform: .appleMusic, playlistID: "pl.u-a1b2c3"))
        #expect(playlist("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc") == .init(platform: .spotify, playlistID: "37i9dQZF1DXcBWIGoYBM5M"))
        #expect(playlist("https://open.spotify.com/intl-ja/playlist/37i9dQZF1DXcBWIGoYBM5M") == .init(platform: .spotify, playlistID: "37i9dQZF1DXcBWIGoYBM5M"))
        #expect(playlist("https://open.spotify.com/album/37i9dQZF1DXcBWIGoYBM5M") == nil)
    }

    @Test func bodianCarriesItsSource() {
        #expect(playlist("https://h5app.kuwo.cn/m/bodian/collection.html?playlistId=2867496601&source=4") == .init(platform: .bodian, playlistID: "2867496601", parameters: ["source": "4"]))
        #expect(playlist("https://bodian.kuwo.cn/share/playlist?pid=99") == .init(platform: .bodian, playlistID: "99"))
        // 普通酷我链接不能被当成波点。
        #expect(playlist("https://www.kuwo.cn/playlist_detail/3567349593")?.platform == .kuwo)
    }

    @Test func xiamiIsDiscontinued() {
        #expect(ExternalPlaylistLink.detect(in: "https://www.xiami.com/collect/1234567") == .discontinued)
        #expect(ExternalPlaylistLink.detect(in: "http://h.xiami.com/collect_detail.html?id=1") == .discontinued)
    }

    @Test func unrelatedTextIsNotALink() {
        #expect(ExternalPlaylistLink.detect(in: "晴天 - 周杰伦") == .none)
        #expect(ExternalPlaylistLink.detect(in: "https://example.com/playlist?id=1") == .none)
    }
}

@Suite struct ExternalPlaylistDecoderTests {
    @Test func netEaseDetailKeepsFullOrderAndKnownTracks() throws {
        let json = """
        {"code":200,"playlist":{"name":"热歌榜","trackIds":[{"id":1973665667},{"id":2},{"id":3}],
         "tracks":[{"name":"海屿你","id":1973665667,"ar":[{"id":1,"name":"马也_Crabbit"}],"al":{"name":"海屿你"},"dt":295940}]}}
        """
        let decoded = try ExternalPlaylistDecoder.netEasePlaylist(Data(json.utf8))
        #expect(decoded.name == "热歌榜")
        #expect(decoded.trackIDs == ["1973665667", "2", "3"])
        let track = try #require(decoded.tracksByID["1973665667"])
        #expect(track.title == "海屿你")
        #expect(track.artists == ["马也_Crabbit"])
        #expect(track.album == "海屿你")
        #expect(abs((track.duration ?? 0) - 295.94) < 0.001)
    }

    @Test func netEaseRefusalIsPrivate() {
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.netEasePlaylist(Data(#"{"code":401,"message":"无权限访问"}"#.utf8))
        }
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.netEasePlaylist(Data(#"{"code":200}"#.utf8))
        }
    }

    @Test func netEaseSongDetailAcceptsLegacyFields() throws {
        let json = """
        {"songs":[{"name":"海屿你","id":1973665667,"artists":[{"name":"马也_Crabbit"}],"album":{"name":"海屿你"},"duration":295940}],"code":200}
        """
        let tracks = try ExternalPlaylistDecoder.netEaseSongDetails(Data(json.utf8))
        #expect(tracks["1973665667"]?.artists == ["马也_Crabbit"])
        #expect(tracks["1973665667"]?.duration == 295.94)
    }

    @Test func qqPage() throws {
        let json = """
        {"code":0,"cdlist":[{"dissname":"AAA&amp;今日私享","total_song_num":30,"songlist":[
          {"songname":"我願意","songmid":"003GAuZN3pyhCR","songid":727900833,"albumname":"煙灰Ash 影视原声带","interval":174,
           "singer":[{"name":"亿轩_Kingston"},{"name":"彭梓烨_Leo"}]}]}]}
        """
        let page = try ExternalPlaylistDecoder.qqPlaylistPage(Data(json.utf8))
        #expect(page.name == "AAA&今日私享")
        #expect(page.total == 30)
        #expect(page.tracks.first?.artists == ["亿轩_Kingston", "彭梓烨_Leo"])
        #expect(page.tracks.first?.duration == 174)
        #expect(page.tracks.first?.externalID == "003GAuZN3pyhCR")
    }

    @Test func qqEmptyBodyMeansMissing() {
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.qqPlaylistPage(Data())
        }
    }

    @Test func kuwoPageSplitsArtists() throws {
        let json = """
        {"result":"ok","title":"dump","total":3,"musiclist":[
          {"name":"沉没","artist":"OneCandy&amp;某人","album":"沉没","duration":"261","id":"78489062","FSONGNAME":""}]}
        """
        let page = try ExternalPlaylistDecoder.kuwoPlaylistPage(Data(json.utf8))
        #expect(page.total == 3)
        #expect(page.tracks.first?.artists == ["OneCandy", "某人"])
        #expect(page.tracks.first?.duration == 261)
    }

    @Test func bodianPage() throws {
        let json = """
        {"code":200,"msg":"success","data":{"total":177,"list":[
          {"id":226543302,"name":"最伟大的作品","album":"最伟大的作品","artist":"周杰伦","artists":[{"id":336,"name":"周杰伦"}],"duration":244},
          {"id":1,"name":"Song &amp; Dance","album":"","artist":"A&amp;B","duration":"200"}]}}
        """
        let page = try ExternalPlaylistDecoder.bodianPage(Data(json.utf8))
        #expect(page.total == 177)
        #expect(page.tracks[0].artists == ["周杰伦"])
        #expect(page.tracks[0].duration == 244)
        #expect(page.tracks[1].title == "Song & Dance")
        #expect(page.tracks[1].artists == ["A", "B"])
        #expect(page.tracks[1].album == nil)
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.bodianPage(Data(#"{"code":-10,"msg":"参数错误"}"#.utf8))
        }
        #expect(ExternalPlaylistDecoder.bodianPlaylistName(Data(#"{"code":200,"data":{"id":1,"name":"终于等到周杰伦"}}"#.utf8)) == "终于等到周杰伦")
    }

    @Test func miguPage() throws {
        let json = """
        {"code":"000000","info":"操作成功","data":{"totalCount":50,"songList":[
          {"contentId":"600902000006889366","songName":"晴天","duration":270,"album":"叶惠美","singerList":[{"id":"112","name":"周杰伦"}]}]}}
        """
        let page = try ExternalPlaylistDecoder.miguPage(Data(json.utf8))
        #expect(page.total == 50)
        #expect(page.tracks.first?.artists == ["周杰伦"])
        #expect(page.tracks.first?.duration == 270)
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.miguPage(Data(#"{"code":"200002","info":"歌单不存在"}"#.utf8))
        }
    }

    @Test func kugouSpecialAndShare() throws {
        let special = """
        {"data":{"total":30,"info":[{"hash":"5BCC","filename":"王泽言 - 遇见爱的人","duration":216,"remark":"风把TA吹到你身边Ⅰ"},
          {"hash":"X","filename":"A、B - Title - Live","duration":200,"remark":""}]},"errcode":0}
        """
        let page = try ExternalPlaylistDecoder.kugouSpecialPage(Data(special.utf8))
        #expect(page.total == 30)
        #expect(page.tracks[0].title == "遇见爱的人")
        #expect(page.tracks[0].artists == ["王泽言"])
        #expect(page.tracks[0].album == "风把TA吹到你身边Ⅰ")
        // 只按第一个 " - " 切：歌名里的 " - Live" 留着给版本标记。
        #expect(page.tracks[1].title == "Title - Live")
        #expect(page.tracks[1].artists == ["A", "B"])

        let share = """
        {"errcode":0,"status":1,"info":[{"name":"【十年榜】华语热门金曲TOP100","count":10}],
         "list":{"count":10,"info":[{"name":"张韶涵 - 隐形的翅膀","timelen":224130,"hash":"H"}]}}
        """
        let sharePage = try ExternalPlaylistDecoder.kugouSharePage(Data(share.utf8))
        #expect(sharePage.name == "【十年榜】华语热门金曲TOP100")
        #expect(sharePage.tracks.first?.artists == ["张韶涵"])
        #expect(abs((sharePage.tracks.first?.duration ?? 0) - 224.13) < 0.001)
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.kugouSharePage(Data(#"{"errcode":101,"status":0,"error":"签名错误"}"#.utf8))
        }
    }

    @Test func sodaPageFromHTML() throws {
        let html = """
        <html><script>window.x={"a":1,"qishui_playlist":{"UniqId":"7461037960796833826","keyword":"治愈精神内耗的音乐","music_list":[
          {"track_id":"7153508211503400962","duration_ms":120047,"name":"备考｜大脑放松 {专注}","artist_name_list":["治愈音乐集"],"album_name":"图书馆"},
          {"track_id":"2","duration_ms":259000,"name":"禅 \\\"静\\\"","artist_name_list":["心的帮助","身心康复"],"album_name":""}]},"b":2}</script></html>
        """
        let page = try ExternalPlaylistDecoder.sodaPlaylistPage(html)
        #expect(page.name == "治愈精神内耗的音乐")
        #expect(page.tracks.count == 2)
        #expect(page.tracks[0].title == "备考｜大脑放松 {专注}")
        #expect(page.tracks[1].artists == ["心的帮助", "身心康复"])
        #expect(page.tracks[1].album == nil)
        #expect(abs((page.tracks[0].duration ?? 0) - 120.047) < 0.001)
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.sodaPlaylistPage("<html>未知歌单</html>")
        }
    }

    @Test func spotifyEmbed() throws {
        let html = """
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"name":"Today’s Top Hits","trackList":[
          {"uri":"spotify:track:2FZ","title":"Bass Persuades","subtitle":"Miley Cyrus, Someone","duration":202460}]}}}}}}</script>
        """
        let page = try ExternalPlaylistDecoder.spotifyEmbedPage(html)
        #expect(page.name == "Today’s Top Hits")
        #expect(page.tracks.first?.artists == ["Miley Cyrus", "Someone"])
        #expect(abs((page.tracks.first?.duration ?? 0) - 202.46) < 0.001)
    }

    @Test func garbageIsUnexpected() {
        #expect(throws: ExternalPlaylistError.unexpectedResponse) {
            try ExternalPlaylistDecoder.kuwoPlaylistPage(Data("<html>".utf8))
        }
    }
}

@Suite struct ExternalPlaylistTextParserTests {
    @Test func titleFirstWithNumberingAndBlankLines() {
        let tracks = ExternalPlaylistTextParser.parse("""
        1. 晴天 - 周杰伦
        2、Hotel California - Live - Eagles

        # 注释
        1989
        稻香 – 周杰伦/某人
        """)
        #expect(tracks.map(\.title) == ["晴天", "Hotel California - Live", "1989", "稻香"])
        #expect(tracks[0].artists == ["周杰伦"])
        #expect(tracks[1].artists == ["Eagles"])
        #expect(tracks[2].artists.isEmpty)
        #expect(tracks[3].artists == ["周杰伦", "某人"])
    }

    @Test func artistFirstSplitsOnFirstSeparator() {
        let tracks = ExternalPlaylistTextParser.parse("Eagles - Hotel California - Live", order: .artistFirst)
        #expect(tracks.first?.title == "Hotel California - Live")
        #expect(tracks.first?.artists == ["Eagles"])
    }

    @Test func tabSeparatedColumns() {
        let tracks = ExternalPlaylistTextParser.parse("晴天\t周杰伦\t叶惠美")
        #expect(tracks.first?.title == "晴天")
        #expect(tracks.first?.artists == ["周杰伦"])
    }
}

@Suite struct ExternalTrackMatchPolicyTests {
    private func key(_ title: String, _ artists: [String], _ duration: Double?) -> ExternalTrackMatchPolicy.Key {
        .init(.init(title: title, artists: artists, duration: duration))
    }

    @Test func traditionalWidthAndCaseDoNotMatter() {
        #expect(ExternalTrackMatchPolicy.verdict(key("我願意", ["周杰倫"], 174), key("我愿意", ["周杰伦"], 175)) == .confident)
        #expect(ExternalTrackMatchPolicy.verdict(key("ＨＥＬＬＯ", ["Adele"], 295), key("Hello", ["ADELE"], 296)) == .confident)
    }

    @Test func versionMarkersMustAgree() {
        #expect(ExternalTrackMatchPolicy.verdict(key("Hello (Live)", ["Adele"], 300), key("Hello", ["Adele"], 300)) == .none)
        #expect(ExternalTrackMatchPolicy.verdict(key("晴天 (伴奏)", ["周杰伦"], 269), key("晴天", ["周杰伦"], 269)) == .none)
        #expect(ExternalTrackMatchPolicy.verdict(key("Hotel California - Live", ["Eagles"], 400), key("Hotel California (Live)", ["Eagles"], 401)) == .confident)
        // 与版本无关的附注照样对得上。
        #expect(ExternalTrackMatchPolicy.verdict(key("Yesterday (Remastered 2009)", ["The Beatles"], 125), key("Yesterday", ["The Beatles"], 126)) == .confident)
        #expect(ExternalTrackMatchPolicy.verdict(key("光年之外 (电影《太空旅客》中国区主题曲)", ["G.E.M. 邓紫棋"], 235), key("光年之外", ["G.E.M. 邓紫棋"], 235)) == .confident)
        // 歌名里的普通英文单词不是现场版标记。
        #expect(ExternalTrackMatchPolicy.verdict(key("Live Forever", ["Oasis"], 276), key("Live Forever", ["Oasis"], 277)) == .confident)
    }

    @Test func artistsNeedAnOverlap() {
        #expect(ExternalTrackMatchPolicy.verdict(key("我願意", ["亿轩_Kingston", "彭梓烨_Leo"], 174), key("我愿意", ["彭梓烨_Leo"], 174)) == .confident)
        #expect(ExternalTrackMatchPolicy.verdict(key("我愿意", ["王菲"], 274), key("我愿意", ["张学友"], 274)) == .none)
        #expect(ExternalTrackMatchPolicy.verdict(key("Señorita", ["Shawn Mendes feat. Camila Cabello"], 191), key("Senorita", ["Camila Cabello"], 190)) == .confident)
    }

    @Test func durationDecidesTheTier() {
        #expect(ExternalTrackMatchPolicy.verdict(key("晴天", ["周杰伦"], 269), key("晴天", ["周杰伦"], 275)) == .probable)
        #expect(ExternalTrackMatchPolicy.verdict(key("晴天", ["周杰伦"], 269), key("晴天", ["周杰伦"], 300)) == .none)
        #expect(ExternalTrackMatchPolicy.verdict(key("晴天", ["周杰伦"], nil), key("晴天", ["周杰伦"], 269)) == .confident)
    }

    @Test func missingArtistIsNeverConfident() {
        #expect(ExternalTrackMatchPolicy.verdict(key("晴天", [], 269), key("晴天", ["周杰伦"], 269)) == .probable)
        #expect(ExternalTrackMatchPolicy.verdict(key("晴天", ["未知歌手"], nil), key("晴天", ["周杰伦"], 269)) == .probable)
    }

    @Test func indexReturnsConfidentBeforeProbable() {
        let index = ExternalTrackMatchIndex<String>([
            (id: "a", subject: .init(title: "晴天", artists: [], duration: 269)),
            (id: "b", subject: .init(title: "晴天", artists: ["周杰伦"], duration: 270)),
            (id: "c", subject: .init(title: "晴天 (Live)", artists: ["周杰伦"], duration: 300)),
            (id: "d", subject: .init(title: "雨天", artists: ["周杰伦"], duration: 270)),
        ])
        let hits = index.matches(for: .init(title: "晴天", artists: ["周杰倫"], duration: 269))
        #expect(hits.map(\.id) == ["b", "a"])
        #expect(hits.map(\.verdict) == [.confident, .probable])
        #expect(index.matches(for: .init(title: "晴天", artists: ["周杰伦"], duration: 269), minimum: .confident).map(\.id) == ["b"])
    }
}

@Suite struct PlayableCopyPreferencePolicyTests {
    @Test func availabilityThenLocalAudioThenQuality() {
        let candidates: [PlayableCopyPreferencePolicy.Candidate] = [
            .init(id: "nas-flac", isAvailable: false, hasLocalAudio: false, qualityScore: 20_000),
            .init(id: "cloud-mp3", isAvailable: true, hasLocalAudio: false, qualityScore: 320),
            .init(id: "cached-aac", isAvailable: true, hasLocalAudio: true, qualityScore: 256),
            .init(id: "cloud-flac", isAvailable: true, hasLocalAudio: false, qualityScore: 18_000),
        ]
        #expect(PlayableCopyPreferencePolicy.ordered(candidates).map(\.id) == ["cached-aac", "cloud-flac", "cloud-mp3", "nas-flac"])
        #expect(PlayableCopyPreferencePolicy.preferred(candidates)?.id == "cached-aac")
        #expect(PlayableCopyPreferencePolicy.preferred([candidates[0]]) == nil)
    }
}

@Suite struct QueueCopySubstitutionWindowPolicyTests {
    @Test func windowStartsAtStartAndWraps() {
        #expect(QueueCopySubstitutionWindowPolicy.indices(count: 5, startingAt: 3, limit: 4) == [3, 4, 0, 1])
        #expect(QueueCopySubstitutionWindowPolicy.indices(count: 3, startingAt: 1, limit: 10) == [1, 2, 0])
    }

    @Test func wholeLibraryQueueIsBounded() {
        let window = QueueCopySubstitutionWindowPolicy.indices(count: 70_000, startingAt: 69_990)
        #expect(window.count == QueueCopySubstitutionWindowPolicy.defaultLimit)
        #expect(window.first == 69_990)
        #expect(window[10] == 0)
    }

    @Test func degenerateInputs() {
        #expect(QueueCopySubstitutionWindowPolicy.indices(count: 0, startingAt: 0).isEmpty)
        #expect(QueueCopySubstitutionWindowPolicy.indices(count: 4, startingAt: 9, limit: 2) == [3, 0])
        #expect(QueueCopySubstitutionWindowPolicy.indices(count: 4, startingAt: -1, limit: 2) == [0, 1])
    }
}

@Suite struct PlaylistPendingEntryTests {
    @Test func syncIdentityRoundTrip() throws {
        let entry = PlaylistPendingEntry(title: "晴天", artists: ["周杰伦", "某人"], album: "叶惠美", duration: 269, origin: "netease")
        #expect(PlaylistPendingEntry.isPendingID(entry.id))
        let identity = entry.syncIdentity
        #expect(identity.filePath.isEmpty)
        let restored = try #require(PlaylistPendingEntry(syncIdentity: identity))
        #expect(restored.id == entry.id)
        #expect(restored.title == "晴天")
        #expect(restored.duration == 269)
        #expect(ExternalTrackMatchPolicy.Key(restored.matchSubject).artistTokens == ["周杰伦", "某人"])
    }

    @Test func ordinaryIdentityIsNotPending() {
        let identity = SongIdentity(songID: "abc", title: "晴天", artistName: nil, duration: 1, cloudAccountID: nil, filePath: "")
        #expect(PlaylistPendingEntry(syncIdentity: identity) == nil)
    }
}
