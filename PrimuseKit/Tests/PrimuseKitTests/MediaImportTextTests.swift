import Foundation
import Testing
@testable import PrimuseKit

@Suite("Shared media import compatibility")
struct MediaImportTextTests {
    @Test func detectsEncodingBeforeTreatingNULsAsUTF8() throws {
        let text = "#EXTM3U\r\n#EXTINF:183,林间信号 - 沿岸微光\r\nMusic/track.mp3\r\n"
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let bytes = try #require(text.data(using: encoding))
            let bom: [UInt8]
            switch encoding {
            case .utf8: bom = [0xEF, 0xBB, 0xBF]
            case .utf16LittleEndian: bom = [0xFF, 0xFE]
            case .utf16BigEndian: bom = [0xFE, 0xFF]
            case .utf32LittleEndian: bom = [0xFF, 0xFE, 0, 0]
            default: bom = [0, 0, 0xFE, 0xFF]
            }
            #expect(MediaImportText.decode(Data(bom) + bytes) == text)
            if encoding == .utf16LittleEndian || encoding == .utf16BigEndian {
                #expect(MediaImportText.decode(bytes) == text)
            }
        }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try #require(text.data(using: .init(rawValue: gb)))
        #expect(RadioPlaylistText.decode(data) == text)
        #expect(ExternalPlaylistFileParser.decodeText(data) == text)
        #expect(MediaImportText.decode(Data([0x50, 0x4B, 0x03, 0x04, 0, 1, 2, 3])) == nil)
    }

    @Test func sharedLinksPreservePunctuationAndSignatures() {
        let url = "https://e.test/list(one).m3u?sig=a,b%2Fc&k=x%3Dy"
        #expect(MediaImportText.urls(in: "分享清单：[沿岸](\(url))，一起听") == [URL(string: url)!])
        #expect(MediaImportText.singleURL(in: "推荐这档节目 https://e.test/feed.xml")?.absoluteString == "https://e.test/feed.xml")
        #expect(MediaImportText.fileExtension(for: "[清单](\(url))").isEmpty)
        #expect(MediaImportText.singleURL(in: "https://e.test/a\nhttps://e.test/b") == nil)
        #expect(PodcastFeedURL.normalized("[节目](feed://e.test/rss)")?.absoluteString == "https://e.test/rss")
        #expect(PodcastFeedURL.appleDirectoryID(in: "听听这档 https://podcasts.apple.com/cn/podcast/show/id12345?i=6") == 12345)
    }

    @Test func routingUsesContentWithoutConfusingTracksAndHLS() {
        #expect(MediaImportText.destination(for: "#EXTM3U\n#EXTINF:-1,广播\nhttps://e.test/live") == .radio)
        #expect(MediaImportText.destination(for: "#EXTM3U\n#EXTINF:184,乐队 - 歌曲\nMusic/song.mp3") == .playlist)
        #expect(MediaImportText.destination(for: "#EXTM3U\n#EXTINF:184,乐队 - 歌曲\nhttps://e.test/song.mp3") == nil)
        #expect(MediaImportText.destination(for: "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\npart.aac") == .radio)
        #expect(MediaImportText.destination(for: "<?xml version='1.0'?><opml><body/></opml>") == .podcast)
        #expect(MediaImportText.destination(for: "[节目](https://podcasts.apple.com/podcast/id123)") == .podcast)
    }

    @Test func importsMisnamedTablesAndPlaylistFiles() throws {
        let table = "\u{FEFF}\nsep=;\r\nTitle;Artist;Album\r\n沿岸微光;林间信号;夜航\r\n"
        let parsed = try ExternalPlaylistFileParser.parse(data: Data(table.utf8), fileExtension: "data", fileName: "清单")
        #expect(parsed.tracks.map(\.title) == ["沿岸微光"])
        #expect(parsed.tracks.first?.artists == ["林间信号"])
        let pls = "[playlist]\r\nFile2 = C:\\Music\\林间信号 - 沿岸微光.flac\r\nLength2 = 185\r\n"
        let tracks = try ExternalPlaylistFileParser.parse(data: Data(pls.utf8), fileExtension: "txt", fileName: "清单").tracks
        #expect(tracks.first?.title == "沿岸微光")
        #expect(tracks.first?.artists == ["林间信号"])
        #expect(tracks.first?.duration == 185)
        let xspf = "<playlist><title>夜航</title><trackList><track><title>沿岸微光</title><creator>林间信号</creator></track></trackList></playlist>"
        let xml = try ExternalPlaylistFileParser.parse(data: Data(xspf.utf8), fileExtension: "xml", fileName: "清单")
        #expect(xml.name == "夜航")
        #expect(xml.tracks.first?.title == "沿岸微光")
        #expect(throws: ExternalPlaylistError.unexpectedResponse) {
            try ExternalPlaylistFileParser.parse(data: Data("<html>登录后访问</html>".utf8), fileExtension: "m3u", fileName: "清单")
        }
    }

    @Test func filePathsAndMissingEXTINFPreserveMatchingMetadata() {
        let title = MediaImportText.playlistTrackTitle(extInfo: nil, path: #"C:\Music\林间信号 - 沿岸微光.flac"#)
        #expect(title.title == "沿岸微光")
        #expect(title.artist == "林间信号")
        let ext = MediaImportText.playlistTrackTitle(extInfo: #"185 group-title="Live, Acoustic",林间信号 - 沿岸微光, Live"#, path: "a.flac")
        #expect(ext.title == "沿岸微光, Live")
        #expect(ext.artist == "林间信号")
        #expect(MediaImportText.fileBasenames("file:///Music/Artist%20-%20Song.mp3").contains("artist - song.mp3"))
        #expect(MediaImportText.fileBasenames("/Music/%20.mp3").first == "%20.mp3")
        #expect(MediaImportText.fileBasename("https://e.test/Music/song.flac?token=x") == "song.flac")
    }

    @Test func podcastDiscoveryAndSubscriptionLists() throws {
        let html = #"<html><head><link TYPE='application/rss+xml' REL='alternate' HREF='../feeds/show.xml?a=1&amp;b=2'><link rel='icon' href='icon.png'></head></html>"#
        let base = URL(string: "https://e.test/shows/one")!
        #expect(PodcastFeedDiscovery.feedURLs(in: html, baseURL: base).map(\.absoluteString) == ["https://e.test/feeds/show.xml?a=1&b=2"])
        #expect(PodcastFeedDiscovery.feedURLs(in: "<a href='https://e.test/a.mp3'>play</a>", baseURL: base).isEmpty)
        let lines = "#订阅列表\n[节目一](https://e.test/one.xml)\nfeed://e.test/two\nhttp://e.test/one.xml\n"
        #expect(try PodcastOPML.parse(Data(lines.utf8)).map(\.feedURL.absoluteString) == ["https://e.test/one.xml", "https://e.test/two"])
        let rss = #"<rss><channel><link href="https://e.test/rss" rel="self" type="application/rss+xml"/></channel></rss>"#
        #expect(try PodcastOPML.parse(Data(rss.utf8)).first?.feedURL.absoluteString == "https://e.test/rss")
        #expect(PodcastFeedURL.normalized(rss) == nil)
    }
}
