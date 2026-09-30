import Foundation
import Testing
@testable import PrimuseKit

@Suite("Desktop lyrics island layout")
struct DesktopLyricsIslandLayoutTests {
    /// 14 英寸 MacBook Pro 默认缩放：1512×982，刘海 32pt 高、约 185pt 宽。
    private static let notchedScreen = DesktopLyricsIslandScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryLeftWidth: 663.5,
        auxiliaryRightWidth: 663.5
    )

    /// 外接 1080p 显示器，菜单栏 25pt，放在内建屏右边。
    private static let flatScreen = DesktopLyricsIslandScreen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055)
    )

    @Test func notchedScreenBorrowsTheNotch() {
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.notchedScreen)
        #expect(metrics.hasNotch)
        #expect(metrics.notchWidth == 185)
        #expect(metrics.topBand == 32)
        #expect(metrics.artworkSide == 20)
        #expect(metrics.wingWidth == 38)
        #expect(metrics.compactMinWidth == 261)
        #expect(metrics.compactHeight == 62)
        #expect(metrics.expandedContentTop == 32)
        #expect(metrics.expandedHeight == 182)
    }

    @Test func flatScreenUsesMenuBarHeight() {
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.flatScreen)
        #expect(!metrics.hasNotch)
        #expect(metrics.notchWidth == 0)
        #expect(metrics.topBand == 25)
        #expect(metrics.wingWidth == 0)
        #expect(metrics.stripHeight == 0)
        #expect(metrics.compactHeight == 33)
        #expect(metrics.expandedContentTop == 10)
    }

    @Test func autoHiddenMenuBarFallsBackToStatusBarThickness() {
        let screen = DesktopLyricsIslandScreen(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            statusBarThickness: 22
        )
        let metrics = DesktopLyricsIslandMetrics.resolve(for: screen)
        #expect(metrics.topBand == 22)
    }

    @Test func safeAreaWithoutAuxiliaryAreasIsNotANotch() {
        let screen = DesktopLyricsIslandScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32
        )
        let metrics = DesktopLyricsIslandMetrics.resolve(for: screen)
        #expect(!metrics.hasNotch)
        #expect(metrics.topBand == 32)
    }

    @Test func compactWidthFollowsTheLyricButStaysInBounds() {
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.notchedScreen)
        #expect(metrics.compactWidth(textWidth: 20) == metrics.compactMinWidth)
        #expect(metrics.compactWidth(textWidth: 300) == 336)
        #expect(metrics.compactWidth(textWidth: 5000) == metrics.compactMaxWidth)
        #expect(metrics.compactMaxWidth == 560)
    }

    @Test func flatCompactWidthMakesRoomForArtworkAndGlyph() {
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.flatScreen)
        // 12 + 16(封面) + 10 + 200 + 10 + 22(声线) + 12
        #expect(metrics.artworkSide == 16)
        #expect(metrics.compactWidth(textWidth: 200) == 282)
    }

    @Test func expandedCardClearsTheNotchAndFitsSmallScreens() {
        let notched = DesktopLyricsIslandMetrics.resolve(for: Self.notchedScreen)
        #expect(notched.expandedWidth >= notched.notchWidth + 240)
        #expect(notched.expandedWidth <= 520)

        let tiny = DesktopLyricsIslandMetrics.resolve(for: DesktopLyricsIslandScreen(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 276)
        ))
        #expect(tiny.expandedWidth == 360)
    }

    @Test func panelHangsFromTheTopCenterAndHoldsEveryState() {
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.flatScreen)
        let frame = metrics.panelFrame(on: Self.flatScreen.frame)
        #expect(frame.maxY == Self.flatScreen.frame.maxY)
        #expect(abs(frame.midX - Self.flatScreen.frame.midX) <= 0.5)
        #expect(frame.width >= metrics.expandedWidth + metrics.glowMargin * 2)
        #expect(frame.width >= metrics.compactMaxWidth + metrics.glowMargin * 2)
        #expect(frame.height >= metrics.expandedHeight + metrics.glowMargin)
    }

    @Test func tuckedIslandHidesBehindTheNotch() {
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.notchedScreen)
        #expect(metrics.tuckedSize.width < metrics.notchWidth)
        #expect(metrics.tuckedSize.height < metrics.topBand)
        #expect(metrics.restingSize == metrics.tuckedSize)

        let flat = DesktopLyricsIslandMetrics.resolve(for: Self.flatScreen)
        #expect(flat.tuckedSize.height == 0)
        #expect(flat.restingSize.height == flat.compactHeight)
    }

    @Test func notchedZonesSplitTopBandFromLyricStrip() {
        let screen = Self.notchedScreen.frame
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.notchedScreen)
        let island = metrics.islandFrame(size: metrics.compactSize(textWidth: 300), on: screen)

        let wing = CGPoint(x: island.minX + 10, y: screen.maxY - 10)
        #expect(metrics.zone(of: wing, islandFrame: island, screenFrame: screen, expanded: false) == .trigger)

        let topEdge = CGPoint(x: screen.midX, y: screen.maxY)
        #expect(metrics.zone(of: topEdge, islandFrame: island, screenFrame: screen, expanded: false) == .trigger)

        let strip = CGPoint(x: screen.midX, y: screen.maxY - 45)
        #expect(metrics.zone(of: strip, islandFrame: island, screenFrame: screen, expanded: false) == .peek)

        let below = CGPoint(x: screen.midX, y: screen.maxY - 90)
        #expect(metrics.zone(of: below, islandFrame: island, screenFrame: screen, expanded: false) == .outside)
    }

    @Test func notchStaysReachableWhileTheIslandIsTucked() {
        let screen = Self.notchedScreen.frame
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.notchedScreen)
        let island = metrics.islandFrame(size: metrics.tuckedSize, on: screen)
        let notchEdge = CGPoint(x: screen.midX + metrics.notchWidth / 2 - 4, y: screen.maxY - 30)
        #expect(!island.contains(notchEdge))
        #expect(metrics.zone(of: notchEdge, islandFrame: island, screenFrame: screen, expanded: false) == .trigger)
    }

    @Test func flatPillIsAllTrigger() {
        let screen = Self.flatScreen.frame
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.flatScreen)
        let island = metrics.islandFrame(size: metrics.compactSize(textWidth: 200), on: screen)
        let bottom = CGPoint(x: screen.midX, y: island.minY + 1)
        #expect(metrics.zone(of: bottom, islandFrame: island, screenFrame: screen, expanded: false) == .trigger)
    }

    @Test func expandedCardKeepsASmallGraceBorder() {
        let screen = Self.flatScreen.frame
        let metrics = DesktopLyricsIslandMetrics.resolve(for: Self.flatScreen)
        let island = metrics.islandFrame(size: metrics.expandedSize, on: screen)
        let justOutside = CGPoint(x: island.maxX + 5, y: island.midY)
        #expect(metrics.zone(of: justOutside, islandFrame: island, screenFrame: screen, expanded: true) == .inside)
        let farOutside = CGPoint(x: island.maxX + 20, y: island.midY)
        #expect(metrics.zone(of: farOutside, islandFrame: island, screenFrame: screen, expanded: true) == .outside)
    }
}

