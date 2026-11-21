import Foundation
import Testing
@testable import PrimuseKit

@Suite("Save location: lyrics")
struct SaveLocationLyricsPlanTests {
    private typealias Policy = SaveLocationPolicy

    private func localFile(
        audio: Policy.Access = .writable,
        folder: Policy.Access = .writable,
        canEmbed: Bool = true
    ) -> Policy.Facts {
        Policy.Facts(source: .files, audioFile: audio, folder: folder, canEmbed: canEmbed)
    }

    @Test("用户在歌词来源里选用了 Primuse 里的版本:只存在 Primuse,原因不是只读音乐源")
    func primuseVersionIsItsOwnReason() {
        var facts = localFile()
        facts.usesPrimuseVersion = true
        let plan = Policy.lyricsPlan(facts, requested: .alongside)
        #expect(plan.destination == .primuseOnly)
        #expect(plan.reason == .usesPrimuseVersion)
        #expect(plan.remedies.isEmpty)

        let readOnly = Policy.lyricsPlan(Policy.Facts(source: .readOnly), requested: .off)
        #expect(readOnly.reason == .readOnlySource)
        #expect(readOnly.reason != plan.reason)
    }

    @Test("文件夹里的歌:三档设置各自落到歌词文件、歌词文件加音频、音频文件")
    func folderSongFollowsTheSetting() {
        let facts = localFile()
        #expect(Policy.lyricsPlan(facts, requested: .off) == .init(destination: .lyricsFile))
        #expect(Policy.lyricsPlan(facts, requested: .alongside)
            == .init(destination: .lyricsFileAndAudioFile, embeddingMode: .alongside))
        #expect(Policy.lyricsPlan(facts, requested: .embedOnly)
            == .init(destination: .audioFile, embeddingMode: .embedOnly))
        // 只嵌入时旁边已经有的歌词文件照样跟着更新。
        #expect(Policy.lyricsPlan(facts, requested: .embedOnly, lyricsDocumentExists: true).destination
            == .lyricsFileAndAudioFile)
    }

    @Test("单独添加的文件选嵌入:嵌入照常,不被文件夹拦住")
    func individuallyAddedFileStillEmbeds() {
        let facts = localFile(folder: .noAccess)
        let embedOnly = Policy.lyricsPlan(facts, requested: .embedOnly)
        #expect(embedOnly.destination == .audioFile)
        #expect(embedOnly.reason == .none)
        #expect(embedOnly.embeddingMode == .embedOnly)

        let alongside = Policy.lyricsPlan(facts, requested: .alongside)
        #expect(alongside.destination == .audioFile)
        #expect(alongside.reason == .noFolderAccessEmbedsOnly)
        #expect(alongside.embeddingMode == .embedOnly, "歌词文件那一半写不了,只剩嵌入")
        #expect(alongside.remedies == [.grantFolderAccess])
    }

    @Test("单独添加的文件只写歌词文件:只存在 Primuse,给授权文件夹和改嵌入两条路")
    func individuallyAddedFileWithLyricsFileOnly() {
        let plan = Policy.lyricsPlan(localFile(folder: .noAccess), requested: .off)
        #expect(plan.destination == .primuseOnly)
        #expect(plan.reason == .noFolderAccess)
        #expect(plan.remedies == [.grantFolderAccess, .embedThisSong, .embedAllSongs])

        // 格式不能嵌入:改嵌入也没用,只剩授权文件夹。
        let wav = Policy.lyricsPlan(localFile(folder: .noAccess, canEmbed: false), requested: .off)
        #expect(wav.remedies == [.grantFolderAccess])
    }

    @Test("文件夹没有写入权限:不提授权,能嵌入就给改嵌入")
    func unwritableFolder() {
        let off = Policy.lyricsPlan(localFile(folder: .notWritable), requested: .off)
        #expect(off.destination == .primuseOnly)
        #expect(off.reason == .folderNotWritable)
        #expect(off.remedies == [.embedThisSong, .embedAllSongs])

        let alongside = Policy.lyricsPlan(localFile(folder: .notWritable), requested: .alongside)
        #expect(alongside.destination == .audioFile)
        #expect(alongside.reason == .folderNotWritableEmbedsOnly)
        #expect(alongside.remedies.isEmpty)
    }

    @Test("音频文件不能写、整块盘只读")
    func unwritableAudioAndReadOnlyVolume() {
        let audio = Policy.lyricsPlan(localFile(audio: .notWritable), requested: .embedOnly)
        #expect(audio.destination == .primuseOnly)
        #expect(audio.reason == .audioFileNotWritable)

        let alongside = Policy.lyricsPlan(localFile(audio: .notWritable), requested: .alongside)
        #expect(alongside.destination == .lyricsFile)
        #expect(alongside.reason == .audioFileNotWritable)

        for mode in LyricsEmbeddingMode.allCases {
            let plan = Policy.lyricsPlan(localFile(audio: .readOnlyVolume, folder: .readOnlyVolume), requested: mode)
            #expect(plan.destination == .primuseOnly)
            #expect(plan.reason == .readOnlyVolume)
            #expect(plan.remedies.isEmpty)
        }
    }

    @Test("单独添加的文件本身也改不了:原因说音频文件,只在授权文件夹能写歌词文件时给授权")
    func individuallyAddedFileThatIsNotWritable() {
        let facts = localFile(audio: .notWritable, folder: .noAccess)
        let alongside = Policy.lyricsPlan(facts, requested: .alongside)
        #expect(alongside.destination == .primuseOnly)
        #expect(alongside.reason == .audioFileNotWritable, "Primuse cannot change the file itself either")
        #expect(alongside.remedies == [.grantFolderAccess])
        let embedOnly = Policy.lyricsPlan(facts, requested: .embedOnly)
        #expect(embedOnly.reason == .audioFileNotWritable)
        #expect(embedOnly.remedies.isEmpty, "Granting the folder does not make the audio file writable")
        let off = Policy.lyricsPlan(facts, requested: .off)
        #expect(off.reason == .noFolderAccess)
        #expect(off.remedies == [.grantFolderAccess], "Embedding cannot help when the file is not writable")
    }

    @Test("格式不能嵌入时选了嵌入:写歌词文件并说明")
    func formatThatCannotEmbed() {
        let plan = Policy.lyricsPlan(localFile(canEmbed: false), requested: .embedOnly)
        #expect(plan.destination == .lyricsFile)
        #expect(plan.reason == .formatCannotEmbed)
        #expect(Policy.lyricsPlan(localFile(canEmbed: false), requested: .off).reason == .none)
    }

    @Test("媒体服务器、只读源、连不上")
    func serverReadOnlyAndUnreachable() {
        #expect(Policy.lyricsPlan(.init(source: .mediaServer(writesLyrics: true)), requested: .off).destination == .mediaServer)
        let emby = Policy.lyricsPlan(.init(source: .mediaServer(writesLyrics: false)), requested: .off)
        #expect(emby.destination == .primuseOnly)
        #expect(emby.reason == .serverTakesNoLyrics)
        let busy = Policy.lyricsPlan(.init(source: .files, reachability: .temporarilyUnreachable), requested: .off)
        #expect(busy.destination == .undetermined)
        #expect(busy.reason == .temporarilyUnreachable)
        #expect(Policy.lyricsPlan(.init(source: .files, reachability: .failed), requested: .off).reason == .unavailable)
    }

    @Test("远端源没探测文件夹和音频:照常按设置写,由服务端判断")
    func remoteSourcesAreNotGuessed() {
        let facts = Policy.Facts(source: .files, audioFile: .unknown, folder: .unknown, canEmbed: true)
        #expect(Policy.lyricsPlan(facts, requested: .alongside).destination == .lyricsFileAndAudioFile)
        #expect(Policy.lyricsPlan(facts, requested: .off).destination == .lyricsFile)
    }

    @Test("「歌词保存到」收窄:只在旁边的文件写不了时把歌词文件并嵌入收成只嵌入")
    func effectiveModes() {
        #expect(Policy.effectiveLyricsMode(.alongside, folder: .noAccess) == .embedOnly)
        #expect(Policy.effectiveLyricsMode(.alongside, folder: .notWritable) == .embedOnly)
        #expect(Policy.effectiveLyricsMode(.alongside, folder: .writable) == .alongside)
        #expect(Policy.effectiveLyricsMode(.alongside, folder: .unknown) == .alongside)
        #expect(Policy.effectiveLyricsMode(.off, folder: .noAccess) == .off)
        #expect(Policy.effectiveCoverMode(.alongside, folder: .noAccess) == .embedOnly)
        #expect(Policy.effectiveCoverMode(.off, folder: .noAccess) == .off)
    }
}

