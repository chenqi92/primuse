#if os(macOS)
import SwiftUI
import PrimuseKit

/// 1.6 重设计后的 macOS 根布局: 自定义 TitleBar + Sidebar + Detail + BottomBar 四件套,
/// 不再依赖 NavigationSplitView。窗口设了 `.windowStyle(.hiddenTitleBar)`,
/// 顶部导航、搜索和窗口控制点都由 `PMTitleBar` 按设计稿绘制。
struct MacContentView: View {
    @State private var selection: MacRoute = .home
    @State private var sidebarCollapsed: Bool = false
    @State private var savedSidebarCollapsed: Bool = false
    @State private var nowPlayingPresented = false
    @State private var queuePresented = false
    @State private var searchText = ""
    @State private var preferences = MacUIPreferences.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(SourcesStore.self) private var sourcesStore
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            PMTitleBar(
                searchText: $searchText,
                sidebarCollapsed: $sidebarCollapsed,
                selection: $selection,
                onAddSource: { selectRoute(.sources) },
                onAudioOutput: { /* 由 BottomBar 右侧的喇叭按钮 popover 接管 */ }
            )

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    MacSidebar(selection: $selection)
                        .frame(width: preferences.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    MacDetailContainer(route: selection, searchText: $searchText)
                        .background(PMColor.bg.ignoresSafeArea())

                    if nowPlayingPresented {
                        MacNowPlayingView(onClose: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                nowPlayingPresented = false
                            }
                        })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if queuePresented {
                    MacQueuePanel(onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            queuePresented = false
                        }
                    })
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
                }
            }

            MacBottomBar(
                isExpanded: nowPlayingPresented,
                isQueueShown: queuePresented,
                onToggleNowPlaying: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        nowPlayingPresented.toggle()
                    }
                },
                onToggleQueue: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        queuePresented.toggle()
                    }
                },
                onMiniPlayer: {
                    PrimuseAppDelegate.shared?.showMiniPlayer()
                },
                onFullScreen: {
                    PrimuseAppDelegate.shared?.toggleFullScreenPlayer()
                }
            )
        }
        .environment(\.pmAppearance, preferences.appearance)
        .background(PMColor.bg.ignoresSafeArea())
        .background(PMWindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: onboardingPresented) {
            OnboardingView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .task { MainWindowOpener.register(openWindow) }
        .onReceive(NotificationCenter.default.publisher(for: .primuseRequestExpandNowPlaying)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                nowPlayingPresented = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectScrobble)) { _ in
            selectRoute(.scrobble)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            savedSidebarCollapsed = sidebarCollapsed
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarCollapsed = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarCollapsed = savedSidebarCollapsed
            }
        }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !hasSeenOnboarding && sourcesStore.sources.isEmpty },
            set: { isPresented in
                if !isPresented { hasSeenOnboarding = true }
            }
        )
    }

    private func selectRoute(_ route: MacRoute) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = route
        }
    }
}
#endif
