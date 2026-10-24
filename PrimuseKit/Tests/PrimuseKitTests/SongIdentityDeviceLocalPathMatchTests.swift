import Foundation
import Testing
@testable import PrimuseKit

@Suite("Device-local path match")
struct SongIdentityDeviceLocalPathMatchTests {
    private func identity(
        title: String = "Song",
        duration: Double = 200,
        cloudAccountID: String? = nil,
        filePath: String = "/Album/Song.mp3"
    ) -> SongIdentity {
        SongIdentity(
            songID: "sender-id", title: title, artistName: "Artist",
            duration: duration, cloudAccountID: cloudAccountID, filePath: filePath
        )
    }

    private typealias Candidate = SongIdentityDeviceLocalPathMatch.Candidate

    /// 另一台设备读完了标签,这台刚导入、还是文件名当歌名、没有时长:同一个相对路径照样认得出。
    @Test func aFreshlyImportedRowMatchesTheSenderByPath() {
        let bare = Candidate(songID: "receiver-id", title: "01 Song", duration: 0)
        #expect(SongIdentityDeviceLocalPathMatch.match(identity(), among: [bare]) == "receiver-id")

        // 反过来:发送方加歌时还没读标签,记下的是文件名和 0 秒。
        let read = Candidate(songID: "receiver-id", title: "Song", duration: 200)
        #expect(SongIdentityDeviceLocalPathMatch.match(
            identity(title: "01 Song", duration: 0), among: [read]
        ) == "receiver-id")
    }

    @Test func aDurationBothSidesKnowVetoesTheMatch() {
        let other = Candidate(songID: "receiver-id", title: "Song", duration: 260)
        #expect(SongIdentityDeviceLocalPathMatch.match(identity(), among: [other]) == nil)

        let close = Candidate(songID: "receiver-id", title: "Song", duration: 201.5)
        #expect(SongIdentityDeviceLocalPathMatch.match(identity(), among: [close]) == "receiver-id")
    }

    @Test func theSameTitleWinsAmongFilesAtOnePath() {
        let first = Candidate(songID: "first", title: "Other", duration: 0)
        let titled = Candidate(songID: "titled", title: "Song", duration: 0)
        #expect(SongIdentityDeviceLocalPathMatch.match(identity(), among: [first, titled]) == "titled")
        #expect(SongIdentityDeviceLocalPathMatch.match(identity(title: ""), among: [first, titled]) == "first")
    }

    /// 云账号的歌走账号 + 路径那一级;没有文件名的路径不算。
    @Test func cloudAccountsAndPathsWithoutAFileAreNotEligible() {
        let candidate = Candidate(songID: "receiver-id", title: "Song", duration: 200)
        #expect(SongIdentityDeviceLocalPathMatch.match(
            identity(cloudAccountID: "account"), among: [candidate]
        ) == nil)
        for path in ["", "/", "/Album", "Album/"] {
            #expect(!SongIdentityDeviceLocalPathMatch.isEligible(identity(filePath: path)), "\(path)")
        }
        #expect(SongIdentityDeviceLocalPathMatch.isEligible(identity(filePath: "/a.flac")))
    }
}

@Suite("Artwork song identity on device-local files")
struct LibraryArtworkDeviceLocalIdentityTests {
    /// 歌单封面选了另一台设备上本机文件里的一首:这台按相对路径认出来以后, 复核也要认。
    @Test func aDeviceLocalFileAtTheSamePathStillMatches() {
        let identity = SongIdentity(
            songID: "other-device-song", title: "Song", artistName: "Artist",
            duration: 200, cloudAccountID: nil, filePath: "/Album/01 Song.mp3"
        )
        func matches(local: Bool, duration: Double, path: String = "/Album/01 Song.mp3") -> Bool {
            LibraryArtworkSongResolutionCachePolicy.song(
                title: "01 Song", artistName: nil, duration: duration, filePath: path,
                cloudAccountID: { nil }, isDeviceLocalFile: { local }, matches: identity
            )
        }
        #expect(matches(local: true, duration: 0))
        #expect(!matches(local: false, duration: 0))
        #expect(!matches(local: true, duration: 260))
        #expect(!matches(local: true, duration: 0, path: "/Album/02 Other.mp3"))
    }
}
