import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 用户此刻是不是在交互(滑动列表、点按带出的转场、播放页展开收起、封面和歌词互换),
/// 给后台往资料库交结果、跑维护工作的时机用(见 `LibraryPublishTimingPolicy`)。
///
/// 不靠各个页面上报: 整库列表散在几十个页面里, 漏一个就在那一页照样顿。
/// - iOS: 手指拖动和惯性滚动期间主线程跑在 `UITrackingRunLoopMode` 里, 所有
///   UIScrollView(SwiftUI 的 ScrollView、List 也是)都一样。查询都在主线程上,
///   直接看当前模式; 进出这个模式时另记一笔时刻, 两次轻扫之间的空档也算在滑。
/// - Mac: 触控板、鼠标滚轮和惯性滚动都是 scrollWheel 事件, 用本地事件监听记下
///   最后一次的时刻; 拖滚动条时主线程在 `eventTracking` 模式里。
@MainActor
final class UserScrollActivityMonitor {
    static let shared = UserScrollActivityMonitor()

    /// 最近一次看到在滑(或刚停下)的时刻。
    private var lastActivityAt: Date?
    #if os(iOS)
    private var trackingObserver: CFRunLoopObserver?
    #elseif os(macOS)
    private var scrollEventMonitor: Any?
    #endif

    private init() {
        install()
    }

    /// 点按触发的转场不进入 tracking 模式，也需要给整库发布留出动画窗口。
    func recordInteraction(now: Date = Date()) {
        recordInteraction(lasting: 0, now: now)
    }

    /// 要占一段时间的转场（播放页展开收起、封面和歌词互换）：从现在到转场结束、再加停稳的那一秒，
    /// 都算在交互里，后台交付和维护工作在这段时间里先等着。
    func recordInteraction(lasting duration: TimeInterval, now: Date = Date()) {
        note(now.addingTimeInterval(max(0, duration)))
    }

    func activity(now: Date = Date()) -> LibraryPublishTimingPolicy.ScrollActivity {
        #if os(iOS)
        let scrolling = RunLoop.main.currentMode == .tracking
        #elseif os(macOS)
        let scrolling = RunLoop.main.currentMode == .eventTracking
        #else
        let scrolling = false
        #endif
        if scrolling { note(now) }
        return .init(isScrolling: scrolling, lastActivityAt: lastActivityAt)
    }

    /// 等这一阵交互（滑动、转场）停稳再往下走；一直不停最多等 `maximumHold`，到点照样往下走，
    /// 维护工作不会因为用户一直开着播放页、一直在滑就无限推后。任务被取消时立刻返回。
    func waitUntilSettled(
        maximumHold: TimeInterval = LibraryPublishTimingPolicy.maximumScrollHold
    ) async {
        let startedAt = Date()
        while !Task.isCancelled {
            let now = Date()
            if LibraryPublishTimingPolicy.isSettled(activity(now: now), now: now) { return }
            if now.timeIntervalSince(startedAt) >= maximumHold { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// 只往后推：正在进行的转场记下的结束时刻，不会被它期间的一次滑动或点按提前。
    private func note(_ moment: Date) {
        if let lastActivityAt, lastActivityAt >= moment { return }
        lastActivityAt = moment
    }

    private func install() {
        #if os(iOS)
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 0
        ) { [weak self] _, _ in
            // 主线程的 run loop 回调, 只是 SDK 没标 @MainActor。
            MainActor.assumeIsolated {
                self?.note(Date())
            }
        }
        CFRunLoopAddObserver(
            CFRunLoopGetMain(), observer, CFRunLoopMode(RunLoop.Mode.tracking.rawValue as CFString)
        )
        trackingObserver = observer
        #elseif os(macOS)
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // 本地事件监听在主线程同步回调, SDK 没标 @MainActor。
            MainActor.assumeIsolated {
                self?.note(Date())
            }
            return event
        }
        #endif
    }
}
