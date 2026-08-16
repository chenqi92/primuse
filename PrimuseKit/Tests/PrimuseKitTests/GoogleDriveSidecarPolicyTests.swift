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
}
