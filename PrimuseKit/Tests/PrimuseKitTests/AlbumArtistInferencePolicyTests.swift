import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album artist inference")
struct AlbumArtistInferencePolicyTests {
    private func track(
        _ id: String,
        sourceID: String = "source",
        directory: String? = "/music/ost",
        albumTitle: String? = "鸣潮 原声带",
        albumArtistName: String? = nil,
        trackArtistName: String? = nil
    ) -> AlbumArtistInferencePolicy.Track {
        AlbumArtistInferencePolicy.Track(
            id: id,
            sourceID: sourceID,
            directory: directory,
            albumTitle: albumTitle,
            albumArtistName: albumArtistName,
            trackArtistName: trackArtistName
        )
    }

    /// A lone track in a second folder. It makes the source directory
    /// authoritative without forming a scope of its own (scopes need ≥ 2).
    private var neighbourFolderTrack: AlbumArtistInferencePolicy.Track {
        track(
            "neighbour",
            directory: "/music/other",
            albumTitle: "别的专辑",
            trackArtistName: "别人"
        )
    }

    @Test func untaggedSiblingsAdoptTheOnlyExplicitAlbumArtist() {
        let tracks = [
            track("1", albumArtistName: "鸣潮先约电台", trackArtistName: "作曲家甲"),
            track("2", trackArtistName: "作曲家乙"),
            track("3", trackArtistName: "鸣潮先约电台"),
            neighbourFolderTrack,
        ]

        let result = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)

