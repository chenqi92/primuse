import Foundation
import Testing
@testable import PrimuseKit

struct LockScreenMotionArtworkPolicyTests {
    @Test func materialPriorityPrefersUserVideosThenServiceThenCustomAnimation() {
        let candidates: [(MotionArtworkMaterialKind, String)] = [
            (.customAnimation, "song-gif"),
            (.serviceMaterial, "service"),
            (.customAnimation, "album-gif"),
            (.albumVideo, "album-video"),
            (.songVideo, "song-video"),
        ]
        let ordered = MotionArtworkMaterialSelection.ordered(candidates) { $0.0 }.map(\.1)
        #expect(ordered == ["song-video", "album-video", "service", "song-gif", "album-gif"])
        let none = MotionArtworkMaterialSelection.ordered([(MotionArtworkMaterialKind, String)]()) { $0.0 }
        #expect(none.isEmpty)
    }

    @Test func onlyLibraryMusicPublishesWhenEverySwitchIsOn() {
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(context()))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(system: false)))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(animated: false)))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(lockScreen: false)))
        for content: LockScreenMotionArtworkContent in [.musicVideo, .liveRadio, .spokenWord, .podcast, .appleMusic] {
            #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(content: content)))
        }
    }

    @Test func wifiOnlyLimitsDownloadsNotLocalMaterial() {
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(context(unmeteredOnly: true, unmetered: false)))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(
            context(local: false, unmeteredOnly: true, unmetered: false)
        ))
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(
            context(local: false, unmeteredOnly: true, unmetered: true)
        ))
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(
            context(local: false, unmeteredOnly: false, unmetered: false)
        ))
    }

    @Test func squareMaterialNeverFillsTheTallSlot() {
        #expect(LockScreenMotionArtworkPolicy.slot(for: .square, supported: [.square, .tall]) == .square)
        #expect(LockScreenMotionArtworkPolicy.slot(for: .tall, supported: [.square, .tall]) == .tall)
        #expect(LockScreenMotionArtworkPolicy.slot(for: .square, supported: [.tall]) == nil)
        #expect(LockScreenMotionArtworkPolicy.slot(for: .tall, supported: [.square]) == nil)
        #expect(LockScreenMotionArtworkPolicy.slot(for: .square, supported: []) == nil)
    }

    @Test func operatingSystemThresholdIsVersion26() {
        #expect(!LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 18))
        #expect(!LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 25))
        #expect(LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 26))
        #expect(LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 27))
    }

    @Test func artworkIDIsStableForSharedAlbumMaterialAndChangesWithContent() {
        let hash = String(repeating: "ab", count: 32)
        let first = LockScreenMotionArtworkPolicy.artworkID(kind: .albumVideo, contentKey: hash, aspect: .tall)
        let again = LockScreenMotionArtworkPolicy.artworkID(kind: .albumVideo, contentKey: hash, aspect: .tall)
        #expect(first == again)
        #expect(first != LockScreenMotionArtworkPolicy.artworkID(kind: .albumVideo, contentKey: hash, aspect: .square))
        #expect(first != LockScreenMotionArtworkPolicy.artworkID(kind: .songVideo, contentKey: hash, aspect: .tall))
        #expect(first != LockScreenMotionArtworkPolicy.artworkID(
            kind: .albumVideo,
            contentKey: String(repeating: "cd", count: 32),
            aspect: .tall
        ))
        let unsafe = LockScreenMotionArtworkPolicy.artworkID(kind: .serviceMaterial, contentKey: "a/b c", aspect: .square)
        #expect(!unsafe.contains("/") && !unsafe.contains(" "))
    }

    @Test func conversionCacheNameTracksContentAspectAndSize() {
        let name = LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abc", aspect: .square, width: 480, height: 480
        )
        #expect(name.hasSuffix(".mp4"))
        #expect(name == LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abc", aspect: .square, width: 480, height: 480
        ))
        #expect(name != LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abc", aspect: .tall, width: 360, height: 480
        ))
        #expect(name != LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abd", aspect: .square, width: 480, height: 480
        ))
        #expect(!LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "../../escape", aspect: .square, width: 1, height: 1
        ).contains("/"))
    }

    private func context(
        system: Bool = true,
        animated: Bool = true,
        lockScreen: Bool = true,
        content: LockScreenMotionArtworkContent = .music,
        local: Bool = true,
        unmeteredOnly: Bool = true,
        unmetered: Bool = true
    ) -> LockScreenMotionArtworkContext {
        LockScreenMotionArtworkContext(
            systemSupportsAnimatedArtwork: system,
            animatedArtworkEnabled: animated,
            lockScreenEnabled: lockScreen,
            content: content,
            materialIsLocal: local,
            unmeteredOnly: unmeteredOnly,
            isOnUnmeteredNetwork: unmetered
        )
    }
}
