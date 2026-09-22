import Foundation
import Testing
@testable import PrimuseKit

@Suite("Minimal navigation detail ledger")
struct MinimalNavigationDetailLedgerTests {
    private enum Scope: Hashable, Sendable {
        case home
        case library
    }

    private typealias Ledger = MinimalNavigationDetailLedger<Scope>

    @Test("push 时顶栏随转场隐藏,不必等 preference")
    func hidesAsSoonAsDetailAppears() {
        var ledger = Ledger()
        ledger.record(.appearing, id: UUID(), scope: .library)
        #expect(ledger.hidesTopNavigation(for: .library))
        #expect(!ledger.hidesTopNavigation(for: .home))
    }

    @Test("返回开始顶栏就回来,返回完成后保持可见")
    func showsDuringAndAfterPop() {
        var ledger = Ledger()
        let id = UUID()
        ledger.record(.appearing, id: id, scope: .library)
        ledger.updateMounted([.library])

        ledger.record(.popping, id: id, scope: .library)
        #expect(!ledger.hidesTopNavigation(for: .library))

        ledger.record(.removed, id: id, scope: .library)
        ledger.updateMounted([])
        #expect(!ledger.hidesTopNavigation(for: .library))
        #expect(ledger == Ledger())
    }

    @Test("返回被取消,详情页还在,顶栏重新隐藏")
    func hidesAgainAfterCancelledPop() {
        var ledger = Ledger()
        let id = UUID()
        ledger.record(.appearing, id: id, scope: .library)
        ledger.updateMounted([.library])
        ledger.record(.popping, id: id, scope: .library)
        ledger.record(.appearing, id: id, scope: .library)
        #expect(ledger.hidesTopNavigation(for: .library))
    }

    @Test("先右后下:前一次返回以取消收尾,页面却被后一次带走,顶栏不能就此消失")
    func cancelledPopFollowedByUnreportedRemoval() {
        var ledger = Ledger()
        let id = UUID()
        ledger.record(.appearing, id: id, scope: .library)
        ledger.updateMounted([.library])

        // 横向返回手势开始,随后被下拉手势接管:前一次报「已取消」。
        ledger.record(.popping, id: id, scope: .library)
        ledger.record(.appearing, id: id, scope: .library)
        // 后一次返回没有再走认得出的返回转场,页面直接没了。
        ledger.updateMounted([])
        #expect(ledger.hidesTopNavigation(for: .library))

        ledger.record(.removed, id: id, scope: .library)
        #expect(!ledger.hidesTopNavigation(for: .library))
        #expect(ledger == Ledger())
    }

    @Test("removed 先于 preference 到达也一样收得干净")
    func removalBeforePreferenceUpdate() {
        var ledger = Ledger()
        let id = UUID()
        ledger.record(.appearing, id: id, scope: .library)
        ledger.updateMounted([.library])

        ledger.record(.removed, id: id, scope: .library)
        // 视图树还没更新,详情页仍算挂着。
        #expect(ledger.hidesTopNavigation(for: .library))
        ledger.updateMounted([])
        #expect(!ledger.hidesTopNavigation(for: .library))
        #expect(ledger == Ledger())
    }

    @Test("上层详情页返回时,下层详情页仍压着顶栏")
    func nestedDetailKeepsChromeHidden() {
        var ledger = Ledger()
        let album = UUID()
        let artist = UUID()
        ledger.record(.appearing, id: artist, scope: .library)
        ledger.record(.appearing, id: album, scope: .library)
        ledger.updateMounted([.library])

        ledger.record(.popping, id: album, scope: .library)
        #expect(ledger.hidesTopNavigation(for: .library))
        ledger.record(.removed, id: album, scope: .library)
        #expect(ledger.hidesTopNavigation(for: .library))
        #expect(ledger.presented == [artist: .library])
    }

    @Test("误报的 removed 无害:页面还挂着就继续隐藏,再次出现时重新登记")
    func spuriousRemovalIsBenign() {
        var ledger = Ledger()
        let id = UUID()
        ledger.record(.appearing, id: id, scope: .library)
        ledger.updateMounted([.library])

        ledger.record(.removed, id: id, scope: .library)
        #expect(ledger.hidesTopNavigation(for: .library))
        ledger.record(.appearing, id: id, scope: .library)
        #expect(ledger.hidesTopNavigation(for: .library))
        #expect(ledger.presented == [id: .library])
    }

    @Test("返回途中页面没经 preference 就消失,不留下「返回途中」的残账")
    func removalClearsStaleReturningScope() {
        var ledger = Ledger()
        let first = UUID()
        ledger.record(.appearing, id: first, scope: .library)
        // preference 还没来得及汇报,页面就被返回带走了。
        ledger.record(.popping, id: first, scope: .library)
        ledger.record(.removed, id: first, scope: .library)
        #expect(ledger.returning.isEmpty)

        // 下一张详情页:preference 先到也要立刻隐藏顶栏。
        ledger.updateMounted([.library])
        #expect(ledger.hidesTopNavigation(for: .library))
    }

    @Test("各页签互不影响")
    func scopesAreIndependent() {
        var ledger = Ledger()
        let libraryDetail = UUID()
        let homeDetail = UUID()
        ledger.record(.appearing, id: libraryDetail, scope: .library)
        ledger.record(.appearing, id: homeDetail, scope: .home)
        ledger.updateMounted([.library, .home])

        ledger.record(.popping, id: homeDetail, scope: .home)
        ledger.record(.removed, id: homeDetail, scope: .home)
        ledger.updateMounted([.library])
        #expect(!ledger.hidesTopNavigation(for: .home))
        #expect(ledger.hidesTopNavigation(for: .library))
    }
}
