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
    @State private var nowPlayingPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ZStack {
                MacDetailContainer(route: selection)

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
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacBottomBar(
                isExpanded: nowPlayingPresented,
                onToggleNowPlaying: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        nowPlayingPresented.toggle()
                    }
                }
            )
        }
    }
}
#endif
