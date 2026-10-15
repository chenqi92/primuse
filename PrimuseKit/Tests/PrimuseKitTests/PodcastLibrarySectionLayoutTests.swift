import Foundation
import Testing
@testable import PrimuseKit

@Suite("Podcast page section order and visibility")
struct PodcastLibrarySectionLayoutTests {
    @Test("Nothing stored shows every section in the default order and stores nothing")
    func emptyStorageIsDefault() {
        let layout = PodcastLibrarySectionLayout.decode("")
        #expect(layout.visibleSections == [.myShows, .continueListening, .latestEpisodes, .likedEpisodes, .localShows])
        #expect(layout.isDefault)
        #expect(layout.encoded.isEmpty)
    }

    @Test("Moving liked episodes above latest episodes round-trips through storage")
    func moveRoundTrips() {
        var layout = PodcastLibrarySectionLayout()
        // List onMove: drag index 3 (liked) to before index 2 (latest).
        layout.move(fromOffsets: IndexSet(integer: 3), toOffset: 2)
        #expect(layout.order == [.myShows, .continueListening, .likedEpisodes, .latestEpisodes, .localShows])
        let restored = PodcastLibrarySectionLayout.decode(layout.encoded)
        #expect(restored == layout)
    }

    @Test("Moving down uses the onMove destination convention")
    func moveDown() {
        var layout = PodcastLibrarySectionLayout()
        // Drag the first row below the third: destination is the index after it.
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(layout.order == [.continueListening, .latestEpisodes, .myShows, .likedEpisodes, .localShows])
    }

    @Test("My shows cannot be hidden; other sections can")
    func myShowsStaysVisible() {
        var layout = PodcastLibrarySectionLayout()
        layout.setVisible(false, for: .myShows)
        layout.setVisible(false, for: .localShows)
        #expect(layout.isVisible(.myShows))
        #expect(!layout.isVisible(.localShows))
        #expect(!layout.visibleSections.contains(.localShows))

        // A hand-edited or older archive hiding my shows is ignored.
        let decoded = PodcastLibrarySectionLayout.decode(#"{"hidden":["myShows","likedEpisodes"],"order":[]}"#)
        #expect(decoded.isVisible(.myShows))
        #expect(!decoded.isVisible(.likedEpisodes))
    }

    @Test("Unknown and duplicate names are dropped, missing sections come back next to their neighbour")
    func archiveIsNormalised() {
        let decoded = PodcastLibrarySectionLayout.decode(
            #"{"hidden":["retired"],"order":["likedEpisodes","likedEpisodes","retired","myShows","latestEpisodes"]}"#
        )
        // Missing sections follow their default predecessor: continue after my shows, local shows after liked.
        #expect(decoded.order == [.likedEpisodes, .localShows, .myShows, .continueListening, .latestEpisodes])
        #expect(decoded.hidden.isEmpty)
    }

    @Test("A corrupt archive falls back to the default")
    func corruptArchive() {
        #expect(PodcastLibrarySectionLayout.decode("not json").isDefault)
    }
}
