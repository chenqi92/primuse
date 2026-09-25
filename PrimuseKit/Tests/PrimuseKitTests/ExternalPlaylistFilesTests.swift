import Foundation
import Testing
@testable import PrimuseKit

@Suite struct ExternalPlaylistMorePlatformsTests {
    private func playlist(_ text: String) -> ExternalPlaylistLink? {
        if case .playlist(let link) = ExternalPlaylistLink.detect(in: text) { return link }
        return nil
    }

    @Test func links() {
        #expect(playlist("https://www.deezer.com/fr/playlist/908622995") == .init(platform: .deezer, playlistID: "908622995"))
        #expect(playlist("https://www.bilibili.com/audio/am10624?type=1") == .init(platform: .bilibili, playlistID: "10624", parameters: ["kind": "menu"]))
        #expect(playlist("https://space.bilibili.com/2/favlist?fid=1052622027&ftype=create") == .init(platform: .bilibili, playlistID: "1052622027", parameters: ["kind": "fav"]))
        #expect(playlist("https://www.bilibili.com/list/ml1052622027") == .init(platform: .bilibili, playlistID: "1052622027", parameters: ["kind": "fav"]))
        #expect(playlist("https://www.youtube.com/playlist?list=PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i") == .init(platform: .youtube, playlistID: "PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i"))
        #expect(playlist("https://music.youtube.com/playlist?list=RDCLAK5uy_kmPRjHDECIcuVwnKsx2Ng7fyNgFKWNJFs&si=x") == .init(platform: .youtube, playlistID: "RDCLAK5uy_kmPRjHDECIcuVwnKsx2Ng7fyNgFKWNJFs"))
        #expect(playlist("https://www.youtube.com/watch?v=abc") == nil)
        guard case .needsRedirect(_, .bilibili) = ExternalPlaylistLink.detect(in: "https://b23.tv/AbCd12") else {
            Issue.record("b23.tv should be followed")
            return
        }
        guard case .needsRedirect(_, .deezer) = ExternalPlaylistLink.detect(in: "https://link.deezer.com/s/30ABC") else {
            Issue.record("deezer short link should be followed")
            return
        }
    }

