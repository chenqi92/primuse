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
        trackArtistName: String? = nil,
        year: Int? = nil,
        disc: Int? = nil,
        number: Int? = nil
    ) -> AlbumArtistInferencePolicy.Track {
        AlbumArtistInferencePolicy.Track(
            id: id,
            sourceID: sourceID,
            directory: directory,
            albumTitle: albumTitle,
            albumArtistName: albumArtistName,
            trackArtistName: trackArtistName,
            year: year,
            discNumber: disc,
            trackNumber: number
        )
    }

    /// 服务器源的一张专辑:路径都一样,没有文件夹替它作证,也就没有多数票。
    private func flat(
        _ id: String,
        _ artist: String?,
        album: String = "纵横四海",
        albumArtist: String? = nil,
        year: Int? = nil,
        disc: Int? = nil,
        number: Int? = nil
    ) -> AlbumArtistInferencePolicy.Track {
        track(id, sourceID: "server", directory: "/songs", albumTitle: album,
              albumArtistName: albumArtist, trackArtistName: artist,
              year: year, disc: disc, number: number)
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
        // Linux Foundation traps on a one-character path; Darwin returns "".
        #expect(AlbumArtistInferencePolicy.directory(ofPath: "c") == "")
        #expect(
            AlbumArtistInferencePolicy.directory(ofPath: "/x/y/")
                == ("/x/y/" as NSString).deletingLastPathComponent
        )
        for path in [
            "", "/", "//", "/c.flac", "a/b", "/a/b/c/", "//a/b.mp3", "a//b/c.mp3",
            "/音乐/周杰伦/晴天 (Live).flac", "./x.mp3", "../a/b.mp3", "~/a.mp3", "/a/./b.mp3",
            "/a/b/c.mp3/", "a/b/ ", " /a/b.mp3",
        ] {
            #expect(
                AlbumArtistInferencePolicy.directory(ofPath: path)
                    == (path as NSString).deletingLastPathComponent,
                "\(path)"
            )
        }
    }

    // MARK: - 合唱并进主唱那张 (#338)

    /// 《纵横四海》没有专辑艺人标签,合唱那首写的是「李荣浩 & 张惠妹」,按曲目艺人分组
    /// 就自成一张。服务器源没有多数票,原来救不回来。
    @Test func aDuetOnAFlatSourceFoldsIntoTheSoloCredit() {
        let tracks = [
            flat("1", "李荣浩", number: 1),
            flat("2", "李荣浩", number: 2),
            flat("3", "李荣浩 & 张惠妹", number: 3),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == ["3": "李荣浩"])
    }

    /// 文件夹源两首歌一比一凑不出多数,合唱照样并进去。
    @Test func aDuetFoldsWhereTheFolderVoteTies() {
        let tracks = [
            track("1", albumTitle: "纵横四海", trackArtistName: "李荣浩"),
            track("2", albumTitle: "纵横四海", trackArtistName: "李荣浩 feat. 张惠妹"),
            neighbourFolderTrack,
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == ["2": "李荣浩"])
    }

    @Test func everyCollaborationSpellingFoldsAndChainsEndAtTheSoloCredit() {
        let tracks = [
            flat("1", "A"),
            flat("2", "A (ft. B)"),
            flat("3", "A、C"),
            flat("4", "A x D"),
            flat("5", "A／E；F"),
            flat("6", "A & B & C"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == [
            "2": "A", "3": "A", "4": "A", "5": "A", "6": "A",
        ])
    }

    /// 乐队名本身带「&」:只会并进同一张里一个它包含的署名,所以不会被拆坏。
    @Test func aBandNameWithASeparatorKeepsItsOwnCredit() {
        let tracks = [
            flat("1", "Simon & Garfunkel", album: "Bookends"),
            flat("2", "Simon & Garfunkel", album: "Bookends"),
            flat("3", "Simon & Garfunkel feat. Guest", album: "Bookends"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == ["3": "Simon & Garfunkel"])
    }

    @Test func ambiguousAllDuetAndUnrelatedCreditsStayApart() {
        // 「A & B」旁边 A 和 B 都在:并给谁都说不清。
        let ambiguous = [flat("1", "A"), flat("2", "B"), flat("3", "A & B")]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: ambiguous).isEmpty)

        // 整张都是合唱、没有一首纯主唱:保持原样。
        let allDuets = [flat("1", "A & B"), flat("2", "A & C")]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: allDuets).isEmpty)

        // 不同歌手的同名专辑没有包含关系。
        let unrelated = [flat("1", "A"), flat("2", "B & C")]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: unrelated).isEmpty)
    }

    @Test func albumArtistTagsDecideBeforeCreditsAreCompared() {
        // 一个显式标签:整张跟它走,合唱也一样。
        let tagged = [
            flat("1", "A", albumArtist: "Label"),
            flat("2", "A"),
            flat("3", "A & B"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tagged) == [
            "2": "Label", "3": "Label",
        ])

        // 标签互相冲突是故意分开的,合唱也不动。
        let conflicting = [
            flat("1", "A", albumArtist: "Label A"),
            flat("2", "B", albumArtist: "Label B"),
            flat("3", "A"),
            flat("4", "A & C"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: conflicting).isEmpty)
    }

    /// 同一位歌手两张同名专辑,一张署名「A」一张「A & 乐队」:年份不同或者曲号撞车就是两张。
    @Test func aDifferentYearOrATakenTrackNumberMeansAnotherRelease() {
        let otherYear = [
            flat("1", "A", album: "Live", year: 2019),
            flat("2", "A", album: "Live", year: 2019),
            flat("3", "A & The Band", album: "Live", year: 2023),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: otherYear).isEmpty)

        let takenNumber = [
            flat("1", "A", album: "Live", number: 1),
            flat("2", "A", album: "Live", number: 2),
            flat("3", "A & The Band", album: "Live", number: 1),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: takenNumber).isEmpty)

        // 第二碟的第 1 首不算撞车;年份对得上也照并。
        let secondDisc = [
            flat("1", "A", album: "Live", year: 2019, disc: 1, number: 1),
            flat("2", "A & The Band", album: "Live", year: 2019, disc: 2, number: 1),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: secondDisc) == ["2": "A"])

        // 两首合唱同一个曲号:先到的并进去,后一首留下。
        let twoDuets = [
            flat("1", "A", album: "Live", number: 1),
            flat("2", "A & B", album: "Live", number: 2),
            flat("3", "A & C", album: "Live", number: 2),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: twoDuets) == ["2": "A"])
    }

    /// 合唱并进主唱那张就定案了,和多数票一样,不必回文件里再读一遍。
    @Test func aFoldedDuetNeedsNoReread() {
        let duet = [
            track("1", albumTitle: "纵横四海", trackArtistName: "李荣浩"),
            track("2", albumTitle: "纵横四海", trackArtistName: "李荣浩 & 张惠妹"),
        ]
        #expect(AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: duet).isEmpty)

        let ambiguous = [
            track("1", albumTitle: "合唱", trackArtistName: "A"),
            track("2", albumTitle: "合唱", trackArtistName: "B"),
            track("3", albumTitle: "合唱", trackArtistName: "A & B"),
        ]
        #expect(AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: ambiguous) == ["1", "2", "3"])
    }

    // MARK: - 服务端已分好的专辑 (#462)

    /// Subsonic 一族的一首:路径都在 `/songs` 下,带服务端专辑 id 和自己标签里的专辑艺人。
    /// `albumArtist` 是 #333 之后存下的值(标签是回退值时换成服务端专辑的艺人)。
    private func served(
        _ id: String,
        _ artist: String,
        album: String,
        tagged: String? = nil,
        albumArtist: String? = nil,
        title: String = "Same Title",
        year: Int? = nil,
        number: Int? = nil
    ) -> AlbumArtistInferencePolicy.Track {
        AlbumArtistInferencePolicy.Track(
            id: id, sourceID: "navidrome", directory: "/songs", albumTitle: title,
            albumArtistName: albumArtist ?? tagged ?? artist, trackArtistName: artist,
            year: year, trackNumber: number,
            serverAlbumID: album, taggedAlbumArtistName: tagged ?? artist
        )
    }

    /// 推断之后每首落在哪位专辑艺人名下,即专辑页上有几张。
    private func albumCredits(_ tracks: [AlbumArtistInferencePolicy.Track]) -> Set<String> {
        let inferred = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)
        return Set(tracks.compactMap { inferred[$0.id] ?? $0.albumArtistName ?? $0.trackArtistName })
    }

    /// #462:两位歌手的同名专辑,服务端是两张。带 feat. 的那首专辑艺人是显式的,另一张那首的
    /// 专辑艺人就是自己,以前被当成缺标签并了过去。年份、曲号也对不上,但这里不靠它们。
    @Test func sameTitledServerAlbumsByDifferentArtistsStayApart() {
        let tracks = [
            served("1", "RAF Camora", album: "raf", year: 2021, number: 1),
            served("2", "RAF Camora feat. Bonez MC", album: "raf", tagged: "RAF Camora", year: 2021, number: 2),
            served("3", "2 Engel & Charlie", album: "engel", year: 2026, number: 1),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
        #expect(albumCredits(tracks) == ["RAF Camora", "2 Engel & Charlie"])

        let undated = [
            served("1", "RAF Camora", album: "raf"),
            served("2", "RAF Camora feat. Bonez MC", album: "raf", tagged: "RAF Camora"),
            served("3", "2 Engel & Charlie", album: "engel"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: undated).isEmpty)
    }

    /// #333 原场景:服务端按专辑名把各首艺人不同、都没有专辑艺人标签的歌并成一张,
    /// 扫描时已经换成服务端专辑的艺人,推断不再动它们。
    @Test func oneServerAlbumOfUntaggedArtistsStaysOneAlbum() {
        let tracks = [
            served("1", "Artist A", album: "sing", albumArtist: "Artist C", number: 1),
            served("2", "Artist B", album: "sing", albumArtist: "Artist C", number: 2),
            served("3", "Artist C", album: "sing", number: 3),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
        #expect(albumCredits(tracks) == ["Artist C"])
    }

    /// 服务端按 MBID 或专辑名并成一张、部分曲目有专辑艺人标签,服务端专辑艺人取到了
    /// 没标签那首的艺人 Y:#333 把没标签的都改成 Y,有标签的仍是 X。看各首自己的标签,
    /// 只有 X 一种,整张都用 X。
    @Test func oneServerAlbumFollowsItsOnlyTaggedAlbumArtist() {
        let tracks = [
            served("1", "Guest A", album: "ost", tagged: "Label X", number: 1),
            served("2", "Composer Y", album: "ost", number: 2),
            served("3", "Composer Z", album: "ost", albumArtist: "Composer Y", number: 3),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == [
            "2": "Label X", "3": "Label X",
        ])
        #expect(albumCredits(tracks) == ["Label X"])

        // 标签有两种:保持 #333 的结果。
        let conflicting = [
            served("1", "Guest A", album: "ost", tagged: "Label X"),
            served("2", "Guest B", album: "ost", tagged: "Label W"),
            served("3", "Composer Z", album: "ost", albumArtist: "Label W"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: conflicting).isEmpty)

        // 统一只在一张服务端专辑之内:同名的另一张不跟着改。
        let besideAnother = tracks + [served("4", "Someone Else", album: "other", number: 1)]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: besideAnother) == [
            "2": "Label X", "3": "Label X",
        ])
    }

    /// #338 在 Navidrome 上:合唱那首没有专辑艺人标签,服务端把它单独算一张;
    /// 同名范围里没有显式标签,照旧并进主唱那张。
    @Test func aDuetOnAServerStillFoldsIntoTheSoloAlbum() {
        let tracks = [
            served("1", "李荣浩", album: "solo", title: "纵横四海", year: 2015, number: 1),
            served("2", "李荣浩", album: "solo", title: "纵横四海", year: 2015, number: 2),
            served("3", "李荣浩 & 张惠妹", album: "duet", title: "纵横四海", year: 2015, number: 3),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks) == ["3": "李荣浩"])
    }

    /// 手改过的行不再跟服务端走,它现在的专辑艺人就是它自己的标签。
    @Test func anEditedServerRowVotesWithItsOwnAlbumArtist() {
        func song(_ id: String, _ artist: String, albumArtist: String, tagged: String?, edited: Bool) -> Song {
            Song(
                id: id, title: id, albumTitle: "Same Title", artistName: artist,
                albumArtistName: albumArtist, fileFormat: .flac, filePath: "/songs/\(id).flac",
                sourceID: "navidrome", userMetadataEditedAt: edited ? Date(timeIntervalSince1970: 1) : nil,
                serverCatalogAlbum: ServerCatalogAlbumReference(id: "ost", taggedArtist: tagged)
            )
        }
        func tracks(_ songs: [Song]) -> [AlbumArtistInferencePolicy.Track] {
            songs.map { AlbumArtistInferencePolicy.Track(song: $0, directory: "/songs") }
        }
        let tagged = song("1", "Guest A", albumArtist: "Label X", tagged: "Label X", edited: false)
        let untagged = song("2", "Composer Z", albumArtist: "Composer Y", tagged: "Composer Z", edited: false)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks([tagged, untagged])) == [
            "2": "Label X",
        ])

        let renamed = song("2", "Composer Z", albumArtist: "My Label", tagged: "Composer Z", edited: true)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks([tagged, renamed])).isEmpty)
    }

    /// 没有服务端专辑的源(飞牛等)照旧收编,但年份或曲号对不上的那一组是同名的另一张。
    @Test func theExplicitVerdictLeavesOutAnotherReleaseOfTheSameTitle() {
        func fn(_ id: String, _ artist: String, albumArtist: String? = nil, year: Int? = nil,
                disc: Int? = nil, number: Int? = nil) -> AlbumArtistInferencePolicy.Track {
            track(id, sourceID: "fnmusic", directory: "/fnmusic/tracks", albumTitle: "Same Title",
                  albumArtistName: albumArtist, trackArtistName: artist,
                  year: year, disc: disc, number: number)
        }
        let raf = [
            fn("1", "RAF Camora", year: 2021, number: 1),
            fn("2", "RAF Camora feat. Bonez MC", albumArtist: "RAF Camora", year: 2021, number: 2),
        ]

        // 年份不同、第 1 首撞车:不收编。
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: raf + [fn("3", "2 Engel & Charlie", year: 2026, number: 1)]).isEmpty)
        // 只有年份不同。
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: raf + [fn("3", "2 Engel & Charlie", year: 2026, number: 16)]).isEmpty)
        // 只有曲号撞车(碟号缺省按 1)。
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: raf + [fn("3", "2 Engel & Charlie", disc: 1, number: 1)]).isEmpty)
        // 一组里有一首撞车,整组都不收编。
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: raf + [fn("3", "2 Engel & Charlie", number: 16), fn("4", "2 Engel & Charlie", number: 1)]
        ).isEmpty)
        // 看不出冲突:照旧收编。
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: raf + [fn("3", "2 Engel & Charlie", number: 16)]) == ["3": "RAF Camora"])
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: raf + [fn("3", "2 Engel & Charlie", year: 2021, disc: 2, number: 1)]) == ["3": "RAF Camora"])
    }

    /// 37ae32d52 的原场景带上年份和曲号:同一张专辑,飞牛只给部分曲目返回专辑艺人,仍并成一张。
    /// 合辑每首写原始年份时年份不统一,不拿年份判断。
    @Test func aPartlyTaggedServerAlbumWithYearsAndNumbersStillJoins() {
        func fn(_ id: String, _ artist: String, albumArtist: String? = nil, year: Int, number: Int)
            -> AlbumArtistInferencePolicy.Track {
            track(id, sourceID: "fnmusic", directory: "/fnmusic/tracks", albumTitle: "游戏《Rewrite》原声带",
                  albumArtistName: albumArtist, trackArtistName: artist, year: year, number: number)
        }
        let ost = [
            fn("1", "水谷瑠奈", albumArtist: "Key Sounds Label", year: 2011, number: 1),
            fn("2", "細井聡司", albumArtist: "Key Sounds Label", year: 2011, number: 2),
            fn("3", "折戸伸治", year: 2011, number: 3),
            fn("4", "麻枝准", year: 2011, number: 4),
            fn("5", "麻枝准", year: 2011, number: 5),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: ost) == [
            "3": "Key Sounds Label", "4": "Key Sounds Label", "5": "Key Sounds Label",
        ])

        let compilation = [
            fn("1", "Singer A", albumArtist: "Various Artists", year: 1990, number: 1),
            fn("2", "Singer B", albumArtist: "Various Artists", year: 1995, number: 2),
            fn("3", "Singer C", year: 2001, number: 3),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: compilation) == [
            "3": "Various Artists",
        ])
    }

    @Test func creditNamesSplitCollaborationsOnly() {
        #expect(AlbumArtistInferencePolicy.creditNames(in: "李荣浩 & 张惠妹") == ["李荣浩", "张惠妹"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "A feat. B") == ["A", "B"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "A (Feat. B)") == ["A", "B"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "A ft B") == ["A", "B"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "A x B") == ["A", "B"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "Daft Punk") == ["Daft Punk"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "Charli xcx") == ["Charli xcx"])
        #expect(AlbumArtistInferencePolicy.creditNames(in: "Elvis Presley") == ["Elvis Presley"])
    }

    private var mergingConfiguration: ArtistNameConfiguration {
        var value = ArtistNameConfiguration.defaultValue
        value.mergesCollaborativeAlbums = true
        return value
    }

    @Test func sameNamedAlbumsMergeUnrelatedExplicitArtistsAcrossSourcesAndFolders() {
        let tracks = [
            track("1", sourceID: "smb", directory: "/one", albumTitle: "夜色合辑",
                  albumArtistName: "乐队甲", trackArtistName: "歌手甲", year: 2020, number: 1),
            track("2", sourceID: "drive", directory: "/two", albumTitle: " 夜色合辑 ",
                  albumArtistName: "乐队乙", trackArtistName: "歌手乙", year: 2026, number: 1),
            track("3", sourceID: "drive", directory: "/three", albumTitle: "另一张专辑", trackArtistName: "歌手丙"),
            track("4", albumTitle: " ", trackArtistName: "歌手丁"),
            track("5", albumTitle: nil, trackArtistName: "歌手戊"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: mergingConfiguration).isEmpty)
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.mergesSameNamedAlbums = true
        let expected = ["1": "Various Artists", "2": "Various Artists"]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: configuration) == expected)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks.reversed(), configuration: configuration) == expected)
        configuration.mergesCollaborativeAlbums = true
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: configuration) == expected)
    }

    @Test func sameNamedAlbumsKeepAgreedCreditsAndIncludeMissingArtists() {
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.mergesSameNamedAlbums = true
        let tracks = [
            track("1", sourceID: "a", albumArtistName: "合辑厂牌", trackArtistName: "甲"),
            track("2", sourceID: "b", albumArtistName: "合辑厂牌", trackArtistName: "乙"),
            track("3", sourceID: "c"),
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: configuration)
                == ["1": "合辑厂牌", "2": "合辑厂牌", "3": "合辑厂牌"])
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: [flat("1", nil), flat("2", nil)], configuration: configuration).isEmpty)
    }

    @Test func optInMergesAnAlbumMadeEntirelyOfCollaborationsAcrossFoldersAndSources() {
        let guests = ["A-Lin", "陈立农", "黄子弘凡", "王赫野", "汪苏泷", "姚晓棠"]
        let tracks = guests.enumerated().map { index, guest in
            track("\(index)", sourceID: index < 3 ? "baidu" : "smb", directory: "/folder/\(index)",
                  albumTitle: "归程", albumArtistName: "吉克隽逸 & \(guest)",
                  trackArtistName: "吉克隽逸 & \(guest)", year: 2026, number: index + 1)
        }
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
        let expected = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, "吉克隽逸") })
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: mergingConfiguration) == expected)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks.reversed(), configuration: mergingConfiguration) == expected)
    }

    @Test func optInKeepsUnrelatedTitlesAndArtistsApart() {
        let tracks = [flat("1", "A & B"), flat("2", "A & C"), flat("3", "D & E"),
                      flat("4", "A & F", album: "Other")]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: mergingConfiguration)
                == ["1": "A", "2": "A"])
    }

    @Test func optInDoesNotChainAmbiguousCollaboratorsOrSplitABand() {
        for tracks in [
            [flat("1", "A & B"), flat("2", "A & C"), flat("3", "B & D")],
            [flat("1", "Simon & Garfunkel feat. A"), flat("2", "Simon & Garfunkel feat. B")],
            [flat("1", "Unknown Artist & B"), flat("2", "Unknown Artist & C")],
        ] {
            #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: mergingConfiguration).isEmpty)
        }
    }

    @Test func optInHonorsProtectedNamesAndCollaborationSeparators() {
        var configuration = mergingConfiguration
        configuration.protectedNames += ["Simon & Garfunkel"]
        for artist in ["AC/DC", "Simon & Garfunkel", "Charli xcx"] {
            let tracks = [flat("1", "\(artist) (feat. Guest B)"), flat("2", "Guest C & \(artist)")]
            #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: configuration)
                    == ["1": artist, "2": artist])
        }
    }

    @Test func optInRespectsReleaseConflictsAndExplicitUnrelatedAlbumArtists() {
        for tracks in [
            [flat("1", "A & B", year: 2025), flat("2", "A & C", year: 2026)],
            [flat("1", "A & B", number: 1), flat("2", "A & C", number: 1)],
            [flat("1", "A & B", albumArtist: "Band One"), flat("2", "A & C", albumArtist: "Band Two")],
        ] {
            #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks, configuration: mergingConfiguration).isEmpty)
        }
        let discs = [flat("1", "A & B", disc: 1, number: 1), flat("2", "A & C", disc: 2, number: 1)]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: discs, configuration: mergingConfiguration)
                == ["1": "A", "2": "A"])
    }
}
