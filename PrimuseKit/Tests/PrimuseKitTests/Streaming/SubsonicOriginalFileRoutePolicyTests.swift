import Foundation
import Testing
@testable import PrimuseKit

@Suite("Subsonic original file route")
struct SubsonicOriginalFileRoutePolicyTests {
    @Test func disabledDownloadsAreRecognized() {
        // Navidrome 关掉下载: HTTP 200 + Subsonic 错误 50。
        #expect(SubsonicOriginalFileRoutePolicy.downloadIsRejected(httpStatus: nil, subsonicErrorCode: 50))
        // 代理或别的实现直接回 403。
        #expect(SubsonicOriginalFileRoutePolicy.downloadIsRejected(httpStatus: 403, subsonicErrorCode: nil))
    }

    @Test func failuresAnotherEndpointCannotFixKeepTheirError() {
        for code in [0, 10, 40, 41, 70] {
            #expect(!SubsonicOriginalFileRoutePolicy.downloadIsRejected(httpStatus: nil, subsonicErrorCode: code))
        }
        for status in [401, 404, 500, 503] {
            #expect(!SubsonicOriginalFileRoutePolicy.downloadIsRejected(httpStatus: status, subsonicErrorCode: nil))
        }
        #expect(!SubsonicOriginalFileRoutePolicy.downloadIsRejected(httpStatus: nil, subsonicErrorCode: nil))
    }

    @Test func rawStreamOfTheSameContainerIsTheOriginal() {
        let cases: [(String, AudioFileSignatureKind)] = [
            ("flac", .flac), ("mp3", .mpegAudio), ("m4a", .isoBaseMedia), ("m4b", .isoBaseMedia),
            ("alac", .isoBaseMedia), ("opus", .ogg), ("ogg", .ogg), ("wav", .riffWave),
            ("wav", .dtsInWave), ("aac", .adtsAAC), ("aiff", .aiff), ("wma", .asf), ("ape", .monkeyAudio),
            (".FLAC", .flac),
        ]
        for (declared, signature) in cases {
            #expect(!SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(
                declaredExtension: declared,
                signature: signature
            ))
        }
    }

    @Test func rawStreamInAnotherCodecIsATranscode() {
        #expect(SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "flac", signature: .mpegAudio))
        #expect(SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "wav", signature: .ogg))
        #expect(SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "m4a", signature: .adtsAAC))
        #expect(SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "wma", signature: .mpegAudio))
    }

    @Test func unrecognizedSidesAreNotBlocked() {
        #expect(!SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "flac", signature: .unknown))
        #expect(!SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "xyz", signature: .mpegAudio))
        #expect(!SubsonicOriginalFileRoutePolicy.rawStreamLooksTranscoded(declaredExtension: "", signature: .flac))
    }
}
