import Testing
@testable import PrimuseKit

@Suite("External display content mode")
struct ExternalDisplayContentModeTests {
    @Test("Unset or unknown values keep the artwork-and-lyrics page")
    func defaultsToNowPlaying() {
        #expect(ExternalDisplayContentMode(storedValue: nil) == .nowPlaying)
        #expect(ExternalDisplayContentMode(storedValue: "") == .nowPlaying)
        #expect(ExternalDisplayContentMode(storedValue: "slideshow") == .nowPlaying)
    }

    @Test("Stored choices round-trip")
    func storedChoicesRoundTrip() {
        for mode in ExternalDisplayContentMode.allCases {
            #expect(ExternalDisplayContentMode(storedValue: mode.rawValue) == mode)
        }
    }

    @Test("Only mirroring leaves the external display to the system")
    func onlyMirroringSkipsOwnContent() {
        #expect(ExternalDisplayContentMode.nowPlaying.drawsOwnContent)
        #expect(ExternalDisplayContentMode.immersive.drawsOwnContent)
        #expect(!ExternalDisplayContentMode.mirror.drawsOwnContent)
    }
}
