import Foundation
import Testing
@testable import PrimuseKit

struct PlaylistOperationAvailabilityTests {
    @Test func fileImportMatchesPlatformCapability() {
        #expect(PlaylistOperationAvailability.standard.supportsImport)
        #expect(!PlaylistOperationAvailability.television.supportsImport)
    }
}

@Suite struct PlaylistImportDestinationPolicyTests {
    private let likedNames = ["我喜欢", "我的最愛", "Liked Songs", "好きな曲", "Gefällt mir"]

    @Test func aMarkedExportOfTheLikedListGoesBackToTheLikedList() {
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "liked", playlistName: "Anything", likedPlaylistNames: likedNames
        ) == .likedSongs)
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: " Liked ", playlistName: "", likedPlaylistNames: []
        ) == .likedSongs)
    }

    @Test func aMarkerWinsOverTheNameSoARenamedOrdinaryPlaylistStaysOrdinary() {
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "playlist", playlistName: "Liked Songs", likedPlaylistNames: likedNames
        ) == .newPlaylist)
    }

    @Test func exportsWrittenBeforeTheMarkerAreRecognisedByNameInAnyLanguage() {
        for name in ["我喜欢", " liked songs ", "GEFALLT MIR", "Ｌｉｋｅｄ Ｓｏｎｇｓ", "好きな曲"] {
            #expect(PlaylistImportDestinationPolicy.suggestedDestination(
                kindMarker: nil, playlistName: name, likedPlaylistNames: likedNames
            ) == .likedSongs, "\(name)")
        }
        for name in ["Road Trip", "我喜欢的摇滚", "", "   "] {
            #expect(PlaylistImportDestinationPolicy.suggestedDestination(
                kindMarker: nil, playlistName: name, likedPlaylistNames: likedNames
            ) == .newPlaylist, "\(name)")
        }
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "", playlistName: "Liked Songs", likedPlaylistNames: likedNames
        ) == .likedSongs)
    }

    @Test func theM3UDirectiveRoundTripsAndOtherCommentsAreNotMarkers() {
        let line = PlaylistImportDestinationPolicy.m3uKindLine(
            marker: PlaylistImportDestinationPolicy.likedKindMarker
        )
        #expect(line == "#PRIMUSE-KIND:liked")
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: line) == "liked")
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "  #primuse-kind: liked  ") == "liked")
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "#PRIMUSE-KIND:") == nil)
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "#PLAYLIST:Liked Songs") == nil)
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "#EXTINF:200,Artist - Title") == nil)
    }
}

@Suite struct PlaylistImportMergePolicyTests {
    private typealias Policy = PlaylistImportMergePolicy

    private func key(_ title: String, _ artists: [String] = [], _ duration: Double? = nil) -> ExternalTrackMatchPolicy.Key {
        ExternalTrackMatchPolicy.Key(.init(title: title, artists: artists, duration: duration))
    }

    private func song(_ id: String, _ title: String, _ artists: [String] = [], _ duration: Double? = nil) -> Policy.Member {
        Policy.Member(id: id, key: key(title, artists, duration))
    }

    private func pending(_ suffix: String, _ title: String, _ artists: [String] = [], _ duration: Double? = nil) -> Policy.Member {
        Policy.Member(id: PlaylistPendingEntry.idPrefix + suffix, key: key(title, artists, duration))
    }

