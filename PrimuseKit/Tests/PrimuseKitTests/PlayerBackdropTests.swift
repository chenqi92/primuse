import Foundation
import Testing
@testable import PrimuseKit

@Suite("Player backdrop")
struct PlayerBackdropTests {
    private let idA = String(repeating: "a", count: 64)
    private let idB = String(repeating: "b", count: 64)

    @Test("Settings round-trip and tolerate unknown or missing values")
    func settingsDecoding() throws {
        let settings = PlayerBackdropSettings(source: .albumBack, rotation: .timed, intervalSeconds: 300)
        let decoded = PlayerBackdropSettings.decode(settings.encodedData())
        #expect(decoded == settings)

        let future = Data(#"{"source":"liveWallpaper","rotation":"shuffle","intervalSeconds":45}"#.utf8)
        let fallback = PlayerBackdropSettings.decode(future)
        #expect(fallback.source == .coverAmbient)
        #expect(fallback.rotation == .fixed)
        #expect(fallback.intervalSeconds == 30)

        #expect(PlayerBackdropSettings.decode(nil) == .default)
        #expect(PlayerBackdropSettings.decode(Data("not json".utf8)) == .default)
        #expect(PlayerBackdropSettings.decode(Data(#"{"source":"coverBlur"}"#.utf8))
            == PlayerBackdropSettings(source: .coverBlur))
        // 「流动色彩」只换色场的画法,不铺图片、不轮播。
        #expect(PlayerBackdropSettings.decode(Data(#"{"source":"liquid"}"#.utf8)).source == .liquid)
        #expect(!PlayerBackdropSource.liquid.showsImage)
        #expect(!PlayerBackdropSource.liquid.supportsRotation)
        #expect(PlayerBackdropSettings(source: .liquid).effectiveSource(hasCustomImages: false) == .liquid)
    }

