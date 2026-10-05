import Foundation
import Testing
@testable import PrimuseKit

@Test func cueSheetParsesAlbumMetadataAndTrackBoundaries() {
    let cue = #"""
    REM GENRE "Rock"
    REM DATE 1998
    PERFORMER "Album Artist"
    TITLE "Album Title"
    FILE "disc image.dts" WAVE
      TRACK 01 AUDIO
        TITLE "First"
        PERFORMER "Singer A"
        INDEX 00 00:00:00
        INDEX 01 00:02:00
      TRACK 02 AUDIO
        TITLE "Second"
        INDEX 01 04:15:37
    """#

    let parsed = CueSheetParser.parse(text: cue)
    #expect(parsed?.title == "Album Title")
    #expect(parsed?.performer == "Album Artist")
    #expect(parsed?.genre == "Rock")
    #expect(parsed?.year == 1998)
    #expect(parsed?.files.first?.name == "disc image.dts")
    #expect(parsed?.files.first?.tracks.count == 2)
    #expect(parsed?.files.first?.tracks[0].startTime == 2)
    #expect(parsed?.files.first?.tracks[0].endTime == 255.0 + 37.0 / 75.0)
    #expect(parsed?.files.first?.tracks[1].performer == nil)
}

@Test func cueSheetSupportsMultipleFilesAndRejectsMissingIndex01() {
    let cue = #"""
    FILE one.flac WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
    FILE two.flac WAVE
      TRACK 02 AUDIO
        INDEX 00 00:00:00
    """#

    let parsed = CueSheetParser.parse(text: cue)
    #expect(parsed?.files.count == 2)
    #expect(parsed?.files[0].tracks[0].endTime == nil)
    #expect(parsed?.files[1].tracks[0].startTime == nil)
}

@Test func cueTimeUsesSeventyFiveFramesPerSecond() {
    #expect(CueSheetParser.parseTime("01:02:74") == 62.0 + 74.0 / 75.0)
    #expect(CueSheetParser.parseTime("01:60:00") == nil)
    #expect(CueSheetParser.parseTime("01:02:75") == nil)
}

@Test func cueBoundarySkipsMalformedTrackWithoutIndex01() {
    let cue = #"""
    FILE album.flac WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        INDEX 00 01:00:00
      TRACK 03 AUDIO
        INDEX 01 02:00:00
    """#

    let parsed = CueSheetParser.parse(text: cue)
    #expect(parsed?.files[0].tracks[0].endTime == 120)
    #expect(parsed?.files[0].tracks[1].startTime == nil)
    #expect(parsed?.files[0].tracks[2].endTime == nil)
}

@Test func cueSheetFindsTrackByAudioFileAndStartTime() {
    let cue = #"""
    TITLE "Live"
    FILE "C:\Rips\Disc.WAV" WAVE
      TRACK 01 AUDIO
        TITLE "Intro"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Song"
        INDEX 01 03:00:00
    FILE "bonus.wav" WAVE
      TRACK 03 AUDIO
        INDEX 01 00:00:00
    """#
    let sheet = CueSheetParser.parse(text: cue)
    // 轨号被刮削改过也按起点认回来。
    #expect(sheet?.track(audioFileName: "disc.wav", startTime: 180, number: 7)?.title == "Song")
    #expect(sheet?.track(audioFileName: "disc.wav", startTime: nil, number: 1)?.title == "Intro")
    #expect(sheet?.track(audioFileName: "bonus.wav", startTime: 0, number: nil)?.number == 3)
    #expect(sheet?.track(audioFileName: "other.wav", startTime: 0, number: 1) == nil)

    // 只有一个 FILE 时不比名字(网盘上曲库里存的是文件 ID)。
    let single = CueSheetParser.parse(text: #"""
    FILE "CD.wav" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        INDEX 01 02:00:00
    """#)
    #expect(single?.track(audioFileName: "fileid-8f3a", startTime: 120, number: nil)?.number == 2)
}

@Test func cueTrackIdentityMatchesScannerDerivation() {
    let withAlbumArtist = CueSheetParser.parse(text: #"""
    PERFORMER "Band"
    TITLE "Album"
    REM GENRE "Jazz"
    REM DATE 2001
    FILE "a.wav" WAVE
      TRACK 01 AUDIO
        TITLE "One"
        PERFORMER "Guest"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        INDEX 01 01:00:00
    """#)!
    let tracks = withAlbumArtist.files[0].tracks
    let first = CueTrackIdentity(sheet: withAlbumArtist, track: tracks[0])
    #expect(first.title == "One")
    #expect(first.artist == "Guest")
    #expect(first.albumArtist == "Band")
    #expect(first.albumTitle == "Album")
    #expect(first.genre == "Jazz")
    #expect(first.year == 2001)
    let second = CueTrackIdentity(sheet: withAlbumArtist, track: tracks[1])
    #expect(second.title == nil)
    #expect(second.artist == "Band")
    #expect(second.trackNumber == 2)

    // 整张没有 PERFORMER:专辑艺术家跟这一轨,一个都没写就都空着。
    let bare = CueSheetParser.parse(text: #"""
    TITLE "Album"
    FILE "a.wav" WAVE
      TRACK 01 AUDIO
        PERFORMER "Solo"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        INDEX 01 01:00:00
    """#)!
    #expect(CueTrackIdentity(sheet: bare, track: bare.files[0].tracks[0]).albumArtist == "Solo")
    let empty = CueTrackIdentity(sheet: bare, track: bare.files[0].tracks[1])
    #expect(empty.artist == nil)
    #expect(empty.albumArtist == nil)
}