        // 1 already carries the tag and 3 already resolves to it; only 2 moves.
        #expect(result == ["2": "鸣潮先约电台"])
    }

    @Test func conflictingExplicitAlbumArtistsLeaveTheFolderAlone() {
        let tracks = [
            track("1", albumArtistName: "Label A", trackArtistName: "Composer A"),
            track("2", albumArtistName: "Label B", trackArtistName: "Composer B"),
            track("3", trackArtistName: "Composer C"),
            neighbourFolderTrack,
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
    }

    @Test func dominantTrackArtistAbsorbsTheMinorityAndTheUntaggedTrack() {
        let tracks = [
            track("1", trackArtistName: "鸣潮先约电台"),
            track("2", trackArtistName: "鸣潮先约电台"),
            track("3", trackArtistName: "鸣潮先约电台"),
            track("4", trackArtistName: "作曲家甲"),
            track("5", trackArtistName: nil),
            neighbourFolderTrack,
        ]

        let result = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)

        #expect(result == ["4": "鸣潮先约电台", "5": "鸣潮先约电台"])
    }

    @Test func aTieOrAllDistinctTrackArtistsInferNothing() {
        let halved = [
            track("1", trackArtistName: "A"),
            track("2", trackArtistName: "A"),
            track("3", trackArtistName: "B"),
            track("4", trackArtistName: "B"),
            neighbourFolderTrack,
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: halved).isEmpty)

        let compilation = [
            track("1", trackArtistName: "A"),
            track("2", trackArtistName: "B"),
            track("3", trackArtistName: "C"),
            neighbourFolderTrack,
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: compilation).isEmpty)
    }

    @Test func differentFoldersAndDifferentTitlesNeverInteract() {
        let tracks = [
            track("1", directory: "/music/a", trackArtistName: "Host"),
            track("2", directory: "/music/a", trackArtistName: "Host"),
            track("3", directory: "/music/b", trackArtistName: "Guest"),
            track("4", directory: "/music/a", albumTitle: "Other", trackArtistName: "Guest"),
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
    }

    /// A source without real folders gets no majority vote: its scope spans a
    /// whole album title, where a majority could rename a same-titled album by
    /// another artist. The same rows decide the majority once a second folder
    /// makes the source directory-authoritative.
    @Test func aSourceWithoutRealFoldersGetsNoMajorityVote() {
        let flat = [
            track("1", sourceID: "server", directory: "/songs", trackArtistName: "Host"),
            track("2", sourceID: "server", directory: "/songs", trackArtistName: "Host"),
            track("3", sourceID: "server", directory: "/songs", trackArtistName: "Guest"),
        ]
        #expect(AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: flat).isEmpty)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: flat).isEmpty)

        let foldered = flat + [
            track("4", sourceID: "server", directory: "/songs/other", trackArtistName: "Other")
        ]
        #expect(
            AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: foldered) == ["server"]
        )
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: foldered) == ["3": "Host"])
    }

    /// fnOS Music addresses tracks by GUID, so every path is `/fnmusic/tracks`
    /// and no folder ever vouches for the source. It still hands back the album
    /// artist for only part of an album, which used to split that album into one
    /// same-titled card per composer. The lone explicit tag now speaks for the
    /// whole album title.
    @Test func aFlatSourceAdoptsTheOnlyExplicitAlbumArtist() {
        let ost = "游戏《Rewrite》原声带"
        let tracks = [
            track("1", sourceID: "fnmusic", directory: "/fnmusic/tracks", albumTitle: ost,
                  albumArtistName: "Key Sounds Label", trackArtistName: "水谷瑠奈"),
            track("2", sourceID: "fnmusic", directory: "/fnmusic/tracks", albumTitle: ost,
                  albumArtistName: "Key Sounds Label", trackArtistName: "細井聡司"),
            track("3", sourceID: "fnmusic", directory: "/fnmusic/tracks", albumTitle: ost,
                  trackArtistName: "折戸伸治"),
            track("4", sourceID: "fnmusic", directory: "/fnmusic/tracks", albumTitle: ost,
                  trackArtistName: "麻枝准"),
        ]

        #expect(AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: tracks).isEmpty)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == [
            "3": "Key Sounds Label",
            "4": "Key Sounds Label",
        ])
    }

    @Test func aFlatSourceLeavesConflictingExplicitTagsAlone() {
        let tracks = [
            track("1", sourceID: "server", directory: "/songs", albumTitle: "合辑",
                  albumArtistName: "Label A", trackArtistName: "Composer A"),
            track("2", sourceID: "server", directory: "/songs", albumTitle: "合辑",
                  albumArtistName: "Label B", trackArtistName: "Composer B"),
            track("3", sourceID: "server", directory: "/songs", albumTitle: "合辑",
                  trackArtistName: "Composer C"),
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
    }

    /// A flat source and a foldered one in one library keep their own rules.
    @Test func aFlatSourceAndAFolderedSourceAreJudgedSeparately() {
        let tracks = [
            track("flat-1", sourceID: "fnmusic", directory: "/fnmusic/tracks",
                  albumArtistName: "Label", trackArtistName: "Composer A"),
            track("flat-2", sourceID: "fnmusic", directory: "/fnmusic/tracks",
                  trackArtistName: "Composer B"),
            track("disk-1", sourceID: "disk", trackArtistName: "Host"),
            track("disk-2", sourceID: "disk", trackArtistName: "Host"),
            track("disk-3", sourceID: "disk", trackArtistName: "Guest"),
            track("disk-4", sourceID: "disk", directory: "/music/other",
                  albumTitle: "别的专辑", trackArtistName: "别人"),
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == [
            "flat-2": "Label",
            "disk-3": "Host",
        ])
    }

    @Test func spellingVariantsOfOneKeyUnifyToTheMostFrequentSpelling() {
        let tracks = [
            track("1", trackArtistName: "ABC"),
            track("2", trackArtistName: "ABC"),
            track("3", trackArtistName: "ABC"),
            track("4", trackArtistName: "abc"),
            track("5", trackArtistName: "Guest"),
            neighbourFolderTrack,
        ]

        let result = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)

        #expect(result == ["4": "ABC", "5": "ABC"])
    }

    /// 两首歌、两位作曲者、都只回退成自己的曲目艺术家 —— 谁也凑不出多数,
    /// 推断只能放弃, 于是那张 OST 在专辑页上永远是两张同名卡片。它们存着的
    /// 专辑艺术家什么也没说明, 必须回到文件里再读一次。
    @Test func fallbackOnlyFolderWithDisagreeingValuesNeedsAReread() {
        let tracks = [
            track(
                "fertilizer",
                albumTitle: "游戏《Rewrite》原声带",
                albumArtistName: "折戸伸治",
                trackArtistName: "折戸伸治"
            ),
            track(
                "tabi",
                albumTitle: "游戏《Rewrite》原声带",
                albumArtistName: "麻枝准",
                trackArtistName: "麻枝准"
            ),
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
        #expect(
            AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: tracks)
                == ["fertilizer", "tabi"]
        )
    }

    @Test func aConfirmedOrSettledFolderIsNotReread() {
        // 文件里真的写了专辑艺术家 —— 已经定案。
        let tagged = [
            track("1", albumArtistName: "Key Sounds Label", trackArtistName: "折戸伸治"),
            track("2", albumArtistName: "Key Sounds Label", trackArtistName: "麻枝准"),
        ]
        #expect(AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: tagged).isEmpty)

        // 回退值一致: 再读一遍也不会改变分组, 不值得整库一首一读。
        let agreeing = [
            track("1", albumArtistName: "某位歌手", trackArtistName: "某位歌手"),
            track("2", albumArtistName: "某位歌手", trackArtistName: "某位歌手"),
        ]
        #expect(AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: agreeing).isEmpty)

        // 占多数的曲目艺术家已经能代表整张专辑, 推断自己定得了案。
        let majority = [
            track("1", trackArtistName: "主唱"),
            track("2", trackArtistName: "主唱"),
            track("3", trackArtistName: "嘉宾"),
            neighbourFolderTrack,
        ]
        #expect(!AlbumArtistInferencePolicy.inferredAlbumArtists(for: majority).isEmpty)
        #expect(AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: majority).isEmpty)

        // 专辑名不同就是两张专辑, 各自成 scope。
        let separateAlbums = [
            track("1", albumTitle: "专辑甲", trackArtistName: "甲"),
            track("2", albumTitle: "专辑乙", trackArtistName: "乙"),
        ]
        #expect(
            AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: separateAlbums).isEmpty
        )
    }

    /// 分组本身不看文件夹 —— 同名专辑的两首歌不在一个目录, 在专辑页上照样
    /// 该是一张。判定也就不能要求同目录, 否则出问题的那类库正好落在外面。
    @Test func aSplitFolderStillCountsAsOneAlbumForTheReread() {
        let tracks = [
            track("1", directory: "/music/disc1", trackArtistName: "甲"),
            track("2", directory: "/music/disc2", trackArtistName: "乙"),
        ]

        #expect(
            AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: tracks) == ["1", "2"]
        )
        // 推断仍然按目录走, 它会改写分组, 必须保守。
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
    }

    /// Google Drive and the other ID-addressed drives list every file under a
    /// real folder, but the path is the item ID, so all their tracks used to
    /// share the directory "" and the drive never got a majority vote. With
    /// the parents from the sync index it is judged folder by folder.
    @Test func anIDAddressedDriveIsJudgedByItsIndexedFolders() {
        let folders = AlbumArtistFolderIndex(parentsBySource: [
            "drive": [
                "1AbC": "folder-ost", "2DeF": "folder-ost", "3GhI": "folder-ost",
                "4JkL": "folder-other",
            ],
        ])
        func tracks(_ folders: AlbumArtistFolderIndex) -> [AlbumArtistInferencePolicy.Track] {
            [
                ("1AbC", "鸣潮 原声带", "鸣潮先约电台"),
                ("2DeF", "鸣潮 原声带", "鸣潮先约电台"),
                ("3GhI", "鸣潮 原声带", "作曲家甲"),
                ("4JkL", "别的专辑", "别人"),
            ].map { path, album, artist in
                track(
                    path,
                    sourceID: "drive",
                    directory: folders.directory(sourceID: "drive", filePath: path),
                    albumTitle: album,
                    trackArtistName: artist
                )
            }
        }

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks(.empty)).isEmpty)
        #expect(
            AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: tracks(folders))
                == ["drive"]
        )
        #expect(
            AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks(folders))
                == ["3GhI": "鸣潮先约电台"]
        )
    }

    /// A file the index has not listed yet — added by a scan that has not
    /// committed — has no folder. It must not land in one catch-all folder
    /// where a majority could rename it; only an undisputed explicit tag in its
    /// album title reaches it.
    @Test func aTrackWithoutAKnownFolderTakesOnlyTheExplicitVerdict() {
        let tracks = [
            track("a1", sourceID: "drive", directory: "folder-a", trackArtistName: "Host"),
            track("b1", sourceID: "drive", directory: "folder-b", albumTitle: "别的专辑",
                  trackArtistName: "别人"),
            track("u1", sourceID: "drive", directory: nil, albumTitle: "新专辑",
                  trackArtistName: "Host"),
            track("u2", sourceID: "drive", directory: nil, albumTitle: "新专辑",
                  trackArtistName: "Host"),
            track("u3", sourceID: "drive", directory: nil, albumTitle: "新专辑",
                  trackArtistName: "Guest"),
            track("u4", sourceID: "drive", directory: nil, albumTitle: "合辑",
                  albumArtistName: "Label", trackArtistName: "Composer A"),
            track("u5", sourceID: "drive", directory: nil, albumTitle: "合辑",
                  trackArtistName: "Composer B"),
        ]

        #expect(AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: tracks) == ["drive"])
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == ["u5": "Label"])
    }

    @Test func folderIndexReadsTheFileRowsOfASyncIndex() {
        let index: [String: SourceSyncIndexedItem] = [
            "folder-ost": SourceSyncIndexedItem(
                stableKey: "folder-ost", path: "folder-ost", displayName: "OST",
                parentPath: "root", isDirectory: true,
                size: 0, modifiedDate: nil, revision: nil
            ),
            "file-1": SourceSyncIndexedItem(
                stableKey: "file-1", path: "file-1", parentPath: "folder-ost",
                isDirectory: false, songIDs: ["song-1", "song-1-cue-2"],
                size: 1, modifiedDate: nil, revision: nil
            ),
            "file-2": SourceSyncIndexedItem(
                stableKey: "file-2", path: "file-2", parentPath: nil,
                isDirectory: false, songIDs: ["song-2"],
                size: 1, modifiedDate: nil, revision: nil
            ),
        ]

        let parents = AlbumArtistFolderIndex.parents(fromSyncIndex: index)
        #expect(parents == ["file-1": "folder-ost"])

        let folders = AlbumArtistFolderIndex(parentsBySource: ["drive": parents, "unscanned": [:]])
        #expect(Set(folders.parentsBySource.keys) == ["drive"])
        #expect(folders.directory(sourceID: "drive", filePath: "file-1") == "folder-ost")
        #expect(folders.directory(sourceID: "drive", filePath: "file-2") == nil)
        #expect(folders.directory(sourceID: "disk", filePath: "/music/a/b.flac") == "/music/a")
        #expect(folders.directory(sourceID: "unscanned", filePath: "3GhI") == "")
    }

    @Test func directoryOfPathMatchesFoundationPathSemantics() {
        #expect(AlbumArtistInferencePolicy.directory(ofPath: "/a/b/c.flac") == "/a/b")
        #expect(AlbumArtistInferencePolicy.directory(ofPath: "c.flac") == "")
        #expect(
            AlbumArtistInferencePolicy.directory(ofPath: "/x/y/")
                == ("/x/y/" as NSString).deletingLastPathComponent
        )
    }
}
