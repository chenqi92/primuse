import Foundation
import Testing
@testable import PrimuseKit

@Suite("详情页头图的元信息")
struct CollectionDetailHeaderPolicyTests {
    @Test("专辑:流派 · 年份 · 格式,缺哪段略哪段")
    func albumMeta() {
        #expect(CollectionDetailHeaderPolicy.albumMeta(genre: "Pop", year: 2021, formats: ["M4A"]) == "Pop · 2021 · M4A")
        #expect(CollectionDetailHeaderPolicy.albumMeta(genre: "  ", year: 2021, formats: ["M4A"]) == "2021 · M4A")
        #expect(CollectionDetailHeaderPolicy.albumMeta(genre: " Jazz\n", year: nil, formats: []) == "Jazz")
        #expect(CollectionDetailHeaderPolicy.albumMeta(genre: nil, year: nil, formats: []) == "")
    }

    @Test("专辑:格式只在整张一致时才写")
    func albumMetaMixedFormats() {
        #expect(CollectionDetailHeaderPolicy.albumMeta(genre: "Rock", year: 2024, formats: ["FLAC", "MP3"]) == "Rock · 2024")
        #expect(CollectionDetailHeaderPolicy.albumMeta(genre: "Rock", year: 2024, formats: [""]) == "Rock · 2024")
    }

    @Test("歌单:有总时长才写,分隔符与专辑一致")
    func countAndDuration() {
        var formatted: [Double] = []
        let format: (Double) -> String = { formatted.append($0); return "1 小时 5 分" }
        #expect(CollectionDetailHeaderPolicy.countAndDuration(countText: "12 首", totalSeconds: 3900, durationText: format) == "12 首 · 1 小时 5 分")
        #expect(CollectionDetailHeaderPolicy.countAndDuration(countText: "0 首", totalSeconds: 0, durationText: format) == "0 首")
        #expect(formatted == [3900])
        #expect(CollectionDetailHeaderPolicy.separator == " \u{00B7} ")
    }
}
