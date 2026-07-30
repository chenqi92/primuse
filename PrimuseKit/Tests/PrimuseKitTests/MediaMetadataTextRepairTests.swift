import Testing
@testable import PrimuseKit

@Test func rejectsPlexQuestionMarkReplacementInChineseTitle() {
    #expect(MediaMetadataTextRepair.repaired("对面??") == nil)
    #expect(MediaMetadataTextRepair.isSuspicious("对面??"))
    #expect(
        MediaMetadataTextRepair.fileNameTitle(
            from: "/mnt/docker/TestMedia/PrimuseMusic/对面的女孩看过来.mp3"
        ) == "对面的女孩看过来"
    )
}

@Test func preservesIntentionalWesternQuestionMarks() {
    #expect(MediaMetadataTextRepair.repaired("What??") == "What??")
    #expect(MediaMetadataTextRepair.isSuspicious("What??") == false)
}

@Test func extractsPlexFilenameArtistFallback() {
    let path = "/mnt/docker/TestMedia/PrimuseMusic/等什么君 - 慕夏.mp3"
    #expect(MediaMetadataTextRepair.fileNameArtist(from: path) == "等什么君")
    #expect(MediaMetadataTextRepair.fileNameTitle(from: path) == "慕夏")
}

@Test func extractsSpacedUnderscoreNASFilenameFields() {
    let path = "/music/谭艳 _ 伤了心的女人怎么了 _ 20140101 _ 【贝壳音乐 环绕5.1声道】 _ PeY.dts"
    #expect(MediaMetadataTextRepair.fileNameArtist(from: path) == "谭艳")
    #expect(MediaMetadataTextRepair.fileNameTitle(from: path) == "伤了心的女人怎么了")
}

@Test func preservesBareUnderscoresInsideFilename() {
    let path = "/music/AC_DC_Live.flac"
    #expect(MediaMetadataTextRepair.fileNameArtist(from: path) == nil)
    #expect(MediaMetadataTextRepair.fileNameTitle(from: path) == "AC_DC_Live")
}

@Test func preservesNumericTrackPrefixBehavior() {
    #expect(MediaMetadataTextRepair.fileNameArtist(from: "/music/01 - Opening.flac") == nil)
    #expect(MediaMetadataTextRepair.fileNameTitle(from: "/music/01 - Opening.flac") == "Opening")
    #expect(MediaMetadataTextRepair.fileNameTitle(from: "/music/02. Finale.flac") == "Finale")
}
