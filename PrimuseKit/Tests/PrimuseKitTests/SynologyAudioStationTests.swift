import Foundation
import Testing
@testable import PrimuseKit

@Suite("Synology Audio Station")
struct SynologyAudioStationTests {
    // MARK: - 接口发现与版本协商

    @Test(arguments: [
        // preferred, minimum, serverMin, serverMax, expected (0 = unsupported)
        [3, 1, 1, 3, 3], [3, 1, 1, 5, 3], [3, 1, 1, 2, 2], [6, 1, 1, 4, 4],
        [2, 1, 3, 4, 0], [3, 2, 1, 1, 0], [7, 3, 1, 6, 6], [3, 1, 4, 2, 0],
    ])
    func versionNegotiation(values: [Int]) {
        let version = SynologyAudioStationAPI.negotiatedVersion(
            preferred: values[0], minimum: values[1], serverMin: values[2], serverMax: values[3]
        )
        #expect(version == (values[4] == 0 ? nil : values[4]))
    }

    @Test func discoveryNegotiatesEveryInterfaceFromRealDescriptors() throws {
        let catalog = try negotiate(Fixtures.apiInfo)
        let expected: [SynologyAudioStationInterface: (String, Int)] = [
            // 登录固定走生产环境验证过的 auth.cgi,不跟 DSM 7 报的 entry.cgi。
            .auth: ("auth.cgi", 7),
            .info: ("AudioStation/info.cgi", 6),
            .song: ("AudioStation/song.cgi", 3),
            .playlist: ("AudioStation/playlist.cgi", 3),
            .stream: ("AudioStation/stream.cgi", 2),
            .cover: ("AudioStation/cover.cgi", 3),
            .lyrics: ("AudioStation/lyrics.cgi", 2),
            .radio: ("AudioStation/radio.cgi", 1),
        ]
        for (interface, value) in expected {
            let endpoint = try catalog.endpoint(for: interface)
            #expect(endpoint.path == value.0)
            #expect(endpoint.version == value.1)
        }
        let base = try #require(URL(string: "https://nas.example:5001/proxy"))
        let url = try #require(SynologyAudioStationAPI.discoveryURL(baseURL: base))
        #expect(url.path == "/proxy/webapi/query.cgi")
        #expect(url.query == "api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth%2CSYNO.AudioStation.")
    }

    @Test func olderServersNegotiateDownAndTooNewServersAreRejected() throws {
        let older = try negotiate(#"{"data":{"SYNO.API.Auth":{"maxVersion":6,"minVersion":1,"path":"auth.cgi"},"SYNO.AudioStation.Info":{"maxVersion":"4","minVersion":"1","path":"AudioStation/info.cgi"},"SYNO.AudioStation.Song":{"maxVersion":2,"minVersion":1,"path":"AudioStation/song.cgi"},"SYNO.AudioStation.Stream":{"maxVersion":1,"minVersion":1,"path":"AudioStation/stream.cgi"},"SYNO.AudioStation.Lyrics":{"maxVersion":5,"minVersion":3,"path":"AudioStation/lyrics.cgi"}},"success":true}"#)
        #expect(try older.endpoint(for: .auth).version == 6)
        #expect(try older.endpoint(for: .info).version == 4)
        #expect(try older.endpoint(for: .song).version == 2)
        #expect(try older.endpoint(for: .stream).version == 1)
        // 可选接口协商不了只影响它自己。
        #expect(throws: SynologyAudioStationError.unsupportedVersion(api: "SYNO.AudioStation.Lyrics")) {
            try older.endpoint(for: .lyrics)
        }
        #expect(throws: SynologyAudioStationError.apiNotFound(code: 102)) { try older.endpoint(for: .playlist) }
        #expect(throws: SynologyAudioStationError.apiNotFound(code: 102)) { try older.endpoint(for: .radio) }
        // 必需接口协商不了,整个音乐源不可用。
        #expect(throws: SynologyAudioStationError.unsupportedVersion(api: "SYNO.AudioStation.Stream")) {
            try negotiate(#"{"data":{"SYNO.AudioStation.Song":{"maxVersion":3,"minVersion":1,"path":"AudioStation/song.cgi"},"SYNO.AudioStation.Stream":{"maxVersion":4,"minVersion":3,"path":"AudioStation/stream.cgi"}},"success":true}"#)
        }
    }

