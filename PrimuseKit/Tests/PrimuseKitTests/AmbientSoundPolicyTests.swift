import Foundation
import Testing
@testable import PrimuseKit

@Suite("Ambient sounds: recognition")
struct AmbientSoundRecognitionTests {
    @Test("流派里点名白噪音、雨声、自然声这类声音的,各种写法都认成环境音")
    func strongGenresAreAmbient() {
        let genres = [
            "White Noise", "white-noise", "Pink Noise", "Brown Noise", "Brownian Noise",
            "Nature Sounds", "Sounds of Nature", "Rain Sounds", "Ocean Sounds", "Sleep Sounds",
            "Soundscape", "Soundscapes", "Field Recording", "Field Recordings", "Binaural Beats", "ASMR",
            "Weißes Rauschen", "Bruit blanc", "Ruido blanco", "Sons da natureza", "Белый шум",
            // 白噪音、白噪声、白噪聲、粉红噪音、自然声、自然音、雨声、雨聲、助眠、环境音、環境音、环境声
            "\u{767D}\u{566A}\u{97F3}", "\u{767D}\u{566A}\u{58F0}", "\u{767D}\u{566A}\u{8072}",
            "\u{7C89}\u{7EA2}\u{566A}\u{97F3}", "\u{81EA}\u{7136}\u{58F0}", "\u{81EA}\u{7136}\u{97F3}",
            "\u{96E8}\u{58F0}", "\u{96E8}\u{8072}", "\u{52A9}\u{7720}",
            "\u{73AF}\u{5883}\u{97F3}", "\u{74B0}\u{5883}\u{97F3}", "\u{73AF}\u{5883}\u{58F0}",
            "ホワイトノイズ", "백색소음", "빗소리",
        ]
        for genre in genres {
            #expect(SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .ambient, "\(genre)")
            #expect(SpokenWordContentPolicy.genreKind(genre) == .ambient, "\(genre)")
            #expect(!SpokenWordContentPolicy.genreNamesSpokenWord(genre), "\(genre) is not spoken word")
        }
    }

    @Test("氛围音乐这一类正经的音乐流派留在音乐里:Brian Eno 的专辑不会被分走")
    func ambientMusicStaysMusic() {
        let genres = [
            "Ambient", "Dark Ambient", "Ambient Electronic", "Ambient Soundtrack", "Ambient Pop",
            "New Age", "Meditation", "Relax", "Relaxation", "Chill", "Chillout", "Lo-Fi", "Lofi Hip Hop",
            "Drone", "Minimalism", "Healing", "Sleep Music",
            // 冥想、放松、轻音乐、环境音乐、環境音楽、環境音樂、氛围音乐、助眠音乐、自然音乐、雨声乐
            "\u{51A5}\u{60F3}", "\u{653E}\u{677E}", "\u{8F7B}\u{97F3}\u{4E50}",
            "\u{73AF}\u{5883}\u{97F3}\u{4E50}", "\u{74B0}\u{5883}\u{97F3}\u{697D}", "\u{74B0}\u{5883}\u{97F3}\u{6A02}",
            "\u{6C1B}\u{56F4}\u{97F3}\u{4E50}", "\u{52A9}\u{7720}\u{97F3}\u{4E50}", "\u{81EA}\u{7136}\u{97F3}\u{4E50}",
        ]
        for genre in genres {
            #expect(SpokenWordContentPolicy.classify(filePath: "/Eno/Music for Airports/1-1.flac", genre: genre) == .music, "\(genre)")
        }
        // Brian Eno 的专辑:流派写的是 Ambient,时长再长也是音乐。
        let inputs = SpokenWordClassificationInputs()
        #expect(inputs.kind(songID: "eno", sourceID: "s", filePath: "/Eno/1-1.flac", genre: "Ambient") == .music)
        var verdicts: [String: ListeningContentKind] = [:]
        #expect(inputs.kind(songID: "eno", sourceID: "s", filePath: "/Eno/1-1.flac", genre: "Ambient",
                            genreVerdicts: &verdicts) == .music)
    }

    @Test("播客、有声书的流派与 .m4b 仍然先认")
    func spokenWordStillWins() {
        #expect(SpokenWordContentPolicy.classify(filePath: "/a.m4b", genre: "White Noise") == .spokenWord)
        #expect(SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: "Podcast") == .podcast)
        #expect(SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: "Audiobook") == .spokenWord)
    }

    @Test("环境音照音乐的方式放,只是不混进音乐的整库集合")
    func ambientPlaysLikeMusic() {
        #expect(!ListeningContentKind.ambient.isSpokenWordListening)
        #expect(ListeningContentKind.ambient.isSeparateFromMusic)
        #expect(ListeningContentKind.spokenWord.isSpokenWordListening)
        #expect(ListeningContentKind.podcast.isSpokenWordListening)
        #expect(!ListeningContentKind.music.isSeparateFromMusic)
        #expect(ListeningSpace.ambient.playbackFamily == .ambient)
        #expect(ListeningSpace.ambient.systemImage == "leaf")
        #expect(ListeningSpace.ambient.fixedTint != nil)
        let others = [ListeningSpace.radio, .spokenWord, .podcast].compactMap(\.fixedTint)
        #expect(!others.contains(ListeningSpace.ambient.fixedTint!))
    }
}

