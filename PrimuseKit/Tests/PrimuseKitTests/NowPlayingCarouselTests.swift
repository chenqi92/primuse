import Foundation
import Testing
@testable import PrimuseKit

@Suite("播放页转轮的排布")
struct NowPlayingCarouselConfigurationTests {
    private typealias Configuration = NowPlayingCarouselConfiguration

    @Test("默认关闭,没改过时用默认排布")
    func defaults() {
        #expect(Configuration.enabledByDefault == false)
        #expect(Configuration.decode("") == .default)
        #expect(Configuration.decode("   ") == .default)
        #expect(Configuration.default.leading.first == .equalizer)
        #expect(Configuration.default.trailing.first == .karaoke)
    }

    @Test("存下来的文本能原样读回,两边都空也照存")
    func roundTrip() {
        let configuration = Configuration(leading: [.similarSongs, .equalizer], trailing: [.karaoke])
        #expect(configuration.storageValue == "similarSongs,equalizer|karaoke")
        #expect(Configuration.decode(configuration.storageValue) == configuration)
        let empty = Configuration.decode("|")
        #expect(empty.isEmpty)
        #expect(empty.pages == [.player])
    }

    @Test("不认识的页名丢掉,重复的只留第一次,每边有上限")
    func normalization() {
        let decoded = Configuration.decode("equalizer,bogus,equalizer|equalizer,karaoke")
        #expect(decoded.leading == [.equalizer])
        #expect(decoded.trailing == [.karaoke])
        let crowded = Configuration(
            leading: [.equalizer, .audioEffects, .similarSongs, .albumAndArtist, .queue],
            trailing: []
        )
        #expect(crowded.leading.count == Configuration.maximumPanelsPerSide)
        #expect(crowded.unassigned.contains(.queue))
    }

    @Test("屏幕页序:左边从外往里,播放器居中,右边从里往外")
    func pageOrder() {
        let configuration = Configuration(leading: [.equalizer, .similarSongs], trailing: [.karaoke, .queue])
        #expect(configuration.pages == [
            .panel(.similarSongs), .panel(.equalizer), .player, .panel(.karaoke), .panel(.queue)
        ])
        #expect(configuration.playerPageIndex == 2)
    }

    @Test("放到另一边会从原来那边拿走;满了不动")
    func insertAndRemove() {
        var configuration = Configuration(leading: [.equalizer], trailing: [.karaoke])
        configuration.insert(.karaoke, on: .leading, at: 0)
        #expect(configuration.leading == [.karaoke, .equalizer])
        #expect(configuration.trailing.isEmpty)

        configuration.remove(.equalizer)
        #expect(configuration.leading == [.karaoke])
        #expect(configuration.side(of: .equalizer) == nil)

        var full = Configuration(leading: [.equalizer, .audioEffects, .similarSongs, .albumAndArtist], trailing: [])
        full.insert(.queue, on: .leading)
        #expect(full.leading == [.equalizer, .audioEffects, .similarSongs, .albumAndArtist])
        #expect(!full.canAdd(to: .leading))
        #expect(full.canAdd(to: .trailing))
    }

    @Test("同一边换顺序和 Array.move 一样")
    func reorder() {
        var configuration = Configuration(leading: [.equalizer, .audioEffects, .similarSongs], trailing: [.karaoke])
        configuration.move(on: .leading, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(configuration.leading == [.audioEffects, .similarSongs, .equalizer])
        configuration.move(on: .leading, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(configuration.leading == [.equalizer, .audioEffects, .similarSongs])
        configuration.move(on: .leading, fromOffsets: IndexSet([0, 1]), toOffset: 3)
        #expect(configuration.leading == [.similarSongs, .equalizer, .audioEffects])
        #expect(configuration.trailing == [.karaoke])
    }
}

@Suite("播放页转轮的手势")
struct NowPlayingCarouselPolicyTests {
    private typealias Policy = NowPlayingCarouselPolicy

    @Test("横向明显占优才翻页,往下拉与斜拉不抢")
    func axis() {
        #expect(Policy.recognizedAxis(translationX: 4, translationY: 1) == nil)
        #expect(Policy.recognizedAxis(translationX: -30, translationY: 6) == .horizontal)
        #expect(Policy.recognizedAxis(translationX: 12, translationY: 40) == .rejected)
        #expect(Policy.recognizedAxis(translationX: 20, translationY: 18) == .rejected)
    }

    @Test("拖过一段或甩一下翻一页,一次最多一页,两端不越界")
    func settle() {
        // 手指往左拖过三成:去右边那页。
        #expect(Policy.settledIndex(current: 2, translation: -120, predictedEndTranslation: -150, pageWidth: 390, pageCount: 5) == 3)
        // 拖得不够、也没甩:留在原地。
        #expect(Policy.settledIndex(current: 2, translation: -60, predictedEndTranslation: -80, pageWidth: 390, pageCount: 5) == 2)
        // 轻轻一甩也算。
        #expect(Policy.settledIndex(current: 2, translation: 40, predictedEndTranslation: 260, pageWidth: 390, pageCount: 5) == 1)
        // 甩得再远也只翻一页。
        #expect(Policy.settledIndex(current: 2, translation: -380, predictedEndTranslation: -2000, pageWidth: 390, pageCount: 5) == 3)
        // 拖过去又往回甩:以松手那一下为准。
        #expect(Policy.settledIndex(current: 2, translation: -130, predictedEndTranslation: 200, pageWidth: 390, pageCount: 5) == 2)
        // 两端。
        #expect(Policy.settledIndex(current: 0, translation: 300, predictedEndTranslation: 900, pageWidth: 390, pageCount: 5) == 0)
        #expect(Policy.settledIndex(current: 4, translation: -300, predictedEndTranslation: -900, pageWidth: 390, pageCount: 5) == 4)
    }

    @Test("拖动中跟手,两端外有阻尼且露出不到半页")
    func position() {
        #expect(Policy.position(current: 1, translation: -195, pageWidth: 390, pageCount: 3) == 1.5)
        let beyondStart = Policy.position(current: 0, translation: 2000, pageWidth: 390, pageCount: 3)
        #expect(beyondStart < 0 && beyondStart > -0.5)
        let beyondEnd = Policy.position(current: 2, translation: -2000, pageWidth: 390, pageCount: 3)
        #expect(beyondEnd > 2 && beyondEnd < 2.5)
    }

    @Test("停稳只画一页,转动途中画相邻两页")
    func visiblePages() {
        #expect(Policy.visiblePageIndices(position: 2, pageCount: 5) == 2...2)
        #expect(Policy.visiblePageIndices(position: 2.4, pageCount: 5) == 2...3)
        #expect(Policy.visiblePageIndices(position: -0.2, pageCount: 5) == 0...0)
        #expect(Policy.visiblePageIndices(position: 4.2, pageCount: 5) == 4...4)
    }
}