    @Test func missingPackageAndHostilePathsAreUnavailable() throws {
        #expect(throws: SynologyAudioStationError.audioStationUnavailable) {
            try negotiate(#"{"data":{"SYNO.API.Auth":{"maxVersion":7,"minVersion":1,"path":"entry.cgi"}},"success":true}"#)
        }
        #expect(throws: SynologyAudioStationError.audioStationUnavailable) {
            try negotiate(#"{"data":{"SYNO.AudioStation.Song":{"maxVersion":3,"minVersion":1,"path":"AudioStation/song.cgi"}},"success":true}"#)
        }
        for path in ["../song.cgi", "/AudioStation/song.cgi", "https://evil.example/song.cgi", "AudioStation/song.php", "AudioStation//song.cgi"] {
            #expect(throws: SynologyAudioStationError.audioStationUnavailable) {
                try negotiate(#"{"data":{"SYNO.AudioStation.Song":{"maxVersion":3,"minVersion":1,"path":"\#(path)"},"SYNO.AudioStation.Stream":{"maxVersion":2,"minVersion":1,"path":"AudioStation/stream.cgi"}},"success":true}"#)
            }
        }
        // 残缺的单个描述只丢掉它自己;Auth 缺席时退回 v7。
        let catalog = try negotiate(#"{"data":{"SYNO.AudioStation.Cover":{"path":"AudioStation/cover.cgi"},"SYNO.AudioStation.Song":{"maxVersion":3,"minVersion":1,"path":"AudioStation/song.cgi"},"SYNO.AudioStation.Stream":{"maxVersion":2,"minVersion":1,"path":"AudioStation/stream.cgi"}},"success":true}"#)
        #expect(try catalog.endpoint(for: .auth).version == 7)
        #expect(throws: SynologyAudioStationError.apiNotFound(code: 102)) { try catalog.endpoint(for: .cover) }
    }

    // MARK: - 信封解码

    @Test func envelopeToleratesBOMStringifiedBodiesAndStringNumbers() throws {
        let plain = #"{"data":{"total":1,"offset":0,"songs":[{"id":"music_1","title":"A"}]},"success":true}"#
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(("\n " + plain).utf8)
        let wholeString = try JSONSerialization.data(withJSONObject: plain, options: [.fragmentsAllowed])
        let dataString = try JSONSerialization.data(withJSONObject: [
            "success": true, "data": #"{"total":"1","offset":"0","songs":[{"id":"music_1","title":"A"}]}"#,
        ])
        for body in [Data(plain.utf8), bom, wholeString, dataString, Data([0xEF, 0xBB, 0xBF]) + wholeString] {
            guard case .success(let page) = try SynologyAudioStationAPI.decode(SynologyAudioStationSongPage.self, from: body) else {
                Issue.record("expected success")
                continue
            }
            #expect(page.total == 1)
            #expect(page.offset == 0)
            #expect(page.songs.map(\.id) == ["music_1"])
        }
        let numeric = #"{"success":"true","data":{"total":"2","songs":[{"id":"music_2","additional":{"song_tag":{"track":"7","disc":"0","year":"1999"},"song_audio":{"bitrate":"320000","duration":"201.0","filesize":"123"},"song_rating":{"rating":"4"}}}]}}"#
        guard case .success(let page) = try SynologyAudioStationAPI.decode(SynologyAudioStationSongPage.self, from: Data(numeric.utf8)) else {
            Issue.record("expected success")
            return
        }
        let song = try #require(page.songs.first)
        #expect(song.trackNumber == 7 && song.discNumber == nil && song.year == 1999)
        #expect(song.bitRateKbps == 320 && song.duration == 201 && song.fileSize == 123 && song.userRating == 4)
    }

    @Test func envelopeFailuresCarryCodeTokenAndTypes() throws {
        let twoFactor = #"{"error":{"code":403,"errors":{"token":"eyJ0eXAiOiJKV1Qxxx","types":[{"type":"otp"}]}},"success":false}"#
        guard case .failure(let failure) = try SynologyAudioStationAPI.decode(SynologyAudioStationEmpty.self, from: Data(twoFactor.utf8)) else {
            Issue.record("expected failure")
            return
        }
        #expect(failure == SynologyAudioStationFailure(code: 403, token: "eyJ0eXAiOiJKV1Qxxx", types: ["otp"]))
        for (body, code) in [
            (#"{"success":false,"error":{"code":"119"}}"#, 119),
            (#"{"success":false,"error":{"code":105,"errors":[0]}}"#, 105),
            (#"{"success":false}"#, 100),
            (#""{\"success\":false,\"error\":{\"code\":106}}""#, 106),
        ] {
            guard case .failure(let failure) = try SynologyAudioStationAPI.decode(SynologyAudioStationEmpty.self, from: Data(body.utf8)) else {
                Issue.record("expected failure for \(body)")
                continue
            }
            #expect(failure.code == code)
        }
        guard case .success = try SynologyAudioStationAPI.decode(SynologyAudioStationEmpty.self, from: Data(#"{"success":true}"#.utf8)) else {
            Issue.record("a write without data is a success")
            return
        }
        // 真实样本里「歌词」那份其实是标签编辑器的数组响应,不是信封。
        for body in [Fixtures.tagEditorArray, "", "<html>login</html>", #"{"data":{}}"#] {
            #expect(throws: SynologyAudioStationError.invalidResponse) {
                try SynologyAudioStationAPI.decode(SynologyAudioStationEmpty.self, from: Data(body.utf8))
            }
        }
        #expect(throws: SynologyAudioStationError.invalidResponse) {
            try SynologyAudioStationAPI.decode(SynologyAudioStationSongPage.self, from: Data(#"{"success":true,"data":{"songs":[]}}"#.utf8))
        }
    }

    // MARK: - 曲目映射

    @Test func realCatalogEntriesMapToSongs() throws {
        let songs = try Fixtures.catalogSongs()
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })

        let flac = try #require(byID["music_6908"]?.makeSong(sourceID: "nas-a"))
        #expect(flac.filePath == "/songs/music_6908.flac")
        #expect(flac.fileFormat == .flac)
        #expect(flac.bitRate == 883 && flac.sampleRate == 44100 && flac.fileSize == 30255188)
        #expect(flac.trackNumber == 3 && flac.discNumber == 4 && flac.year == 1990 && flac.duration == 262)
        #expect(flac.genre == "90年代")
        #expect(flac.albumTitle == "You're the only one" && flac.artistName == "王菲" && flac.albumArtistName == "王菲")
        #expect(flac.coverArtFileName == "synology-audiostation:cover:song:music_6908:30255188")
        #expect(SynologyAudioStationAPI.songID(fromTrackPath: flac.filePath) == "music_6908")
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: flac.filePath) == "music_6908")
        #expect(flac.id != byID["music_6908"]?.makeSong(sourceID: "nas-b")?.id)
        #expect(flac.id.count == 64)

        // 路径扩展名是大写的 .FLAC;容器优先,统一小写。截断的流派去掉尾巴残片。
        let upper = try #require(byID["music_6021"]?.makeSong(sourceID: "nas-a"))
        #expect(upper.filePath == "/songs/music_6021.flac")
        #expect(upper.genre == "Pop; Folk, World, & Country")

        let zeros = try #require(byID["music_5961"])
        let zeroSong = try #require(zeros.makeSong(sourceID: "nas-a"))
        #expect(zeroSong.trackNumber == nil && zeroSong.discNumber == nil && zeroSong.year == nil && zeroSong.genre == nil)
        #expect(zeros.userRating == 5)

        let ape = try #require(byID["music_6467"]?.makeSong(sourceID: "nas-a"))
        #expect(ape.fileFormat == .ape && ape.bitRate == nil)
        let wma = try #require(byID["music_6148"]?.makeSong(sourceID: "nas-a"))
        #expect(wma.fileFormat == .wma && wma.filePath == "/songs/music_6148.wma" && wma.bitRate == 320)

        // 没有艺人标签时不编造;标题照用服务端给的。
        let untagged = try #require(byID["music_7026"]?.makeSong(sourceID: "nas-a"))
        #expect(untagged.artistName == nil && untagged.albumArtistName == nil && untagged.title == "17岁-刘德华")

        #expect(byID["music_6884"]?.genre == "粤语; Pop")
    }

    @Test func folderPlacementUsesTheSharedFolderAsLibraryRoot() throws {
        let song = try #require(try Fixtures.catalogSongs().first { $0.id == "music_6908" })
        let placement = song.folderPlacement
        #expect(placement.providerFilePath == "/music/王菲/1990-《You're the only one》/王菲 - 然后某天.flac")
        #expect(placement.libraryRoot == "/music")
        #expect(placement.artistName == "王菲" && placement.albumName == "You're the only one")
        #expect(SynologyAudioStationAPI.libraryRoot(forNASPath: "/homes/alice/music/A/b.flac") == "/homes/alice/music")
        #expect(SynologyAudioStationAPI.libraryRoot(forNASPath: "/music/b.flac") == "/music")
        #expect(SynologyAudioStationAPI.libraryRoot(forNASPath: "b.flac") == nil)
        #expect(SynologyAudioStationAPI.libraryRoot(forNASPath: "/b.flac") == nil)
    }

    @Test func virtualCueTracksAreTranscodedMP3WithoutOriginalSize() throws {
        let track = try decodeSong(#"{"id":"music_v_1111","title":"Track 2","path":"/music/Album/CDImage.ape","type":"file","additional":{"song_audio":{"bitrate":900000,"codec":"ape","container":"ape","duration":245,"filesize":310000000,"frequency":44100},"song_tag":{"album":"Album","artist":"Artist","track":2}}}"#)
        #expect(track.isVirtualTrack)
        let song = try #require(track.makeSong(sourceID: "nas-a"))
        #expect(song.filePath == "/songs/music_v_1111.mp3")
        #expect(song.fileFormat == .mp3)
        #expect(song.fileSize == 0 && song.bitRate == nil && song.sampleRate == nil)
        #expect(song.duration == 245 && song.trackNumber == 2)
        #expect(SynologyAudioStationAPI.songID(fromTrackPath: song.filePath) == "music_v_1111")
        #expect(track.hasUsableTitle)
        // 标题缺失或是占位值时要交给后续的文件头检查;标题退回文件名。
        let placeholder = try decodeSong(#"{"id":"music_2","title":"Unknown","path":"/music/Artist - Real Name.flac"}"#)
        #expect(!placeholder.hasUsableTitle)
        let untitled = try decodeSong(#"{"id":"music_3","path":"/music/Some Song.flac"}"#)
        #expect(!untitled.hasUsableTitle && untitled.displayTitle == "Some Song")
    }

    @Test(arguments: [
        (#"{"container":"mp4","codec":"aac"}"#, "/music/a.m4a", "m4a"),
        (#"{"container":"","codec":""}"#, "/music/a.MP3", "mp3"),
        (#"{"container":"ogg","codec":"opus"}"#, "/music/a.opus", "opus"),
        (#"{"container":"ogg","codec":"vorbis"}"#, "/music/a.ogg", "ogg"),
        (#"{"container":"asf","codec":"wma"}"#, "/music/a.wma", "wma"),
        (#"{"container":"dsf","codec":"dsd"}"#, "/music/a.dsf", "dsf"),
    ])
    func containerDecidesTheExtension(audio: String, path: String, expected: String) throws {
        let track = try decodeSong(#"{"id":"music_9","path":"\#(path)","additional":{"song_audio":\#(audio)}}"#)
        #expect(track.trackPath == "/songs/music_9.\(expected)")
    }

    @Test func unknownFormatsAndUnindexedEntriesDoNotBecomeSongs() throws {
        #expect(try decodeSong(#"{"id":"music_9","path":"/music/a.xyz","additional":{"song_audio":{"container":"xyz"}}}"#).makeSong(sourceID: "a") == nil)
        // 歌单里尚未入库的条目:id 就是 NAS 路径。
        let unindexed = try decodeSong(#"{"id":"music_/volume1/music/日语/刘小慧 - 初恋情人.flac","path":"/music/日语/刘小慧 - 初恋情人.flac","title":"刘小慧 - 初恋情人.flac","additional":{"song_audio":{"container":"","filesize":0}}}"#)
        #expect(!unindexed.isCatalogSong)
        #expect(unindexed.makeSong(sourceID: "a") == nil)
        #expect(unindexed.coverReference == nil)
    }

    @Test(arguments: [
        ("90年代; 90年代", "90年代"),
        ("Pop; pop; POP", "Pop"),
        ("粤语; Pop", "粤语; Pop"),
        ("kuwo; Fusion; kuwo; Fusion; kuwo; Fusion", "kuwo; Fusion"),
        (" ; ;", nil),
        ("Rock Pop; Rock", "Rock Pop; Rock"),
        ("Pop; Folk, World, & Country; Pop; Folk, World, & Country; Pop; Folk, World, & Country; Pop; Folk, World, & Country; Pop; Folk, W", "Pop; Folk, World, & Country"),
    ] as [(String, String?)])
    func genreIsDeduplicatedAndKeepsTheServerSeparator(raw: String, expected: String?) {
        #expect(SynologyAudioStationAPI.normalizedGenre(raw) == expected)
    }

    // MARK: - 路径 ↔ id

    @Test func trackPathsRoundTrip() {
        for id in ["music_1", "music_6906", "music_v_1111", "music_p_42"] {
            let path = SynologyAudioStationAPI.trackPath(id: id, fileExtension: "flac")
            #expect(path.flatMap(SynologyAudioStationAPI.songID(fromTrackPath:)) == id)
        }
        #expect(SynologyAudioStationAPI.isVirtualTrackID("music_v_1111"))
        #expect(!SynologyAudioStationAPI.isVirtualTrackID("music_1111"))
        #expect(SynologyAudioStationAPI.trackPath(id: "music_/volume1/a.flac", fileExtension: "flac") == nil)
        #expect(SynologyAudioStationAPI.trackPath(id: "music_1", fileExtension: "FLAC") == nil)
    }

    @Test(arguments: [
        "", "/songs/", "/songs/.flac", "/songs/music_1", "/songs/music_1.", "/songs/music_.flac",
        "/songs/music_1.FLAC", "/songs/../music_1.flac", "/songs/music_1/2.flac", "/songs/music_1.flac?_sid=x",
        "/songs/music_1.flac#x", "/songs/music_%31.flac", "/songs/dir_1.flac", "/songs/music_v_.flac",
        "/songs/music_V_1.flac", "/songs/music_1a.flac", "/items/music_1.flac", "songs/music_1.flac",
        "/songs/music_1.fl ac", "/songs/music_-1.flac", "/songs/music_1.flac/", "/songs/ music_1.flac",
    ])
    func invalidTrackPathsAreRejected(path: String) {
        #expect(SynologyAudioStationAPI.songID(fromTrackPath: path) == nil)
    }

    // MARK: - 请求构造

    @Test func formEncodingIsSingleAndRoundTrips() throws {
        let tricky = "A/B & C+D 中文 100% =x?#"
        let encoded = try #require(SynologyAudioStationAPI.formEncoded([SynologyAudioStationParameter("name", tricky)]))
        #expect(encoded == "name=A%2FB%20%26%20C%2BD%20%E4%B8%AD%E6%96%87%20100%25%20%3Dx%3F%23")
        #expect(formDecode(encoded)["name"] == tricky)

        let base = try #require(URL(string: "https://nas.example:5001"))
        let playlistEndpoint = SynologyAudioStationEndpoint(interface: .playlist, path: "AudioStation/playlist.cgi", version: 3)
        let rename = try #require(SynologyAudioStationAPI.request(
            for: SynologyAudioStationAPI.renamePlaylistCall(id: "playlist_personal_normal/开车 & 路上", newName: tricky),
            baseURL: base, endpoint: playlistEndpoint, sid: "SID+/="
        ))
        #expect(rename.httpMethod == "POST")
        #expect(rename.url?.query == nil)
        #expect(rename.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=UTF-8")
        let body = String(decoding: try #require(rename.httpBody), as: UTF8.self)
        #expect(!body.contains("+") && !body.contains("%25E4"))
        let fields = orderedFormDecode(body)
        #expect(fields.map(\.0) == ["api", "version", "method", "library", "id", "new_name", "_sid"])
        #expect(fields.last?.1 == "SID+/=")
        #expect(formDecode(body)["id"] == "playlist_personal_normal/开车 & 路上")
        #expect(formDecode(body)["new_name"] == tricky)

        let create = try #require(SynologyAudioStationAPI.request(
            for: SynologyAudioStationAPI.createPlaylistCall(name: "新歌单/2026", shared: false),
            baseURL: base, endpoint: playlistEndpoint, sid: "sid"
        ))
        let createBody = try #require(create.httpBody)
        #expect(formDecode(String(decoding: createBody, as: UTF8.self))["name"] == "新歌单/2026")
    }

    @Test func streamTranscodeAndCoverURLs() throws {
        let base = try #require(URL(string: "https://nas.example:5001/proxy"))
        let stream = SynologyAudioStationEndpoint(interface: .stream, path: "AudioStation/stream.cgi", version: 2)
        let original = try #require(SynologyAudioStationAPI.streamURL(baseURL: base, endpoint: stream, id: "music_6906", transcode: nil, sid: "s/1+"))
        #expect(original.path == "/proxy/webapi/AudioStation/stream.cgi")
        #expect(original.query == "api=SYNO.AudioStation.Stream&version=2&method=stream&id=music_6906&_sid=s%2F1%2B")

        let transcoded = try #require(SynologyAudioStationAPI.streamURL(
            baseURL: base, endpoint: stream, id: "music_6906", transcode: .mp3,
            extraQueryItems: [URLQueryItem(name: "primuse_transcoded", value: "1")], sid: "sid"
        ))
        #expect(transcoded.path == "/proxy/webapi/AudioStation/stream.cgi/0.mp3")
        #expect(transcoded.query == "api=SYNO.AudioStation.Stream&version=2&method=transcode&id=music_6906&format=mp3&primuse_transcoded=1&_sid=sid")

        // 虚拟音轨不指定也转码。
        let virtual = try #require(SynologyAudioStationAPI.streamURL(baseURL: base, endpoint: stream, id: "music_v_1111", transcode: nil, sid: "sid"))
        #expect(virtual.path.hasSuffix("/stream.cgi/0.mp3") && virtual.query?.contains("method=transcode") == true)
        let lossless = try #require(SynologyAudioStationAPI.streamURL(baseURL: base, endpoint: stream, id: "music_1", transcode: .wav, sid: "sid"))
        #expect(lossless.path.hasSuffix("/stream.cgi/0.wav") && lossless.query?.contains("format=wav") == true)

        // 附加标记不能改写协议参数;非目录 id 拼不出链接。
        #expect(SynologyAudioStationAPI.streamURL(baseURL: base, endpoint: stream, id: "music_1", transcode: nil,
                                                  extraQueryItems: [URLQueryItem(name: "_sid", value: "x")], sid: "sid") == nil)
        #expect(SynologyAudioStationAPI.streamURL(baseURL: base, endpoint: stream, id: "music_1", transcode: nil,
                                                  extraQueryItems: [URLQueryItem(name: "id", value: "music_2")], sid: "sid") == nil)
        #expect(SynologyAudioStationAPI.streamURL(baseURL: base, endpoint: stream, id: "music_/volume1/a.flac", transcode: nil, sid: "sid") == nil)

        let cover = SynologyAudioStationEndpoint(interface: .cover, path: "AudioStation/cover.cgi", version: 3)
        let songCover = try #require(SynologyAudioStationAPI.url(
            for: SynologyAudioStationAPI.coverCall(for: .song(id: "music_6906", revision: nil)),
            baseURL: base, endpoint: cover, sid: "sid"
        ))
        #expect(songCover.query == "api=SYNO.AudioStation.Cover&version=3&method=getsongcover&id=music_6906&library=all&_sid=sid")
        let albumReference = SynologyAudioStationCoverReference.album(name: "You're the only one / 1990 & +", albumArtist: "王菲")
        #expect(SynologyAudioStationCoverReference(rawValue: albumReference.rawValue) == albumReference)
        #expect(!albumReference.rawValue.contains("/") && !albumReference.rawValue.contains("+"))
        let albumCover = try #require(SynologyAudioStationAPI.url(
            for: SynologyAudioStationAPI.coverCall(for: albumReference), baseURL: base, endpoint: cover, sid: "sid"
        ))
        let albumQuery = try #require(albumCover.query)
        #expect(!albumQuery.contains("output_default"))
        #expect(formDecode(albumQuery)["album_name"] == "You're the only one / 1990 & +")
        #expect(formDecode(albumQuery)["album_artist_name"] == "王菲")
        #expect(albumQuery.hasSuffix("&_sid=sid"))
    }

