import SwiftUI
import WatchKit
@preconcurrency import WatchConnectivity

@main
struct PrimuseWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var store = WatchPlayerStore()

    var body: some Scene {
        WindowGroup {
            // 正在播放是根页面, 一屏放下封面和播放键: 播放列表从左上角推进去, 更多选项从
            // 右上角弹出。不再横滑分页: 分页圆点压在播放键上, 表冠也要留给 iPhone 音量。
            NavigationStack {
                NowPlayingWatchView()
            }
            .environment(store)
            .alert(WatchString("ext.watch.offline.title"), isPresented: Binding(
                get: { store.offlineError != nil || store.offlinePlayer.error != nil },
                set: { if !$0 { store.offlineError = nil; store.offlinePlayer.clearError() } }
            )) {
                Button(WatchString("ext.watch.offline.ok")) { store.offlineError = nil; store.offlinePlayer.clearError() }
            } message: { Text(store.offlineError ?? store.offlinePlayer.error ?? "") }
            .onChange(of: scenePhase, initial: true) { _, phase in
                store.setActive(phase == .active)
            }
        }
    }
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private var tasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var completionTask: Task<Void, Never>?

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            tasks.append(connectivity)
            connectivity.expirationHandler = { [weak self, weak connectivity] in
                Task { @MainActor in
                    guard let self, let connectivity else { return }
                    self.finish(connectivity)
                }
            }
        }
        guard completionTask == nil else { return }
        completionTask = Task { [weak self] in
            while let self, !self.tasks.isEmpty {
                if WCSession.default.activationState == .activated, !WCSession.default.hasContentPending {
                    for task in self.tasks { self.finish(task) }
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.completionTask = nil
        }
    }

    private func finish(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        guard tasks.contains(where: { $0 === task }) else { return }
        tasks.removeAll { $0 === task }
        task.expirationHandler = nil
        task.setTaskCompletedWithSnapshot(false)
    }
}