    @Test func deezerAndBilibiliPages() throws {
        let deezer = """
        {"data":[{"id":116348656,"title":"Hey Jude (Remastered 2015)","duration":429,"artist":{"name":"The Beatles"},"album":{"title":"1 (Remastered)"}}],"total":50,"next":"x"}
        """
        let page = try ExternalPlaylistDecoder.deezerTracksPage(Data(deezer.utf8))
        #expect(page.total == 50)
        #expect(page.tracks.first?.artists == ["The Beatles"])
        #expect(throws: ExternalPlaylistError.notFoundOrPrivate) {
            try ExternalPlaylistDecoder.deezerPlaylistName(Data(#"{"error":{"type":"DataException","message":"no data","code":800}}"#.utf8))
        }

        let menu = """
        {"code":0,"data":{"totalSize":16,"data":[{"id":2478206,"title":"【Mitchie M】Nechusho No!No! (feat. 初音未来 \\u0026 MEIKO)","author":"初音未来, MEIKO · Mitchie M","uname":"MitchieM","duration":112}]}}
        """
        let menuPage = try ExternalPlaylistDecoder.bilibiliMenuPage(Data(menu.utf8))
        #expect(menuPage.total == 16)
        #expect(menuPage.tracks.first?.artists == ["初音未来", "MEIKO", "Mitchie M"])

        let fav = """
        {"code":0,"data":{"info":{"title":"我的歌","media_count":28},"has_more":true,"medias":[
          {"title":"周杰伦 - 晴天 (官方MV)","duration":269,"bvid":"BV1","upper":{"name":"某UP主"}},
          {"title":"已失效视频","duration":0,"upper":{"name":"x"}}]}}
        """
        let favPage = try ExternalPlaylistDecoder.bilibiliFavoritesPage(Data(fav.utf8))
        #expect(favPage.hasMore)
        #expect(favPage.page.name == "我的歌")
        #expect(favPage.page.tracks.count == 1)
        #expect(favPage.page.tracks[0].title == "晴天 (官方MV)")
        #expect(favPage.page.tracks[0].artists == ["周杰伦"])
    }

    @Test func youtubeLockups() throws {
        let html = """
        <title>Top 100 Songs Global - YouTube</title><script>var ytInitialData = {"contents":{"list":{"contents":[
          {"lockupViewModel":{"contentId":"abc","contentImage":{"thumbnailViewModel":{"overlays":[{"badge":{"text":"4:01"}}]}},
            "metadata":{"lockupMetadataViewModel":{"title":{"content":"Shakira, Burna Boy - Dai Dai (Official Video)"},
              "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"Shakira"}}]}]}}}}}},
          {"lockupViewModel":{"contentId":"def","contentImage":{"t":{"text":"3:05"}},
            "metadata":{"lockupMetadataViewModel":{"title":{"content":"Blinding Lights"},
              "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"The Weeknd - Topic"}}]}]}}}}}},
          {"continuationItemViewModel":{"continuationCommand":{"innertubeCommand":{"continuationCommand":{"token":"TOKEN123"}}}}}
        ]}}};</script><script>ytcfg.set({"INNERTUBE_CLIENT_VERSION":"2.20260920.01.00"})</script>
        """
        let page = try ExternalPlaylistDecoder.youtubePlaylistPage(html)
        #expect(page.name == "Top 100 Songs Global")
        #expect(page.continuation == "TOKEN123")
        #expect(page.clientVersion == "2.20260920.01.00")
        #expect(page.tracks.count == 2)
        #expect(page.tracks[0].title == "Dai Dai (Official Video)")
        #expect(page.tracks[0].artists == ["Shakira", "Burna Boy"])
        #expect(page.tracks[0].duration == 241)
        // Topic 频道名就是歌手。
        #expect(page.tracks[1].matchSubjects.contains { $0.title == "Blinding Lights" && $0.artists == ["The Weeknd"] })
    }

    @Test func videoTitleReadings() {
        let key = { (subject: ExternalTrackMatchPolicy.Subject) in ExternalTrackMatchPolicy.Key(subject) }
        let library = key(.init(title: "晴天", artists: ["周杰伦"], duration: 269))
        // 「歌名 - 歌手」顺序反过来也要能对上。
        let reversed = VideoTitleInterpretation.subjects(videoTitle: "晴天 - 周杰伦【高音质】", channel: nil, duration: 270)
        #expect(reversed.contains { ExternalTrackMatchPolicy.verdict(key($0), library) == .confident })
        let bracket = VideoTitleInterpretation.subjects(videoTitle: "【周杰伦】晴天 MV", channel: "UP主", duration: nil)
        #expect(bracket.contains { $0.title == "晴天 MV" && $0.artists == ["周杰伦"] })
        let quoted = VideoTitleInterpretation.subjects(videoTitle: "周杰伦《晴天》完整版", channel: nil, duration: 269)
        #expect(quoted.first == .init(title: "晴天", artists: ["周杰伦"], duration: 269))
        #expect(ExternalTrackMatchPolicy.verdict(key(quoted[0]), library) == .confident)
    }
}

@Suite struct ExternalPlaylistFileParserTests {
    @Test func exportifyCSV() throws {
        let csv = #"""
        "Track URI","Track Name","Artist Name(s)","Album Name","Duration (ms)"
        "spotify:track:1","Hotel California - 2013 Remaster","Eagles","Hotel California","391376"
        "spotify:track:2","Señorita","Shawn Mendes;Camila Cabello","Señorita","190799"
        "spotify:track:3","Quote ""Me""","A, B","",""
        """#
        let playlist = try ExternalPlaylistFileParser.parse(data: Data(csv.utf8), fileExtension: "csv", fileName: "Liked")
        #expect(playlist.name == "Liked")
        #expect(playlist.tracks.count == 3)
        #expect(playlist.tracks[0].duration == 391.376)
        #expect(playlist.tracks[1].artists == ["Shawn Mendes", "Camila Cabello"])
        #expect(playlist.tracks[2].title == "Quote \"Me\"")
        #expect(playlist.tracks[2].artists == ["A, B"])
    }

    @Test func appleMusicTextExportInUTF16() throws {
        let text = "Name\tArtist\tComposer\tAlbum\tGrouping\tTime\n晴天\t周杰伦\t周杰伦\t叶惠美\t\t269\nYesterday\tThe Beatles\t\tHelp!\t\t125\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let playlist = try ExternalPlaylistFileParser.parse(data: data, fileExtension: "txt", fileName: "Favourites")
        #expect(playlist.tracks.map(\.title) == ["晴天", "Yesterday"])
        #expect(playlist.tracks[0].artists == ["周杰伦"])
        #expect(playlist.tracks[0].album == "叶惠美")
        #expect(playlist.tracks[1].duration == 125)
    }

    @Test func chineseAppleMusicHeadersAndPlainTextFallback() throws {
        let zh = "名称\t表演者\t专辑\t时间\n稻香\t周杰伦\t魔杰座\t3:43\n"
        let table = try ExternalPlaylistFileParser.parse(data: Data(zh.utf8), fileExtension: "txt", fileName: "x")
        #expect(table.tracks.first?.duration == 223)
        let plain = try ExternalPlaylistFileParser.parse(data: Data("晴天 - 周杰伦\n稻香 - 周杰伦".utf8), fileExtension: "txt", fileName: "x")
        #expect(plain.tracks.count == 2)
        #expect(plain.tracks[1].artists == ["周杰伦"])
    }

    @Test func iTunesXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Tracks</key><dict>
            <key>101</key><dict><key>Track ID</key><integer>101</integer><key>Name</key><string>晴天</string><key>Artist</key><string>周杰伦</string><key>Album</key><string>叶惠美</string><key>Total Time</key><integer>269000</integer><key>Location</key><string>file:///Users/me/Music/%E6%99%B4%E5%A4%A9.flac</string></dict>
            <key>102</key><dict><key>Track ID</key><integer>102</integer><key>Name</key><string>稻香</string><key>Artist</key><string>周杰伦</string></dict>
          </dict>
          <key>Playlists</key><array><dict><key>Name</key><string>周董</string><key>Playlist Items</key><array>
            <dict><key>Track ID</key><integer>102</integer></dict><dict><key>Track ID</key><integer>101</integer></dict>
          </array></dict></array>
        </dict></plist>
        """
        let playlist = try ExternalPlaylistFileParser.parse(data: Data(xml.utf8), fileExtension: "xml", fileName: "x")
        #expect(playlist.name == "周董")
        #expect(playlist.tracks.map(\.title) == ["稻香", "晴天"])
        #expect(playlist.tracks[1].duration == 269)
        #expect(playlist.tracks[1].location == "/Users/me/Music/晴天.flac")
    }