@Suite("Save location: tags and cover")
struct SaveLocationTagPlanTests {
    private typealias Policy = SaveLocationPolicy

    @Test("嵌入只需要音频文件可写:单独添加的文件照样写进文件")
    func embeddingNeedsOnlyTheAudioFile() {
        let facts = Policy.Facts(source: .files, audioFile: .writable, folder: .noAccess, canEmbed: true)
        #expect(Policy.tagPlan(facts, capability: .embedded) == .init(destination: .audioFile))
        let locked = Policy.Facts(source: .files, audioFile: .notWritable, folder: .writable, canEmbed: true)
        #expect(Policy.tagPlan(locked, capability: .embedded).reason == .audioFileNotWritable)
        let volume = Policy.Facts(source: .files, audioFile: .readOnlyVolume, folder: .readOnlyVolume, canEmbed: true)
        #expect(Policy.tagPlan(volume, capability: .embedded).reason == .readOnlyVolume)
    }

    @Test("只收封面文件的格式:封面要写旁边的文件,所以看文件夹")
    func coverFileNeedsTheFolder() {
        let folder = Policy.Facts(source: .files, audioFile: .writable, folder: .writable)
        #expect(Policy.tagPlan(folder, capability: .sidecarOnly).reason == .formatCannotEmbed)
        let single = Policy.Facts(source: .files, audioFile: .writable, folder: .noAccess)
        let plan = Policy.tagPlan(single, capability: .sidecarOnly)
        #expect(plan.reason == .noFolderAccess)
        #expect(plan.remedies == [.grantFolderAccess])
    }

