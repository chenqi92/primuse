import Foundation
import Testing
@testable import PrimuseKit

struct MusicVideoCompatibilityPolicyTests {
    private typealias Policy = MusicVideoCompatibilityPolicy
    private static let phone = Policy.Platform(decodesAV1: false, decodesProRes: false)
    private static let newMac = Policy.Platform(decodesAV1: true, decodesProRes: true)

    @Test("Every scanned video extension is either native or rewritten")
    func everyVideoExtensionHasARoute() {
        for fileExtension in PrimuseConstants.supportedMusicVideoExtensions {
            let format = VideoFormat.from(fileExtension: fileExtension)
            #expect(format != nil, "\(fileExtension)")
            #expect(PrimuseConstants.supportedAudioExtensions.contains(fileExtension) == false)
        }
        for native in ["mp4", "m4v", "mov"] {
            #expect(VideoFormat.from(fileExtension: native)?.isNativelyPlayable == true)
            #expect(!Policy.needsConversion(path: "/MV/song.\(native)"))
        }
        let rewritten: [String: VideoFormat] = [
            "MKV": .mkv, "webm": .webm, "divx": .avi, "flv": .flv, "f4v": .f4v,
            "wmv": .wmv, "ts": .ts, "mts": .m2ts, "mpeg": .mpg, "vob": .vob,
            "rm": .rmvb, "rmvb": .rmvb, "ogv": .ogv, "3g2": .threeGP,
        ]
        for (fileExtension, format) in rewritten {
            #expect(VideoFormat.from(fileExtension: fileExtension) == format)
            #expect(Policy.needsConversion(path: "/MV/song.\(fileExtension)"))
        }
        // A server stream URL is the server's to make playable.
        #expect(!Policy.needsConversion(path: "https://nas.local/videos/song.mkv"))
        #expect(!Policy.needsConversion(path: "/MV/cover.jpg"))
    }

    @Test("Only streams AVPlayer decodes on every device are copied")
    func copyDecisions() {
        func video(_ codec: String, profile: Int = -99, depth: Int = 8, chroma420: Bool = true) -> Policy.Stream {
            Policy.Stream(kind: .video, codecName: codec, profile: profile, bitDepth: depth, chroma420: chroma420)
        }
        // H.264 up to High, 8-bit 4:2:0.
        #expect(Policy.canCopy(video("h264", profile: 100), on: Self.phone))
        #expect(Policy.canCopy(video("h264", profile: 578), on: Self.phone))
        #expect(Policy.canCopy(video("h264"), on: Self.phone))
        #expect(!Policy.canCopy(video("h264", profile: 110, depth: 10), on: Self.phone))
        #expect(!Policy.canCopy(video("h264", profile: 122, chroma420: false), on: Self.phone))
        // HEVC Main / Main 10.
        #expect(Policy.canCopy(video("hevc", profile: 2, depth: 10), on: Self.phone))
        #expect(!Policy.canCopy(video("hevc", profile: 4, chroma420: false), on: Self.phone))
        // AV1 only where VideoToolbox decodes it.
        #expect(!Policy.canCopy(video("av1"), on: Self.phone))
        #expect(Policy.canCopy(video("av1", depth: 10), on: Self.newMac))
        // ProRes only on the Mac.
        #expect(!Policy.canCopy(video("prores", chroma420: false), on: Self.phone))
        #expect(Policy.canCopy(video("prores", chroma420: false), on: Self.newMac))
        // Everything else is re-encoded.
        for codec in ["mpeg2video", "mpeg4", "vp9", "vp8", "wmv3", "vc1", "flv1", "rv40", "theora", "mjpeg"] {
            #expect(!Policy.canCopy(video(codec), on: Self.newMac), "\(codec)")
        }
        for codec in ["aac", "ac3", "eac3", "alac"] {
            #expect(Policy.canCopy(Policy.Stream(kind: .audio, codecName: codec), on: Self.phone))
        }
        // MP3 in MP4 opens in AVFoundation and then yields no audio.
        for codec in ["mp3", "opus", "vorbis", "flac", "mp2", "wmav2", "dts", "pcm_s16le", "cook"] {
            #expect(!Policy.canCopy(Policy.Stream(kind: .audio, codecName: codec), on: Self.newMac), "\(codec)")
        }
    }

    @Test("Cache eviction drops the least recently played until the rest fits")
    func evictionOrder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = [
            Policy.CacheEntry(name: "old.mp4", byteCount: 400, lastAccess: now.addingTimeInterval(-300)),
            Policy.CacheEntry(name: "older.mp4", byteCount: 300, lastAccess: now.addingTimeInterval(-600)),
            Policy.CacheEntry(name: "new.mp4", byteCount: 500, lastAccess: now),
        ]
        #expect(Policy.evictionVictims(entries, budget: 2_000, keeping: nil).isEmpty)
        #expect(Policy.evictionVictims(entries, budget: 900, keeping: nil) == ["older.mp4"])
        #expect(Policy.evictionVictims(entries, budget: 500, keeping: nil) == ["older.mp4", "old.mp4"])
        // The video about to play stays even when it alone exceeds the budget.
        #expect(Policy.evictionVictims(entries, budget: 100, keeping: "new.mp4") == ["older.mp4", "old.mp4"])
    }
}
