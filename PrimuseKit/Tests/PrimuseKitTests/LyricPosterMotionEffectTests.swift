import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterMotionEffectTests {
    @Test func effectsThatNeedACoverDisappearWithoutOne() {
        let withArtwork = LyricPosterMotionEffectCatalog.available(hasArtwork: true)
        let withoutArtwork = LyricPosterMotionEffectCatalog.available(hasArtwork: false)

        #expect(withArtwork.contains { $0.id == .artworkZoom })
        #expect(!withoutArtwork.contains { $0.id == .artworkZoom })
        // 没封面也永远有"不动"可选，选择器不会空。
        #expect(withoutArtwork.first?.id == LyricPosterMotionEffectID.none)
        #expect(withArtwork.map(\.order) == withArtwork.map(\.order).sorted())
    }

    @Test func storedPreferenceFallsBackWhenItStopsBeingUsable() {
        #expect(
            LyricPosterMotionEffectCatalog.resolved(preferred: .particles, hasArtwork: false).id
                == .particles
        )
        // 上一首有封面时选了推镜头，这一首没封面就退回不动。
        #expect(
            LyricPosterMotionEffectCatalog.resolved(preferred: .artworkZoom, hasArtwork: false).id
                == LyricPosterMotionEffectID.none
        )
        #expect(
            LyricPosterMotionEffectCatalog.resolved(
                preferred: LyricPosterMotionEffectID("removed_later"),
                hasArtwork: true
            ).id == LyricPosterMotionEffectID.none
        )
    }

    @Test func everyMotionIsAPureFunctionOfTime() {
        // 导出是一帧一帧独立渲染的：同一时刻必须永远算出同一画面，
        // 否则导出的动画和预览会对不上。
        for frame in 0..<40 {
            let time = Double(frame) / 24
            #expect(
                LyricPosterMotionPhysics.floatOffset(lineIndex: 2, at: time)
                    == LyricPosterMotionPhysics.floatOffset(lineIndex: 2, at: time)
            )
            let first = LyricPosterMotionPhysics.particle(index: 7, at: time, duration: 5)
            let second = LyricPosterMotionPhysics.particle(index: 7, at: time, duration: 5)
            #expect(first == second)
            #expect(
                LyricPosterMotionPhysics.waveformBar(index: 3, count: 24, at: time)
                    == LyricPosterMotionPhysics.waveformBar(index: 3, count: 24, at: time)
            )
        }
    }

    @Test func particlesStayInsideTheCanvasAcrossTheWholeClip() {
        for index in 0..<60 {
            for frame in 0...120 {
                let time = Double(frame) / 24
                let particle = LyricPosterMotionPhysics.particle(index: index, at: time, duration: 5)
                #expect(particle.x >= 0 && particle.x <= 1)
                #expect(particle.y >= 0 && particle.y <= 1)
                #expect(particle.opacity >= -0.001 && particle.opacity <= 1.001)
                #expect(particle.size > 0)
            }
        }
    }

    @Test func particlesDoNotAllSitOnTopOfEachOther() {
        let sample = (0..<24).map { LyricPosterMotionPhysics.particle(index: $0, at: 1.0, duration: 5) }
        let columns = Set(sample.map { Int($0.x * 10) })
        let rows = Set(sample.map { Int($0.y * 10) })
        #expect(columns.count >= 5)
        #expect(rows.count >= 5)
    }

    @Test func lyricLinesFloatOutOfPhaseWithEachOther() {
        let time = 0.8
        let first = LyricPosterMotionPhysics.floatOffset(lineIndex: 0, at: time)
        let second = LyricPosterMotionPhysics.floatOffset(lineIndex: 1, at: time)
        #expect(abs(first - second) > 0.05)
        for index in 0..<8 {
            let value = LyricPosterMotionPhysics.floatOffset(lineIndex: index, at: time)
            #expect(value >= -1.001 && value <= 1.001)
        }
    }

    @Test func waveformStaysInRangeAndSwingsWidestInTheMiddle() {
        let count = 32
        var peaks = [Double](repeating: 0, count: count)

        for frame in 0...96 {
            let time = Double(frame) / 24
            for index in 0..<count {
                let bar = LyricPosterMotionPhysics.waveformBar(index: index, count: count, at: time)
                #expect(bar >= 0.05 && bar <= 1)
                peaks[index] = max(peaks[index], bar)
            }
        }

        // 包络约束的是能摆多大，不是每一帧中间都比两边高 —— 单看一帧，
        // 中间那根完全可能正处在波谷。
        #expect(peaks[count / 2] > peaks[0])
        #expect(peaks[count / 2] > peaks[count - 1])
        #expect(LyricPosterMotionPhysics.waveformBar(index: 0, count: 0, at: 1) == 0)
    }

    @Test func theCoverPushesInAndThenHolds() {
        let duration = 5.0
        #expect(LyricPosterMotionPhysics.artworkZoom(at: 0, duration: duration) == 1)
        let mid = LyricPosterMotionPhysics.artworkZoom(at: duration / 2, duration: duration)
        let end = LyricPosterMotionPhysics.artworkZoom(at: duration, duration: duration)
        #expect(mid > 1 && mid < end)
        // 超出片长不再继续放大，实况照片循环播放时不会越放越大。
        #expect(LyricPosterMotionPhysics.artworkZoom(at: duration * 3, duration: duration) == end)
        #expect(LyricPosterMotionPhysics.artworkZoom(at: 1, duration: 0) == 1)
    }
}
