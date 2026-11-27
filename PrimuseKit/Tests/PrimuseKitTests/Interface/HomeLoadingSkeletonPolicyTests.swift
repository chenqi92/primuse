import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home loading skeleton")
struct HomeLoadingSkeletonPolicyTests {
    private func pick(
        _ order: [HomeSectionKind],
        hidden: Set<HomeSectionKind> = [],
        heights: [HomeSectionKind: Double] = [:],
        spacing: Double = 24,
        available: Double = 2_000
    ) -> [HomeSectionKind] {
        HomeLoadingSkeletonPolicy.sections(
            in: order,
            isShown: { !hidden.contains($0) },
            estimatedHeight: { heights[$0] ?? 200 },
            spacing: spacing,
            availableHeight: available
        )
    }

    @Test("照用户排的顺序画,关掉的区块不画")
    func followsUserOrderAndSkipsHidden() {
        let order: [HomeSectionKind] = [.recentlyAdded, .forYou, .playlists, .stats]
        #expect(pick(order, hidden: [.forYou]) == [.recentlyAdded, .playlists, .stats])
    }

    @Test("填满一屏就停,越线的那一块也画上")
    func stopsOnceTheViewportIsFilled() {
        let order: [HomeSectionKind] = [.recentlyAdded, .forYou, .playlists, .stats]
        // 200 + 24 + 200 = 424 < 500,第三块从 448 画到 648 越过 500,第四块不画。
        #expect(pick(order, available: 500) == [.recentlyAdded, .forYou, .playlists])
    }

    @Test("第一块就比一屏高时只画这一块")
    func tallFirstSectionFillsTheScreenAlone() {
        let order: [HomeSectionKind] = [.startListening, .forYou]
        #expect(pick(order, heights: [.startListening: 900], available: 600) == [.startListening])
    }

    @Test("全关掉时什么都不画")
    func everythingHiddenDrawsNothing() {
        let order: [HomeSectionKind] = [.forYou, .playlists]
        #expect(pick(order, hidden: [.forYou, .playlists]).isEmpty)
    }

    @Test("视口还没量到时按默认高度估,不会一块都不画")
    func unmeasuredViewportUsesFallbackHeight() {
        let order: [HomeSectionKind] = [.recentlyAdded, .forYou, .playlists, .stats, .topArtists, .folders]
        let fallback = pick(order, available: HomeLoadingSkeletonPolicy.unmeasuredViewportHeight)
        #expect(pick(order, available: 0) == fallback)
        #expect(pick(order, available: .nan) == fallback)
        #expect(!fallback.isEmpty)
        #expect(fallback.count < order.count)
    }

    @Test("Mac 区块同样适用")
    func worksForMacSections() {
        let order = MacHomeSectionLayout.decodeOrder("")
        let picked = HomeLoadingSkeletonPolicy.sections(
            in: order,
            isShown: { $0 != .overview },
            estimatedHeight: { _ in 300 },
            spacing: 24,
            availableHeight: 700
        )
        #expect(picked == [.pipeline, .startListening, .forYou])
    }
}
