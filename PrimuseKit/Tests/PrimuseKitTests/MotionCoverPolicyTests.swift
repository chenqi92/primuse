import Foundation
import Testing
@testable import PrimuseKit

struct MotionCoverPolicyTests {
    @Test func aspectMatchingAllowsSmallRoundingOnly() {
        #expect(MotionCoverAspect.matching(width: 1_080, height: 1_080) == .square)
        #expect(MotionCoverAspect.matching(width: 1_080, height: 1_090) == .square)
        #expect(MotionCoverAspect.matching(width: 810, height: 1_080) == .tall)
        #expect(MotionCoverAspect.matching(width: 2_048, height: 2_732) == .tall)
        #expect(MotionCoverAspect.matching(width: 1_920, height: 1_080) == nil)
        #expect(MotionCoverAspect.matching(width: 1_080, height: 1_920) == nil)
        #expect(MotionCoverAspect.matching(width: 0, height: 1_080) == nil)
        #expect(MotionCoverAspect.matching(width: .nan, height: 1_080) == nil)
    }

    @Test func nearestAspectCropsPortraitPhoneVideoToTall() {
        #expect(MotionCoverAspect.nearest(width: 1_080, height: 1_920) == .tall)
        #expect(MotionCoverAspect.nearest(width: 1_920, height: 1_080) == .square)
        #expect(MotionCoverAspect.nearest(width: 900, height: 1_000) == .square)
        #expect(MotionCoverAspect.nearest(width: 780, height: 1_000) == .tall)
    }

    @Test func renderSizeKeepsExactRatioWithoutUpscaling() {
        let square = MotionCoverAspect.square.renderSize(sourceWidth: 3_840, sourceHeight: 2_160)
        #expect(square.width == 1_080 && square.height == 1_080)

        let tall = MotionCoverAspect.tall.renderSize(sourceWidth: 2_160, sourceHeight: 3_840)
        #expect(tall.height == 1_080 && tall.width == 810)

        let smallTall = MotionCoverAspect.tall.renderSize(sourceWidth: 720, sourceHeight: 1_280)
        #expect(smallTall.width == 720 && smallTall.height == 960)

        let smallSquare = MotionCoverAspect.square.renderSize(sourceWidth: 500, sourceHeight: 400)
        #expect(smallSquare.width == 400 && smallSquare.height == 400)

        for size in [square, tall, smallTall, smallSquare] {
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
        }
    }

    @Test func compliantVideoIsOnlyRemuxed() {
        let plan = MotionCoverImportPlan.make(for: traits())
        #expect(plan == .remux(aspect: .square))

        let tall = MotionCoverImportPlan.make(for: traits(width: 810, height: 1_080, codec: .hevc))
        #expect(tall == .remux(aspect: .tall))
    }

    @Test func audioTrackAloneDoesNotForceReencoding() {
        #expect(MotionCoverImportPlan.make(for: traits(hasAudio: true)) == .remux(aspect: .square))
    }

