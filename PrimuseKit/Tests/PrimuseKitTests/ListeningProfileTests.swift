import Foundation
import Testing
@testable import PrimuseKit

private struct ProfileTestSong: ListeningSongTraits {
    var id: String
    var albumID: String?
    var albumTitle: String?
    var artistName: String?
    var albumArtistName: String?
    var genre: String?
    var year: Int?
    var duration: TimeInterval = 240
    var dateAdded: Date = Date(timeIntervalSince1970: 1_700_000_000)
    var trackNumber: Int?
    var discNumber: Int?
    var cueSheetPath: String?
    var coverArtFileName: String?
    var isPlayable: Bool = true
    var sourceID: String = "nas"
    var filePath: String = ""
    var listeningQuality: ListeningAudioQuality = .lossy
}

@Suite("Listening profile and personal intents")
struct ListeningProfileTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// 「音乐」下按类别分的三个文件夹(流行、纯音乐、01-摇滚),每个三位艺人各两张专辑、每张五首;
    /// 外加一个只放一位艺人的文件夹和一个「Downloads」。
    private var library: [ProfileTestSong] {
        var songs: [ProfileTestSong] = []
        let kinds: [(folder: String, genre: String, year: Int, quality: ListeningAudioQuality)] = [
            ("流行", "Pop", 2005, .lossy),
            ("纯音乐", "Piano", 2012, .lossless),
            ("01-摇滚", "Rock", 1995, .hiRes),
        ]
        for kind in kinds {
            for artist in 0..<3 {
                for album in 0..<2 {
                    for track in 0..<5 {
                        let artistName = "\(kind.genre) Artist \(artist)"
                        let albumID = "\(kind.genre)-\(artist)-\(album)"
                        songs.append(ProfileTestSong(
                            id: "\(albumID)-\(track)",
                            albumID: albumID,
                            albumTitle: "\(kind.genre) Album \(artist)\(album)",
                            artistName: artistName,
                            genre: kind.genre,
                            year: kind.year + album,
                            trackNumber: track + 1,
                            discNumber: 1,
                            filePath: "Music/\(kind.folder)/\(artistName)/\(albumID)/\(track).flac",
                            listeningQuality: kind.quality
                        ))
                    }
                }
            }
        }
        for track in 0..<25 {
            songs.append(ProfileTestSong(
                id: "solo-\(track)", albumID: "solo-\(track / 5)", albumTitle: "Solo \(track / 5)",
                artistName: "Solo Singer", genre: "Folk", year: 2018,
                filePath: "Music/Solo Singer/Album \(track / 5)/\(track).mp3"
            ))
        }
        for track in 0..<24 {
            songs.append(ProfileTestSong(
                id: "dl-\(track)", albumID: "dl-\(track / 4)", albumTitle: "Download \(track / 4)",
                artistName: "DL Artist \(track % 4)", genre: "Pop", year: 2020,
                filePath: "Music/Downloads/\(track).mp3"
            ))
        }
        return songs
    }

    private func history(_ plays: [(String, Int)], daysAgo: Double = 2) -> ListeningHistoryIndex {
        var events: [HomeListeningEvent] = []
        for (songID, count) in plays {
            for index in 0..<count {
                events.append(HomeListeningEvent(
                    songID: songID,
                    playedAt: now.addingTimeInterval(-daysAgo * 86_400 - Double(index) * 3_600),
                    listenedSeconds: 200
                ))
            }
        }
        return ListeningHistoryIndex(events: events, now: now)
    }

    @Test("Folders sorted by kind become folder intents; storage and single-artist folders do not")
    func categoryFolders() throws {
        let profile = try #require(ListeningProfile.build(songs: library, history: .empty(now: now)))
        let names = Set(profile.folders.map(\.name))
        #expect(names == ["流行", "纯音乐", "摇滚"])
        #expect(profile.folders.allSatisfy { $0.scope.sourceID == "nas" && $0.scope.path.hasPrefix("Music/") })
        let rock = try #require(profile.folders.first { $0.name == "摇滚" })
        #expect(rock.scope.path == "Music/01-摇滚")
        #expect(rock.songCount == 30)

        let intents = PersonalListeningIntentPolicy.intents(from: profile)
        let folderIntent = try #require(intents.first { $0.customTitle == "纯音乐" })
        let lit = try #require(ListeningIntentEngine.availability(
            songs: library, intents: [folderIntent], history: .empty(now: now), libraryGeneration: 1
        ))
        #expect(lit.songCount(for: folderIntent) == 30)
    }

    @Test("Folder scopes match whole path components, with or without a leading slash")
    func folderScope() {
        let scope = ListeningFolderScope(sourceID: "nas", path: "/Music/流行/")
        #expect(scope.path == "Music/流行")
        #expect(scope.contains(sourceID: "nas", filePath: "Music/流行/a.flac"))
        #expect(scope.contains(sourceID: "nas", filePath: "/Music/流行/x/a.flac"))
        #expect(!scope.contains(sourceID: "nas", filePath: "Music/流行歌/a.flac"))
        #expect(!scope.contains(sourceID: "other", filePath: "Music/流行/a.flac"))
        #expect(!scope.contains(sourceID: "nas", filePath: "Music/流行"))
    }

    @Test("Folder names drop sort numbers and storage names")
    func folderNames() {
        #expect(ListeningFolderNaming.displayName("01-流行") == "流行")
        #expect(ListeningFolderNaming.displayName("[03] 儿歌") == "儿歌")
        #expect(ListeningFolderNaming.displayName("2010s") == "2010s")
        #expect(ListeningFolderNaming.displayName("一人食") == "一人食")
        #expect(ListeningFolderNaming.displayName("Downloads") == nil)
        #expect(ListeningFolderNaming.displayName("我的音乐") == nil)
    }

    @Test("Artists the listener plays become artist intents; before a history only big collections do")
    func artistIntents() throws {
        let played = history((0..<5).map { ("solo-\($0)", 3) })
        let profile = try #require(ListeningProfile.build(songs: library, history: played))
        let intents = PersonalListeningIntentPolicy.intents(from: profile)
        let artist = try #require(intents.first { $0.id.hasPrefix("personal:artist:") })
        #expect(artist.customTitle == "Solo Singer")
        let lit = try #require(ListeningIntentEngine.availability(
            songs: library, intents: [artist], history: played, libraryGeneration: 1
        ))
        #expect(lit.songCount(for: artist) == 25)
        // An artist with fewer songs than a queue needs stays out, however much it is played.
        let small = history((0..<5).map { ("Rock-1-0-\($0)", 3) })
        let smallProfile = try #require(ListeningProfile.build(songs: library, history: small))
        #expect(!PersonalListeningIntentPolicy.intents(from: smallProfile).contains { $0.id.hasPrefix("personal:artist:") })

        let cold = try #require(ListeningProfile.build(songs: library, history: .empty(now: now)))
        #expect(!PersonalListeningIntentPolicy.intents(from: cold).contains { $0.id.hasPrefix("personal:artist:") })
    }

    @Test("A loved album becomes 'albums like it', played whole and in order")
    func albumLike() throws {
        let played = history((0..<3).map { ("Pop-0-0-\($0)", 3) } + (0..<3).map { ("dl-\($0)", 2) })
        let profile = try #require(ListeningProfile.build(songs: library, history: played))
        let similar = profile.similarAlbums(to: "Pop-0-0")
        #expect(!similar.isEmpty)
        #expect(!similar.contains { $0.albumID == "Pop-0-0" })
        #expect(similar.allSatisfy { $0.familyMask & ListeningGenreFamily.pop.bit != 0 })

        let intent = try #require(PersonalListeningIntentPolicy.intents(from: profile).first { $0.id == "personal:albumLike:Pop-0-0" })
        #expect(intent.titleArgument == "Pop Album 00")
        let queue = ListeningIntentEngine.queueSongIDs(for: intent, songs: library, history: played, seed: 1)
        let firstAlbum = try #require(intent.rule?.albumIDs?.first)
        #expect(Array(queue.prefix(5)) == (0..<5).map { "\(firstAlbum)-\($0)" })
        #expect(Set(queue).count == queue.count)
    }

    @Test("Quality intents follow what is played, and only one card when hi-res is all the lossless there is")
    func qualityIntents() throws {
        let lossless = history((0..<5).map { ("Piano-0-0-\($0)", 4) } + [("Pop-0-0-0", 2)])
        let profile = try #require(ListeningProfile.build(songs: library, history: lossless))
        let ids = PersonalListeningIntentPolicy.intents(from: profile).map(\.id)
        #expect(ids.contains("personal:lossless"))
        #expect(!ids.contains("personal:hiRes"))

        let hiRes = history((0..<5).map { ("Rock-0-0-\($0)", 4) })
        let hiResProfile = try #require(ListeningProfile.build(songs: library, history: hiRes))
        let hiResIDs = PersonalListeningIntentPolicy.intents(from: hiResProfile).map(\.id)
        #expect(hiResIDs.contains("personal:hiRes"))

        let lit = try #require(ListeningIntentEngine.availability(
            songs: library,
            intents: [PersonalListeningIntentPolicy.qualityIntent(.lossless), PersonalListeningIntentPolicy.qualityIntent(.hiRes)],
            history: .empty(now: now),
            libraryGeneration: 1
        ))
        #expect(lit.songCounts["personal:lossless"] == 60)
        #expect(lit.songCounts["personal:hiRes"] == 30)
    }

    @Test("Songs played over and over lately become 'in rotation'")
    func rotation() throws {
        let plays = (0..<5).flatMap { album in (0..<3).map { ("Pop-\(album % 3)-\(album % 2)-\($0)", 4) } }
        let profile = try #require(ListeningProfile.build(songs: library, history: history(plays)))
        #expect(profile.rotationSongIDs.count >= 12)
        #expect(PersonalListeningIntentPolicy.intents(from: profile).contains { $0.id == "personal:rotation" })

        let old = try #require(ListeningProfile.build(songs: library, history: history(plays, daysAgo: 30)))
        #expect(old.rotationSongIDs.isEmpty)
    }

    @Test("Ranking follows listening once there is enough of it; personal intents get a nudge")
    func behaviourRanking() throws {
        let pop = ListeningIntent.builtIn(.pop)
        let rock = ListeningIntent.builtIn(.rock)
        // Same library share; rock is what gets played.
        let played = history((0..<5).map { ("Rock-2-1-\($0)", 4) })
        let lit = try #require(ListeningIntentEngine.availability(
            songs: library, intents: [pop, rock], history: played, libraryGeneration: 1
        ))
        #expect(lit.litIntents([pop, rock]).first == rock)

        let cold = try #require(ListeningIntentEngine.availability(
            songs: library, intents: [pop, rock], history: .empty(now: now), libraryGeneration: 1
        ))
        // Pop has the Downloads songs too.
        #expect(cold.litIntents([pop, rock]).first == pop)

        let coldProfile = try #require(ListeningProfile.build(songs: library, history: .empty(now: now)))
        let folder = try #require(PersonalListeningIntentPolicy.intents(from: coldProfile).first { $0.customTitle == "摇滚" })
        let withPersonal = try #require(ListeningIntentEngine.availability(
            songs: library, intents: [rock, folder], history: .empty(now: now), libraryGeneration: 1
        ))
        #expect(withPersonal.litIntents([rock, folder]).first == folder)
    }

    @Test("The shelf ranks personal intents with the built-ins and the page groups them as 'for you'")
    func shelfAndPage() throws {
        let played = history((0..<5).map { ("Rock-1-0-\($0)", 3) })
        let profile = try #require(ListeningProfile.build(songs: library, history: played))
        let personal = PersonalListeningIntentPolicy.intents(from: profile)
        let lit = try #require(ListeningIntentEngine.availability(
            songs: library,
            intents: personal + ListeningIntentShelfPolicy.builtInCatalog,
            history: played,
            libraryGeneration: 1
        ))
        let row = ListeningIntentShelfPolicy.row(
            availability: lit, configuration: .init(), resumeSongCount: nil, personal: personal, limit: .max
        )
        #expect(row.contains { $0.intent.category == .personal })
        #expect(Set(row.map(\.id)).count == row.count)

        var configuration = ListeningIntentShelfConfiguration()
        let pinned = try #require(personal.first)
        configuration.setPinned(true, intentID: pinned.id)
        let pinnedRow = ListeningIntentShelfPolicy.row(
            availability: lit, configuration: configuration, resumeSongCount: nil, personal: personal
        )
        #expect(pinnedRow.dropFirst().first?.id == pinned.id)

        let sections = ListeningIntentShelfPolicy.page(
            availability: lit, configuration: configuration, personal: personal
        )
        #expect(sections.map(\.kind).prefix(2) == [.pinned, .personal])
        let page = try #require(sections.first { $0.kind == .personal })
        #expect(!page.items.contains { $0.id == pinned.id })
        #expect(page.titleKey == "listening_intent_group_personal")
    }

    @Test("The AI request carries play figures only with listening consent")
    func aiRequest() throws {
        let played = history((0..<5).map { ("Rock-1-0-\($0)", 3) })
        let profile = try #require(ListeningProfile.build(songs: library, history: played))
        let withListening = ListeningIntentAIExchange.prepare(profile: profile, languageCode: "zh-Hans", includesListening: true)
        #expect(withListening.request.folders.count == 3)
        #expect(withListening.request.artists.first?.plays != nil)
        #expect(!withListening.request.albums.isEmpty)
        #expect(withListening.request.losslessPlays != nil)
        #expect(ListeningIntentAIExchange.isWorthAsking(withListening.request))

        let without = ListeningIntentAIExchange.prepare(profile: profile, languageCode: "zh-Hans", includesListening: false)
        #expect(without.request.artists.allSatisfy { $0.plays == nil })
        #expect(without.request.folders.allSatisfy { $0.plays == nil })
        #expect(without.request.albums.isEmpty)
        #expect(without.request.losslessPlays == nil)
        let json = try #require(ListeningIntentAIExchange.payloadJSON(without.request))
        #expect(!json.contains("\"plays\""))
    }

    @Test("AI answers are checked: unknown ids, lone genres and empty titles are dropped")
    func aiValidation() throws {
        let played = history((0..<5).map { ("Rock-1-0-\($0)", 3) })
        let profile = try #require(ListeningProfile.build(songs: library, history: played))
        let prepared = ListeningIntentAIExchange.prepare(profile: profile, languageCode: "zh-Hans", includesListening: true)
        let folderID = try #require(prepared.request.folders.first { $0.name == "纯音乐" }?.id)
        let artistID = try #require(prepared.request.artists.first?.id)
        let text = """
        Here you go:
        ```json
        {"intents":[
          {"kind":"folder","title":"「安静的钢琴」","refs":["\(folderID)"]},
          {"kind":"folder","title":"不存在","refs":["f99"]},
          {"kind":"artist","title":"常听的他","refs":["\(artistID)","a99"]},
          {"kind":"genre_mix","title":"只有流行","genres":["pop"]},
          {"kind":"genre_mix","title":"九十年代摇滚","genres":["Rock"],"decade":1994},
          {"kind":"quality","title":"无损时刻","quality":"lossless"},
          {"kind":"rotation","title":"   "},
          {"kind":"mystery","title":"?"}
        ]}
        ```
        """
        let drafts = try ListeningIntentAIExchange.drafts(fromText: text, request: prepared.request)
        #expect(drafts.map(\.kind) == [.folder, .artist, .genreMix, .quality])
        #expect(drafts[0].title == "安静的钢琴")
        #expect(drafts[1].refs == [artistID])
        #expect(drafts[2].decade == 1990)
        #expect(drafts[2].genres == [.rock])
        #expect(throws: ListeningIntentAIExchangeError.unreadableAnswer) {
            try ListeningIntentAIExchange.drafts(fromText: "sorry", request: prepared.request)
        }

        let intents = ListeningIntentAIExchange.intents(from: drafts, context: prepared.context, profile: profile)
        let local = PersonalListeningIntentPolicy.intents(from: profile)
        // Same folder, same id: a pin on the device's own card survives.
        let folder = try #require(intents.first)
        #expect(local.contains { $0.id == folder.id })
        #expect(folder.customTitle == "安静的钢琴")
        #expect(folder.isAICurated == true)
        let mix = intents[2]
        #expect(mix.id.hasPrefix("personal:ai:"))
        #expect(mix.rule?.years == 1990...1999)
        let again = ListeningIntentAIExchange.intents(from: drafts, context: prepared.context, profile: profile)
        #expect(again.map(\.id) == intents.map(\.id))

        let merged = PersonalListeningIntentPolicy.merged(ai: intents, local: local)
        #expect(Array(merged.prefix(intents.count)) == intents)
        #expect(Set(merged.map(\.id)).count == merged.count)
        #expect(merged.count <= PersonalListeningIntentPolicy.maximumIntents)
    }

    @Test("The fingerprint moves with what the profile is about, not with every play")
    func fingerprint() throws {
        let base = try #require(ListeningProfile.build(songs: library, history: .empty(now: now)))
        let same = try #require(ListeningProfile.build(songs: library, history: .empty(now: now)))
        #expect(base.fingerprint == same.fingerprint)
        var smaller = library
        smaller.removeAll { $0.filePath.contains("纯音乐") }
        let changed = try #require(ListeningProfile.build(songs: smaller, history: .empty(now: now)))
        #expect(changed.fingerprint != base.fingerprint)
    }
}
