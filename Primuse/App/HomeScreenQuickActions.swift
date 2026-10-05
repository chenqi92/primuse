#if os(iOS)
import Observation
import PrimuseKit
import UIKit

/// 主屏幕上长按 App 图标弹出的快捷菜单项。
enum HomeScreenQuickAction: String {
    case resume = "com.welape.yuanyin.quick-action.resume"
    case shuffleLibrary = "com.welape.yuanyin.quick-action.shuffle-library"
    case shuffleLiked = "com.welape.yuanyin.quick-action.shuffle-liked"
    case search = "com.welape.yuanyin.quick-action.search"
}

/// 主屏幕快捷菜单:继续播放(写着上次那首)、随机播放全部、随机播放「我喜欢的」、搜索。
///
/// 菜单项每次退到后台时按当下的状态重新登记,没有可续的歌、没有喜欢的歌时不摆对应的项。
/// 点进来时:冷启动的动作跟着场景连接选项到(`PrimuseAppDelegate` 配场景时取出),
/// App 还在后台时由 `PrimuseWindowSceneDelegate` 收到。播放类的直接开播,不必等界面;
/// 搜索要切页,先记在 `pendingSearch` 上,由 ContentView 接手——冷启动时那一刻挂在树上的
/// 可能还只是占位界面。
@MainActor
@Observable
final class HomeScreenQuickActionCenter {
    static let shared = HomeScreenQuickActionCenter()

    private(set) var pendingSearch = false

    private init() {}

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = HomeScreenQuickAction(rawValue: item.type) else { return false }
        plog("Home screen quick action: \(action)")
        switch action {
        case .search:
            pendingSearch = true
        case .resume:
            Task { await Self.resumeRestoredPlayback() }
        case .shuffleLibrary:
            Task { await PrimuseIntentBridge.shared.shuffleLibrary() }
        case .shuffleLiked:
            Task { await Self.shuffleLikedSongs() }
        }
        return true
    }

    func consumeSearchRequest() {
        pendingSearch = false
    }

    func publishShortcutItems() {
        let services = AppServices.shared
        let library = services.musicLibrary
        var items: [UIApplicationShortcutItem] = []
        if let song = services.playerService.currentSong {
            let artist = library.artistDisplayName(for: song) ?? song.artistName ?? ""
            items.append(UIApplicationShortcutItem(
                type: HomeScreenQuickAction.resume.rawValue,
                localizedTitle: String(localized: "Resume Playback"),
                localizedSubtitle: artist.isEmpty ? song.title : "\(song.title) · \(artist)",
                icon: UIApplicationShortcutIcon(systemImageName: "play.fill")
            ))
        }
        if !library.musicSongs.isEmpty {
            items.append(UIApplicationShortcutItem(
                type: HomeScreenQuickAction.shuffleLibrary.rawValue,
                localizedTitle: String(localized: "shuffle_all"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "shuffle")
            ))
        }
        if library.songCount(forPlaylist: MusicLibrary.likedSongsPlaylistID) > 0 {
            items.append(UIApplicationShortcutItem(
                type: HomeScreenQuickAction.shuffleLiked.rawValue,
                localizedTitle: String(localized: "sidebar_liked_songs"),
                localizedSubtitle: String(localized: "shuffle"),
                icon: UIApplicationShortcutIcon(systemImageName: "heart.fill")
            ))
        }
        items.append(UIApplicationShortcutItem(
            type: HomeScreenQuickAction.search.rawValue,
            localizedTitle: String(localized: "search_title"),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass")
        ))
        UIApplication.shared.shortcutItems = items
        let published = items.compactMap { HomeScreenQuickAction(rawValue: $0.type).map { "\($0)" } }
        plog("Home screen quick actions published: \(published.joined(separator: ","))")
    }

    /// 冷启动点进来时,上次的队列还在后台装回来,装好了才有歌可续;等的时间有上限。
    private static func resumeRestoredPlayback() async {
        let services = AppServices.shared
        _ = await services.musicLibrary.whenReady(timeout: .seconds(8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline,
              [.pending, .restoring].contains(services.playerService.playbackSessionRestoreLifecycle.phase) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        _ = await PrimuseIntentBridge.shared.resumePlayback()
    }

    private static func shuffleLikedSongs() async {
        let services = AppServices.shared
        _ = await services.musicLibrary.whenReady(timeout: .seconds(8))
        let queue = services.musicLibrary
            .songs(forPlaylist: MusicLibrary.likedSongsPlaylistID)
            .filteredPlayable()
            .shuffled()
        guard !queue.isEmpty else { return }
        services.playerService.shuffleEnabled = true
        await services.playerService.play(queue: queue, startingAt: 0, caller: "QuickAction")
    }
}

/// 主窗口场景的代理,只为接住 App 已在后台时点的快捷菜单。窗口仍由 SwiftUI 管。
@MainActor
final class PrimuseWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(HomeScreenQuickActionCenter.shared.handle(shortcutItem))
    }
}
#endif
