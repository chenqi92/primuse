import Foundation
import Testing
@testable import PrimuseKit

/// Duo 外屏竖握 466×678（紧凑宽 / 常规高）、横握 678×466（紧凑 / 紧凑）；内屏横握约 951×669、竖握 669×951（常规 / 常规）。
@Suite("折叠屏换屏时的整屏过渡")
struct ScreenChangeTransitionPolicyTests {
    private typealias Policy = ScreenChangeTransitionPolicy

    private func canvas(
        _ width: Double, _ height: Double,
        screen: (Double, Double)? = nil,
        regularWidth: Bool, regularHeight: Bool,
        screenID: Int? = nil, phone: Bool = true
    ) -> Policy.Canvas {
        let screenSize = screen ?? (width, height)
        return Policy.Canvas(
            screenID: screenID,
            width: width, height: height,
            screenWidth: screenSize.0, screenHeight: screenSize.1,
            isRegularWidth: regularWidth, isRegularHeight: regularHeight,
            isPhone: phone
        )
    }

    private var outer: Policy.Canvas { canvas(466, 678, regularWidth: false, regularHeight: true) }
    private var outerLandscape: Policy.Canvas { canvas(678, 466, regularWidth: false, regularHeight: false) }
    private var inner: Policy.Canvas { canvas(951, 669, regularWidth: true, regularHeight: true) }
    private var innerPortrait: Policy.Canvas { canvas(669, 951, regularWidth: true, regularHeight: true) }

    @Test("合上、展开算换屏，拉伸方向跟着画布变化大的一边")
    func foldAndUnfold() {
        #expect(Policy.change(from: outer, to: inner) == .init(axis: .horizontal, isUnfolding: true))
        #expect(Policy.change(from: inner, to: outer) == .init(axis: .horizontal, isUnfolding: false))
        #expect(Policy.change(from: outerLandscape, to: inner)?.isUnfolding == true)
        #expect(Policy.change(from: innerPortrait, to: outer) == .init(axis: .vertical, isUnfolding: false))
    }

    @Test("同一块屏幕上转屏不算")
    func rotationIsNotAScreenChange() {
        #expect(Policy.change(from: outer, to: outerLandscape) == nil)
        #expect(Policy.change(from: inner, to: innerPortrait) == nil)
        // 普通 iPhone：Pro Max 横屏是常规宽 + 紧凑高，SE 横竖都是紧凑宽。
        let proMax = canvas(440, 956, regularWidth: false, regularHeight: true)
        let proMaxLandscape = canvas(956, 440, regularWidth: true, regularHeight: false)
        #expect(Policy.change(from: proMax, to: proMaxLandscape) == nil)
        #expect(Policy.change(from: proMaxLandscape, to: proMax) == nil)
    }

    @Test("分屏多任务里拖宽拖窄不算")
    func splitViewResizeIsNotAScreenChange() {
        let half = canvas(470, 669, screen: (951, 669), regularWidth: false, regularHeight: true)
        #expect(!half.fillsScreen)
        #expect(Policy.change(from: inner, to: half) == nil)
        #expect(Policy.change(from: half, to: inner) == nil)
    }

    @Test("屏幕换了就算，哪怕画布等级没变")
    func screenIdentityChange() {
        var a = inner
        a.screenID = 1
        var b = inner
        b.screenID = 2
        #expect(Policy.change(from: a, to: b) != nil)
        b.screenID = 1
        #expect(Policy.change(from: a, to: b) == nil)
        // 拿不到屏幕标识时只看画布翻转。
        a.screenID = nil
        b.screenID = 2
        #expect(Policy.change(from: a, to: b) == nil)
    }

    @Test("第一次看到画布、iPad 都不算")
    func firstObservationAndPad() {
        #expect(Policy.change(from: nil, to: inner) == nil)
        let pad = canvas(1180, 820, regularWidth: true, regularHeight: true, phone: false)
        let padSplit = canvas(678, 820, screen: (1180, 820), regularWidth: false, regularHeight: true, phone: false)
        #expect(Policy.change(from: pad, to: padSplit) == nil)
        #expect(Policy.change(from: padSplit, to: pad) == nil)
    }

    @Test("屏幕尺寸按另一个朝向报也算铺满")
    func fillsScreenAcrossOrientation() {
        #expect(canvas(678, 466, screen: (466, 678), regularWidth: false, regularHeight: false).fillsScreen)
        #expect(!canvas(386, 678, screen: (466, 678), regularWidth: false, regularHeight: true).fillsScreen)
        #expect(!canvas(0, 0, regularWidth: false, regularHeight: false).fillsScreen)
    }

    @Test("过渡的起点与终点")
    func frames() {
        let start = Policy.frame(progress: 1, axis: .horizontal, reduceMotion: false)
        #expect(abs(start.scaleX - 1.05) < 1e-9)
        #expect(start.scaleY == 1)
        #expect(start.blurRadius == 14)
        #expect(abs(start.opacity - 0.88) < 1e-9)
        let end = Policy.frame(progress: 0, axis: .horizontal, reduceMotion: false)
        #expect(end == .init(scaleX: 1, scaleY: 1, blurRadius: 0, opacity: 1))
        let vertical = Policy.frame(progress: 1, axis: .vertical, reduceMotion: false)
        #expect(vertical.scaleX == 1 && abs(vertical.scaleY - 1.05) < 1e-9)
        let reduced = Policy.frame(progress: 1, axis: .horizontal, reduceMotion: true)
        #expect(reduced.scaleX == 1 && reduced.scaleY == 1 && reduced.blurRadius == 0)
        #expect(abs(reduced.opacity - 0.55) < 1e-9)
        #expect(Policy.frame(progress: .nan, axis: .horizontal, reduceMotion: false) == end)
        #expect(Policy.frame(progress: 3, axis: .horizontal, reduceMotion: false) == start)
    }

    @Test("按屏幕宽高比认折叠屏")
    func foldableScreens() {
        #expect(Policy.isFoldableScreen(nativeWidth: 1398, nativeHeight: 2034))
        #expect(Policy.isFoldableScreen(nativeWidth: 1878, nativeHeight: 2670))
        #expect(!Policy.isFoldableScreen(nativeWidth: 750, nativeHeight: 1334))
        #expect(!Policy.isFoldableScreen(nativeWidth: 1206, nativeHeight: 2622))
        #expect(!Policy.isFoldableScreen(nativeWidth: 0, nativeHeight: 2622))
    }
}
