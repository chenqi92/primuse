#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 根布局: 顶部 tab bar (TopShelf 风格) + 当前 tab 的全屏内容。
/// tvOS 不用 sidebar - 设计稿要求横向焦点导航, 跟 Apple TV 系统应用一致。
struct TVRoot: View {
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case home, library, search, nowPlaying, settings

        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .home: return "home_title"
            case .library: return "library_title"
            case .search: return "search_title"
            case .nowPlaying: return "now_playing"
            case .settings: return "settings"
            }
        }
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .library: return "music.note.list"
            case .search: return "magnifyingglass"
            case .nowPlaying: return "play.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @State private var tab: Tab = .home

    var body: some View {
        TabView(selection: $tab) {
            TVHomeView()
                .tabItem { Label(Tab.home.titleKey, systemImage: Tab.home.icon) }
                .tag(Tab.home)
            TVLibraryView()
                .tabItem { Label(Tab.library.titleKey, systemImage: Tab.library.icon) }
                .tag(Tab.library)
            TVSearchView()
                .tabItem { Label(Tab.search.titleKey, systemImage: Tab.search.icon) }
                .tag(Tab.search)
            TVNowPlayingView()
                .tabItem { Label(Tab.nowPlaying.titleKey, systemImage: Tab.nowPlaying.icon) }
                .tag(Tab.nowPlaying)
            TVSettingsView()
                .tabItem { Label(Tab.settings.titleKey, systemImage: Tab.settings.icon) }
                .tag(Tab.settings)
        }
        .background(TVColor.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
#endif