@Suite("Ambient sounds: classification switch")
struct AmbientSoundClassificationSwitchTests {
    private let source = LibraryFolderSourceDescriptor(source: MusicSource(id: "nas", name: "nas", type: .smb))

    private func inputs(
        overrides: [String: ListeningContentKind] = [:],
        folderTags: [String: [String: ListeningContentKind]] = [:],
        separatesAmbient: Bool
    ) -> SpokenWordClassificationInputs {
        SpokenWordClassificationInputs(
            overrides: overrides,
            folderRules: SpokenWordFolderRules(folderTags: folderTags, sources: [source]),
            separatesAmbient: separatesAmbient
        )
    }

    @Test("单曲手动归属、目录标签、流派都能归到环境音")
    func everyLayerCanSayAmbient() {
        let on = inputs(
            overrides: ["rain": .ambient],
            folderTags: ["nas": ["/Sleep": .ambient]],
            separatesAmbient: true
        )
        #expect(on.kind(songID: "rain", sourceID: "nas", filePath: "/Music/rain.mp3", genre: "Pop") == .ambient)
        #expect(on.kind(songID: "sea", sourceID: "nas", filePath: "/Sleep/sea.flac", genre: nil) == .ambient)
        #expect(on.kind(songID: "fan", sourceID: "nas", filePath: "/Misc/fan.mp3", genre: "White Noise") == .ambient)
        #expect(on.inferredKind(sourceID: "nas", filePath: "/Sleep/sea.flac", genre: nil) == .ambient)
    }

    @Test("关掉「单独归类环境音」:一律按音乐算,手动归属照旧记着")
    func switchOffTreatsAmbientAsMusic() {
        let overrides: [String: ListeningContentKind] = ["rain": .ambient, "book": .spokenWord]
        let off = inputs(
            overrides: overrides,
            folderTags: ["nas": ["/Books": .spokenWord, "/Books/Rain": .ambient, "/Sleep": .ambient]],
            separatesAmbient: false
        )
        #expect(off.overrides == overrides)
        #expect(off.kind(songID: "rain", sourceID: "nas", filePath: "/Music/rain.mp3", genre: nil) == .music)
        #expect(off.kind(songID: "book", sourceID: "nas", filePath: "/Music/b.mp3", genre: nil) == .spokenWord)
        #expect(off.kind(songID: "sea", sourceID: "nas", filePath: "/Sleep/sea.flac", genre: nil) == .music)
        #expect(off.kind(songID: "fan", sourceID: "nas", filePath: "/Misc/fan.mp3", genre: "White Noise") == .music)
        // 有声书目录里标成环境音的子目录:像标成「音乐」的子目录一样挡住上级,交回文件自己推断。
        #expect(off.kind(songID: "drop", sourceID: "nas", filePath: "/Books/Rain/drop.mp3", genre: nil) == .music)
        #expect(off.kind(songID: "ch1", sourceID: "nas", filePath: "/Books/ch1.mp3", genre: nil) == .spokenWord)
        // 整库遍历的那条快路径结论一样。
        var verdicts: [String: ListeningContentKind] = [:]
        for (id, path, genre) in [("rain", "/Music/rain.mp3", nil), ("sea", "/Sleep/sea.flac", nil),
                                  ("fan", "/Misc/fan.mp3", "White Noise"), ("drop", "/Books/Rain/drop.mp3", nil)]
            as [(String, String, String?)] {
            #expect(off.kind(songID: id, sourceID: "nas", filePath: path, genre: genre, genreVerdicts: &verdicts) == .music)
        }
    }