    @Test func anUpdatedFileGoesIntoThePlaylistOfTheSameName() {
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: nil, playlistName: "Road Trip", likedPlaylistNames: [], hasSameNamePlaylist: true
        ) == .existingPlaylist)
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "playlist", playlistName: "Road Trip", likedPlaylistNames: [], hasSameNamePlaylist: true
        ) == .existingPlaylist)
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: nil, playlistName: "Road Trip", likedPlaylistNames: [], hasSameNamePlaylist: false
        ) == .newPlaylist)
        // The liked list keeps its own destination even when a playlist shares its name.
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: nil, playlistName: "Liked Songs", likedPlaylistNames: ["Liked Songs"], hasSameNamePlaylist: true
        ) == .likedSongs)
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "liked", playlistName: "Road Trip", likedPlaylistNames: [], hasSameNamePlaylist: true
        ) == .likedSongs)
    }

    @Test func sameNameTargetsPutTheMostRecentlyChangedFirst() {
        let old = Policy.Target(id: "old", name: "Road Trip", updatedAt: Date(timeIntervalSince1970: 100))
        let recent = Policy.Target(id: "recent", name: " road trip ", updatedAt: Date(timeIntervalSince1970: 200))
        let wide = Policy.Target(id: "wide", name: "Ｒｏａｄ Ｔｒｉｐ", updatedAt: Date(timeIntervalSince1970: 50))
        let other = Policy.Target(id: "other", name: "Road Trip 2", updatedAt: Date(timeIntervalSince1970: 300))
        let first = Policy.Target(id: "first", name: "Jazz", updatedAt: Date(timeIntervalSince1970: 10))
        let targets = [first, old, other, recent, wide]

        #expect(Policy.sameNameTargets(targets, importedName: "Road Trip").map(\.id) == ["recent", "old", "wide"])
        #expect(Policy.orderedTargets(targets, importedName: "Road Trip").map(\.id)
            == ["recent", "old", "wide", "first", "other"])
        #expect(Policy.sameNameTargets(targets, importedName: "  ").isEmpty)
        #expect(Policy.orderedTargets(targets, importedName: "").map(\.id) == targets.map(\.id))
    }

    @Test func onlySongsTheListDoesNotHaveYetAreAppendedAndTheExistingOrderStays() {
        let existing = [song("b", "Blue", ["Ann"], 200), song("a", "Amber", ["Ben"], 180)]
        let incoming = [
            song("a", "Amber", ["Ben"], 180),
            song("c", "Cedar", ["Cy"], 210),
            song("b", "Blue", ["Ann"], 200),
            song("d", "Dune", ["Di"], 190),
            song("c", "Cedar", ["Cy"], 210),
        ]
        let plan = Policy.plan(existing: existing, incoming: incoming)
        #expect(plan.memberIDs == ["b", "a", "c", "d"])
        #expect(plan.appendedSongCount == 2)
        #expect(plan.alreadyPresentCount == 3)
        #expect(plan.hasChanges)
    }

    @Test func aCopyOfTheSameSongOnAnotherSourceCountsAsAlreadyThere() {
        let existing = [song("nas-blue", "Blue (Remastered)", ["Ann"], 200)]
        let incoming = [
            song("drive-blue", "Blue", ["Ann", "Guest"], 201.5),
            song("drive-blue-live", "Blue (Live)", ["Ann"], 260),
            song("drive-blue-cover", "Blue", ["Somebody Else"], 200),
        ]
        let plan = Policy.plan(existing: existing, incoming: incoming)
        #expect(plan.memberIDs == ["nas-blue", "drive-blue-live", "drive-blue-cover"])
        #expect(plan.alreadyPresentCount == 1)
    }

    @Test func aSongThatOnlyProbablyMatchesIsStillAdded() {
        let existing = [song("short", "Blue", ["Ann"], 200)]
        let plan = Policy.plan(existing: existing, incoming: [song("long", "Blue", ["Ann"], 207)])
        #expect(plan.memberIDs == ["short", "long"])
    }

    @Test func aGrayEntryLightsUpInPlaceWhenTheImportedSongIsIt() {
        let existing = [song("a", "Amber", ["Ben"]), pending("x", "Xanadu", ["Olivia"], 240), song("c", "Cedar", ["Cy"])]
        let incoming = [song("x1", "Xanadu", ["Olivia"], 241), song("x2", "Xanadu", ["Olivia"], 240)]
        let plan = Policy.plan(existing: existing, incoming: incoming)
        #expect(plan.memberIDs == ["a", "x1", "c"])
        #expect(plan.resolvedPendingCount == 1)
        #expect(plan.appendedSongCount == 0)
        #expect(plan.alreadyPresentCount == 1)
        #expect(plan.hasChanges)
    }

    @Test func grayEntriesAreNotRepeated() {
        let existing = [song("y", "Yesterday", ["The Beatles"], 125), pending("old", "Zephyr", ["Kai"])]
        let incoming = [
            pending("1", "Yesterday"),
            pending("2", "Zephyr", ["Kai"]),
            pending("3", "Nocturne", ["Lu"]),
            pending("4", "Nocturne", ["Lu"]),
            pending("5", "Nocturne", ["Someone Else"]),
        ]
        let plan = Policy.plan(existing: existing, incoming: incoming)
        let prefix = PlaylistPendingEntry.idPrefix
        #expect(plan.memberIDs == ["y", prefix + "old", prefix + "3", prefix + "5"])
        #expect(plan.appendedPendingIDs == [prefix + "3", prefix + "5"])
        #expect(plan.alreadyPresentCount == 3)
    }

    @Test func membersWithoutMetadataAreMatchedByIDOnly() {
        let existing = [Policy.Member(id: "hidden", key: nil), song("a", "Amber", ["Ben"])]
        let incoming = [
            Policy.Member(id: "hidden", key: nil),
            Policy.Member(id: "unknown", key: nil),
            song("hidden-copy", "Hidden", ["Nobody"]),
        ]
        let plan = Policy.plan(existing: existing, incoming: incoming)
        #expect(plan.memberIDs == ["hidden", "a", "unknown", "hidden-copy"])
        #expect(plan.appendedSongCount == 2)
    }

    @Test func importingTheSameFileAgainChangesNothing() {
        let existing = [song("a", "Amber", ["Ben"]), pending("p", "Pine", ["Pat"])]
        let plan = Policy.plan(
            existing: existing,
            incoming: [song("a", "Amber", ["Ben"]), pending("q", "Pine", ["Pat"])]
        )
        #expect(!plan.hasChanges)
        #expect(plan.memberIDs == existing.map(\.id))
        #expect(plan.alreadyPresentCount == 2)
    }
}

