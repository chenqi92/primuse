#if os(iOS)
import CoreSpotlight
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
            // 冷启动点进来时上次的队列还在装回来,它会先等装好(有上限)再续。
            Task { _ = await PrimuseIntentBridge.shared.resumePlayback() }
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

    private static func shuffleLikedSongs() async {
        let services = AppServices.shared
        _ = await services.musicLibrary.whenReady(timeout: .seconds(8))
        let queue = services.playerService.shufflePlayOrder(
            services.musicLibrary
                .songs(forPlaylist: MusicLibrary.likedSongsPlaylistID)
                .filteredPlayable()
        )
        guard !queue.isEmpty else { return }
        services.playerService.shuffleEnabled = true
        await services.playerService.play(queue: queue, startingAt: 0, caller: "QuickAction")
    }
}

/// Spotlight 里点开的一项、Spotlight 的「在 App 中搜索」，以及从另一台设备接力过来的正在播放。
///
/// 系统可能从三条路送来：SwiftUI 的 `onContinueUserActivity`、场景代理的 `scene(_:continue:)`、
/// 冷启动时场景连接选项里的 `userActivities`，同一次点按也可能两条路都送。#346 里点 Spotlight 的结果
/// 只把 App 打开、不播也不跳，所以每条路都交到这里，同一项几秒内只处理一次。播放不等界面；要切页的
/// 记在 `pendingDestination` 上，由 ContentView 接手——冷启动时那一刻挂在树上的可能还只是占位页。
@MainActor
@Observable
final class SystemActivityRouter {
    static let shared = SystemActivityRouter()
    static let handoffActivityType = "com.welape.yuanyin.nowplaying"

    enum Destination: Equatable {
        case library(LibraryDeepLink)
        case search(String)
    }

    private(set) var pendingDestination: Destination?
    @ObservationIgnored private var handledAt: [String: ContinuousClock.Instant] = [:]
    /// 两条路送同一次点按的间隔：冷启动时 SwiftUI 那条要等首屏挂上才到。
    private static let duplicateWindow: Duration = .seconds(10)

    private init() {}

    /// 认得的活动返回 true；`route` 只用来在诊断日志里分清是哪条路送来的。
    @discardableResult
    func handle(_ activity: NSUserActivity, route: String) -> Bool {
        switch activity.activityType {
        case CSSearchableItemActionType:
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let item = SpotlightIndexService.parse(uniqueIdentifier: identifier) else {
                plog("🔎 Spotlight activity without a known item via \(route)")
                return false
            }
            guard admit("item:\(identifier)", route: route) else { return true }
            plog("🔎 Spotlight open \(identifier.prefix(48)) via \(route)")
            Task { await open(item) }
        case CSQueryContinuationActionType:
            let query = (activity.userInfo?[CSSearchQueryString] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return false }
            showSearch(query, route: route)
        case Self.handoffActivityType:
            guard let request = HandoffRequest(activity.userInfo) else { return false }
            guard admit("handoff:\(request.songID):\(request.snapshotTime)", route: route) else { return true }
            plog("🔁 Handoff continue via \(route)")
            Task { await continueHandoff(request) }
        default:
            return false
        }
        return true
    }

    /// 带着字进搜索页:Spotlight 的「在 App 中搜索」,以及 Siri / 快捷指令的搜索意图。
    func showSearch(_ query: String, route: String) {
        guard admit("query:\(query)", route: route) else { return }
        plog("🔎 Search in app via \(route)")
        pendingDestination = .search(query)
    }

    func consumeDestination() {
        pendingDestination = nil
    }

    private func admit(_ key: String, route: String) -> Bool {
        let now = ContinuousClock.now
        handledAt = handledAt.filter { now - $0.value < Self.duplicateWindow }
        guard handledAt[key] == nil else {
            plog("🔎 Same system activity again via \(route); already handled")
            return false
        }
        handledAt[key] = now
        return true
    }

    /// `song` 直接进队列开播; album / artist / playlist 进资料库推到对应详情页。
    private func open(_ item: SpotlightItem) async {
        let library = AppServices.shared.musicLibrary
        await library.whenReady()
        switch item {
        case .song(let id):
            await playSongWithLibrary(id: id, caller: "Spotlight")
        case .album(let id):
            guard let album = library.visibleAlbum(id: id) else {
                plog("🔎 Spotlight album \(id.prefix(12)) is not in the visible library")
                return
            }
            pendingDestination = .library(.album(album))
        case .artist(let id):
            guard let artist = library.visibleArtist(id: id) else {
                plog("🔎 Spotlight artist \(id.prefix(12)) is not in the visible library")
                return
            }
            pendingDestination = .library(.artist(artist))
        case .playlist(let id):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else {
                plog("🔎 Spotlight playlist \(id.prefix(12)) no longer exists")
                return
            }
            pendingDestination = .library(.playlist(playlist))
        }
    }

