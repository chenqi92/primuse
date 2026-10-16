import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 用户此刻是不是在滑动列表, 给后台往资料库交结果的时机用(见
/// `LibraryPublishTimingPolicy`)。
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

    func activity(now: Date = Date()) -> LibraryPublishTimingPolicy.ScrollActivity {
        #if os(iOS)
        let scrolling = RunLoop.main.currentMode == .tracking
        #elseif os(macOS)
        let scrolling = RunLoop.main.currentMode == .eventTracking
        #else
        let scrolling = false
        #endif
        if scrolling { lastActivityAt = now }
        return .init(isScrolling: scrolling, lastActivityAt: lastActivityAt)
    }

    private func install() {
        #if os(iOS)
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 0
        ) { [weak self] _, _ in
            // 主线程的 run loop 回调, 只是 SDK 没标 @MainActor。
            MainActor.assumeIsolated {
                self?.lastActivityAt = Date()
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
                self?.lastActivityAt = Date()
            }
            return event
        }
        #endif
    }
}
