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
