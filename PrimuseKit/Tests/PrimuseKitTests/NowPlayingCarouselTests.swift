import Foundation
import Testing
@testable import PrimuseKit

@Suite("播放页转轮的排布")
struct NowPlayingCarouselConfigurationTests {
    private typealias Configuration = NowPlayingCarouselConfiguration

    @Test("默认关闭,没改过时左边调音、发现,右边接下来、舞台")
    func defaults() {
        #expect(Configuration.enabledByDefault == false)
        #expect(Configuration.decode("") == .default)
        #expect(Configuration.decode("   ") == .default)
        #expect(Configuration.default.leading == [.sound, .explore])
        #expect(Configuration.default.trailing == [.upNext, .stage])
        #expect(Configuration.default.unassigned.isEmpty)
    }

    @Test("存下来的文本能原样读回,两边都空也照存")
    func roundTrip() {
        let configuration = Configuration(leading: [.explore, .sound], trailing: [.stage])
        #expect(configuration.storageValue == "explore,sound|stage")
        #expect(Configuration.decode(configuration.storageValue) == configuration)
        let empty = Configuration.decode("|")
        #expect(empty.isEmpty)
        #expect(empty.pages == [.player])
    }

    @Test("旧版六页并进四个面:左右归属与先后不变,重复的只留先出现的")
    func legacyMigration() {
        // 旧版默认排布。
        let legacyDefault = Configuration.decode("equalizer,audioEffects,similarSongs,albumAndArtist|karaoke,queue")
        #expect(legacyDefault.leading == [.sound, .explore])
        #expect(legacyDefault.trailing == [.stage, .upNext])

        // 先出现的那边为准:音效在左边先出现,右边的均衡器就不再放。
        let split = Configuration.decode("queue,audioEffects|equalizer,karaoke,albumAndArtist")
        #expect(split.leading == [.upNext, .sound])
        #expect(split.trailing == [.stage, .explore])

        // 新旧名字混着也认,不认识的照旧丢掉。
        let mixed = Configuration.decode("similarSongs,explore,bogus|stage,karaoke")
        #expect(mixed.leading == [.explore])
        #expect(mixed.trailing == [.stage])

        // 升级后再存一次就是新名字。
        #expect(legacyDefault.storageValue == "sound,explore|stage,upNext")
    }

    @Test("不认识的名字丢掉,重复的只留第一次,每边有上限")
    func normalization() {
        let decoded = Configuration.decode("sound,bogus,sound|sound,stage")
        #expect(decoded.leading == [.sound])
        #expect(decoded.trailing == [.stage])
        let crowded = Configuration(leading: [.sound, .explore, .upNext, .stage, .sound], trailing: [.stage])
        #expect(crowded.leading.count == Configuration.maximumPanelsPerSide)
        #expect(crowded.trailing.isEmpty)
    }

