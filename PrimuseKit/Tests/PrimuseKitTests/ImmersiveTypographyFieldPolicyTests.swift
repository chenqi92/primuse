import Testing
@testable import PrimuseKit

@Suite("Immersive lyric typography")
struct ImmersiveLyricTypographyPolicyTests {
    @Test("1080p television keeps the active lyric readable at distance")
    func televisionHierarchy() {
        let metrics = ImmersiveLyricTypographyPolicy.metrics(
            for: "我把名字写在退潮的沙上",
            canvasWidth: 1920,
            canvasHeight: 1080,
            availableWidth: 1040,
            platform: .television
        )

        #expect(metrics.currentFontSize >= 58)
        #expect(metrics.adjacentFontSize <= metrics.currentFontSize * 0.67)
        #expect(metrics.adjacentFontSize >= 25)
        #expect(metrics.currentLineLimit == 2)
    }

    @Test("Long Latin and CJK lines scale and wrap without collapsing")
    func longLinesAdapt() {
        let latin = ImmersiveLyricTypographyPolicy.metrics(
            for: "When every streetlight disappears behind the rain I still remember exactly where your footsteps turned",
            canvasWidth: 1440,
            canvasHeight: 900,
            availableWidth: 590,
            platform: .desktop
        )
        let cjk = ImmersiveLyricTypographyPolicy.metrics(
            for: "沿着没有尽头的海岸一直走到所有灯光都在身后慢慢消失的时候仍然记得你的名字",
            canvasWidth: 1440,
            canvasHeight: 900,
            availableWidth: 590,
            platform: .desktop
        )

        #expect((3...4).contains(latin.currentLineLimit))
        #expect((3...4).contains(cjk.currentLineLimit))
        #expect(latin.currentFontSize >= 19.8)
        #expect(cjk.currentFontSize >= 19.8)
        #expect(latin.currentFontSize < 42)
        #expect(cjk.currentFontSize < 42)
    }

    @Test("RTL text uses the same bounded readable scale")
    func rightToLeftText() {
        let rtl = ImmersiveLyricTypographyPolicy.metrics(
            for: "وقتی میای صدای پات از همه جاده ها میاد",
            canvasWidth: 1280,
            canvasHeight: 800,
            availableWidth: 520,
            platform: .desktop
        )
        #expect(rtl.currentFontSize.isFinite)
        #expect(rtl.currentFontSize >= 17.6)
        #expect((2...4).contains(rtl.currentLineLimit))
    }

    @Test("Resizable Mac windows reduce typography before clipping")
    func resizableDesktopCanvas() {
        let fullScreen = ImmersiveLyricTypographyPolicy.metrics(
            for: "A short lyric line",
            canvasWidth: 1728,
            canvasHeight: 1080,
            availableWidth: 720,
            platform: .desktop
        )
        let window = ImmersiveLyricTypographyPolicy.metrics(
            for: "A short lyric line",
            canvasWidth: 900,
            canvasHeight: 600,
            availableWidth: 360,
            platform: .desktop
        )
        #expect(window.currentFontSize < fullScreen.currentFontSize)
        #expect(window.currentFontSize >= 13.2)
    }
}

@Suite("Immersive typography field selection")
struct ImmersiveTypographyFieldPolicyTests {
    @Test("Pool removes timestamps, blanks, duplicates and the song title")
    func meaningfulUniquePool() {
        let pool = ImmersiveTypographyFieldPolicy.textPool(
            from: [
                "[00:12.34]First light on the water",
                "  ",
                "First   light on the water",
                "<00:15.20>Second line",
                "TITLE",
                "[ar:Example Artist]",
                "•••",
                "第三行",
            ],
            title: "Title"
        )

        #expect(pool == ["First light on the water", "Second line", "第三行"])
    }

    @Test("Current lyric and title remain unique foreground content")
    func foregroundContentIsExcluded() {
        let pool = ImmersiveTypographyFieldPolicy.textPool(
            from: ["Song Name", "Current lyric", "Another lyric", "Current lyric"],
            title: "Song Name"
        )
        let visible = ImmersiveTypographyFieldPolicy.visibleLines(
            in: pool,
            excluding: "Song Name",
            currentLyric: "Current lyric"
        )
        #expect(visible == ["Another lyric"])
    }