    @Test func coverReferencesRejectForeignOrMalformedValues() {
        let song = SynologyAudioStationCoverReference.song(id: "music_6906", revision: "30255188")
        #expect(SynologyAudioStationCoverReference(rawValue: song.rawValue) == song)
        for raw in ["synology-audiostation:cover:song:music_/x", "synology-audiostation:cover:song:music_1:a/b",
                    "synology-audiostation:cover:album::", "songloft:cover:songs:1:x", "https://nas/cover.cgi?_sid=x",
                    "synology-audiostation:cover:album:@@:x"] {
            #expect(SynologyAudioStationCoverReference(rawValue: raw) == nil)
        }
    }

    @Test func baseURLKeepsProxyPrefixAndRejectsCredentials() throws {
        #expect(SynologyAudioStationAPI.baseURL(host: "nas.example", port: 5001, useSSL: true, basePath: "/as/")?.absoluteString
                == "https://nas.example:5001/as")
        #expect(SynologyAudioStationAPI.baseURL(host: "http://nas.example:8080/dsm", port: 5001, useSSL: true, basePath: nil)?.absoluteString
                == "http://nas.example:8080/dsm")
        #expect(SynologyAudioStationAPI.baseURL(host: "fd7a::1", port: 5001, useSSL: false, basePath: nil)?.absoluteString
                == "http://[fd7a::1]:5001")
        #expect(SynologyAudioStationAPI.baseURL(host: "https://user:secret@nas.example", port: nil, useSSL: true, basePath: nil) == nil)
        #expect(SynologyAudioStationAPI.baseURL(host: "ftp://nas.example", port: nil, useSSL: true, basePath: nil) == nil)
        #expect(SynologyAudioStationAPI.baseURL(host: "", port: 5001, useSSL: true, basePath: nil) == nil)
    }

    // MARK: - 歌单与评分模型

    @Test func playlistListFiltersSystemEntryAndMarksSmartOnesReadOnly() throws {
        guard case .success(let page) = try SynologyAudioStationAPI.decode(
            SynologyAudioStationPlaylistPage.self, from: Data([0xEF, 0xBB, 0xBF]) + Data(Fixtures.playlistList.utf8)
        ) else {
            Issue.record("expected success")
            return
        }
        #expect(page.total == 7 && page.playlists.count == 7)
        #expect(page.playlists.filter(\.isSystem).map(\.name) == ["__SYNO_AUDIO_SHARED_SONGS__"])
        let smart = try #require(page.playlists.first { $0.id == "playlist_personal_smart/ぐされ" })
        #expect(smart.isSmart && smart.isReadOnly)
        let shared = try #require(page.playlists.first { $0.id == "playlist_shared_normal/1" })
        #expect(shared.isShared && !shared.isReadOnly && shared.name == "热门")
        #expect(SynologyAudioStationAPI.isSmartPlaylistID("playlist_shared_smart/x"))
        #expect(!SynologyAudioStationAPI.isPlaylistID("playlist_personal_normal/"))
        #expect(!SynologyAudioStationAPI.isPlaylistID("dir_1"))
    }

    @Test func infoSampleDecodes() throws {
        guard case .success(let info) = try SynologyAudioStationAPI.decode(SynologyAudioStationInfo.self, from: Data(Fixtures.info.utf8)) else {
            Issue.record("expected success")
            return
        }
        #expect(info.versionString == "7.2.0-5516")
        #expect(info.canEditPlaylists == true && info.canEditTags == true && info.isManager == true)
        #expect(info.transcodeCapability == ["wav", "mp3"])
        #expect(info.supportsTranscode(to: .mp3) && info.supportsTranscode(to: .wav))
        #expect(info.downloadEnabled == true && info.personalLibraryEnabled == false && info.hasMusicShare == true)
        // v1 的 Info 只有 path 与对象形式的 version,也不能解失败。
        guard case .success(let legacy) = try SynologyAudioStationAPI.decode(
            SynologyAudioStationInfo.self,
            from: Data(#"{"data":{"path":"/webman/3rdparty/AudioStation","version":{"build":"5508","major":"7","minor":"1"}},"success":true}"#.utf8)
        ) else {
            Issue.record("expected success")
            return
        }
        #expect(legacy.versionString == nil && legacy.transcodeCapability.isEmpty)
    }

    // MARK: - 错误映射

    @Test func errorCodesMapByCallContext() {
        let login = SynologyAudioStationAPI.loginCall(account: "a", password: "b", otp: nil, deviceName: nil, deviceID: nil)
        let list = SynologyAudioStationAPI.songListCall(offset: 0, limit: 1)
        let rate = SynologyAudioStationAPI.setRatingCall(id: "music_1", rating: 5)
        let append = SynologyAudioStationAPI.updatePlaylistSongsCall(id: "playlist_personal_normal/a", offset: -1, limit: 0, songIDs: ["music_1"], skipDuplicates: false)
        let cases: [(SynologyAudioStationCall, Int, SynologyAudioStationError)] = [
            (login, 400, .invalidCredentials), (login, 401, .accountDisabled), (login, 402, .noAudioStationPermission),
            (login, 403, .twoFactorRequired(token: "t", types: ["otp"])), (login, 406, .twoFactorRequired(token: "t", types: ["otp"])),
            (login, 404, .invalidOneTimePassword), (login, 407, .ipBlocked), (login, 408, .passwordExpired(code: 408)),
            (login, 409, .passwordExpired(code: 409)), (login, 410, .passwordExpired(code: 410)),
            (list, 102, .apiNotFound(code: 102)), (list, 103, .apiNotFound(code: 103)),
            (list, 104, .unsupportedVersion(api: "SYNO.AudioStation.Song")),
            (list, 105, .noAudioStationPermission), (rate, 105, .operationNotPermitted), (append, 105, .operationNotPermitted),
            (list, 106, .sessionExpired(code: 106)), (list, 107, .sessionExpired(code: 107)),
            (list, 119, .sessionExpired(code: 119)), (list, 150, .sessionExpired(code: 150)),
            (list, 109, .serverBusy(code: 109)), (list, 117, .serverBusy(code: 117)),
            (append, 411, .duplicateInPlaylist), (list, 411, .server(code: 411)), (list, 400, .server(code: 400)),
            (list, 100, .server(code: 100)),
        ]
        for (call, code, expected) in cases {
            let failure = SynologyAudioStationFailure(code: code, token: "t", types: ["otp"])
            #expect(SynologyAudioStationAPI.error(for: failure, call: call) == expected, "code \(code) \(call.method)")
        }
        // 与群晖直连的两步验证判定保持同一组码。
        for code in 400...411 {
            let mapped = SynologyAudioStationAPI.error(for: SynologyAudioStationFailure(code: code), call: login)
            #expect(mapped.requiresOneTimePassword == SynologyAuthenticationPolicy.requiresTwoFactorAuthentication(errorCode: code))
        }
        #expect(SynologyAudioStationError.invalidCredentials.requiresCredentialPrompt)
        #expect(!SynologyAudioStationError.ipBlocked.requiresCredentialPrompt)
        for code in [105, 106, 107, 119, 150] { #expect(SynologyAudioStationAPI.renewsSession(after: code)) }
        for code in [100, 102, 104, 400, 403, 411] { #expect(!SynologyAudioStationAPI.renewsSession(after: code)) }
    }

    @Test func imageSniffingAcceptsBitmapsOnly() {
        #expect(SynologyAudioStationAPI.isImageData(Fixtures.jpeg))
        #expect(SynologyAudioStationAPI.isImageData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        #expect(SynologyAudioStationAPI.isImageData(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)))
        #expect(!SynologyAudioStationAPI.isImageData(Data(#"{"success":false,"error":{"code":100}}"#.utf8)))
        #expect(!SynologyAudioStationAPI.isImageData(Data("<html>".utf8)))
        #expect(!SynologyAudioStationAPI.isImageData(Data()))
    }

    // MARK: - 客户端(注入传输层)

    @Test func loginSendsProductionParametersWithAudioStationSession() async throws {
        let fixture = AudioStationFixture(deviceID: "did-old")
        let client = fixture.client(deviceName: "Primuse-iOS")
        let login = try await client.login(otp: "123456")
        #expect(login.sid == "sid-1" && login.deviceID == "did-new")
        let requests = await fixture.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/proxy/webapi/query.cgi")
        let request = requests[1]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://nas.example:5001/proxy/webapi/auth.cgi")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        let fields = orderedFormDecode(body)
        #expect(fields.map(\.0) == ["api", "version", "method", "account", "passwd", "session", "format",
                                    "otp_code", "device_name", "enable_device_token", "device_id"])
        let values = formDecode(body)
        #expect(values["api"] == "SYNO.API.Auth" && values["version"] == "7" && values["method"] == "login")
        #expect(values["account"] == "alice" && values["passwd"] == AudioStationFixture.password)
        #expect(values["session"] == "AudioStation" && values["format"] == "sid")
        #expect(values["otp_code"] == "123456" && values["device_name"] == "Primuse-iOS")
        #expect(values["enable_device_token"] == "yes" && values["device_id"] == "did-old")
        #expect(values["_sid"] == nil)
        // 新的受信设备令牌用于之后的自动重登。
        await client.invalidateSession()
        _ = try await client.info()
        let relogin = try #require(await fixture.requests.last { $0.url?.path.hasSuffix("/auth.cgi") == true })
        let reloginBody = try #require(relogin.httpBody)
        #expect(formDecode(String(decoding: reloginBody, as: UTF8.self))["device_id"] == "did-new")
    }

    @Test func twoFactorChallengeCarriesTokenAndOTPLoginRecovers() async throws {
        let fixture = AudioStationFixture(mode: .twoFactor)
        let client = fixture.client()
        await #expect(throws: SynologyAudioStationError.twoFactorRequired(token: "otp-token", types: ["otp"])) {
            try await client.info()
        }
        _ = try await client.login(otp: "654321")
        #expect(try await client.info().versionString == "7.2.0-5516")
        #expect(await fixture.logins == 2)
    }

    @Test func missingCredentialFailsBeforeAnyRequest() async throws {
        let fixture = AudioStationFixture()
        let client = SynologyAudioStationClient(source: fixture.source, credential: SourceCredential(username: "alice", password: ""),
                                                transport: fixture.transport())
        await #expect(throws: SynologyAudioStationError.missingCredential) { try await client.info() }
        #expect(await fixture.requests.isEmpty)
    }

    @Test func expiredSessionIsRenewedExactlyOnceAndSharedByConcurrentRequests() async throws {
        let fixture = AudioStationFixture(mode: .expiredFirstSession)
        let client = fixture.client()
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<12 { group.addTask { try await client.info().versionString } }
            for try await version in group { #expect(version == "7.2.0-5516") }
        }
        #expect(await fixture.logins == 2)
        let requests = await fixture.requests
        #expect(requests.filter { $0.url?.path.hasSuffix("/query.cgi") == true }.count == 1)
        let infoSIDs = requests.filter { $0.url?.path.hasSuffix("/info.cgi") == true }.compactMap { formDecode($0.url?.query ?? "")["_sid"] }
        #expect(infoSIDs.filter { $0 == "sid-2" }.count == 12)
    }

    @Test func persistentSessionFailureDoesNotLoopLogin() async throws {
        let fixture = AudioStationFixture(mode: .alwaysExpired)
        let client = fixture.client()
        await #expect(throws: SynologyAudioStationError.sessionExpired(code: 119)) { try await client.info() }
        #expect(await fixture.logins == 2)
        let denied = AudioStationFixture(mode: .noPermission)
        let deniedClient = denied.client()
        await #expect(throws: SynologyAudioStationError.noAudioStationPermission) { try await deniedClient.songPage(offset: 0, limit: 1) }
        await #expect(throws: SynologyAudioStationError.operationNotPermitted) { try await deniedClient.setRating(id: "music_6906", rating: 3) }
        // 第二次调用沿用 sid-2,只为自己的 105 重登一次。
        #expect(await denied.logins == 3)
    }

    @Test func invalidatingSessionRediscoversAndQuickConnectIsResolvedPerSession() async throws {
        let fixture = AudioStationFixture()
        let resolutions = ResolutionCounter()
        let source = MusicSource(id: "qc", name: "Audio Station", type: .synology, host: "my-nas", port: 5001, useSsl: true,
                                 synologyConnectionMode: .quickConnect, username: "alice", basePath: "/ignored")
        let client = SynologyAudioStationClient(
            source: source, credential: SourceCredential(username: "alice", password: AudioStationFixture.password),
            transport: fixture.transport(),
            quickConnectResolver: { id in
                await resolutions.record(id)
                return URL(string: "https://nas.example:5001/proxy")!
            }
        )
        _ = try await client.info()
        _ = try await client.info()
        await client.invalidateSession()
        _ = try await client.info()
        #expect(await resolutions.ids == ["my-nas", "my-nas"])
        let requests = await fixture.requests
        #expect(requests.filter { $0.url?.path.hasSuffix("/query.cgi") == true }.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "nas.example" && $0.url?.path.hasPrefix("/proxy/webapi/") == true })
    }

    @Test func catalogStreamPagesWithValidationAndRechecksTotal() async throws {
        let fixture = AudioStationFixture()
        let client = fixture.client()
        var ids: [String] = []
        for try await song in await client.songs(pageSize: 2) { ids.append(song.id) }
        #expect(ids == ["music_6906", "music_6908", "music_5961"])
        let lists = await fixture.requests.filter { $0.url?.path.hasSuffix("/song.cgi") == true }.map { formDecode($0.url?.query ?? "") }
        #expect(lists.map { $0["offset"] ?? "" } == ["0", "2", "0"])
        #expect(lists.map { $0["limit"] ?? "" } == ["2", "2", "1"])
        #expect(lists.allSatisfy { $0["library"] == "all" && $0["additional"] == "song_tag,song_audio,song_rating" && $0["method"] == "list" })

        let growing = AudioStationFixture(mode: .catalogGrows)
        let growingClient = growing.client()
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            for try await _ in await growingClient.songs(pageSize: 2) {}
        }
    }

    @Test func stringifiedResponsesAreUnwrapped() async throws {
        let client = AudioStationFixture(mode: .stringified).client()
        let page = try await client.songPage(offset: 0, limit: 5)
        #expect(page.total == 3 && page.songs.count == 3)
    }

    @Test func playlistsAndPagedTrackIDs() async throws {
        let fixture = AudioStationFixture()
        let client = fixture.client()
        let playlists = try await client.playlists()
        #expect(playlists.count == 6)
        #expect(!playlists.contains { $0.isSystem })
        let ids = try await client.playlistTrackIDs(id: "playlist_personal_normal/开车", pageSize: 2)
        #expect(ids == ["music_6906", "music_/volume1/music/日语/刘小慧 - 初恋情人.flac", "music_6906"])
        let pages = await fixture.requests.filter { formDecode($0.url?.query ?? "")["method"] == "getinfo" }.map { formDecode($0.url?.query ?? "") }
        #expect(pages.map { $0["songs_offset"] ?? "" } == ["0", "2"])
        #expect(pages.allSatisfy { $0["id"] == "playlist_personal_normal/开车" && $0["additional"] == "songs_song_tag,songs_song_audio,songs_song_rating" })
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await client.playlistTrackIDs(id: "playlist_personal_normal/坏掉", pageSize: 2)
        }
    }

    /// 镜像 id 已经落在用户设备上,换算方式一变,现有镜像就会被当成服务端已删除。
    @Test func playlistMirrorIDsStayPinned() {
        #expect(SynologyAudioStationPlaylistMirrorSnapshot.mirrorID(for: "playlist_personal_normal/开车")
            == "as-d4b060dbc3d0aa6ecdd0f9194ff41a3d")
        #expect(SynologyAudioStationPlaylistMirrorSnapshot.mirrorID(for: "playlist_shared_normal/1")
            == "as-fdc9211b4b5575782687f7ca644bcb1a")
    }

    @Test func playlistMirrorSnapshotDropsUnindexedEntries() async throws {
        let snapshot = try await AudioStationFixture().client().playlistMirrorSnapshot()
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(snapshot.playlists.map(\.name) == ["开车", "放松", "欢快周杰伦", "粤语", "热门", "ぐされ"])
        let drive = try #require(snapshot.playlists.first)
        #expect(drive.id == "as-d4b060dbc3d0aa6ecdd0f9194ff41a3d")
        #expect(drive.trackIDs == ["music_6906", "music_6906"])
    }

    @Test func playlistMirrorSnapshotKeepsFailedPlaylistsApart() async throws {
        let listed = try JSONDecoder().decode([SynologyAudioStationPlaylist].self, from: Data("""
            [{"id":"playlist_personal_normal/好","name":"好"},{"id":"playlist_personal_normal/坏","name":"坏"}]
            """.utf8))
        let snapshot = try await SynologyAudioStationPlaylistMirrorSnapshot.collect(
            playlists: { listed },
            trackIDs: { id in
                guard id.hasSuffix("好") else { throw SynologyAudioStationError.invalidResponse }
                return ["music_1", "music_/volume1/a.flac", "music_v_2"]
            }
        )
        #expect(snapshot.playlists.map(\.name) == ["好"])
        #expect(snapshot.playlists.first?.trackIDs == ["music_1", "music_v_2"])
        #expect(snapshot.failedPlaylistIDs == [
            SynologyAudioStationPlaylistMirrorSnapshot.mirrorID(for: "playlist_personal_normal/坏")
        ])

        await #expect(throws: CancellationError.self) {
            try await SynologyAudioStationPlaylistMirrorSnapshot.collect(
                playlists: { listed },
                trackIDs: { _ in throw CancellationError() }
            )
        }
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await SynologyAudioStationPlaylistMirrorSnapshot.collect(
                playlists: { throw SynologyAudioStationError.invalidResponse },
                trackIDs: { _ in [] }
            )
        }
    }

    // MARK: - 电台

    @Test func radioContainersPageInServerOrder() async throws {
        let fixture = AudioStationFixture()
        let client = fixture.client()
        let favorites = try await client.radios(in: .favorite, pageSize: 2)
        #expect(favorites.map(\.title) == ["SmoothJazz.com Global", "Groove Salad", "Jazz"])
        #expect(favorites.map(\.isContainer) == [false, false, true])
        let pages = await fixture.requests.filter { $0.url?.path.hasSuffix("/radio.cgi") == true }
            .map { formDecode($0.url?.query ?? "") }
        #expect(pages.map { $0["offset"] ?? "" } == ["0", "2"])
        #expect(pages.allSatisfy {
            $0["method"] == "list" && $0["version"] == "1" && $0["container"] == "Favorite" && $0["limit"] == "2"
        })

        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await AudioStationFixture(mode: .radioTotalChanges).client().radios(in: .favorite, pageSize: 2)
        }
    }

    @Test func radioMirrorsSkipFoldersAndDuplicatesAcrossContainers() async throws {
        let mirrors = try await AudioStationFixture().client().radioMirrors()
        #expect(mirrors.map(\.name) == ["SmoothJazz.com Global", "Groove Salad", "Stream", "新闻台"])
        #expect(mirrors.map(\.container) == [.favorite, .favorite, .userDefined, .userDefined])
        #expect(mirrors.map(\.url) == [
            "http://yp.shoutcast.com/sbin/tunein-station.pls?id=1477271",
            "https://ice5.somafm.com/groovesalad-128",
            "http://46.105.100.126:8000/stream",
            "https://e.test/news/index.m3u8",
        ])
        #expect(mirrors.map(\.id) == mirrors.map { SynologyAudioStationRadioMirror.mirrorID(forStationURL: $0.url) })

        await #expect(throws: SynologyAudioStationError.apiNotFound(code: 102)) {
            try await AudioStationFixture(mode: .noRadioAPI).client().radioMirrors()
        }
    }

    /// 镜像 id 已经落在用户设备上,换算方式一变,现有镜像就会被当成服务端已删除。
    @Test func radioMirrorIDsFollowTheAddressNotTheName() {
        let id = SynologyAudioStationRadioMirror.mirrorID(forStationURL: "http://yp.shoutcast.com/sbin/tunein-station.pls?id=1477271")
        #expect(id == "as-73ad281432064170b9ed82a03971c1f5")
        #expect(SynologyAudioStationRadioMirror.mirrorID(forStationURL: "https://yp.shoutcast.com/sbin/tunein-station.pls?id=1477271") == id)
        #expect(SynologyAudioStationRadioMirror.mirrorID(forStationURL: "not a url") == nil)
    }

    @Test func radioMirrorsFailAsAWhole() async {
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await SynologyAudioStationRadioMirror.collect(radios: { container in
                guard container == .favorite else { throw SynologyAudioStationError.invalidResponse }
                return []
            })
        }
    }

    @Test func playlistWritesUsePOSTAndRefuseSmartPlaylists() async throws {
        let fixture = AudioStationFixture()
        let client = fixture.client()
        #expect(try await client.createPlaylist(name: " 路上 & 家 ") == "playlist_personal_normal/路上 & 家")
        try await client.appendToPlaylist(id: "playlist_personal_normal/开车", songIDs: ["music_6906", "music_v_1111"])
        await #expect(throws: SynologyAudioStationError.duplicateInPlaylist) {
            try await client.updatePlaylistSongs(id: "playlist_personal_normal/开车", offset: 0, limit: 0, songIDs: ["music_6906"])
        }
        await #expect(throws: SynologyAudioStationError.operationNotPermitted) {
            try await client.appendToPlaylist(id: "playlist_personal_smart/ぐされ", songIDs: ["music_6906"])
        }
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await client.appendToPlaylist(id: "playlist_personal_normal/开车", songIDs: ["music_/volume1/a.flac"])
        }
        let writes = await fixture.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/playlist.cgi") == true }
        #expect(writes.count == 3)
        let append = formDecode(String(decoding: try #require(writes[1].httpBody), as: UTF8.self))
        #expect(append["method"] == "updatesongs" && append["offset"] == "-1" && append["limit"] == "0")
        #expect(append["songs"] == "music_6906,music_v_1111" && append["skip_duplicate"] == "true")
        #expect(writes.allSatisfy { $0.url?.query == nil })
    }

    @Test func ratingZeroIsNilAndWritesAreConfirmed() async throws {
        let fixture = AudioStationFixture()
        let client = fixture.client()
        #expect(try await client.rating(id: "music_6906") == nil)
        #expect(try await client.setRating(id: "music_6906", rating: 5) == 5)
        #expect(try await client.rating(id: "music_6906") == 5)
        #expect(try await client.setRating(id: "music_6906", rating: nil) == nil)
        let writes = await fixture.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/song.cgi") == true }
        #expect(writes.map { formDecode(String(decoding: $0.httpBody ?? Data(), as: UTF8.self))["rating"] ?? "" } == ["5", "0"])
        await #expect(throws: SynologyAudioStationError.invalidResponse) { try await client.setRating(id: "music_6906", rating: 6) }
        let ignoring = AudioStationFixture(mode: .ratingIgnored)
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await ignoring.client().setRating(id: "music_6906", rating: 4)
        }
    }

    @Test func lyricsTreatEmptyAsAbsent() async throws {
        let client = AudioStationFixture().client()
        #expect(try await client.lyrics(id: "music_6906") == "[00:01.00]Hello")
        #expect(try await client.lyrics(id: "music_6908") == nil)
    }

    @Test func rangeReadsValidateTheWindow() async throws {
        let fixture = AudioStationFixture()
        let client = fixture.client()
        #expect(try await client.fetchRange(id: "music_6906", offset: 0, length: 2) == Data([0x66, 0x4C]))
        let request = try #require(await fixture.requests.last)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-1")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        let query = try #require(request.url?.query)
        #expect(query.hasPrefix("api=SYNO.AudioStation.Stream&version=2&method=stream&id=music_6906"))
        #expect(query.hasSuffix("&_sid=sid-1"))

        await #expect(throws: SynologyAudioStationError.rangeNotSupported) {
            try await AudioStationFixture(mode: .rangeIgnored).client().fetchRange(id: "music_6906", offset: 0, length: 2)
        }
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await AudioStationFixture(mode: .wrongRange).client().fetchRange(id: "music_6906", offset: 0, length: 2)
        }
        let before = await fixture.requests.count
        await #expect(throws: SynologyAudioStationError.transcodeRequired) {
            try await client.fetchRange(id: "music_v_1111", offset: 0, length: 2)
        }
        #expect(await fixture.requests.count == before)
        // 会话失效时 stream.cgi 回 200 + JSON:重登后再取,不把错误体当音频。
        let expiring = AudioStationFixture(mode: .expiredFirstSession)
        #expect(try await expiring.client().fetchRange(id: "music_6906", offset: 0, length: 2) == Data([0x66, 0x4C]))
        #expect(await expiring.logins == 2)
    }

    @Test func downloadsRejectDocumentsAndRenewSessions() async throws {
        let expiring = AudioStationFixture(mode: .expiredFirstSession)
        let file = try await expiring.client().downloadOriginal(id: "music_6906")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data([0x66, 0x4C, 0x61, 0x43]))
        #expect(await expiring.logins == 2)
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await AudioStationFixture(mode: .htmlAudio).client().downloadOriginal(id: "music_6906")
        }
        await #expect(throws: SynologyAudioStationError.transcodeRequired) {
            try await AudioStationFixture().client().downloadOriginal(id: "music_v_1111")
        }
    }

    @Test func streamURLCarriesCurrentSessionAndMarkers() async throws {
        let client = AudioStationFixture().client()
        let url = try await client.streamURL(
            id: "music_6906", transcode: .mp3,
            extraQueryItems: [URLQueryItem(name: "primuse_transcoded", value: "1"), URLQueryItem(name: "primuse_adaptive", value: "1")]
        )
        #expect(url.absoluteString == "https://nas.example:5001/proxy/webapi/AudioStation/stream.cgi/0.mp3?api=SYNO.AudioStation.Stream&version=2&method=transcode&id=music_6906&format=mp3&primuse_transcoded=1&primuse_adaptive=1&_sid=sid-1")
        #expect(!url.absoluteString.contains(AudioStationFixture.password))
        await #expect(throws: SynologyAudioStationError.invalidResponse) { try await client.streamURL(id: "../music_1") }
    }

    @Test func artworkReturnsImagesOnly() async throws {
        let reference = SynologyAudioStationCoverReference.song(id: "music_6906", revision: "1").rawValue
        let fixture = AudioStationFixture()
        #expect(try await fixture.client().artwork(reference: reference, maxBytes: 1_024) == Fixtures.jpeg)
        let cover = try #require(await fixture.requests.last?.url?.query)
        #expect(!cover.contains("output_default") && formDecode(cover)["method"] == "getsongcover")

        for mode in [AudioStationFixture.Mode.coverMissing, .coverNotImage, .coverHTTP404] {
            #expect(try await AudioStationFixture(mode: mode).client().artwork(reference: reference, maxBytes: 1_024) == nil)
        }
        let expiring = AudioStationFixture(mode: .expiredFirstSession)
        #expect(try await expiring.client().artwork(reference: reference, maxBytes: 1_024) == Fixtures.jpeg)
        #expect(await expiring.logins == 2)
        await #expect(throws: SynologyAudioStationError.sessionExpired(code: 119)) {
            try await AudioStationFixture(mode: .alwaysExpired).client().artwork(reference: reference, maxBytes: 1_024)
        }
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await fixture.client().artwork(reference: reference, maxBytes: 4)
        }
        await #expect(throws: SynologyAudioStationError.invalidResponse) {
            try await fixture.client().artwork(reference: "https://foreign.example/cover.jpg", maxBytes: 1_024)
        }
    }

    // MARK: - 辅助

    private func negotiate(_ json: String) throws -> SynologyAudioStationAPICatalog {
        guard case .success(let table) = try SynologyAudioStationAPI.decode(
            SynologyAudioStationAPIDescriptor.Table.self, from: Data(json.utf8)
        ) else { throw SynologyAudioStationError.invalidResponse }
        return try SynologyAudioStationAPI.negotiate(table.descriptors)
    }

    private func decodeSong(_ json: String) throws -> SynologyAudioStationSong {
        try JSONDecoder().decode(SynologyAudioStationSong.self, from: Data(json.utf8))
    }
}

