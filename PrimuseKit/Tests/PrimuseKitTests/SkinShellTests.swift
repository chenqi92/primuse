import Foundation
import Testing
@testable import PrimuseKit

@Suite("Skin shells")
struct SkinShellTests {
    @Test("经典是标签栏外壳配附件迷你条,极简是顶部 tab 外壳配停靠条")
    func shippedSkinsDeclareTheirShell() {
        #expect(SkinCatalog.classic.shell == SkinShell(navigation: .tabBar, nowPlayingBar: .tabAccessory))
        #expect(SkinCatalog.classic.shell == .tabBar)
        #expect(SkinCatalog.minimal.shell == SkinShell(navigation: .topTabs, nowPlayingBar: .dockedBar))
        #expect(SkinCatalog.minimal.shell == .topTabs)
    }

    @Test("标签栏只配附件;顶部 tab 只配停靠条或胶囊")
    func validCombinations() {
        #expect(SkinShell.nowPlayingBars(for: .tabBar) == [.tabAccessory])
        #expect(SkinShell.nowPlayingBars(for: .topTabs) == [.dockedBar, .floatingCapsule])
        var valid: [SkinShell] = []
        for navigation in SkinShell.Navigation.allCases {
            for bar in SkinShell.NowPlayingBar.allCases {
                let shell = SkinShell(navigation: navigation, nowPlayingBar: bar)
                if shell.isValid { valid.append(shell) }
            }
        }
        #expect(
            Set(valid) == [
                SkinShell(navigation: .tabBar, nowPlayingBar: .tabAccessory),
                SkinShell(navigation: .topTabs, nowPlayingBar: .dockedBar),
                SkinShell(navigation: .topTabs, nowPlayingBar: .floatingCapsule),
            ]
        )
        // 每种播放条都至少有一种导航结构能配 —— 登记了却永远选不上的实现是死代码。
        for bar in SkinShell.NowPlayingBar.allCases {
            #expect(SkinShell.Navigation.allCases.contains { SkinShell.nowPlayingBars(for: $0).contains(bar) }, "\(bar)")
        }
    }

    @Test("凑不成一对的外壳被校验拦下")
    func invalidShellIsRejected() {
        for shell in [
            SkinShell(navigation: .tabBar, nowPlayingBar: .dockedBar),
            SkinShell(navigation: .tabBar, nowPlayingBar: .floatingCapsule),
            SkinShell(navigation: .topTabs, nowPlayingBar: .tabAccessory),
        ] {
            let skin = SkinDefinition(
                id: "odd-shell",
                nameKey: "k",
                descriptionKey: "k",
                colors: SkinCatalog.classic.colors,
                metrics: SkinCatalog.classic.metrics,
                typography: SkinCatalog.classic.typography,
                motion: SkinCatalog.classic.motion,
                shell: shell
            )
            #expect(!shell.isValid)
            #expect(SkinValidationPolicy.issues(in: skin) == [.invalidShell(skinID: "odd-shell", shell: shell)])
        }
    }

    @Test("旧导航开关的镜像值由外壳的导航结构决定")
    func legacyNavigationFollowsTheShell() {
        #expect(SkinMigrationPolicy.legacyNavigationModeRawValue(for: SkinCatalog.classic) == "standard")
        #expect(SkinMigrationPolicy.legacyNavigationModeRawValue(for: SkinCatalog.minimal) == "minimal")
        #expect(SkinMigrationPolicy.legacyNavigationModeRawValue(for: SkinFixtures.midnight) == "minimal")
    }

    @Test("外壳能 JSON 往返")
    func shellRoundTrips() throws {
        let shell = SkinShell(navigation: .topTabs, nowPlayingBar: .floatingCapsule)
        let decoded = try JSONDecoder().decode(SkinShell.self, from: JSONEncoder().encode(shell))
        #expect(decoded == shell)
    }
}