    @Test("Short and empty lyrics never invent or repeat text")
    func controlledFallback() {
        let short = ImmersiveTypographyFieldPolicy.textPool(
            from: ["Only one line", "Only one line"],
            title: "Title"
        )
        let empty = ImmersiveTypographyFieldPolicy.textPool(
            from: ["", "[00:10.00]", "---"],
            title: "Title"
        )
        #expect(short == ["Only one line"])
        #expect(empty.isEmpty)
        #expect(ImmersiveTypographyFieldPolicy.layout(
            lines: empty,
            canvasWidth: 1920,
            canvasHeight: 1080,
            platform: .television,
            reduceMotion: false
        ).isEmpty)
    }

    @Test("1080p field fills multiple depths with unique lines")
    func televisionFieldDepth() {
        let lines = (0..<20).map { "Lyric line \($0)" }
        let layout = ImmersiveTypographyFieldPolicy.layout(
            lines: lines,
            canvasWidth: 1920,
            canvasHeight: 1080,
            platform: .television,
            reduceMotion: false
        )
        #expect(layout.count == 16)
        #expect(Set(layout.map(\.text)).count == layout.count)
        #expect(layout.map(\.normalizedY).max()! - layout.map(\.normalizedY).min()! > 0.80)
        #expect(layout.contains { $0.isOutlined })
        #expect(layout.contains { !$0.isOutlined })
        #expect(Set(layout.map(\.opacity)).count >= 3)
    }

    @Test("Reduce Motion freezes drift without changing layout or selection")
    func reduceMotion() {
        let lines = (0..<12).map { "Line \($0)" }
        let moving = ImmersiveTypographyFieldPolicy.layout(
            lines: lines,
            canvasWidth: 1440,
            canvasHeight: 900,
            platform: .desktop,
            reduceMotion: false
        )
        let reduced = ImmersiveTypographyFieldPolicy.layout(
            lines: lines,
            canvasWidth: 1440,
            canvasHeight: 900,
            platform: .desktop,
            reduceMotion: true
        )
        #expect(moving.map(\.text) == reduced.map(\.text))
        #expect(moving.contains { $0.driftXFraction > 0 || $0.driftYFraction > 0 })
        #expect(reduced.allSatisfy { $0.driftXFraction == 0 && $0.driftYFraction == 0 })
    }

    @Test("Different canvases use bounded item counts")
    func canvasItemCounts() {
        let lines = (0..<24).map { "Line \($0)" }
        let television = ImmersiveTypographyFieldPolicy.layout(
            lines: lines,
            canvasWidth: 1920,
            canvasHeight: 1080,
            platform: .television,
            reduceMotion: false
        )
        let compactMac = ImmersiveTypographyFieldPolicy.layout(
            lines: lines,
            canvasWidth: 900,
            canvasHeight: 600,
            platform: .desktop,
            reduceMotion: false
        )
        #expect(television.count == 16)
        #expect(compactMac.count == 10)
    }

    @Test("A short lyric set still spans the television canvas")
    func sparseLyricsSpanCanvas() {
        let layout = ImmersiveTypographyFieldPolicy.layout(
            lines: (0..<8).map { "Line \($0)" },
            canvasWidth: 1920,
            canvasHeight: 1080,
            platform: .television,
            reduceMotion: false
        )
        #expect(layout.count == 8)
        #expect(layout.map(\.normalizedY).max()! - layout.map(\.normalizedY).min()! > 0.80)
    }
}

