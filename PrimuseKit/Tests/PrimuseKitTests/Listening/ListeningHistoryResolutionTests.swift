import Foundation
import Testing
@testable import PrimuseKit

struct ListeningHistoryResolutionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func song(
        _ id: String,
        title: String,
        artist: String? = "Stray Kids",
        album: String? = "SUIATSU",
        duration: TimeInterval = 180,
        sourceID: String = "primuse.appleMusic.system",
        filePath: String? = nil,
        cueSheetPath: String? = nil,
        cueStartTime: TimeInterval? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            albumTitle: album,
            artistName: artist,
            duration: duration,
            fileFormat: .flac,
            filePath: filePath ?? "/Music/\(id).flac",
            sourceID: sourceID,
            cueSheetPath: cueSheetPath,
            cueStartTime: cueStartTime
        )
    }

    @Test func multiVersionAlbumExactTitleResolvesBoostVersionWithoutDuration() {
        let original = song("iphone-orig", title: "SUIATSU", duration: 190)
        let deep = song("iphone-deep", title: "SUIATSU (Deep Version)", duration: 225)
        let boost = song("iphone-boost", title: "SUIATSU (Boost Version)", duration: 165)
        let library = [original, deep, boost]

        let macPlay = HomeListeningEvent(
            songID: "mac-boost",
            playedAt: date(25),
            listenedSeconds: 165,
            songTitle: "SUIATSU (Boost Version)",
            artistName: "Stray Kids",
            albumTitle: "SUIATSU",
            songDuration: nil,
            sourceID: "primuse.appleMusic.system"
        )

        let candidates = ListeningSongIdentity.libraryCandidates(events: [macPlay], songs: library)
        #expect(candidates == ["mac-boost": ["iphone-boost"]])

        for category in [HomeListeningCategory.songs, .albums, .artists] {
            let ranks = HomeListeningRanking.ranks(
                events: [macPlay],
                librarySongs: library,
                folders: nil,
                period: .week,
                category: category,
                now: date(27),
                calendar: calendar
            )
            #expect(ranks.count == 1)
            #expect(ranks.first?.songGroups == [["mac-boost", "iphone-boost"]])
            #expect(ranks.first?.distinctSongIDs(preferring: { $0.hasPrefix("iphone-") }) == ["iphone-boost"])
        }
    }

    @Test func distinctMissingVersionsWithoutDurationStaySeparateInRanking() {
        let original = song("iphone-orig", title: "SUIATSU", duration: 190)
        let boost = song("iphone-boost", title: "SUIATSU (Boost Version)", duration: 165)
        let library = [original, boost]

        let events = [
            HomeListeningEvent(
                songID: "mac-orig", playedAt: date(25), listenedSeconds: 190,
                songTitle: "SUIATSU", artistName: "Stray Kids", albumTitle: "SUIATSU",
                songDuration: nil, sourceID: "primuse.appleMusic.system"
            ),
            HomeListeningEvent(
                songID: "mac-boost", playedAt: date(26), listenedSeconds: 165,
                songTitle: "SUIATSU (Boost Version)", artistName: "Stray Kids", albumTitle: "SUIATSU",
                songDuration: nil, sourceID: "primuse.appleMusic.system"
            ),
            HomeListeningEvent(
                songID: "mac-boost", playedAt: date(27), listenedSeconds: 165,
                songTitle: "SUIATSU (Boost Version)", artistName: "Stray Kids", albumTitle: "SUIATSU",
                songDuration: nil, sourceID: "primuse.appleMusic.system"
            ),
        ]

        let ranks = HomeListeningRanking.ranks(
            events: events,
            librarySongs: library,
            folders: nil,
            period: .week,
            category: .songs,
            now: date(27),
            calendar: calendar
        )
        #expect(ranks.count == 2)
        #expect(ranks[0].title == "SUIATSU (Boost Version)")
        #expect(ranks[0].distinctSongIDs(preferring: { $0.hasPrefix("iphone-") }) == ["iphone-boost"])
        #expect(ranks[1].title == "SUIATSU")
        #expect(ranks[1].distinctSongIDs(preferring: { $0.hasPrefix("iphone-") }) == ["iphone-orig"])
    }

    @Test func sameSourcePathResolvesDifferentSongIDEvenBeforeTagsBackfill() {
        let untaggedOnPhone = song(
            "iphone-fsid",
            title: "07 SUIATSU (Boost Version)",
            artist: nil,
            album: nil,
            duration: 0,
            sourceID: "baidu-1",
            filePath: "/Music/Stray Kids/07 SUIATSU (Boost Version).flac"
        )
        let macEvent = HomeListeningEvent(
            songID: "mac-legacy-path-id",
            playedAt: date(26),
            listenedSeconds: 165,
            songTitle: "SUIATSU (Boost Version)",
            artistName: "Stray Kids",
            albumTitle: "SUIATSU",
            songDuration: 165,
            sourceID: "baidu-1",
            filePath: "/Music/Stray Kids/07 SUIATSU (Boost Version).flac"
        )

        #expect(
            ListeningSongIdentity.libraryCandidates(events: [macEvent], songs: [untaggedOnPhone])
                == ["mac-legacy-path-id": ["iphone-fsid"]]
        )

        var overwritten = untaggedOnPhone
        overwritten.duration = 320
        #expect(ListeningSongIdentity.libraryCandidates(events: [macEvent], songs: [overwritten]).isEmpty)
    }

    @Test func cueSheetMultiTrackPathRequiresTitleConfirmationAndRejectsUnmatchedTrack() {
        let track1 = song(
            "cue-1", title: "SUIATSU", duration: 190,
            sourceID: "nas-1", filePath: "/Albums/SUIATSU/Disc.flac",
            cueSheetPath: "/Albums/SUIATSU/Disc.cue", cueStartTime: 0
        )
        let track7 = song(
            "cue-7", title: "SUIATSU (Boost Version)", duration: 165,
            sourceID: "nas-1", filePath: "/Albums/SUIATSU/Disc.flac",
            cueSheetPath: "/Albums/SUIATSU/Disc.cue", cueStartTime: 1000
        )

        let boostEvent = HomeListeningEvent(
            songID: "mac-cue-7", playedAt: date(26), listenedSeconds: 165,
            songTitle: "SUIATSU (Boost Version)", artistName: "Stray Kids", albumTitle: "SUIATSU",
            sourceID: "nas-1", filePath: "/Albums/SUIATSU/Disc.flac"
        )
        #expect(
            ListeningSongIdentity.libraryCandidates(events: [boostEvent], songs: [track1, track7])
                == ["mac-cue-7": ["cue-7"]]
        )

        let unrelatedEvent = HomeListeningEvent(
            songID: "mac-cue-9", playedAt: date(26), listenedSeconds: 180,
            songTitle: "Other Track", artistName: "Stray Kids", albumTitle: "SUIATSU",
            sourceID: "nas-1", filePath: "/Albums/SUIATSU/Disc.flac"
        )
        #expect(ListeningSongIdentity.libraryCandidates(events: [unrelatedEvent], songs: [track1, track7]).isEmpty)
        // Even if only one CUE track is present in the library, never match a different track on that sheet.
        #expect(ListeningSongIdentity.libraryCandidates(events: [unrelatedEvent], songs: [track1]).isEmpty)
    }

    #if canImport(CryptoKit)
    @Test func navidromeCanonicalSubsonicPathResolvesAcrossIDReencoding() {
        let legacyHexID = "0123456789abcdef0123456789abcdef"
        let canonicalID = NavidromeCanonicalIDPolicy.canonicalID(legacyHexID)
        #expect(canonicalID != legacyHexID)

        let phoneSong = song(
            "iphone-b62",
            title: "Untagged",
            artist: nil,
            album: nil,
            duration: 0,
            sourceID: "navidrome-1",
            filePath: "/songs/\(canonicalID).flac"
        )
        let macEvent = HomeListeningEvent(
            songID: "mac-hex",
            playedAt: date(26),
            listenedSeconds: 180,
            songTitle: "One Fifth",
            artistName: "One Fifth",
            albumTitle: "5分之1",
            sourceID: "navidrome-1",
            filePath: "/songs/\(legacyHexID).flac"
        )

        let requirements = ListeningSongIdentity.candidateFilterRequirements(for: [macEvent])
        #expect(!requirements.subsonicCanonicalKeys.isEmpty)
        #expect(requirements.matches(phoneSong))
        #expect(
            ListeningSongIdentity.libraryCandidates(events: [macEvent], songs: [phoneSong])
                == ["mac-hex": ["iphone-b62"]]
        )
    }
    #endif

    @Test func normalizedAlbumMatchesTraditionalSimplifiedAndEPSuffixWhileRejectingOtherAlbum() {
        let simplified = song(
            "iphone-cn", title: "好心分手", artist: "卢巧音", album: "天演论", duration: 181, sourceID: "nas-1"
        )
        let traditionalEvent = HomeListeningEvent(
            songID: "mac-tc", playedAt: date(26), listenedSeconds: 180,
            songTitle: "好心分手", artistName: "盧巧音", albumTitle: "天演論"
        )
        #expect(
            ListeningSongIdentity.libraryCandidates(events: [traditionalEvent], songs: [simplified])
                == ["mac-tc": ["iphone-cn"]]
        )

        let epSong = song("iphone-ep", title: "SUIATSU", artist: "Stray Kids", album: "SUIATSU", duration: 190)
        let epEvent = HomeListeningEvent(
            songID: "mac-ep", playedAt: date(26), listenedSeconds: 190,
            songTitle: "SUIATSU", artistName: "Stray Kids", albumTitle: "SUIATSU - EP"
        )
        #expect(
            ListeningSongIdentity.libraryCandidates(events: [epEvent], songs: [epSong])
                == ["mac-ep": ["iphone-ep"]]
        )

        let wrongAlbumEvent = HomeListeningEvent(
            songID: "mac-other", playedAt: date(26), listenedSeconds: 190,
            songTitle: "SUIATSU", artistName: "Stray Kids", albumTitle: "Different Album"
        )
        #expect(ListeningSongIdentity.libraryCandidates(events: [wrongAlbumEvent], songs: [epSong]).isEmpty)
    }

    @Test func sameSourceOrdersFirstDisambiguatesDurationAndAttributesFoldersWithoutCrossSourceBleed() {
        let sourceA = song(
            "a-song", title: "One Fifth", artist: "One Fifth", album: "5分之1",
            duration: 200, sourceID: "source-a", filePath: "/Music/A/One Fifth.flac"
        )
        let sourceB = song(
            "b-song", title: "One Fifth", artist: "One Fifth", album: "5分之1",
            duration: 200, sourceID: "source-b", filePath: "/Music/B/One Fifth.flac"
        )

        let eventFromB = HomeListeningEvent(
            songID: "mac-b", playedAt: date(26), listenedSeconds: 200,
            songTitle: "One Fifth", artistName: "One Fifth", albumTitle: "5分之1",
            sourceID: "source-b"
        )
        #expect(
            ListeningSongIdentity.libraryCandidates(events: [eventFromB], songs: [sourceA, sourceB])
                == ["mac-b": ["b-song", "a-song"]]
        )

        var conflictingA = sourceA
        conflictingA.duration = 250
        #expect(
            ListeningSongIdentity.libraryCandidates(events: [eventFromB], songs: [conflictingA, sourceB])
                == ["mac-b": ["b-song"]]
        )

        let folders = LibraryFolderIndexBuilder.build(
            sources: [
                LibraryFolderSourceDescriptor(
                    sourceID: "source-a", displayName: "Source A", scanRoots: ["/Music"], pathSemantics: .hierarchical
                ),
                LibraryFolderSourceDescriptor(
                    sourceID: "source-b", displayName: "Source B", scanRoots: ["/Music"], pathSemantics: .hierarchical
                ),
            ],
            songs: [sourceA, sourceB]
        )
        let sameSourceFolderRanks = HomeListeningRanking.ranks(
            events: [eventFromB],
            librarySongs: [sourceA, sourceB],
            folders: folders,
            period: .week,
            category: .folders,
            now: date(27),
            calendar: calendar
        )
        #expect(sameSourceFolderRanks.count == 1)
        #expect(sameSourceFolderRanks.first?.title == "B")

        let eventFromOtherSource = HomeListeningEvent(
            songID: "mac-c", playedAt: date(26), listenedSeconds: 200,
            songTitle: "One Fifth", artistName: "One Fifth", albumTitle: "5分之1",
            sourceID: "source-c"
        )
        let crossSourceFolderRanks = HomeListeningRanking.ranks(
            events: [eventFromOtherSource],
            librarySongs: [sourceA, sourceB],
            folders: folders,
            period: .week,
            category: .folders,
            now: date(27),
            calendar: calendar
        )
        #expect(crossSourceFolderRanks.isEmpty)
    }

    @Test func candidateFilterRequirementsExcludesDisabledSourcesForPathsWhileKeepingMetadataTitles() {
        let disabledSong = song(
            "disabled-1", title: "SUIATSU (Boost Version)",
            sourceID: "source-disabled", filePath: "/Music/Boost.flac"
        )
        let enabledSong = song(
            "enabled-1", title: "SUIATSU (Boost Version)",
            sourceID: "source-enabled", filePath: "/Other/Boost.flac"
        )
        let untaggedDisabled = song(
            "disabled-2", title: "07", artist: nil, album: nil,
            sourceID: "source-disabled", filePath: "/Music/Boost.flac"
        )
        let event = HomeListeningEvent(
            songID: "mac-1", playedAt: date(26), listenedSeconds: 165,
            songTitle: "SUIATSU (Boost Version)", artistName: "Stray Kids", albumTitle: "SUIATSU",
            sourceID: "source-disabled", filePath: "/Music/Boost.flac"
        )

        let filtered = ListeningSongIdentity.candidateFilterRequirements(for: [event])
            .filteringDisabledSources(["source-disabled"])
        #expect(filtered.sourcePaths.isEmpty)
        #expect(!filtered.matches(untaggedDisabled))
        #expect(filtered.matches(enabledSong))
        #expect(filtered.matches(disabledSong))
    }
}