/// 按 `application/x-www-form-urlencoded` 解一次;输出里不应出现字面量 `+`。
private func orderedFormDecode(_ encoded: String) -> [(String, String)] {
    encoded.split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]).removingPercentEncoding ?? "", parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? "" : "")
    }
}

private func formDecode(_ encoded: String) -> [String: String] {
    Dictionary(orderedFormDecode(encoded), uniquingKeysWith: { _, last in last })
}

private actor ResolutionCounter {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private actor AudioStationFixture {
    enum Mode: Sendable {
        case normal, twoFactor, expiredFirstSession, alwaysExpired, noPermission, catalogGrows, stringified
        case rangeIgnored, wrongRange, htmlAudio, coverMissing, coverNotImage, coverHTTP404, ratingIgnored
        case radioTotalChanges, noRadioAPI
    }

    static let password = "p@ss&w=rd+ 中"
    let mode: Mode
    nonisolated let source: MusicSource
    var requests: [URLRequest] = []
    private(set) var logins = 0
    private var ratings: [String: Int] = ["music_6906": 0]
    private var songListCalls = 0
    private var playlistSongs = ["music_6906"]

    init(mode: Mode = .normal, deviceID: String? = nil) {
        self.mode = mode
        source = MusicSource(id: "nas", name: "Audio Station", type: .synology, host: "nas.example", port: 5001,
                             useSsl: true, username: "alice", basePath: "/proxy", deviceId: deviceID)
    }

    nonisolated func client(deviceName: String? = nil) -> SynologyAudioStationClient {
        SynologyAudioStationClient(source: source, credential: SourceCredential(username: "alice", password: Self.password),
                                   deviceName: deviceName, transport: transport())
    }

    nonisolated func transport() -> SynologyAudioStationRequestTransport {
        SynologyAudioStationRequestTransport(data: { try await self.reply($0) }, download: { request in
            let (data, response) = try await self.reply(request)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: file)
            return (file, response)
        })
    }

    func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        let encoded = request.httpMethod == "POST"
            ? String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            : (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        let params = formDecode(encoded)
        guard url.path.hasPrefix("/proxy/webapi/") else { throw URLError(.unsupportedURL) }
        let endpoint = String(url.path.dropFirst("/proxy/webapi/".count))

        if endpoint == "query.cgi" {
            return json(url, mode == .noRadioAPI
                ? Fixtures.apiInfo.replacingOccurrences(of: #""SYNO.AudioStation.Radio":{"maxVersion":2,"minVersion":1,"path":"AudioStation/radio.cgi"},"#, with: "")
                : Fixtures.apiInfo)
        }
        if endpoint == "auth.cgi" {
            if params["method"] == "logout" { return json(url, #"{"success":true}"#) }
            logins += 1
            let generation = logins
            try await Task.sleep(for: .milliseconds(10))
            if mode == .twoFactor, params["otp_code"] == nil {
                return json(url, #"{"error":{"code":403,"errors":{"token":"otp-token","types":[{"type":"otp"}]}},"success":false}"#)
            }
            let did = params["enable_device_token"] == "yes" ? #","did":"did-new""# : ""
            return json(url, #"{"data":{"sid":"sid-\#(generation)"\#(did),"is_portal_port":false},"success":true}"#)
        }

        let sid = params["_sid"] ?? ""
        switch mode {
        case .alwaysExpired: return json(url, #"{"success":false,"error":{"code":119}}"#)
        case .expiredFirstSession where sid == "sid-1": return json(url, #"{"error":{"code":106},"success":false}"#)
        case .noPermission: return json(url, #"{"success":false,"error":{"code":105}}"#)
        default: break
        }

        switch endpoint {
        case "AudioStation/info.cgi":
            return json(url, Fixtures.info)
        case "AudioStation/song.cgi":
            return songReply(url, params)
        case "AudioStation/playlist.cgi":
            return playlistReply(url, params)
        case "AudioStation/radio.cgi":
            return radioReply(url, params)
        case "AudioStation/lyrics.cgi":
            return json(url, params["id"] == "music_6906" ? #"{"data":{"lyrics":"[00:01.00]Hello"},"success":true}"# : #"{"data":{"lyrics":"  "},"success":true}"#)
        case "AudioStation/stream.cgi":
            let full = Data([0x66, 0x4C, 0x61, 0x43])
            guard request.value(forHTTPHeaderField: "Range") != nil else {
                return (full, response(url, 200, ["Content-Type": mode == .htmlAudio ? "text/html" : "audio/flac", "Content-Length": "4"]))
            }
            if mode == .rangeIgnored { return (full, response(url, 200, ["Content-Type": "audio/flac", "Content-Length": "4"])) }
            let range = mode == .wrongRange ? "bytes 2-3/4" : "bytes 0-1/4"
            return (Data([0x66, 0x4C]), response(url, 206, ["Content-Type": "audio/flac", "Content-Length": "2", "Content-Range": range]))
        case "AudioStation/cover.cgi":
            switch mode {
            case .coverMissing: return json(url, #"{"success":false,"error":{"code":100}}"#)
            case .coverNotImage: return (Data("<html></html>".utf8), response(url, 200, ["Content-Type": "image/jpeg"]))
            case .coverHTTP404: return (Data(), response(url, 404, [:]))
            default: return (Fixtures.jpeg, response(url, 200, ["Content-Type": "image/jpeg"]))
            }
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func songReply(_ url: URL, _ params: [String: String]) -> (Data, URLResponse) {
        switch params["method"] {
        case "list":
            songListCalls += 1
            let total = mode == .catalogGrows && songListCalls > 1 ? 4 : 3
            let offset = Int(params["offset"] ?? "") ?? 0
            let limit = Int(params["limit"] ?? "") ?? 0
            let slice = Fixtures.pagedSongs.dropFirst(offset).prefix(limit)
            let body = #"{"data":{"offset":\#(offset),"songs":[\#(slice.joined(separator: ","))],"total":\#(total)},"success":true}"#
            if mode == .stringified {
                return ((try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])) ?? Data(), response(url, 200, [:]))
            }
            return json(url, body)
        case "getinfo":
            let id = params["id"] ?? ""
            return json(url, #"{"data":{"songs":[{"id":"\#(id)","additional":{"song_rating":{"rating":\#(ratings[id] ?? 0)}}}]},"success":true}"#)
        case "setrating":
            if mode != .ratingIgnored, let id = params["id"], let rating = Int(params["rating"] ?? "") { ratings[id] = rating }
            return json(url, #"{"success":true}"#)
        default:
            return json(url, #"{"success":false,"error":{"code":103}}"#)
        }
    }

    private func playlistReply(_ url: URL, _ params: [String: String]) -> (Data, URLResponse) {
        switch params["method"] {
        case "list":
            return (Data([0xEF, 0xBB, 0xBF]) + Data(Fixtures.playlistList.utf8), response(url, 200, ["Content-Type": "application/json"]))
        case "getinfo":
            let id = params["id"] ?? ""
            let entries = [#"{"id":"music_6906","path":"/music/a.flac","title":"a"}"#,
                           #"{"id":"music_/volume1/music/日语/刘小慧 - 初恋情人.flac","path":"/music/日语/刘小慧 - 初恋情人.flac","title":"刘小慧 - 初恋情人.flac"}"#,
                           #"{"id":"music_6906","path":"/music/a.flac","title":"a"}"#]
            let offset = Int(params["songs_offset"] ?? "") ?? 0
            let limit = Int(params["songs_limit"] ?? "") ?? 0
            // 「坏掉」的歌单第二页总数变了。
            let total = id.hasSuffix("坏掉") && offset > 0 ? 4 : 3
            let page = entries.dropFirst(offset).prefix(limit).joined(separator: ",")
            return json(url, #"{"data":{"playlists":[{"additional":{"songs":[\#(page)],"songs_offset":\#(offset),"songs_total":\#(total)},"id":"\#(id)","library":"personal","name":"n","type":"normal"}]},"success":true}"#)
        case "create":
            return json(url, #"{"data":{"id":"playlist_personal_normal/\#(params["name"] ?? "")"},"success":true}"#)
        case "updatesongs":
            let songs = (params["songs"] ?? "").split(separator: ",").map(String.init)
            if params["skip_duplicate"] != "true", songs.contains(where: playlistSongs.contains) {
                return json(url, #"{"success":false,"error":{"code":411}}"#)
            }
            playlistSongs += songs.filter { !playlistSongs.contains($0) }
            return json(url, #"{"success":true}"#)
        default:
            return json(url, #"{"success":true}"#)
        }
    }

    /// 响应形状按 open-audio-server 与 streamish/music-server 两份独立的接口复刻:
    /// `radios` 数组 + `total`,条目的 `id` 由名字和地址拼成。
    private func radioReply(_ url: URL, _ params: [String: String]) -> (Data, URLResponse) {
        guard params["method"] == "list" else { return json(url, #"{"success":false,"error":{"code":103}}"#) }
        let entries: [String]
        switch params["container"] {
        case "Favorite":
            entries = [
                #"{"desc":"MP3 (128 kbps)","id":"radio_SmoothJazz.com Global http://yp.shoutcast.com/sbin/tunein-station.pls?id=1477271","title":"SmoothJazz.com Global","type":"station","url":"http://yp.shoutcast.com/sbin/tunein-station.pls?id=1477271"}"#,
                #"{"desc":"","id":"radio_Groove Salad https://ice5.somafm.com/groovesalad-128","title":"Groove Salad","type":"station","url":"https://ice5.somafm.com/groovesalad-128"}"#,
                #"{"desc":"","id":"SHOUTcast_genre_Jazz","title":"Jazz","type":"container","url":""}"#,
            ]
        case "UserDefined":
            entries = [
                // 与「我的最爱」里那台是同一个流,只差协议和末尾斜杠。
                #"{"desc":"","id":"radio_GS http://ice5.somafm.com/groovesalad-128/","title":"GS","type":"station","url":"http://ice5.somafm.com/groovesalad-128/"}"#,
                #"{"desc":"","id":"radio_ http://46.105.100.126:8000/stream","title":"  ","type":"station","url":"http://46.105.100.126:8000/stream"}"#,
                #"{"desc":"","id":"radio_坏 rtsp://e.test/live","title":"坏","type":"station","url":"rtsp://e.test/live"}"#,
                #"{"desc":"","id":"radio_新闻台 https://e.test/news/index.m3u8","title":"新闻台","type":"station","url":"https://e.test/news/index.m3u8"}"#,
            ]
        default:
            return json(url, #"{"success":false,"error":{"code":101}}"#)
        }
        let offset = Int(params["offset"] ?? "") ?? 0
        let limit = Int(params["limit"] ?? "") ?? 0
        let total = mode == .radioTotalChanges && offset > 0 ? entries.count + 1 : entries.count
        let page = entries.dropFirst(offset).prefix(limit).joined(separator: ",")
        return json(url, #"{"data":{"offset":\#(offset),"radios":[\#(page)],"total":\#(total)},"success":true}"#)
    }

    private func json(_ url: URL, _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), response(url, 200, ["Content-Type": "application/json; charset=utf-8"]))
    }

    private func response(_ url: URL, _ status: Int, _ fields: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    }
}

/// 真实 DSM 7.2 响应样本的节选;`serial_number` 与 `sid` 已替换成假值。
private enum Fixtures {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])

    static let apiInfo = #"{"data":{"SYNO.API.Auth":{"maxVersion":7,"minVersion":1,"path":"entry.cgi"},"SYNO.API.Info":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},"SYNO.AudioStation.Album":{"maxVersion":3,"minVersion":1,"path":"AudioStation/album.cgi"},"SYNO.AudioStation.Cover":{"maxVersion":3,"minVersion":1,"path":"AudioStation/cover.cgi"},"SYNO.AudioStation.Download":{"maxVersion":1,"minVersion":1,"path":"AudioStation/download.cgi"},"SYNO.AudioStation.Info":{"maxVersion":6,"minVersion":1,"path":"AudioStation/info.cgi"},"SYNO.AudioStation.Lyrics":{"maxVersion":2,"minVersion":1,"path":"AudioStation/lyrics.cgi"},"SYNO.AudioStation.Pin":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},"SYNO.AudioStation.Playlist":{"maxVersion":3,"minVersion":1,"path":"AudioStation/playlist.cgi"},"SYNO.AudioStation.Radio":{"maxVersion":2,"minVersion":1,"path":"AudioStation/radio.cgi"},"SYNO.AudioStation.Search":{"maxVersion":1,"minVersion":1,"path":"AudioStation/search.cgi"},"SYNO.AudioStation.Song":{"maxVersion":3,"minVersion":1,"path":"AudioStation/song.cgi"},"SYNO.AudioStation.Stream":{"maxVersion":2,"minVersion":1,"path":"AudioStation/stream.cgi"}},"success":true}"#

    static let info = #"{"data":{"ame_status":{"ame_major_version":4,"has_aac":false,"has_license":true,"is_aac_activated":false,"is_ame_broken":false,"is_ame_install":true,"need_aac_transcoding":false},"browse_personal_library":"all","dsd_decode_capability":true,"enable_equalizer":false,"enable_personal_library":false,"enable_user_home":true,"has_music_share":true,"is_manager":true,"playing_queue_max":8192,"privilege":{"playlist_edit":true,"remote_player":true,"sharing":true,"tag_edit":true,"upnp_browse":true},"remote_controller":false,"same_subnet":true,"serial_number":"0000000000000","settings":{"audio_show_virtual_library":true,"disable_upnp":false,"enable_download":true,"prefer_using_html5":true,"transcode_to_mp3":true},"sid":"FAKE-SID","support_bluetooth":false,"support_usb":false,"support_virtual_library":true,"transcode_capability":["wav","mp3"],"version":5516,"version_string":"7.2.0-5516"},"success":true}"#

    static let playlistList = #"{"data":{"offset":0,"playlists":[{"id":"playlist_personal_normal/__SYNO_AUDIO_SHARED_SONGS__","library":"personal","name":"__SYNO_AUDIO_SHARED_SONGS__","sharing_status":"none","type":"normal"},{"id":"playlist_personal_normal/开车","library":"personal","name":"开车","sharing_status":"none","type":"normal"},{"id":"playlist_personal_normal/放松","library":"personal","name":"放松","sharing_status":"none","type":"normal"},{"id":"playlist_personal_normal/欢快周杰伦","library":"personal","name":"欢快周杰伦","sharing_status":"none","type":"normal"},{"id":"playlist_personal_normal/粤语","library":"personal","name":"粤语","sharing_status":"none","type":"normal"},{"id":"playlist_shared_normal/1","library":"shared","name":"热门","path":"/music/playlists","sharing_status":"none","type":"normal"},{"id":"playlist_personal_smart/ぐされ","library":"personal","name":"ぐされ","sharing_status":"valid","type":"smart"}],"total":7},"success":true}"#

    static let tagEditorArray = #"[{"audioInfos":[{"album":"叶惠美","path":"/music/周杰伦/2003-叶惠美/周杰伦 - 东风破.FLAC","title":"东风破"}],"lyrics":"[00:00.00]东风破","codePage":"SYNO_NO_CODE_PAGE_CONVERT"}]"#

    static let catalogPage = #"{"data":{"offset":0,"songs":[\#(catalogEntries.joined(separator: ","))],"total":1505},"success":true}"#

    static let catalogEntries = [
        #"{"additional":{"song_audio":{"bitrate":883000,"channel":2,"codec":"flac","container":"flac","duration":262,"filesize":30255188,"frequency":44100},"song_rating":{"rating":0},"song_tag":{"album":"You're the only one","album_artist":"王菲","artist":"王菲","comment":"","composer":"","disc":4,"genre":"90年代; 90年代","track":3,"year":1990}},"id":"music_6908","path":"/music/王菲/1990-《You're the only one》/王菲 - 然后某天.flac","title":"然后某天","type":"file"}"#,
        #"{"additional":{"song_audio":{"bitrate":979000,"channel":2,"codec":"flac","container":"flac","duration":281,"filesize":35447117,"frequency":44100},"song_rating":{"rating":5},"song_tag":{"album":"粤语","album_artist":"刘小慧","artist":"刘小慧","comment":"","composer":"","disc":0,"genre":"","track":0,"year":0}},"id":"music_5961","path":"/music/刘小慧/刘小慧 - 初恋情人.flac","title":"初恋情人","type":"file"}"#,
        #"{"additional":{"song_audio":{"bitrate":320000,"channel":2,"codec":"wma","container":"wma","duration":207,"filesize":8344877,"frequency":44100},"song_rating":{"rating":4},"song_tag":{"album":"星辰大海","album_artist":"黄霄雲","artist":"黄霄雲","comment":"","composer":"","disc":0,"genre":"Blues","track":0,"year":0}},"id":"music_6148","path":"/music/喜欢/黄霄雲 - 星辰大海.wma","title":"星辰大海","type":"file"}"#,
        #"{"additional":{"song_audio":{"bitrate":0,"channel":2,"codec":"ape","container":"ape","duration":314,"filesize":33268000,"frequency":44100},"song_rating":{"rating":0},"song_tag":{"album":"嗯","album_artist":"李荣浩","artist":"李荣浩","comment":"酷我音乐","composer":"","disc":0,"genre":"","track":0,"year":0}},"id":"music_6467","path":"/music/李荣浩/嗯/李荣浩-就这样.ape","title":"就这样","type":"file"}"#,
        #"{"additional":{"song_audio":{"bitrate":929000,"channel":2,"codec":"flac","container":"flac","duration":204,"filesize":23876446,"frequency":44100},"song_rating":{"rating":0},"song_tag":{"album":"七里香","album_artist":"周杰伦","artist":"周杰伦","comment":"","composer":"","disc":1,"genre":"Pop; Folk, World, & Country; Pop; Folk, World, & Country; Pop; Folk, World, & Country; Pop; Folk, World, & Country; Pop; Folk, W","track":5,"year":2004}},"id":"music_6021","path":"/music/周杰伦/2004-七里香/周杰伦 - 将军.FLAC","title":"将军","type":"file"}"#,
        #"{"additional":{"song_audio":{"bitrate":760000,"channel":2,"codec":"flac","container":"flac","duration":265,"filesize":26352878,"frequency":48000},"song_rating":{"rating":5},"song_tag":{"album":"王菲-单曲","album_artist":"王菲","artist":"王菲","comment":"","composer":"","disc":0,"genre":"粤语; Pop","track":0,"year":2021}},"id":"music_6884","path":"/music/王菲/如愿-王菲.flac","title":"如愿-王菲","type":"file"}"#,
        #"{"additional":{"song_audio":{"bitrate":128000,"channel":2,"codec":"mp3","container":"mp3","duration":240,"filesize":3847039,"frequency":44100},"song_rating":{"rating":0},"song_tag":{"album":"粤语","album_artist":"","artist":"","comment":"","composer":"","disc":0,"genre":"","track":0,"year":0}},"id":"music_7026","path":"/music/粤语/17岁-刘德华.mp3","title":"17岁-刘德华","type":"file"}"#,
    ]

    static let pagedSongs = [
        #"{"additional":{"song_audio":{"bitrate":909000,"channel":2,"codec":"flac","container":"flac","duration":275,"filesize":32562676,"frequency":44100},"song_rating":{"rating":0},"song_tag":{"album":"You're the only one","album_artist":"王菲","artist":"王菲","comment":"","composer":"","disc":4,"genre":"90年代","track":1,"year":1990}},"id":"music_6906","path":"/music/王菲/1990-《You're the only one》/王菲 - 美丽的震荡.flac","title":"美丽的震荡","type":"file"}"#,
        catalogEntries[0],
        catalogEntries[1],
    ]

    static func catalogSongs() throws -> [SynologyAudioStationSong] {
        guard case .success(let page) = try SynologyAudioStationAPI.decode(SynologyAudioStationSongPage.self, from: Data(catalogPage.utf8)) else {
            throw SynologyAudioStationError.invalidResponse
        }
        return page.songs
    }
}
