import Testing
@testable import PrimuseKit

@Suite("Local-first snapshot bootstrap")
struct LocalFirstSnapshotBootstrapTests {
    @Test("Local songs stay visible while automatic synchronization waits")
    @MainActor
    func publishesLocalSongsBeforeDownload() async {
        var visibleSongCount = 0
        var observedDuringDownload: [Int] = []
        var mergeBaseline: Int?

        await LocalFirstSnapshotBootstrap.run(
            publishLocal: {
                visibleSongCount = 12
                return visibleSongCount
            },
            download: {
                observedDuringDownload.append(visibleSongCount)
                await Task.yield()
                observedDuringDownload.append(visibleSongCount)
            },
            applyDownloaded: { localCount in
                mergeBaseline = localCount
                visibleSongCount = 13
            }
        )

        #expect(observedDuringDownload == [12, 12])
        #expect(mergeBaseline == 12)
        #expect(visibleSongCount == 13)
    }
}
