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
            NavigationStack {
                WatchPlaybackPager()
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

private struct WatchPlaybackPager: View {
    @Environment(WatchPlayerStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = Page.playing
    @State private var offset: CGFloat = 0
    @State private var horizontalDrag: Bool?
    @State private var isTransitioning = false
    @State private var transitionID = 0
    @State private var visibleRoots: Set<Page> = []
    @State private var didOpenInitialPage = false
    @State private var showsOptions = false
    @State private var isDraggingSeek = false

    private enum Page: Hashable {
        case queue, playing, seek
    }

    private var pages: [Page] {
        if store.isLiveStream { return [.playing] }
        return store.hasSong && store.duration > 0 ? [.queue, .playing, .seek] : [.queue, .playing]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(pages, id: \.self) { page in
                    content(for: page, width: geometry.size.width)
                    .onAppear { visibleRoots.insert(page) }
                    .onDisappear { visibleRoots.remove(page) }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: position(of: page) * geometry.size.width + offset)
                    .allowsHitTesting(selection == page && !isTransitioning)
                    .accessibilityHidden(selection != page)
                }
            }
            // 横向裁切邻页，顶部保留封面伸入导航栏两颗按钮之间的空间。
            .clipShape(Path(CGRect(
                x: 0, y: -geometry.safeAreaInsets.top,
                width: geometry.size.width,
                height: geometry.size.height + geometry.safeAreaInsets.top
            )))
            .contentShape(Rectangle())
            .simultaneousGesture(swipe(width: geometry.size.width))
            .accessibilityScrollAction { edge in
                guard visibleRoots.contains(selection) else { return }
                if edge == .trailing { turn(direction: 1, width: geometry.size.width) }
                if edge == .leading { turn(direction: -1, width: geometry.size.width) }
            }
            .toolbar {
                if selection == .playing {
                    if !store.isLiveStream {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { turn(direction: -1, width: geometry.size.width) } label: {
                                Image(systemName: "list.bullet")
                            }
                            .accessibilityLabel(WatchString("ext.watch.queue.title"))
                        }
                    }
                    if store.hasSong {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showsOptions = true } label: { Image(systemName: "ellipsis") }
                                .accessibilityLabel(WatchString("ext.watch.more.title"))
                        }
                    }
                } else if selection == .queue {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { OfflineLibraryWatchView() } label: { Image(systemName: "applewatch") }
                            .accessibilityLabel(WatchString("ext.watch.offline.title"))
                    }
                } else if selection == .seek {
                    ToolbarItem(placement: .topBarLeading) {
                        clockAlignmentSpace
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        clockAlignmentSpace
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(navigationTitle)
        .containerBackground(for: .navigation) {
            if selection == .playing || selection == .seek {
                WatchNowPlayingBackdrop(cover: store.coverImage, accent: store.accent)
            } else if selection == .queue {
                LinearGradient(colors: [store.accent.opacity(0.45), .black], startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
        .onChange(of: pages) { _, available in
            resetTransition()
            if !available.contains(selection) { selection = .playing }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetTransition() }
        }
        .onAppear {
            guard !didOpenInitialPage else { return }
            didOpenInitialPage = true
            #if DEBUG
            if store.demoScreen == "queue", pages.contains(.queue) { selection = .queue }
            if store.demoScreen == "seek", pages.contains(.seek) { selection = .seek }
            #endif
        }
    }

    private var navigationTitle: String {
        switch selection {
        case .playing: ""
        case .queue: WatchString("ext.watch.queue.title")
        case .seek: ""
        }
    }

    // 对称保留工具栏空间，让系统时间与正在播放页一样居中。
    private var clockAlignmentSpace: some View {
        Color.clear
            .frame(width: 32, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(for page: Page, width: CGFloat) -> some View {
        switch page {
        case .queue:
            LibraryWatchView()
        case .playing:
            NowPlayingWatchView(
                isActive: selection == .playing && !isTransitioning && offset == 0,
                showsOptions: $showsOptions,
                onShowSeek: { turn(direction: 1, width: width) }
            )
        case .seek:
            WatchSeekView(isActive: selection == .seek && !isTransitioning && offset == 0,
                          onDialDraggingChanged: { isDraggingSeek = $0 })
        }
    }

    private func position(of page: Page) -> CGFloat {
        guard page != selection, let current = pages.firstIndex(of: selection),
              let index = pages.firstIndex(of: page) else { return 0 }
        // 两页时同一个邻页可从左右任一侧进入，不复制页面或它的表冠控件。
        if pages.count == 2 { return offset > 0 ? -1 : 1 }
        return (index - current + pages.count) % pages.count == 1 ? 1 : -1
    }

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                if isDraggingSeek {
                    horizontalDrag = false
                    return
                }
                guard pages.count > 1, !isTransitioning, visibleRoots.contains(selection) else { return }
                if horizontalDrag == nil {
                    horizontalDrag = abs(value.translation.width) > abs(value.translation.height) * 1.2
                }
                guard horizontalDrag == true else { return }
                offset = min(width, max(-width, value.translation.width))
            }
            .onEnded { value in
                defer { horizontalDrag = nil }
                guard horizontalDrag == true, !isTransitioning, !isDraggingSeek else { return }
                let translation = value.translation.width
                let predicted = value.predictedEndTranslation.width
                if abs(translation) > width * 0.25 || abs(predicted) > width * 0.5 {
                    turn(direction: translation < 0 ? 1 : -1, width: width)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                }
            }
    }

    private func turn(direction: Int, width: CGFloat) {
        guard pages.count > 1, !isTransitioning, !isDraggingSeek,
              let current = pages.firstIndex(of: selection) else { return }
        let target = pages[(current + direction + pages.count) % pages.count]
        transitionID &+= 1
        let id = transitionID
        isTransitioning = true
        withAnimation(.easeOut(duration: 0.25), completionCriteria: .logicallyComplete) {
            offset = direction > 0 ? -width : width
        } completion: {
            guard transitionID == id else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = pages.contains(target) ? target : .playing
                offset = 0
                isTransitioning = false
            }
        }
    }

    private func resetTransition() {
        transitionID &+= 1
        offset = 0
        horizontalDrag = nil
        isTransitioning = false
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
