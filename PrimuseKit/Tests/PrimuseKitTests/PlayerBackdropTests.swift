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
}