@Suite struct PlaylistBatchImportPolicyTests {
    private typealias Policy = PlaylistBatchImportPolicy

    private func candidate(
        _ destination: PlaylistImportDestination,
        name: String = "Road Trip",
        target: Bool = true,
        matched: Int = 10,
        missing: Int = 2,
        mergeHasChanges: Bool? = nil
    ) -> Policy.Candidate {
        Policy.Candidate(
            destination: destination,
            name: name,
            hasMergeTarget: target,
            matchedCount: matched,
            missingCount: missing,
            mergeHasChanges: mergeHasChanges
        )
    }

    @Test func aNewPlaylistNeedsANameAndSomethingToPutInIt() {
        #expect(Policy.isImportable(candidate(.newPlaylist), keepingMissing: false))
        #expect(!Policy.isImportable(candidate(.newPlaylist, name: "  \n"), keepingMissing: true))
        // 一首都没对上: 只有保留置灰时才建得出来。
        #expect(Policy.isImportable(candidate(.newPlaylist, matched: 0, missing: 3), keepingMissing: true))
        #expect(!Policy.isImportable(candidate(.newPlaylist, matched: 0, missing: 3), keepingMissing: false))
        #expect(!Policy.isImportable(candidate(.newPlaylist, matched: 0, missing: 0), keepingMissing: true))
    }

    @Test func theLikedListOnlyTakesMatchedSongs() {
        #expect(Policy.isImportable(candidate(.likedSongs, name: ""), keepingMissing: true))
        #expect(!Policy.isImportable(candidate(.likedSongs, matched: 0, missing: 5), keepingMissing: true))
    }

