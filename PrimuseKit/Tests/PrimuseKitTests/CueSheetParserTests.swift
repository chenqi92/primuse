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