    /// 命中歌 + 整库剩下的拼起来当队列，跟 Siri / Shortcuts 同款行为；只交 ID，整库在主线程之外按窗口取。
    private func playSongWithLibrary(id: String, caller: String) async {
        let library = AppServices.shared.musicLibrary
        guard library.visibleSong(id: id) != nil else {
            plog("🔎 \(caller) song \(id.prefix(12)) is not in the visible library")
            return
        }
        var ids = [id]
        ids.reserveCapacity(library.visibleSongs.count)
        for song in library.visibleSongs where song.id != id { ids.append(song.id) }
        await AppServices.shared.playerService.play(queueIDs: ids, startingAt: 0, caller: caller)
    }

    /// 接力过来的播放上下文 (当前歌、队列、播放位置、播放或暂停、shuffle、repeat)。
    private struct HandoffRequest: Sendable {
        let songID: String
        let queueIDs: [String]
        let shuffleEnabled: Bool?
        let repeatMode: RepeatMode?
        let snapshotTime: Double
        let currentTime: Double
        let wasPlaying: Bool

        init?(_ info: [AnyHashable: Any]?) {
            guard let info, let songID = info["songID"] as? String else { return nil }
            self.songID = songID
            queueIDs = (info["queueIDs"] as? [String]) ?? [songID]
            shuffleEnabled = info["shuffleEnabled"] as? Bool
            repeatMode = (info["repeatMode"] as? String).flatMap(RepeatMode.init(rawValue:))
            snapshotTime = (info["snapshotTime"] as? Double) ?? Date().timeIntervalSinceReferenceDate
            currentTime = (info["currentTime"] as? Double) ?? 0
            wasPlaying = (info["isPlaying"] as? Bool) ?? true
        }
    }

    /// 受方库里找不到的歌跳过, 当前歌也找不到时退回整库起播这一首 (跨设备库未同步的常见情况,
    /// 不弹 error 干扰用户)。
    private func continueHandoff(_ request: HandoffRequest) async {
        let library = AppServices.shared.musicLibrary
        let player = AppServices.shared.playerService
        await library.whenReady()
        // 受方 library 现在可能比 publisher 少 (CloudKit 同步未到位 / 不同 source
        // 启用状态),compactMap 后丢失的歌不影响其它歌正常播。
        let resolvedQueue = request.queueIDs.compactMap { library.visibleSong(id: $0) }
        guard !resolvedQueue.isEmpty,
              let songIndex = resolvedQueue.firstIndex(where: { $0.id == request.songID }) else {
            await playSongWithLibrary(id: request.songID, caller: "Handoff")
            return
        }

        let song = resolvedQueue[songIndex]
        if let shuffle = request.shuffleEnabled { player.shuffleEnabled = shuffle }
        if let repeatMode = request.repeatMode { player.repeatMode = repeatMode }
        // 仅当 publisher 当时是播放状态才把"经过时间"加上;暂停态就保留
        // 原 currentTime,用户继续听不会跳过任何内容。
        let elapsed = request.wasPlaying
            ? max(0, Date().timeIntervalSinceReferenceDate - request.snapshotTime)
            : 0
        let resumeTime = request.currentTime + elapsed

        if request.wasPlaying {
            await player.play(queue: resolvedQueue, startingAt: songIndex, caller: "Handoff")
            // play(song:) starts at zero; seek to the publisher's live
            // position only for an explicitly playing Handoff.
            player.seek(to: resumeTime, startPlaying: true)
        } else {
            player.stop()
            player.setQueue(resolvedQueue, startAt: songIndex)
            if let shuffle = request.shuffleEnabled { player.shuffleEnabled = shuffle }
            if let repeatMode = request.repeatMode { player.repeatMode = repeatMode }
            player.stagePausedHandoff(song: song, at: resumeTime)
        }
    }
}

/// 主窗口场景的代理,接住 App 已在后台时点的快捷菜单和 Spotlight 结果。窗口仍由 SwiftUI 管。
@MainActor
final class PrimuseWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(HomeScreenQuickActionCenter.shared.handle(shortcutItem))
    }

    /// SwiftUI 的 `onContinueUserActivity` 也会收到同一次点按，由 `SystemActivityRouter` 去重。
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SystemActivityRouter.shared.handle(userActivity, route: "scene")
    }
}
#endif