    @Test("开着时整库遍历与逐首判定一致")
    func fastPathMatches() {
        let on = inputs(folderTags: ["nas": ["/Sleep": .ambient]], separatesAmbient: true)
        var verdicts: [String: ListeningContentKind] = [:]
        for (path, genre) in [("/Sleep/a.mp3", nil), ("/x/b.mp3", "Rain Sounds"), ("/x/c.mp3", "Ambient"),
                              ("/x/d.m4b", "White Noise")] as [(String, String?)] {
            #expect(
                on.kind(songID: path, sourceID: "nas", filePath: path, genre: genre, genreVerdicts: &verdicts)
                    == on.kind(songID: path, sourceID: "nas", filePath: path, genre: genre)
            )
        }
    }

    @Test("开关的偏好默认开,存了就照存的读")
    func preferenceDefaultsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "ambient-preference-\(UUID().uuidString)"))
        #expect(AmbientSoundPreferences.isEnabled(in: defaults))
        AmbientSoundPreferences.setEnabled(false, in: defaults)
        #expect(!AmbientSoundPreferences.isEnabled(in: defaults))
        AmbientSoundPreferences.setEnabled(true, in: defaults)
        #expect(AmbientSoundPreferences.isEnabled(in: defaults))
    }
}

@Suite("Ambient sounds: storage and sync with older versions")
struct AmbientSoundStorageTests {
    private typealias Policy = SpokenWordSyncPolicy
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 没有环境音的版本认得的分类。
    private enum LegacyKind: String, Codable {
        case music, spokenWord, podcast
    }

    @Test("写盘时环境音写成音乐、播客写成有声书,另带清单;读回来还原")
    func storageRoundTrip() {
        let folderKey = SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/Sleep")
        let overrides: [String: ListeningContentKind] = [
            "rain": .ambient, "show": .podcast, "book": .spokenWord, "song": .music, folderKey: .ambient,
        ]
        let stored = SpokenWordOverrideStorage.storedValues(overrides)
        #expect(stored["rain"] == "music")
        #expect(stored[folderKey] == "music")
        #expect(stored["show"] == "spokenWord")
        #expect(stored["book"] == "spokenWord")
        #expect(stored["song"] == "music")
        let ambientIDs = SpokenWordOverrideStorage.ambientIDs(overrides)
        #expect(ambientIDs == ["rain", folderKey])
        let restored = SpokenWordOverrideStorage.overrides(
            from: stored,
            podcastSongIDs: SpokenWordOverrideStorage.podcastIDs(overrides),
            ambientSongIDs: ambientIDs
        )
        #expect(restored == overrides)
    }

    @Test("老版本读到的是音乐,不会当成有声书;新版本读老版本写的照旧")
    func olderVersionsReadMusic() {
        let stored = SpokenWordOverrideStorage.storedValues(["rain": .ambient, "show": .podcast])
        let legacy = stored.compactMapValues(LegacyKind.init(rawValue:))
        #expect(legacy == ["rain": .music, "show": .spokenWord])
        // 老版本写的文件没有环境音清单:读成它写的样子。
        let fromOld = SpokenWordOverrideStorage.overrides(from: ["a": "music", "b": "spokenWord"], podcastSongIDs: [])
        #expect(fromOld == ["a": .music, "b": .spokenWord])
        // 清单只在写成音乐的那条上生效:老版本把它改成了有声书,就是有声书。
        let changedByOld = SpokenWordOverrideStorage.overrides(
            from: ["rain": "spokenWord"], podcastSongIDs: [], ambientSongIDs: ["rain"]
        )
        #expect(changedByOld == ["rain": .spokenWord])
    }

