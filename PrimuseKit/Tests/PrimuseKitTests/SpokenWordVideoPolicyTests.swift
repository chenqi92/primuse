import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word video")
struct SpokenWordVideoPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func audioOnlyNeedsAContainerTheAudioPathOpens() {
        #expect(SpokenWordVideoPolicy.supportsAudioOnly(path: "/Podcasts/第一集.mp4", fallbackExtension: nil))
        #expect(SpokenWordVideoPolicy.supportsAudioOnly(path: "https://cdn.example.com/ep/1.MOV?sig=a.b", fallbackExtension: nil))
        #expect(SpokenWordVideoPolicy.supportsAudioOnly(path: "/Shows/x.m4v", fallbackExtension: "mp3"))
        #expect(!SpokenWordVideoPolicy.supportsAudioOnly(path: "/Shows/讲座.mkv", fallbackExtension: "mp3"))
        #expect(!SpokenWordVideoPolicy.supportsAudioOnly(path: "https://cdn.example.com/live/index.m3u8", fallbackExtension: "mp4"))
    }

    @Test func addressWithoutAContainerUsesTheMIMEGuess() {
        #expect(SpokenWordVideoPolicy.supportsAudioOnly(path: "https://dts.example.com/download.php?id=5", fallbackExtension: "mp4"))
        #expect(SpokenWordVideoPolicy.supportsAudioOnly(path: "https://dts.example.com/track/abc", fallbackExtension: "mov"))
        #expect(!SpokenWordVideoPolicy.supportsAudioOnly(path: "https://dts.example.com/track/abc", fallbackExtension: nil))
        // 地址明说是 MKV,按 MIME 猜的 mp4 不算。
        #expect(!SpokenWordVideoPolicy.supportsAudioOnly(path: "https://dts.example.com/1.mkv", fallbackExtension: "mp4"))
    }

    @Test func musicVideosKeepTheirRules() {
        // 音乐的独立 MV 一直放画面,不管有声那边的选择、车机和 MV 开关。
        #expect(SpokenWordVideoPolicy.usesVideoPipeline(
            isStandaloneVideo: true, hasSidecarVideo: false, isSpokenWord: false,
            showsSpokenWordVideo: false, musicVideoModeEnabled: false,
            forcesAudioOnly: true, supportsAudioOnly: true
        ))
        // 同名 MV 跟着 MV 开关,车机上只放声音。
        #expect(SpokenWordVideoPolicy.usesVideoPipeline(
            isStandaloneVideo: false, hasSidecarVideo: true, isSpokenWord: false,
            showsSpokenWordVideo: false, musicVideoModeEnabled: true,
            forcesAudioOnly: false, supportsAudioOnly: true
        ))
        #expect(!SpokenWordVideoPolicy.usesVideoPipeline(
            isStandaloneVideo: false, hasSidecarVideo: true, isSpokenWord: false,
            showsSpokenWordVideo: true, musicVideoModeEnabled: true,
            forcesAudioOnly: true, supportsAudioOnly: true
        ))
        #expect(!SpokenWordVideoPolicy.usesVideoPipeline(
            isStandaloneVideo: false, hasSidecarVideo: false, isSpokenWord: true,
            showsSpokenWordVideo: true, musicVideoModeEnabled: true,
            forcesAudioOnly: false, supportsAudioOnly: true
        ))
    }

    @Test func spokenWordVideoFollowsTheListenersChoice() {
        func uses(shows: Bool, car: Bool = false, audioOnly: Bool = true, failed: Bool = false) -> Bool {
            SpokenWordVideoPolicy.usesVideoPipeline(
                isStandaloneVideo: true, hasSidecarVideo: false, isSpokenWord: true,
                showsSpokenWordVideo: shows, musicVideoModeEnabled: false,
                forcesAudioOnly: car, supportsAudioOnly: audioOnly, videoFailed: failed
            )
        }
        #expect(uses(shows: true))
        #expect(!uses(shows: false))
        #expect(!uses(shows: true, car: true))
        #expect(!uses(shows: true, failed: true))
        // 只能走视频管线的(MKV 等),选了只听声音也照样放视频。
        #expect(uses(shows: false, audioOnly: false))
        #expect(uses(shows: true, car: true, audioOnly: false))
    }

    @Test func toggleOnlyForSwitchableSpokenWordVideoOnThisScreen() {
        #expect(SpokenWordVideoPolicy.offersToggle(
            isStandaloneVideo: true, isSpokenWord: true, supportsAudioOnly: true,
            forcesAudioOnly: false, isCasting: false
        ))
        #expect(!SpokenWordVideoPolicy.offersToggle(
            isStandaloneVideo: true, isSpokenWord: false, supportsAudioOnly: true,
            forcesAudioOnly: false, isCasting: false
        ))
        #expect(!SpokenWordVideoPolicy.offersToggle(
            isStandaloneVideo: true, isSpokenWord: true, supportsAudioOnly: false,
            forcesAudioOnly: false, isCasting: false
        ))
        #expect(!SpokenWordVideoPolicy.offersToggle(
            isStandaloneVideo: true, isSpokenWord: true, supportsAudioOnly: true,
            forcesAudioOnly: true, isCasting: false
        ))
        #expect(!SpokenWordVideoPolicy.offersToggle(
            isStandaloneVideo: true, isSpokenWord: true, supportsAudioOnly: true,
            forcesAudioOnly: false, isCasting: true
        ))
    }

    @Test func videoEpisodePointsItsVideoAtItself() {
        let video = PodcastEpisode(
            id: "podcast:v", showID: "s", guid: "g", title: "t",
            enclosureURL: URL(string: "https://cdn.example.com/ep/4")!, enclosureType: "video/quicktime", firstSeenAt: t0
        )
        #expect(video.isVideo)
        #expect(video.audioFileExtension == "mov")
        let song = PodcastPlaybackSong.song(for: video, show: nil)
        #expect(song.mvPath == "https://cdn.example.com/ep/4")
        #expect(song.isStandaloneMusicVideo)
        #expect(SpokenWordVideoPolicy.supportsAudioOnly(path: song.filePath, fallbackExtension: song.fileFormat.rawValue))

        let m4v = PodcastEpisode(
            id: "podcast:w", showID: "s", guid: "g2", title: "t",
            enclosureURL: URL(string: "https://cdn.example.com/ep/5")!, enclosureType: "video/x-m4v", firstSeenAt: t0
        )
        #expect(m4v.audioFileExtension == "m4v")

        let audio = PodcastEpisode(
            id: "podcast:a", showID: "s", guid: "g3", title: "t",
            enclosureURL: URL(string: "https://cdn.example.com/ep/6.m4a")!, enclosureType: "audio/mp4", firstSeenAt: t0
        )
        #expect(PodcastPlaybackSong.song(for: audio, show: nil).mvPath == nil)

        // AVPlayer 打不开的视频格式照旧只放声音,不挂视频。
        let webm = PodcastEpisode(
            id: "podcast:m", showID: "s", guid: "g4", title: "t",
            enclosureURL: URL(string: "https://cdn.example.com/ep/7")!, enclosureType: "video/webm", firstSeenAt: t0
        )
        #expect(webm.isVideo)
        #expect(!webm.playsAsVideo)
        #expect(PodcastPlaybackSong.song(for: webm, show: nil).mvPath == nil)
    }
}
