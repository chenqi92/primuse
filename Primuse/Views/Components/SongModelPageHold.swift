import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
#endif

/// 一个分类(或首页、搜索的一页)在歌曲模型不在内存里时怎么显示(6c 单元 4 S1)。
enum LibraryPageReadiness: Equatable {
    /// 不读曲库,随时画(电台、播客;有声书架自己先摆上次的书架或骨架)。
    case always
    /// 已改成读曲库目录:曲库可用(`isUsable`)就画。
    case catalog
    /// 还读整库数组:模型在内存里(`isReady`)才画;放掉了时显示启动预览或「加载中」,并替页面占用模型
    /// (`.songModelPage`,`.legacyPage`),装好就画。
    case legacy
}

/// 一个页面(或页面里的一支)还要读整库数组、没改成读曲库目录时,替它占住歌曲模型(`.legacyPage`)。
///
/// 规则(6c 单元 4 S1):
/// - 只在页面要数组、看得见、App 在前台,而歌曲模型此刻放掉了(可用、不在内存里)时才拿;拿了就请模型装回来,页面在装好之前
///   照旧显示「加载中」(页面自己按 `isReady` 判断)。
/// - 拿到之后页面一直看得见、App 一直在前台就一直拿着(装好之后也不放,免得看着的时候被放掉)。
/// - 页面消失、App 进后台(iOS 场景离开 `.active`;macOS 隐藏或失去前台,与后台修剪同一个信号)就放手 ——
///   放掉歌曲模型时页面占用与别的占用一样算数,所以在后台不能留着。回到前台而页面还在时再拿。
/// - 歌曲模型本来就在内存里时不拿:前台不会放掉它,进后台时页面本来也要放手。
@MainActor
@Observable
final class SongModelPageHold {
    /// 正拿着(或正在拿)占用。
    private(set) var isHolding = false
    // deinit 不在主 actor 上,只在那里读一次(同 `FavoriteCollectionStore.observer`)。
    @ObservationIgnored nonisolated(unsafe) fileprivate var hold: MusicLibrary.SongModelHold?
    @ObservationIgnored nonisolated(unsafe) fileprivate var acquisition: Task<Void, Never>?

    init() {}

    deinit {
        // 视图没走到 onDisappear 就没了时兜底放手,不让一个看不见的页面一直挡着放掉。
        let hold = hold
        acquisition?.cancel()
        if let hold { Task { @MainActor in hold.end() } }
    }
}

extension SongModelPageHold {
    /// 按此刻的条件拿或放。`needsArrays`:这一页(这一支)要整库数组;`isVisible`:页面在屏幕上;
    /// `isActive`:App 在前台。
    func update(library: MusicLibrary, needsArrays: Bool, isVisible: Bool, isActive: Bool) {
        guard needsArrays, isVisible, isActive else {
            drop()
            return
        }
        // 只在模型放掉了(可用而不在内存里)时拿。第一次发布之前不拿:那时占用会把启动窗口里推迟着的读取
        // 提前开始,改变启动的先后。
        guard !isHolding, !library.isReady, library.isUsable else { return }
        isHolding = true
        acquisition = Task { @MainActor [weak self] in
            let token = await library.holdSongModel(.legacyPage)
            guard let self, self.isHolding, !Task.isCancelled else {
                token.end()
                return
            }
            self.hold = token
            self.acquisition = nil
        }
    }

    /// 放手(还在等装载的也一起撤掉)。
    func drop() {
        guard isHolding else { return }
        isHolding = false
        acquisition?.cancel()
        acquisition = nil
        hold?.end()
        hold = nil
    }
}

/// `.songModelPage(needsArrays:)` 的实现:把页面看不看得见、App 在不在前台、要不要数组交给 `SongModelPageHold`。
@MainActor
struct SongModelPageModifier: ViewModifier {
    @Environment(MusicLibrary.self) private var library
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var pageHold = SongModelPageHold()
    @State private var isVisible = false
    #if os(macOS)
    @State private var isAppActive = SongModelPageModifier.appIsActive
    #endif
    let needsArrays: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                refresh()
            }
            .onDisappear {
                isVisible = false
                refresh()
            }
            .onChange(of: needsArrays) { _, _ in refresh() }
            .onChange(of: library.isReady) { _, _ in refresh() }
            #if os(iOS)
            .onChange(of: scenePhase) { _, _ in refresh() }
            #else
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
                appActivityChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                appActivityChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                appActivityChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
                appActivityChanged()
            }
            #endif
    }

    private var isActive: Bool {
        #if os(iOS)
        scenePhase == .active
        #else
        isAppActive
        #endif
    }

    private func refresh() {
        pageHold.update(library: library, needsArrays: needsArrays, isVisible: isVisible, isActive: isActive)
    }

    #if os(macOS)
    private static var appIsActive: Bool {
        guard let app = NSApp else { return true }
        return app.isActive && !app.isHidden
    }

    private func appActivityChanged() {
        isAppActive = Self.appIsActive
        refresh()
    }
    #endif
}

extension View {
    /// 这一页(或这一支,`needsArrays` 随页面状态变)还要整库数组:歌曲模型不在内存里时替它占用、装回来,
    /// 页面消失或 App 进后台时放手。页面自己在 `isReady` 之前显示「加载中」。
    /// `keepsInputOnRelease`:收用户输入的页(编辑器)由这里来画加载:显示过内容之后模型被放掉也不换下来,
    /// 盖一层加载、不接输入,装回来就揭开(`SongModelPageLatch`,UB)。
    @ViewBuilder
    func songModelPage(needsArrays: Bool = true, keepsInputOnRelease: Bool = false) -> some View {
        if keepsInputOnRelease {
            modifier(SongModelInputPageModifier(readiness: needsArrays ? .legacy : .catalog))
        } else {
            modifier(SongModelPageModifier(needsArrays: needsArrays))
        }
    }
}