    @Test("屏幕页序:左边从外往里,播放器居中,右边从里往外")
    func pageOrder() {
        let configuration = Configuration(leading: [.sound, .explore], trailing: [.upNext, .stage])
        #expect(configuration.pages == [
            .panel(.explore), .panel(.sound), .player, .panel(.upNext), .panel(.stage)
        ])
        #expect(configuration.playerPageIndex == 2)
    }

    @Test("一张卡都没有的面临时跳过,其余顺序不变")
    func skipping() {
        let configuration = Configuration.default
        let skipped = configuration.skippingPanels { $0 == .explore }
        #expect(skipped.leading == [.sound])
        #expect(skipped.trailing == [.upNext, .stage])
        #expect(skipped.pages == [.panel(.sound), .player, .panel(.upNext), .panel(.stage)])
        #expect(configuration.skippingPanels { _ in true }.pages == [.player])
    }

    @Test("放到另一边会从原来那边拿走;满了不动")
    func insertAndRemove() {
        var configuration = Configuration(leading: [.sound], trailing: [.stage])
        configuration.insert(.stage, on: .leading, at: 0)
        #expect(configuration.leading == [.stage, .sound])
        #expect(configuration.trailing.isEmpty)

        configuration.remove(.sound)
        #expect(configuration.leading == [.stage])
        #expect(configuration.side(of: .sound) == nil)
        #expect(configuration.unassigned == [.sound, .explore, .upNext])

        var full = Configuration(leading: [.sound, .explore, .upNext, .stage], trailing: [])
        #expect(!full.canAdd(to: .leading))
        #expect(full.canAdd(to: .trailing))
        full.insert(.sound, on: .trailing)
        #expect(full.leading == [.explore, .upNext, .stage])
        #expect(full.trailing == [.sound])
    }

    @Test("同一边换顺序和 Array.move 一样")
    func reorder() {
        var configuration = Configuration(leading: [.sound, .explore, .upNext], trailing: [.stage])
        configuration.move(on: .leading, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(configuration.leading == [.explore, .upNext, .sound])
        configuration.move(on: .leading, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(configuration.leading == [.sound, .explore, .upNext])
        configuration.move(on: .leading, fromOffsets: IndexSet([0, 1]), toOffset: 3)
        #expect(configuration.leading == [.upNext, .sound, .explore])
        #expect(configuration.trailing == [.stage])
    }
}

@Suite("播放页转轮的卡片")
struct NowPlayingCarouselCardTests {
    private typealias Settings = NowPlayingCarouselCardSettings

    @Test("每张卡只属于一面,四个面都有卡")
    func cardsBelongToOnePanel() {
        #expect(NowPlayingCarouselPanel.sound.cards == [.equalizer, .audioEffects, .speedAndPitch, .outputAndQuality])
        #expect(NowPlayingCarouselPanel.explore.cards == [.album, .artist, .similarSongs])
        #expect(NowPlayingCarouselPanel.upNext.cards == [.playbackModes, .queue])
        #expect(NowPlayingCarouselPanel.stage.cards == [.karaoke, .fullscreenEffects])
        let all = NowPlayingCarouselPanel.allCases.flatMap(\.cards)
        #expect(all.count == NowPlayingCarouselCard.allCases.count)
        #expect(Set(all).count == all.count)
    }

    @Test("默认全开;关掉的按固定顺序存,读不认识的丢掉")
    func storage() {
        #expect(Settings.decode("").isDefault)
        var settings = Settings()
        settings.setEnabled(false, for: .queue)
        settings.setEnabled(false, for: .equalizer)
        #expect(settings.storageValue == "equalizer,queue")
        #expect(Settings.decode("queue, equalizer,bogus") == settings)
        settings.setEnabled(true, for: .equalizer)
        #expect(settings.isEnabled(.equalizer))
        #expect(settings.storageValue == "queue")
    }

    @Test("Apple Music 曲目不出均衡器、音效、速度音调与卡拉 OK;投放时不出均衡器与音效")
    func availability() {
        let settings = Settings()
        let appleMusic = NowPlayingCarouselCardContext(isAppleMusic: true)
        #expect(settings.visibleCards(on: .sound, in: appleMusic) == [.outputAndQuality])
        #expect(settings.visibleCards(on: .stage, in: appleMusic) == [.fullscreenEffects])
        #expect(settings.visibleCards(on: .explore, in: appleMusic) == [.album, .artist, .similarSongs])

        let casting = NowPlayingCarouselCardContext(isCasting: true)
        #expect(settings.visibleCards(on: .sound, in: casting) == [.speedAndPitch, .outputAndQuality])
        #expect(settings.visibleCards(on: .stage, in: casting) == [.karaoke, .fullscreenEffects])

        let local = NowPlayingCarouselCardContext()
        #expect(settings.visibleCards(on: .sound, in: local) == NowPlayingCarouselPanel.sound.cards)
    }

    @Test("用户关掉的与当前用不了的叠在一起;一张不剩的面从转轮里跳过")
    func emptyPanelSkipped() {
        var settings = Settings()
        settings.setEnabled(false, for: .outputAndQuality)
        let appleMusic = NowPlayingCarouselCardContext(isAppleMusic: true)
        #expect(settings.visibleCards(on: .sound, in: appleMusic).isEmpty)
        let pages = NowPlayingCarouselConfiguration.default.skippingPanels {
            settings.visibleCards(on: $0, in: appleMusic).isEmpty
        }.pages
        #expect(pages == [.panel(.explore), .player, .panel(.upNext), .panel(.stage)])
        // 本机的歌照样有调音。
        #expect(!settings.visibleCards(on: .sound, in: .init()).isEmpty)
    }
}

@Suite("播放页转轮的全屏去向")
struct NowPlayingCarouselFullscreenTests {
    private typealias Policy = NowPlayingCarouselFullscreenPolicy

    @Test("每一面去自己的全屏")
    func destinations() {
        func destination(_ page: NowPlayingCarouselPage, karaoke: Bool = true, album: Bool = true, artist: Bool = true) -> NowPlayingCarouselFullscreenDestination {
            Policy.destination(for: page, karaokeAvailable: karaoke, hasAlbum: album, hasArtist: artist)
        }
        #expect(destination(.player) == .playerDefault)
        #expect(destination(.panel(.sound)) == .effect("spectrumHorizon"))
        #expect(destination(.panel(.upNext)) == .effect("albumFlow"))
        #expect(destination(.panel(.stage)) == .karaokeStage)
        #expect(destination(.panel(.stage), karaoke: false) == .selectedEffect)
        #expect(destination(.panel(.explore)) == .albumPage)
        #expect(destination(.panel(.explore), album: false) == .artistPage)
        #expect(destination(.panel(.explore), album: false, artist: false) == .selectedEffect)
    }

    @Test("转横屏只在打开了自动全屏时才进,去向同样按面区分")
    func landscape() {
        #expect(Policy.landscapeDestination(
            for: .panel(.upNext), entersFullscreenInLandscape: false,
            karaokeAvailable: true, hasAlbum: true, hasArtist: true
        ) == nil)
        #expect(Policy.landscapeDestination(
            for: .panel(.upNext), entersFullscreenInLandscape: true,
            karaokeAvailable: true, hasAlbum: true, hasArtist: true
        ) == .effect("albumFlow"))
        #expect(Policy.landscapeDestination(
            for: .player, entersFullscreenInLandscape: true,
            karaokeAvailable: true, hasAlbum: true, hasArtist: true
        ) == .playerDefault)
    }

    @Test("双指张开过了门槛才进全屏")
    func pinch() {
        #expect(!Policy.pinchCommits(magnification: 1))
        #expect(!Policy.pinchCommits(magnification: 1.1))
        #expect(Policy.pinchCommits(magnification: 1.3))
        #expect(!Policy.pinchCommits(magnification: 0.7))
        #expect(!Policy.pinchCommits(magnification: .nan))
    }

    @Test("全屏效果一排:当前的在前,最近进过的其次,不够按推荐补,目录里没有的丢掉")
    func effectShelf() {
        let available = ["native", "spectrumHorizon", "albumFlow", "kineticLyrics", "vinylDeck", "auroraVeil", "radialPulse"]
        var recent: [String] = []
        recent = NowPlayingCarouselEffectShelf.recording("albumFlow", into: recent)
        recent = NowPlayingCarouselEffectShelf.recording("removedEffect", into: recent)
        recent = NowPlayingCarouselEffectShelf.recording("albumFlow", into: recent)
        #expect(recent == ["albumFlow", "removedEffect"])
        #expect(NowPlayingCarouselEffectShelf.decodeRecent(NowPlayingCarouselEffectShelf.encodeRecent(recent)) == recent)

        let shelf = NowPlayingCarouselEffectShelf.shelf(
            current: "kineticLyrics",
            recent: recent,
            suggestions: ["spectrumHorizon", "albumFlow", "vinylDeck", "auroraVeil", "radialPulse"],
            available: available,
            limit: 5
        )
        #expect(shelf == ["kineticLyrics", "albumFlow", "spectrumHorizon", "vinylDeck", "auroraVeil"])

        let capped = (0..<10).reduce([String]()) { NowPlayingCarouselEffectShelf.recording("e\($1)", into: $0) }
        #expect(capped.count == NowPlayingCarouselEffectShelf.recentLimit)
        #expect(capped.first == "e9")
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

    @Test("转盘停在播放器上只露小图标,离开不到半页就长全")
    func dialChrome() {
        #expect(Policy.dialChrome(position: 2, playerIndex: 2) == 0)
        #expect(Policy.dialChrome(position: 2.2, playerIndex: 2) > 0.4)
        #expect(Policy.dialChrome(position: 1.5, playerIndex: 2) == 1)
        #expect(Policy.dialChrome(position: 0, playerIndex: 2) == 1)
    }

    @Test("速度、音调按档位一档一档走,不在档上时先落到相邻的档,到头不动")
    func stepper() {
        let rates = NowPlayingCarouselStepper.playbackRates
        #expect(NowPlayingCarouselStepper.step(1, by: 1, in: rates) == 1.25)
        #expect(NowPlayingCarouselStepper.step(1, by: -1, in: rates) == 0.75)
        #expect(NowPlayingCarouselStepper.step(1.1, by: 1, in: rates) == 1.25)
        #expect(NowPlayingCarouselStepper.step(1.1, by: -1, in: rates) == 1)
        #expect(NowPlayingCarouselStepper.step(2, by: 1, in: rates) == 2)
        #expect(NowPlayingCarouselStepper.step(0.5, by: -2, in: rates) == 0.5)
        #expect(!NowPlayingCarouselStepper.canStep(2, by: 1, in: rates))
        #expect(NowPlayingCarouselStepper.canStep(2, by: -1, in: rates))
        let keys = (-3...3).map(Double.init)
        #expect(NowPlayingCarouselStepper.step(0, by: 2, in: keys) == 2)
        #expect(NowPlayingCarouselStepper.step(-3, by: -1, in: keys) == -3)
    }

    @Test("首次回弹:两边都有面时先右后左再回正,一边没有就只弹有的那边")
    func hintBounce() {
        #expect(NowPlayingCarouselHintPolicy.bounceSteps(hasLeading: true, hasTrailing: true) == [-0.1, 0.08, 0])
        #expect(NowPlayingCarouselHintPolicy.bounceSteps(hasLeading: false, hasTrailing: true) == [-0.1, 0])
        #expect(NowPlayingCarouselHintPolicy.bounceSteps(hasLeading: true, hasTrailing: false) == [0.1, 0])
        #expect(NowPlayingCarouselHintPolicy.bounceSteps(hasLeading: false, hasTrailing: false).isEmpty)
    }
}