    @Test("iCloud 文档:环境音的修正写成音乐加一个标记,往返不丢")
    func syncRoundTrip() throws {
        let records = SpokenWordLocalRecords(
            overrides: ["rain": "music", "song": "music"],
            ambientSongIDs: ["rain"],
            ledger: SpokenWordSyncLedger(
                overrideChangedAt: ["rain": at(10), "song": at(5)],
                ambientMarkChangedAt: ["rain": at(10)]
            )
        )
        let state = Policy.state(from: records)
        #expect(state.overrides["rain"]?.value == "music")
        #expect(state.ambientMarks["rain"]?.value == true)
        #expect(state.ambientMarks["song"] == nil)
        let data = try #require(Policy.encode(state))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"am\""))
        let decoded = try #require(Policy.decode(data))
        #expect(decoded == state)
        let back = Policy.records(from: decoded)
        #expect(back.ambientSongIDs == ["rain"])
        #expect(back.overrides == records.overrides)
        #expect(back.ledger.ambientMarkChangedAt["rain"] == at(10))
    }

    @Test("老版本推上来的文档没有环境音标记:合并后本机的标记还在")
    func mergeWithDocumentFromOlderVersion() throws {
        let local = Policy.state(from: SpokenWordLocalRecords(
            overrides: ["rain": "music"],
            ambientSongIDs: ["rain"],
            ledger: SpokenWordSyncLedger(overrideChangedAt: ["rain": at(10)], ambientMarkChangedAt: ["rain": at(10)])
        ))
        // 老版本解开再推回去:不认识的 "am" 一节丢了,修正记录原样留着。
        var fromOld = local
        fromOld.ambientMarks = [:]
        let oldJSON = try #require(Policy.encode(fromOld))
        #expect(!String(decoding: oldJSON, as: UTF8.self).contains("\"am\""))
        let remote = try #require(Policy.decode(oldJSON))
        let merged = Policy.merge(local, remote)
        #expect(merged.ambientMarks["rain"]?.value == true)
        let restored = SpokenWordOverrideStorage.overrides(
            from: Policy.records(from: merged).overrides,
            podcastSongIDs: [],
            ambientSongIDs: Policy.records(from: merged).ambientSongIDs
        )
        #expect(restored == ["rain": .ambient])
    }

    @Test("归回音乐留下墓碑,别的设备合并后也不再是环境音")
    func clearingTheMarkWins() {
        let marked = Policy.state(from: SpokenWordLocalRecords(
            overrides: ["rain": "music"],
            ambientSongIDs: ["rain"],
            ledger: SpokenWordSyncLedger(overrideChangedAt: ["rain": at(10)], ambientMarkChangedAt: ["rain": at(10)])
        ))
        let cleared = Policy.state(from: SpokenWordLocalRecords(
            overrides: ["rain": "music"],
            ledger: SpokenWordSyncLedger(overrideChangedAt: ["rain": at(20)], ambientMarkChangedAt: ["rain": at(20)])
        ))
        let merged = Policy.merge(marked, cleared)
        #expect(merged.ambientMarks["rain"]?.value == nil)
        #expect(!Policy.records(from: merged).ambientSongIDs.contains("rain"))
        #expect(Policy.merge(cleared, marked) == merged)
    }

    @Test("上传超出预算时环境音标记和别的记录一起按新旧裁")
    func uploadKeepsBudget() {
        var state = SpokenWordSyncState()
        for index in 0..<4000 {
            state.ambientMarks["song-\(index)-" + String(repeating: "x", count: 40)] =
                SpokenWordSyncRegister(value: true, stamp: at(TimeInterval(index)))
        }
        let upload = Policy.uploadState(state, byteBudget: 20 * 1024)
        #expect((Policy.encode(upload)?.count ?? .max) <= 20 * 1024)
        #expect(!upload.ambientMarks.isEmpty)
        #expect(upload.ambientMarks["song-3999-" + String(repeating: "x", count: 40)] != nil)
    }
}

@Suite("Ambient sounds: playback and grouping")
struct AmbientSoundPlaybackTests {
    private let shuffledLoop = ListeningPlayMode(shuffleEnabled: true, repeatMode: .all)

