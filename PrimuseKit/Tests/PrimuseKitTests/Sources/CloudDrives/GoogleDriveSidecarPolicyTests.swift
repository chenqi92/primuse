import Foundation
import Testing
@testable import PrimuseKit

@Suite("Google Drive sidecar path policy")
struct GoogleDriveSidecarPolicyTests {
    @Test func parsesLyricsVirtualPath() {
        #expect(
            GoogleDriveSidecarPolicy.reference(from: "opaque-file-id.lrc")
                == GoogleDriveSidecarReference(
                    sourceFileID: "opaque-file-id",
                    suffix: ".lrc"
                )
        )
        #expect(
            GoogleDriveSidecarPolicy.reference(from: "opaque-file-id.ttml")
                == GoogleDriveSidecarReference(
                    sourceFileID: "opaque-file-id",
                    suffix: ".ttml"
                )
        )
    }

    @Test func parsesCoverVirtualPath() {
        #expect(
            GoogleDriveSidecarPolicy.reference(from: "opaque-file-id-cover.jpg")
                == GoogleDriveSidecarReference(
                    sourceFileID: "opaque-file-id",
                    suffix: "-cover.jpg"
                )
        )
    }

    @Test func rejectsUnsupportedOrEmptyVirtualPath() {
        #expect(GoogleDriveSidecarPolicy.reference(from: "opaque-file-id.txt") == nil)
        #expect(GoogleDriveSidecarPolicy.reference(from: ".lrc") == nil)
        #expect(GoogleDriveSidecarPolicy.reference(from: ".ttml") == nil)
        #expect(GoogleDriveSidecarPolicy.reference(from: "-cover.jpg") == nil)
    }

    @Test func buildsUnicodeSidecarNameFromSourceName() {
        #expect(
            GoogleDriveSidecarPolicy.targetName(
                sourceFileName: "组合字符 é 与中文.flac",
                suffix: ".lrc"
            ) == "组合字符 é 与中文.lrc"
        )
    }

    @Test func preservesAnExistingTTMLSidecar() {
        #expect(
            GoogleDriveSidecarPolicy.preferredLyricsSuffix(
                sourceFileName: "Track.flac",
                siblingNames: ["TRACK.TTML"]
            ) == ".ttml"
        )
        #expect(
            GoogleDriveSidecarPolicy.preferredLyricsSuffix(
                sourceFileName: "Track.flac",
                siblingNames: ["Track.ttml", "Track.lrc"]
            ) == ".lrc"
        )
        #expect(
            GoogleDriveSidecarPolicy.preferredLyricsSuffix(
                sourceFileName: "Track.flac",
                siblingNames: []
            ) == ".lrc"
        )
    }

    @Test func usesTextMIMETypesForEveryLyricsFormat() {
        #expect(GoogleDriveSidecarPolicy.mimeType(for: ".lrc") == "text/plain; charset=utf-8")
        #expect(
            GoogleDriveSidecarPolicy.mimeType(for: ".ttml")
                == "application/ttml+xml"
        )
        #expect(GoogleDriveSidecarPolicy.mimeType(for: "-cover.jpg") == "image/jpeg")
    }
}