@Suite("调音面频响曲线的起手")
struct NowPlayingCarouselEQGestureTests {
    private typealias Policy = NowPlayingCarouselEQGesturePolicy

    @Test("竖着起手交给滚动,横着起手开始画,按住不动够久才开始调")
    func decision() {
        // 手指还在容差里:没按够久时继续等,按够了就开始调。
        #expect(Policy.decision(translationX: 2, translationY: 3, heldFor: 0.05) == .undecided)
        #expect(Policy.decision(translationX: 2, translationY: 3, heldFor: Policy.holdDuration) == .begin(.hold))
        // 竖着起手:哪怕已经按了一会儿,只要还没开始调,就是在滚整面。
        #expect(Policy.decision(translationX: 2, translationY: -14, heldFor: 0.1) == .yield)
        #expect(Policy.decision(translationX: 0, translationY: 30, heldFor: 0.15) == .yield)
        // 斜着起手不算横着。
        #expect(Policy.decision(translationX: 12, translationY: 11, heldFor: 0.05) == .yield)
        // 横着起手:左右都算。
        #expect(Policy.decision(translationX: 14, translationY: 3, heldFor: 0.05) == .begin(.sweep))
        #expect(Policy.decision(translationX: -16, translationY: -6, heldFor: 0.02) == .begin(.sweep))
        #expect(Policy.decision(translationX: .nan, translationY: 0, heldFor: 1) == .yield)
    }

