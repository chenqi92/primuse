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

@Suite("Immersive lyric line keys")
struct ImmersiveTypographyFieldPolicyTests {
    @Test("Timestamps, spacing, case and diacritics do not split one line into two")
    func normalizedKeyMatchesTheSameLine() {
        let key = ImmersiveTypographyFieldPolicy.normalizedKey("First light on the water")
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("[00:12.34]First light on the water") == key)
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("<00:15.20> First   light on the WATER ") == key)
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("Café") == ImmersiveTypographyFieldPolicy.normalizedKey("cafe"))
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("Second line") != key)
    }

    @Test("Metadata tags and blank lines are not mistaken for timestamps")
    func normalizedKeyKeepsNonTimestampBrackets() {
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("[ar:Example Artist]") == "[ar:example artist]")
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("[00:10.00]").isEmpty)
        #expect(ImmersiveTypographyFieldPolicy.normalizedKey("   ").isEmpty)
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
