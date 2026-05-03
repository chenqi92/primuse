#if os(macOS)
import SwiftUI
import PrimuseKit

/// Top-level macOS layout: NavigationSplitView (sidebar + detail) with a
/// full-width transport bar pinned to the bottom safe area. Settings live
/// in a separate scene wired up by `PrimuseApp` (⌘,).
///
/// The "now playing" view slides in over the detail pane (not as a sheet),
/// so the sidebar and the bottom mini bar stay visible — matches Apple
/// Music / Cider behavior.
struct MacContentView: View {
    @State private var selection: MacRoute = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 进入全屏前的侧栏可见性,退出全屏要还原成它。
    @State private var savedColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var nowPlayingPresented = false
    @State private var queuePresented = false
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            // detail 横向拆成 [主内容] + [可选 队列侧栏],让队列像
            // Apple Music 一样紧贴右侧边缘 slide-in,不再用 modal sheet
            // 把整个屏幕劫持。
            HStack(spacing: 0) {
                ZStack {
                    MacDetailContainer(route: selection, searchText: $searchText)

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
                    Divider()
                    MacQueuePanel(onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            queuePresented = false
                        }
                    })
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
                }
            }
            // 底栏只挂在 detail 上,避免横跨到 sidebar 把音乐源列表
            // 的尾部条目遮住。
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .primuseRequestExpandNowPlaying)) { _ in
            // 全屏请求由 AppDelegate 发出,这里把 NowPlaying 视图展开,
            // 让全屏内容直接是播放器界面。
            withAnimation(.easeInOut(duration: 0.25)) {
                nowPlayingPresented = true
            }
        }
        // 进入全屏: 默认收起侧栏,内容更集中,跟 Apple Music 一致。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            savedColumnVisibility = columnVisibility
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = savedColumnVisibility
            }
        }
    }
}
#endif