    @Test func plsXSPFAndWPL() throws {
        let pls = "[playlist]\nFile1=/music/周杰伦 - 晴天.flac\nTitle1=\nLength1=269\nFile2=D:\\Music\\稻香.mp3\nTitle2=周杰伦 - 稻香\nNumberOfEntries=2\n"
        let fromPLS = try ExternalPlaylistFileParser.parse(data: Data(pls.utf8), fileExtension: "pls", fileName: "p")
        #expect(fromPLS.tracks.map(\.title) == ["晴天", "稻香"])
        #expect(fromPLS.tracks[0].artists == ["周杰伦"])
        #expect(fromPLS.tracks[0].location == "/music/周杰伦 - 晴天.flac")
        #expect(fromPLS.tracks[0].duration == 269)

        let xspf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <playlist version="1" xmlns="http://xspf.org/ns/0/"><title>VLC 歌单</title><trackList>
          <track><location>file:///music/a.flac</location><title>晴天</title><creator>周杰伦</creator><album>叶惠美</album><duration>269000</duration></track>
        </trackList></playlist>
        """
        let fromXSPF = try ExternalPlaylistFileParser.parse(data: Data(xspf.utf8), fileExtension: "xspf", fileName: "x")
        #expect(fromXSPF.name == "VLC 歌单")
        #expect(fromXSPF.tracks.first?.artists == ["周杰伦"])
        #expect(fromXSPF.tracks.first?.duration == 269)

        let wpl = """
        <?wpl version="1.0"?><smil><head><title>WMP</title></head><body><seq>
          <media src="..\\Music\\周杰伦 - 晴天.mp3"/><media src="C:\\Music\\Yesterday.mp3"/>
        </seq></body></smil>
        """
        let fromWPL = try ExternalPlaylistFileParser.parse(data: Data(wpl.utf8), fileExtension: "wpl", fileName: "x")
        #expect(fromWPL.name == "WMP")
        #expect(fromWPL.tracks.map(\.title) == ["晴天", "Yesterday"])
        #expect(fromWPL.tracks[0].location == "..\\Music\\周杰伦 - 晴天.mp3")
    }

    @Test func emptyFileIsEmpty() {
        #expect(throws: ExternalPlaylistError.empty) {
            try ExternalPlaylistFileParser.parse(data: Data("Track Name,Artist\n".utf8), fileExtension: "csv", fileName: "x")
        }
    }
}