    @Test("只读源和媒体服务器")
    func readOnlyAndServer() {
        #expect(Policy.tagPlan(.init(source: .readOnly), capability: .localOnly).reason == .readOnlySource)
        #expect(Policy.tagPlan(.init(source: .mediaServer(writesLyrics: false)), capability: .serverAPI).destination
            == .mediaServer)
    }
}

@Suite("Lyrics embedding per song")
struct LyricsEmbeddingSongModeTests {
    @Test("单独为一首歌选的保存方式优先,清掉后跟随全局")
    func songOverrideFallsBackToGlobal() throws {
        let suite = "SaveLocationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        EmbeddedLyricsCopyPolicy.setMode(.off, defaults: defaults)
        #expect(EmbeddedLyricsCopyPolicy.mode(forSongID: "a", defaults: defaults) == .off)
        EmbeddedLyricsCopyPolicy.setMode(.embedOnly, forSongID: "a", defaults: defaults)
        #expect(EmbeddedLyricsCopyPolicy.mode(forSongID: "a", defaults: defaults) == .embedOnly)
        #expect(EmbeddedLyricsCopyPolicy.mode(forSongID: "b", defaults: defaults) == .off)
        EmbeddedLyricsCopyPolicy.setMode(nil, forSongID: "a", defaults: defaults)
        #expect(EmbeddedLyricsCopyPolicy.mode(forSongID: "a", defaults: defaults) == .off)
        #expect(defaults.object(forKey: EmbeddedLyricsCopyPolicy.songModesDefaultsKey) == nil)
    }
}

@Suite("Tag write conflicts")
struct TagWriteConflictPolicyTests {
    private typealias State = TagWriteConflictPolicy.FieldState<String>

    @Test("别处改的字段和这次改的不重叠:自动重试")
    func disjointChangesRetry() {
        // 用户改了艺人;文件里艺人还是原来的(别处改的是专辑,不在这次改的字段里)。
        let changed = [State(field: "artist", baseline: "Old", fileNow: "Old", edited: "New")]
        #expect(TagWriteConflictPolicy.resolve(changed) == .retry)
    }

    @Test("文件里已经是用户要的值:不算冲突")
    func alreadyWrittenValueIsNotAConflict() {
        let changed = [State(field: "title", baseline: "A", fileNow: "B ", edited: "B")]
        #expect(TagWriteConflictPolicy.resolve(changed) == .retry)
    }

    @Test("两边都改了同一项:要用户选,只列重叠的那几项")
    func overlappingChangesAskTheUser() {
        let changed = [
            State(field: "artist", baseline: "Old", fileNow: "Other device", edited: "Mine"),
            State(field: "year", baseline: "2001", fileNow: "2001", edited: "2002"),
            State(field: "genre", baseline: nil, fileNow: "Jazz", edited: "Pop"),
        ]
        #expect(TagWriteConflictPolicy.resolve(changed) == .askUser(["artist", "genre"]))
    }

    @Test("换了封面、文件又变过:没有基线,只要文件里不是新封面就交给用户选")
    func coverChangedElsewhereAsksTheUser() {
        #expect(TagWriteConflictPolicy.coverOverlaps(userChangedCover: true, fileCoverIsTheNewOne: false))
        #expect(!TagWriteConflictPolicy.coverOverlaps(userChangedCover: true, fileCoverIsTheNewOne: true))
        #expect(!TagWriteConflictPolicy.coverOverlaps(userChangedCover: false, fileCoverIsTheNewOne: false))
    }

    @Test("空白和空串当成没有值")
    func blanksCompareAsMissing() {
        let changed = [State(field: "genre", baseline: "", fileNow: nil, edited: "Pop")]
        #expect(TagWriteConflictPolicy.resolve(changed) == .retry)
        #expect(TagWriteConflictPolicy.normalized("  ") == nil)
        #expect(TagWriteConflictPolicy.normalized(" a ") == "a")
    }
}