    @Test("横坐标认最近的一段,超出两端按两端算")
    func band() {
        #expect(Policy.band(atX: 12, plotMinX: 12, plotWidth: 300, count: 10) == 0)
        #expect(Policy.band(atX: 312, plotMinX: 12, plotWidth: 300, count: 10) == 9)
        #expect(Policy.band(atX: 12 + 300.0 / 9 * 4 + 10, plotMinX: 12, plotWidth: 300, count: 10) == 4)
        #expect(Policy.band(atX: -40, plotMinX: 12, plotWidth: 300, count: 10) == 0)
        #expect(Policy.band(atX: 900, plotMinX: 12, plotWidth: 300, count: 10) == 9)
        #expect(Policy.band(atX: 50, plotMinX: 0, plotWidth: 0, count: 10) == 0)
    }

    @Test("高度换成增益:顶上最大、底下最小,半分贝一档,靠近 0 吸到 0")
    func gain() {
        #expect(Policy.gain(atY: 6, plotMinY: 6, plotHeight: 100, minimum: -12, maximum: 12) == 12)
        #expect(Policy.gain(atY: 106, plotMinY: 6, plotHeight: 100, minimum: -12, maximum: 12) == -12)
        #expect(Policy.gain(atY: -50, plotMinY: 6, plotHeight: 100, minimum: -12, maximum: 12) == 12)
        #expect(Policy.gain(atY: 57, plotMinY: 6, plotHeight: 100, minimum: -12, maximum: 12) == 0)
        // 4.4 分贝落在 4.5 这一档。
        #expect(Policy.gain(atY: 6 + 100 * (1 - 16.4 / 24), plotMinY: 6, plotHeight: 100, minimum: -12, maximum: 12) == 4.5)
        // 离 0 不到吸附范围的吸到 0。
        #expect(Policy.gain(atY: 6 + 100 * (1 - 12.5 / 24), plotMinY: 6, plotHeight: 100, minimum: -12, maximum: 12) == 0)
        #expect(Policy.gain(atY: 50, plotMinY: 0, plotHeight: 0, minimum: -12, maximum: 12) == 0)
    }
}