    @Test("进环境音:不随机、单曲循环,音乐的设置挂起,回到音乐还回去")
    func ambientParksMusic() {
        var ledger = ListeningPlayModeLedger()
        #expect(ledger.queueInstalled(ownedBy: .ambient, current: shuffledLoop) == AmbientSoundPlaybackPolicy.playMode)
        #expect(ledger.activeSpace == .ambient)
        #expect(ledger.parkedMusicMode == shuffledLoop)
        #expect(ledger.queueInstalled(ownedBy: .music, current: AmbientSoundPlaybackPolicy.playMode) == shuffledLoop)
        #expect(ledger.activeSpace == .music)
    }

    @Test("换一段环境音重新循环;环境音和书之间来回,音乐一直挂着")
    func ambientAndBooksKeepMusicParked() {
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .ambient, current: shuffledLoop)
        ledger.repeatChanged()
        let stopped = ListeningPlayMode(shuffleEnabled: false, repeatMode: .off)
        #expect(ledger.queueInstalled(ownedBy: .ambient, current: stopped) == AmbientSoundPlaybackPolicy.playMode)
        #expect(!ledger.repeatChangedDuringBook)
        #expect(ledger.queueInstalled(ownedBy: .spokenWord, current: AmbientSoundPlaybackPolicy.playMode) == .inOrder)
        #expect(ledger.activeSpace == .spokenWord)
        #expect(ledger.queueInstalled(ownedBy: .ambient, current: .inOrder) == AmbientSoundPlaybackPolicy.playMode)
        #expect(ledger.queueInstalled(ownedBy: .music, current: AmbientSoundPlaybackPolicy.playMode) == shuffledLoop)
    }

    @Test("电台不动账本;环境音时碰过的开关算数")
    func radioAndTouchedSwitches() {
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .ambient, current: shuffledLoop)
        #expect(ledger.queueInstalled(ownedBy: .radio, current: .inOrder) == nil)
        #expect(ledger.activeSpace == .ambient)
        ledger.shuffleChanged()
        #expect(ledger.shuffleChangedDuringBook)
    }

    @Test("定时:以分钟为主,没有「播完这一首」;不淡入淡出、不从曲库续歌")
    func sleepAndTransitions() {
        let options = SleepTimerOptionPolicy.options(for: .ambient, hasChapters: true)
        #expect(options == [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .minutes(90)])
        #expect(!ListeningSpaceTransitionPolicy.allowsCrossfade(from: .ambient, to: .ambient))
        #expect(!ListeningSpaceTransitionPolicy.allowsCrossfade(from: .music, to: .ambient))
        #expect(!ListeningSpaceTransitionPolicy.allowsCrossfade(from: .ambient, to: .music))
        #expect(!ShuffleLibraryContinuationPolicy.continuesFromLibrary(currentSpace: .ambient))
        #expect(SiriSleepTimerRequest.endOfTrack.resolution(space: .ambient, hasChapters: false) == .unavailable)
        #expect(SiriSleepTimerRequest.minutes30.resolution(space: .ambient, hasChapters: false) == .set(.minutes(30)))
        #expect(AmbientSoundPlaybackPolicy.quickTimerMinutes == [15, 30, 60, nil])
    }

    @Test("全屏:环境音几秒就进休憩层,音乐照旧五分钟")
    func fullscreenRest() {
        #expect(AmbientSoundPlaybackPolicy.fullscreenRestDelay(isAmbient: true) < 10)
        #expect(AmbientSoundPlaybackPolicy.fullscreenRestDelay(isAmbient: false) == 5 * 60)
    }

    @Test("单曲循环的环境音一律无缝自接")
    func seamlessLoop() {
        #expect(AmbientSoundPlaybackPolicy.forcesSeamlessLoop(space: .ambient, repeatMode: .one))
        #expect(!AmbientSoundPlaybackPolicy.forcesSeamlessLoop(space: .ambient, repeatMode: .all))
        #expect(!AmbientSoundPlaybackPolicy.forcesSeamlessLoop(space: .music, repeatMode: .one))
        #expect(!AmbientSoundPlaybackPolicy.forcesSeamlessLoop(space: nil, repeatMode: .one))
    }

    @Test("播放记录:曲库给的环境音单独算,不进音乐")
    func historySpace() {
        #expect(ListeningHistorySpacePolicy.space(songID: "rain", sourceID: "s", spokenWordSongIDs: [],
                                                  ambientSongIDs: ["rain"]) == .ambient)
        #expect(ListeningHistorySpacePolicy.space(songID: "song", sourceID: "s", spokenWordSongIDs: [],
                                                  ambientSongIDs: ["rain"]) == .music)
        #expect(ListeningHistorySpacePolicy.space(of: .ambient) == .ambient)
    }

    @Test("搜索:有环境音时多一个分段")
    func searchScopes() {
        #expect(ListeningSpaceSearchPolicy.scopes(visibleSpaces: [.music, .ambient]) == [.all, .music, .ambient])
        #expect(ListeningSpaceSearchPolicy.scopes(visibleSpaces: [.music]) == [])
        #expect(ListeningSpaceSearchPolicy.shows(.ambient, in: .ambient))
        #expect(!ListeningSpaceSearchPolicy.shows(.ambient, in: .music))
    }

    @Test("搜索:声音名先于专辑、目录,再到艺人与流派")
    func searchMatching() {
        typealias Candidate = ListeningSpaceSearchPolicy.AmbientCandidate
        let candidates = [
            Candidate(id: "genre", title: "Fan", genre: "Rain Sounds"),
            Candidate(id: "album", title: "Thunder", album: "Rain Collection"),
            Candidate(id: "exact", title: "Rain"),
            Candidate(id: "prefix", title: "Rain on Roof"),
            Candidate(id: "folder", title: "Drops", folder: "rain"),
            Candidate(id: "none", title: "Ocean"),
        ]
        #expect(ListeningSpaceSearchPolicy.matchAmbientSounds(query: "rain", in: candidates)
            == ["exact", "prefix", "album", "folder", "genre"])
        #expect(ListeningSpaceSearchPolicy.matchAmbientSounds(query: "  ", in: candidates).isEmpty)
        #expect(ListeningSpaceSearchPolicy.matchAmbientSounds(query: "thunder rain", in: candidates) == ["album"])
    }

    @Test("按专辑、目录分组,组里按碟号曲号排,认不出的放最后")
    func grouping() {
        func song(_ id: String, title: String, album: String? = nil, albumID: String? = nil,
                  path: String, track: Int? = nil) -> Song {
            Song(id: id, title: title, albumID: albumID, albumTitle: album, trackNumber: track,
                 fileFormat: .mp3, filePath: path, sourceID: "nas")
        }
        let songs = [
            song("w2", title: "Wind", album: "Weather", albumID: "a1", path: "/x/w2.mp3", track: 2),
            song("loose", title: "Fan", path: "fileid-123"),
            song("w1", title: "Rain", album: "Weather", albumID: "a1", path: "/x/w1.mp3", track: 1),
            song("s1", title: "Waves", path: "/Sleep/Beach/waves.flac"),
            song("s2", title: "Gulls", path: "/Sleep/Beach/gulls.flac"),
        ]
        let groups = AmbientSoundGrouping.groups(for: songs)
        #expect(groups.map(\.title) == ["Beach", "Weather", nil])
        #expect(groups[0].songIDs == ["s2", "s1"])
        #expect(groups[1].songIDs == ["w1", "w2"])
        #expect(groups[2].songIDs == ["loose"])
        #expect(groups[2].id == AmbientSoundGrouping.looseGroupID)
        #expect(AmbientSoundGrouping.groups(for: []).isEmpty)
    }

    @Test("首页胶囊:开关开着、有内容、资料库分类没收起才出现")
    func reachability() {
        #expect(AmbientSoundLibrarySection.isReachable(separatesAmbient: true, hasContent: true, sectionHidden: false))
        #expect(!AmbientSoundLibrarySection.isReachable(separatesAmbient: false, hasContent: true, sectionHidden: false))
        #expect(!AmbientSoundLibrarySection.isReachable(separatesAmbient: true, hasContent: false, sectionHidden: false))
        #expect(!AmbientSoundLibrarySection.isReachable(separatesAmbient: true, hasContent: true, sectionHidden: true))
    }
}