@Suite("Immersive typography field motion")
struct ImmersiveTypographyFieldMotionPolicyTests {
    @Test("Motion uses explicit bounded full-cycle durations")
    func boundedCycleDurations() {
        for itemID in 0..<16 {
            #expect((12...18).contains(
                ImmersiveTypographyFieldMotionPolicy.opacityCycleDuration(for: itemID)
            ))
            #expect((30...48).contains(
                ImmersiveTypographyFieldMotionPolicy.horizontalCycleDuration(for: itemID)
            ))
            #expect((38...54).contains(
                ImmersiveTypographyFieldMotionPolicy.verticalCycleDuration(for: itemID)
            ))
        }
        #expect(ImmersiveTypographyFieldMotionPolicy.refreshInterval >= 0.20)
    }

    @Test("Motion changes visibly within a few seconds")
    func visibleEarlyChange() throws {
        let item = try #require(makeMovingItem())
        let start = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: 0,
            allowsMotion: true
        )
        let later = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: 3,
            allowsMotion: true
        )

        #expect(later.opacityMultiplier - start.opacityMultiplier > 0.06)
        #expect(abs(later.xOffsetFraction - start.xOffsetFraction) > 0.004)
    }

    @Test("Each oscillator returns to its starting point after a full cycle")
    func completeCycles() throws {
        let item = try #require(makeMovingItem())
        let start = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: 0,
            allowsMotion: true
        )
        let opacityCycle = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: ImmersiveTypographyFieldMotionPolicy.opacityCycleDuration(for: item.id),
            allowsMotion: true
        )
        let horizontalCycle = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: ImmersiveTypographyFieldMotionPolicy.horizontalCycleDuration(for: item.id),
            allowsMotion: true
        )
        let verticalCycle = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: ImmersiveTypographyFieldMotionPolicy.verticalCycleDuration(for: item.id),
            allowsMotion: true
        )

        #expect(abs(opacityCycle.opacityMultiplier - start.opacityMultiplier) < 0.000_001)
        #expect(abs(horizontalCycle.xOffsetFraction - start.xOffsetFraction) < 0.000_001)
        #expect(abs(verticalCycle.yOffsetFraction - start.yOffsetFraction) < 0.000_001)
    }

    @Test("Disabled motion has a stable neutral fallback")
    func disabledMotion() throws {
        let item = try #require(makeMovingItem())
        let state = ImmersiveTypographyFieldMotionPolicy.state(
            for: item,
            at: 123.4,
            allowsMotion: false
        )

        #expect(state.opacityMultiplier == 1)
        #expect(state.xOffsetFraction == 0)
        #expect(state.yOffsetFraction == 0)
    }

    private func makeMovingItem() -> ImmersiveTypographyFieldItem? {
        ImmersiveTypographyFieldPolicy.layout(
            lines: ["First background lyric"],
            canvasWidth: 1920,
            canvasHeight: 1080,
            platform: .television,
            reduceMotion: false
        ).first
    }
}

@Suite("Immersive word highlight progress")
struct ImmersiveLyricHighlightProgressPolicyTests {
    @Test("Line timing provides a bounded fallback highlight")
    func lineProgress() {
        #expect(ImmersiveLyricHighlightProgressPolicy.progress(from: 10, to: 14, at: 9) == 0)
        #expect(ImmersiveLyricHighlightProgressPolicy.progress(from: 10, to: 14, at: 12) == 0.5)
        #expect(ImmersiveLyricHighlightProgressPolicy.progress(from: 10, to: 14, at: 15) == 1)
    }

    @Test("Word timing advances monotonically and respects RTL text weights")
    func wordProgress() {
        let syllables = [
            LyricSyllable(text: "سلام", start: 10, end: 10.5),
            LyricSyllable(text: " دنیا", start: 10.5, end: 11.2),
        ]
        let before = ImmersiveLyricHighlightProgressPolicy.progress(in: syllables, at: 9.8)
        let first = ImmersiveLyricHighlightProgressPolicy.progress(in: syllables, at: 10.3)
        let second = ImmersiveLyricHighlightProgressPolicy.progress(in: syllables, at: 10.8)
        let complete = ImmersiveLyricHighlightProgressPolicy.progress(in: syllables, at: 12)
        #expect(before == 0)
        #expect(first > before)
        #expect(second > first)
        #expect(complete == 1)
    }
}