    @Test("Visualizer backdrop keeps its style, and older settings read the same as before")
    func visualizerDecoding() throws {
        let settings = PlayerBackdropSettings(source: .visualizer, visualizerStyle: .stardust)
        #expect(PlayerBackdropSettings.decode(settings.encodedData()) == settings)
        #expect(!PlayerBackdropSource.visualizer.showsImage)
        #expect(!PlayerBackdropSource.visualizer.supportsRotation)
        #expect(settings.effectiveSource(hasCustomImages: false) == .visualizer)

        // 没碰过样式的设置编码出来和以前一样,不多写一项。
        let plain = try #require(PlayerBackdropSettings(source: .coverBlur).encodedData())
        #expect(!String(decoding: plain, as: UTF8.self).contains("visualizerStyle"))
        #expect(PlayerBackdropSettings.decode(plain).visualizerStyle == .spectrum)

        // 更新版本多出来的样式按默认处理,来源照旧。
        let future = Data(#"{"source":"visualizer","visualizerStyle":"milkdrop"}"#.utf8)
        let decoded = PlayerBackdropSettings.decode(future)
        #expect(decoded.source == .visualizer)
        #expect(decoded.visualizerStyle == .spectrum)
    }

    @Test("Visualizer bars mirror the bands with the bass in the middle")
    func visualizerBars() {
        let bands = (0..<32).map { 1 - Double($0) / 31 }
        let bars = PlayerVisualizerGeometry.barLevels(bands: bands, count: 25)
        #expect(bars.count == 25)
        for index in 0..<12 {
            #expect(abs(bars[index] - bars[24 - index]) < 1e-9)
        }
        // 低频最响时中间那根最高, 往两边一路降。
        #expect(bars[12] == bars.max())
        #expect(bars[0] < bars[6])
        #expect(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(PlayerVisualizerGeometry.barLevels(bands: [], count: 4) == [0, 0, 0, 0])
        #expect(PlayerVisualizerGeometry.barLevels(bands: [0.5], count: 0).isEmpty)
        #expect(PlayerVisualizerGeometry.barCount(forWidth: 390) == 24)
        #expect(PlayerVisualizerGeometry.barCount(forWidth: 800) == 50)
        #expect(PlayerVisualizerGeometry.barCount(forWidth: 3000) == 64)
        #expect(PlayerVisualizerGeometry.barCount(forWidth: .nan) == 24)
    }

    @Test("Visualizer waves stay pinned at the edges and only breathe in silence")
    func visualizerWaves() {
        let loud = PlayerVisualizerGeometry.Registers(low: 1, mid: 1, high: 1)
        var silentPeak = 0.0
        var loudPeak = 0.0
        for step in 0...200 {
            let x = Double(step) / 200
            for line in 0..<3 {
                let quiet = PlayerVisualizerGeometry.waveOffset(x: x, time: 3.7, line: line, registers: .silent)
                let busy = PlayerVisualizerGeometry.waveOffset(x: x, time: 3.7, line: line, registers: loud)
                silentPeak = max(silentPeak, abs(quiet))
                loudPeak = max(loudPeak, abs(busy))
                #expect(abs(busy) <= 1)
            }
        }
        #expect(silentPeak <= 0.05 + 1e-9)
        #expect(loudPeak > 0.4)
        #expect(abs(PlayerVisualizerGeometry.waveOffset(x: 0, time: 1, line: 0, registers: loud)) < 1e-9)
        #expect(abs(PlayerVisualizerGeometry.waveOffset(x: 1, time: 1, line: 2, registers: loud)) < 1e-6)

        let registers = PlayerVisualizerGeometry.registers((0..<32).map { $0 < 5 ? 0.9 : 0.1 })
        #expect(registers.low > registers.mid)
        #expect(abs(registers.high - 0.1) < 1e-9)
        #expect(PlayerVisualizerGeometry.registers([]) == .silent)
    }

    @Test("Stardust rises, fades at both ends, and grows with the bass")
    func visualizerStardust() {
        for index in 0..<60 {
            let mote = PlayerVisualizerGeometry.mote(index: index, time: 12.5, low: 0)
            #expect(mote.y >= -0.1 && mote.y <= 1.05)
            #expect(mote.alpha >= 0 && mote.alpha <= 1)
            #expect(mote == PlayerVisualizerGeometry.mote(index: index, time: 12.5, low: 0))
            let pushed = PlayerVisualizerGeometry.mote(index: index, time: 12.5, low: 1)
            #expect(pushed.size > mote.size)
            // 一小段时间后往上走了(没绕回底下的那些)。
            let later = PlayerVisualizerGeometry.mote(index: index, time: 13.0, low: 0)
            if later.y < mote.y + 0.5 { #expect(later.y < mote.y) }
        }
    }

    @Test("Intervals snap to the nearest offered choice")
    func intervalNormalization() {
        #expect(PlayerBackdropSettings.normalizedInterval(60) == 60)
        #expect(PlayerBackdropSettings.normalizedInterval(1) == 15)
        #expect(PlayerBackdropSettings.normalizedInterval(45) == 30)
        #expect(PlayerBackdropSettings.normalizedInterval(200) == 300)
        #expect(PlayerBackdropSettings.normalizedInterval(100_000) == 600)
        #expect(PlayerBackdropSettings.normalizedInterval(-5) == 15)
    }

    @Test("Custom image ids keep order, drop duplicates and malformed ids, and are capped")
    func customImageIDs() {
        let ids = [idA, "nope", idB, idA, String(repeating: "A", count: 64)]
        #expect(PlayerBackdropSettings.sanitizedCustomImageIDs(ids) == [idA, idB])

        let many = (0..<40).map { String(format: "%064x", $0) }
        #expect(PlayerBackdropSettings.sanitizedCustomImageIDs(many).count
            == PlayerBackdropSettings.maximumCustomImages)
    }

    @Test("Choosing custom images without any on this device falls back to the cover palette")
    func effectiveSource() {
        let settings = PlayerBackdropSettings(source: .customImages)
        #expect(settings.effectiveSource(hasCustomImages: false) == .coverAmbient)
        #expect(settings.effectiveSource(hasCustomImages: true) == .customImages)
        #expect(PlayerBackdropSettings(source: .albumBack).effectiveSource(hasCustomImages: false) == .albumBack)
    }

    @Test("Per-song rotation advances only when a different song follows another")
    func perSongRotation() {
        var state = PlayerBackdropRotationState()
        #expect(state.observeSong("s1", rotation: .perSong) == false)
        #expect(state.index(count: 3, rotation: .perSong) == 0)
        #expect(state.observeSong("s1", rotation: .perSong) == false)
        #expect(state.observeSong("s2", rotation: .perSong) == true)
        #expect(state.index(count: 3, rotation: .perSong) == 1)
        #expect(state.observeSong(nil, rotation: .perSong) == false)
        #expect(state.observeSong("s3", rotation: .perSong) == false)
        #expect(state.observeSong("s4", rotation: .perSong) == true)
        #expect(state.index(count: 3, rotation: .perSong) == 2)
        #expect(state.observeSong("s5", rotation: .perSong) == true)
        #expect(state.index(count: 3, rotation: .perSong) == 0)
        // Removing images never indexes past the end.
        #expect(state.index(count: 1, rotation: .perSong) == 0)
        #expect(state.index(count: 0, rotation: .perSong) == nil)
    }

    @Test("Timer and fixed rotation")
    func timedAndFixedRotation() {
        var state = PlayerBackdropRotationState()
        #expect(state.timerFired(rotation: .fixed) == false)
        #expect(state.timerFired(rotation: .perSong) == false)
        #expect(state.timerFired(rotation: .timed) == true)
        #expect(state.timerFired(rotation: .timed) == true)
        #expect(state.index(count: 5, rotation: .timed) == 2)
        #expect(state.index(count: 5, rotation: .fixed) == 0)
        _ = state.observeSong("a", rotation: .timed)
        #expect(state.observeSong("b", rotation: .timed) == false)
        #expect(state.index(count: 5, rotation: .timed) == 2)
    }

    @Test("Album back images are recognised by prefix, not by accident")
    func albumBackNames() {
        for name in ["back.jpg", "Back.JPG", "BACK COVER.png", "back-1.jpeg", "backcover.webp",
                     "Backside.jpg", "rear.png", "Rear (2).jpg", "inside.jpg", "Inside_02.png",
                     "back.gif", "folder/back.jpg"] {
            #expect(AlbumBackArtworkPolicy.isCandidate(name), "\(name)")
        }
        for name in ["background.jpg", "backup.png", "rearview.jpg", "insider.png", "cover.jpg",
                     "front.jpg", "back.txt", "back", "back.mp3", "cd-back.jpg"] {
            #expect(!AlbumBackArtworkPolicy.isCandidate(name), "\(name)")
        }
    }

    @Test("Back covers sort back, rear, inside, then by name with numbers in order")
    func albumBackOrdering() {
        let names = ["inside.jpg", "cover.jpg", "Back 10.jpg", "rear.jpg", "back 2.jpg",
                     "BACK 2.JPG", "back.jpg", "notes.txt"]
        let ordered = AlbumBackArtworkPolicy.orderedCandidateIndices(names: names).map { names[$0] }
        #expect(ordered == ["back.jpg", "back 2.jpg", "Back 10.jpg", "rear.jpg", "inside.jpg"])
        #expect(AlbumBackArtworkPolicy.orderedCandidateIndices(names: ["a.jpg"]).isEmpty)
    }

    @Test("Disc sub-folders also search the album folder above them")
    func discFolders() {
        #expect(AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: "/Music/Album/CD1")
            == ["/Music/Album/CD1", "/Music/Album"])
        #expect(AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: "/Music/Album/Disc 2/")
            == ["/Music/Album/Disc 2", "/Music/Album"])
        #expect(AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: "/Music/Album/第2张")
            == ["/Music/Album/第2张", "/Music/Album"])
        #expect(AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: "/Music/Album")
            == ["/Music/Album"])
        #expect(AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: "/Music/CDs")
            == ["/Music/CDs"])
        #expect(AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: "") == ["/"])
        #expect(AlbumBackArtworkPolicy.isDiscFolderName("disk-3"))
        #expect(AlbumBackArtworkPolicy.isDiscFolderName("CD.2"))
        #expect(!AlbumBackArtworkPolicy.isDiscFolderName("CD"))
        #expect(!AlbumBackArtworkPolicy.isDiscFolderName("Discography"))
        #expect(!AlbumBackArtworkPolicy.isDiscFolderName("第二张"))
    }

    @Test("Scrim protects legibility more when the ambient strength is low")
    func scrim() {
        let faint = PlayerBackdropScrimPolicy.scrim(isLight: false, strength: 0, usesIncreasedContrast: false)
        let vivid = PlayerBackdropScrimPolicy.scrim(isLight: false, strength: 1, usesIncreasedContrast: false)
        #expect(faint.bottomOpacity > vivid.bottomOpacity)
        #expect(vivid.bottomOpacity >= 0.5)
        let contrast = PlayerBackdropScrimPolicy.scrim(isLight: false, strength: 1, usesIncreasedContrast: true)
        #expect(contrast.topOpacity > vivid.topOpacity)
        let light = PlayerBackdropScrimPolicy.scrim(isLight: true, strength: .nan, usesIncreasedContrast: true)
        #expect(light.bottomOpacity <= 0.92)
        #expect(light.topOpacity > 0)
    }

    @Test("Storage size follows the display, bucketed and bounded")
    func pixelPolicy() {
        #expect(PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: 2868) == 3072)
        #expect(PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: 2556) == 2560)
        #expect(PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: 600) == 1280)
        #expect(PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: 10_000) == 3200)
        #expect(PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: .nan) == 2880)
    }

    @Test("Audiobooks use the backdrop only when switched on, and old data reads as off")
    func audiobookBackdropOptIn() throws {
        #expect(PlayerBackdropSettings.default.appliesToAudiobooks == false)
        let on = PlayerBackdropSettings(source: .liquid, appliesToAudiobooks: true)
        #expect(PlayerBackdropSettings.decode(on.encodedData()) == on)
        let off = PlayerBackdropSettings(source: .liquid)
        let offJSON = try #require(off.encodedData().flatMap { String(data: $0, encoding: .utf8) })
        #expect(!offJSON.contains("appliesToAudiobooks"))
        let legacy = Data(#"{"source":"coverBlur","rotation":"perSong","intervalSeconds":60}"#.utf8)
        #expect(PlayerBackdropSettings.decode(legacy).appliesToAudiobooks == false)
    }
}