    @Test func aMergeNeedsATargetAndSomethingNew() {
        #expect(Policy.isImportable(candidate(.existingPlaylist), keepingMissing: true))
        #expect(Policy.isImportable(candidate(.existingPlaylist, mergeHasChanges: true), keepingMissing: true))
        #expect(!Policy.isImportable(candidate(.existingPlaylist, mergeHasChanges: false), keepingMissing: true))
        #expect(!Policy.isImportable(candidate(.existingPlaylist, target: false), keepingMissing: true))
    }

    @Test func eachSkippedCopySaysWhy() {
        #expect(Policy.skipReason(candidate(.newPlaylist, name: ""), keepingMissing: true) == .missingName)
        #expect(Policy.skipReason(candidate(.newPlaylist, matched: 0, missing: 4), keepingMissing: false) == .nothingToWrite)
        #expect(Policy.skipReason(candidate(.likedSongs, matched: 0, missing: 4), keepingMissing: true) == .nothingToWrite)
        #expect(Policy.skipReason(candidate(.existingPlaylist, target: false), keepingMissing: true) == .missingTarget)
        #expect(Policy.skipReason(candidate(.existingPlaylist, mergeHasChanges: false), keepingMissing: true) == .nothingNew)
        #expect(Policy.skipReason(candidate(.existingPlaylist, mergeHasChanges: true), keepingMissing: true) == nil)
    }

    @Test func theSummaryCountsWhatWillBeWrittenAndWhatIsSkipped() {
        let summary = Policy.summary([
            candidate(.newPlaylist, matched: 10, missing: 2),
            candidate(.newPlaylist, name: "", matched: 4, missing: 1),
            candidate(.existingPlaylist, matched: 6, missing: 3),
            candidate(.existingPlaylist, matched: 6, missing: 0, mergeHasChanges: false),
            candidate(.likedSongs, matched: 5, missing: 7),
        ], keepingMissing: true)
        #expect(summary.newPlaylistCount == 1)
        #expect(summary.mergedPlaylistCount == 1)
        #expect(summary.likedCount == 1)
        #expect(summary.importableCount == 3)
        #expect(summary.skippedCount == 2)
        #expect(summary.songCount == 21)
        // 「我喜欢」不留置灰。
        #expect(summary.pendingCount == 5)

        let withoutPending = Policy.summary([candidate(.newPlaylist, matched: 1, missing: 9)], keepingMissing: false)
        #expect(withoutPending.pendingCount == 0)
        #expect(withoutPending.importableCount == 1)
    }
}

@Suite struct ServerPlaylistCopyPolicyTests {
    private typealias Policy = ServerPlaylistCopyPolicy
    private typealias Target = PlaylistImportMergePolicy.Target

    @Test func aPlaylistCopiedBeforeGoesBackIntoTheSameServerPlaylist() {
        let older = Target(id: "mirror-old", name: "Road Trip", updatedAt: Date(timeIntervalSince1970: 100))
        let newer = Target(id: "mirror-new", name: " road trip ", updatedAt: Date(timeIntervalSince1970: 200))
        let other = Target(id: "mirror-other", name: "Focus", updatedAt: Date(timeIntervalSince1970: 300))
        #expect(Policy.destination(playlistName: "Road Trip", writablePlaylists: [older, other, newer], canCreate: true)
            == .append(playlistID: "mirror-new"))
        // 能不能新建不影响往同名歌单里加。
        #expect(Policy.destination(playlistName: "Road Trip", writablePlaylists: [older], canCreate: false)
            == .append(playlistID: "mirror-old"))
    }

    @Test func withoutASameNamePlaylistItIsCreatedOrTheServerNeedsOneFirst() {
        let other = Target(id: "mirror-other", name: "Focus", updatedAt: Date())
        #expect(Policy.destination(playlistName: "Road Trip", writablePlaylists: [other], canCreate: true) == .create)
        #expect(Policy.destination(playlistName: "Road Trip", writablePlaylists: [], canCreate: false) == .needsServerPlaylist)
        #expect(Policy.destination(playlistName: "", writablePlaylists: [other], canCreate: true) == .create)
    }
}