@Suite("舞台那一面的全屏效果一排")
struct NowPlayingCarouselStageLayoutTests {
    @Test("矮屏收成胶囊,够高时是缩略画面")
    func effectStrip() {
        #expect(NowPlayingCarouselStageLayout.effectStrip(forFaceHeight: 667) == .chips)
        #expect(NowPlayingCarouselStageLayout.effectStrip(forFaceHeight: 736) == .chips)
        #expect(NowPlayingCarouselStageLayout.effectStrip(forFaceHeight: 812) == .thumbnails)
        #expect(NowPlayingCarouselStageLayout.effectStrip(forFaceHeight: 874) == .thumbnails)
        #expect(NowPlayingCarouselStageLayout.effectStrip(forFaceHeight: 0) == .thumbnails)
    }
}

@Suite("转轮松手时接着手指的速度")
struct NowPlayingCarouselReleaseVelocityTests {
    @Test("往左甩转向下一页:速度换成剩下这段的相对值")
    func flingTowardTheTarget() {
        // 停在第 0.6 页、往第 1 页走,剩 0.4 页;手指往左 800 点/秒,页宽 400 → 每秒 2 页 → 相对 5。
        let v = NowPlayingCarouselPolicy.releaseVelocity(position: 0.6, target: 1, velocity: -800, pageWidth: 400)
        #expect(abs(v - 5) < 0.0001)
    }

    @Test("往回甩、已经到位或页宽为零时从静止开始")
    func noVelocityWhenMovingAwayOrDone() {
        #expect(NowPlayingCarouselPolicy.releaseVelocity(position: 0.6, target: 1, velocity: 800, pageWidth: 400) == 0)
        #expect(NowPlayingCarouselPolicy.releaseVelocity(position: 1, target: 1, velocity: -800, pageWidth: 400) == 0)
        #expect(NowPlayingCarouselPolicy.releaseVelocity(position: 0.6, target: 1, velocity: -800, pageWidth: 0) == 0)
    }

    @Test("甩得太快时封顶")
    func clampsVeryFastFlings() {
        let v = NowPlayingCarouselPolicy.releaseVelocity(position: 0.95, target: 1, velocity: -4000, pageWidth: 400)
        #expect(v == NowPlayingCarouselPolicy.maximumReleaseVelocity)
    }

    @Test("往前一页(位置变小)同样按方向算")
    func flingTowardThePreviousPage() {
        // 从第 2 页往第 1 页,停在 1.5,手指往右 400 点/秒,页宽 400 → 每秒 -1 页,剩 -0.5 → 相对 2。
        let v = NowPlayingCarouselPolicy.releaseVelocity(position: 1.5, target: 1, velocity: 400, pageWidth: 400)
        #expect(abs(v - 2) < 0.0001)
    }
}