    @Test func oversizedRotatedHDROrUnusualVideoIsTranscoded() {
        #expect(MotionCoverImportPlan.make(for: traits(width: 2_160, height: 2_160))
            == .transcode(aspect: .square, width: 1_080, height: 1_080, frameRate: 30))
        #expect(MotionCoverImportPlan.make(for: traits(identity: false))
            == .transcode(aspect: .square, width: 1_080, height: 1_080, frameRate: 30))
        #expect(MotionCoverImportPlan.make(for: traits(frameRate: 24, hdr: true))
            == .transcode(aspect: .square, width: 1_080, height: 1_080, frameRate: 24))
        #expect(MotionCoverImportPlan.make(for: traits(codec: .other))
            == .transcode(aspect: .square, width: 1_080, height: 1_080, frameRate: 30))
        #expect(MotionCoverImportPlan.make(for: traits(frameRate: 120))
            == .transcode(aspect: .square, width: 1_080, height: 1_080, frameRate: 30))
        #expect(MotionCoverImportPlan.make(for: traits(width: 1_080, height: 1_920))
            == .transcode(aspect: .tall, width: 810, height: 1_080, frameRate: 30))
    }

    @Test func importLimitsRejectLongLargeAndBrokenVideo() {
        #expect(MotionCoverImportPlan.make(for: traits(duration: 61)) == .reject(.tooLong))
        #expect(MotionCoverImportPlan.make(for: traits(duration: 60)) == .remux(aspect: .square))
        #expect(MotionCoverImportPlan.make(for: traits(duration: 60.1))
            == .transcode(aspect: .square, width: 1_080, height: 1_080, frameRate: 30))
        #expect(MotionCoverImportPlan.make(for: traits(size: MotionCoverImportLimits.maximumInputBytes + 1))
            == .reject(.tooLarge))
        #expect(MotionCoverImportPlan.make(for: traits(duration: 0)) == .reject(.unreadable))
        #expect(MotionCoverImportPlan.make(for: traits(duration: .nan)) == .reject(.unreadable))
        #expect(MotionCoverImportPlan.make(for: traits(width: 0)) == .reject(.unreadable))
    }

    @Test func animationsAreAlwaysEncodedToTheNearestAspect() {
        #expect(MotionCoverImportPlan.forAnimation(pixelWidth: 480, pixelHeight: 480, duration: 4, frameCount: 40)
            == .transcode(aspect: .square, width: 480, height: 480, frameRate: 30))
        #expect(MotionCoverImportPlan.forAnimation(pixelWidth: 640, pixelHeight: 360, duration: 4, frameCount: 40)
            == .transcode(aspect: .square, width: 360, height: 360, frameRate: 30))
        #expect(MotionCoverImportPlan.forAnimation(pixelWidth: 480, pixelHeight: 480, duration: 4, frameCount: 1)
            == .reject(.unreadable))
        #expect(MotionCoverImportPlan.forAnimation(pixelWidth: 480, pixelHeight: 480, duration: 75, frameCount: 750)
            == .reject(.tooLong))
    }

    @Test func songChoiceWinsOverAlbumChoice() {
        let songAsset = asset("a")
        let albumAsset = asset("b")
        var index = MotionCoverIndex()
        index.set(albumAsset, for: .album("album"))
        #expect(index.effectiveAsset(songID: "song", albumID: "album")?.asset == albumAsset)
        #expect(index.effectiveAsset(songID: "song", albumID: "album")?.owner == .album("album"))

        index.set(songAsset, for: .song("song"))
        #expect(index.effectiveAsset(songID: "song", albumID: "album")?.asset == songAsset)
        #expect(index.effectiveAsset(songID: "song", albumID: "album")?.owner == .song("song"))
        #expect(index.effectiveAsset(songID: "other", albumID: "album")?.asset == albumAsset)
        #expect(index.effectiveAsset(songID: nil, albumID: nil)?.asset == nil)
        #expect(index.effectiveAsset(songID: "", albumID: "")?.asset == nil)
    }

    @Test func removalPrunesBindingsAndReferencedFiles() {
        var index = MotionCoverIndex()
        index.set(asset("a"), for: .song("s1"))
        index.set(asset("a"), for: .song("s2"))
        index.set(asset("b"), for: .album("al"))
        #expect(index.referencedContentIDs == [String(repeating: "a", count: 64), String(repeating: "b", count: 64)])

        let removedFirstSong = index.remove(songIDs: ["s1"], albumIDs: [])
        #expect(removedFirstSong)
        #expect(index.referencedContentIDs.contains(String(repeating: "a", count: 64)))
        let removedMissing = index.remove(songIDs: ["missing"], albumIDs: ["missing"])
        #expect(!removedMissing)
        let removedRest = index.remove(songIDs: ["s2"], albumIDs: ["al"])
        #expect(removedRest)
        #expect(index.isEmpty)
        #expect(index.referencedContentIDs.isEmpty)
    }

    @Test func indexRoundTripsThroughJSON() throws {
        var index = MotionCoverIndex()
        index.set(asset("c"), for: .album("album"))
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(MotionCoverIndex.self, from: data)
        #expect(decoded == index)
        #expect(decoded.version == MotionCoverIndex.currentVersion)
    }

    @Test func contentIDValidation() {
        #expect(MotionCoverAsset.isValidContentID(String(repeating: "0a", count: 32)))
        #expect(!MotionCoverAsset.isValidContentID(String(repeating: "0A", count: 32)))
        #expect(!MotionCoverAsset.isValidContentID("../escape"))
    }

    private func traits(
        duration: Double = 12,
        width: Double = 1_080,
        height: Double = 1_080,
        frameRate: Double = 30,
        hasAudio: Bool = false,
        identity: Bool = true,
        codec: MotionCoverVideoCodec = .h264,
        hdr: Bool = false,
        size: Int64 = 8_000_000
    ) -> MotionCoverVideoTraits {
        MotionCoverVideoTraits(
            duration: duration,
            displayWidth: width,
            displayHeight: height,
            nominalFrameRate: frameRate,
            hasAudioTrack: hasAudio,
            hasIdentityTransform: identity,
            codec: codec,
            isHDR: hdr,
            fileSize: size
        )
    }

    private func asset(_ seed: Character) -> MotionCoverAsset {
        MotionCoverAsset(
            contentID: String(repeating: seed, count: 64),
            aspect: .square,
            pixelWidth: 1_080,
            pixelHeight: 1_080,
            duration: 10,
            byteCount: 1_000,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