@Suite("Desktop lyrics island activities")
struct DesktopLyricsIslandActivityPolicyTests {
    @Test func bluetoothNamesPickTheirOwnGlyph() {
        let p = DesktopLyricsIslandActivityPolicy.self
        #expect(p.outputSymbol(kind: .bluetooth, name: "chenqi's AirPods Pro", isHeadphoneJack: false) == "airpodspro")
        #expect(p.outputSymbol(kind: .bluetooth, name: "AirPods Max", isHeadphoneJack: false) == "airpodsmax")
        #expect(p.outputSymbol(kind: .bluetooth, name: "AirPods", isHeadphoneJack: false) == "airpods")
        #expect(p.outputSymbol(kind: .bluetooth, name: "Beats Studio Pro", isHeadphoneJack: false) == "beats.headphones")
        #expect(p.outputSymbol(kind: .bluetooth, name: "WH-1000XM5", isHeadphoneJack: false) == "headphones")
    }

    @Test func builtInOutputTellsJackFromSpeakers() {
        let p = DesktopLyricsIslandActivityPolicy.self
        #expect(p.outputSymbol(kind: .builtIn, name: "External Headphones", isHeadphoneJack: false) == "headphones")
        #expect(p.outputSymbol(kind: .builtIn, name: "Built-in Output", isHeadphoneJack: true) == "headphones")
        #expect(p.outputSymbol(kind: .builtIn, name: "MacBook Pro Speakers", isHeadphoneJack: false) == "laptopcomputer")
        #expect(p.outputSymbol(kind: .builtIn, name: "Mac mini Speakers", isHeadphoneJack: false) == "speaker.wave.2.fill")
        #expect(p.outputSymbol(kind: .airPlay, name: "Living Room", isHeadphoneJack: false) == "airplayaudio")
        #expect(p.outputSymbol(kind: .display, name: "LG UltraFine", isHeadphoneJack: false) == "display")
    }

    @Test func volumeGlyphTracksLevelAndMute() {
        let p = DesktopLyricsIslandActivityPolicy.self
        #expect(p.volumeSymbol(level: 0.5, muted: true) == "speaker.slash.fill")
        #expect(p.volumeSymbol(level: 0, muted: false) == "speaker.slash.fill")
        #expect(p.volumeSymbol(level: 0.2, muted: false) == "speaker.wave.1.fill")
        #expect(p.volumeSymbol(level: 0.5, muted: false) == "speaker.wave.2.fill")
        #expect(p.volumeSymbol(level: 0.9, muted: false) == "speaker.wave.3.fill")
    }

    @Test func batteryGlyphTracksLevelAndCharging() {
        let p = DesktopLyricsIslandActivityPolicy.self
        #expect(p.batterySymbol(level: 0.05, charging: true) == "battery.100percent.bolt")
        #expect(p.batterySymbol(level: 0.05, charging: false) == "battery.0percent")
        #expect(p.batterySymbol(level: 0.3, charging: false) == "battery.25percent")
        #expect(p.batterySymbol(level: 0.5, charging: false) == "battery.50percent")
        #expect(p.batterySymbol(level: 0.8, charging: false) == "battery.75percent")
        #expect(p.batterySymbol(level: 1, charging: false) == "battery.100percent")
    }
}
