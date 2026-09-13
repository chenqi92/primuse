#if os(iOS)
@preconcurrency import CarPlay
import MediaPlayer
import OSLog
import PrimuseKit
import UIKit

private let carplayLog = Logger(subsystem: "com.welape.yuanyin", category: "CarPlay")

/// 把 CarKit 的非 Sendable completionHandler 安全送进 @MainActor hop。@preconcurrency
/// import 豁免 CarPlay 具名类型, 但不豁免方法参数里函数类型的 region-based "sending"
/// 检查。CarKit 约定完成回调在主线程调用, 我们只在 hop(主线程)内调它, 故 @unchecked 安全。
private struct CarPlaySendableBox<T>: @unchecked Sendable {
    let value: T
}

/// CarPlay allows at most five levels for audio apps. The framework can raise
/// an Objective-C exception before its completion handler reports an error, so
/// callers must make room before issuing the push.
enum CarPlayNavigationStackPolicy {
    static let maximumDepth = 5

    enum Action: Equatable {
        case push
        case replaceTop
        case resetToRoot
    }

    static func action(currentDepth: Int) -> Action {
        if currentDepth > maximumDepth { return .resetToRoot }
        if currentDepth == maximumDepth { return .replaceTop }
        return .push
    }
}

/// A full CarPlay list may contain hundreds of rows, but CarPlay does not
/// expose row-visibility callbacks. Keep the useful first screenfuls rich and
/// leave later rows on lightweight placeholders instead of retaining tens of
/// megabytes of backing bitmaps in both the app and the template host.
enum CarPlayArtworkLoadPolicy {
    static let maximumEagerArtworkCount = 64

    static func shouldLoad(index: Int, budget: Int = maximumEagerArtworkCount) -> Bool {
        index >= 0 && index < max(0, budget)
    }
}

/// Serializes and spaces out CarPlay artwork work. ImageIO decoding on the
/// cooperative pool is off-main, but hundreds of uninterrupted decodes still
/// trip iOS's sustained-CPU watchdog and starve the CarPlay template host.
actor CarPlayArtworkScheduler {
    static let shared = CarPlayArtworkScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []
    private var nextStart = Date.distantPast
    private let minimumCooldown: TimeInterval
    private let maximumCooldown: TimeInterval
    private let dynamicCooldownMultiplier: Double

    init(
        minimumCooldown: TimeInterval = 0.075,
        maximumCooldown: TimeInterval = 0.75,
        dynamicCooldownMultiplier: Double = 1.5
    ) {
        self.minimumCooldown = max(0, minimumCooldown)
        self.maximumCooldown = max(self.minimumCooldown, maximumCooldown)
        self.dynamicCooldownMultiplier = max(0, dynamicCooldownMultiplier)
    }

    func image(_ operation: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        let acquired = await acquire()
        guard acquired, !Task.isCancelled else {
            if acquired { release() }
            return nil
        }
        defer { release() }

        let wait = nextStart.timeIntervalSinceNow
        if wait > 0 {
            do {
                try await Task.sleep(for: .milliseconds(Int64((wait * 1_000).rounded(.up))))
            } catch {
                return nil
            }
        }
        guard !Task.isCancelled else { return nil }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return nil
        default:
            break
        }

        let started = Date()
        let image = await operation()
        let elapsed = Date().timeIntervalSince(started)
        var cooldown = max(minimumCooldown, elapsed * dynamicCooldownMultiplier)
        if ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState == .fair {
            cooldown *= 2
        }
        nextStart = Date().addingTimeInterval(min(maximumCooldown, cooldown))
        return Task.isCancelled ? nil : image
    }

    private func acquire() async -> Bool {
        if !isOccupied {
            isOccupied = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if let waiter = waiters.popLast() {
            waiter.continuation.resume(returning: true)
        } else {
            isOccupied = false
        }
    }
}

/// Keeps CarPlay artwork decode off the main actor, deduplicates repeat rows,
/// and repairs a Jellyfin/Emby JPEG variant that iOS ImageIO cannot decode
/// cleanly (`NULL _blockArray`).
actor CarPlayArtworkDecoder {
    static let shared = CarPlayArtworkDecoder()

    private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    func thumbnail(forSongID songID: String, coverRef: String?, maximumPixelSize: Int = 88) async -> UIImage? {
        let cacheKey = "\(songID):\(coverRef ?? ""): \(maximumPixelSize)" as NSString
        if let cached = thumbnails.object(forKey: cacheKey) {
            return cached
        }
        guard var data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) else {
            return nil
        }

        // Some ffmpeg-generated JPEGs use the same non-1x1 sampling factor
        // for every component (for example Y/Cb/Cr are all 1x2). The stream is
        // recoverable, but iOS 18 ImageIO logs a decode error for it. Detect
        // that header without invoking ImageIO and ask the media server for a
        // PNG representation. If the server is unavailable, leave this one row
        // on its placeholder instead of repeatedly feeding bad data to ImageIO.
        if ArtworkImageCompatibility.hasRedundantJPEGSampling(data) {
            guard let repaired = await Self.fetchPNGVariant(from: coverRef) else {
                return nil
            }
            data = repaired
            await MetadataAssetStore.shared.cacheCover(repaired, forSongID: songID)
        }

        guard data.count <= 16 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: cgImage)
        thumbnails.setObject(
            thumbnail,
            forKey: cacheKey,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return thumbnail
    }

    func thumbnail(forRadioID radioID: String, data: Data) -> UIImage? {
        let key = "radio:\(radioID)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard data.count <= 16 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 88
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: cgImage)
        thumbnails.setObject(thumbnail, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return thumbnail
    }

    private static func fetchPNGVariant(from coverRef: String?) async -> Data? {
        guard let coverRef,
              var components = URLComponents(string: coverRef),
              components.url?.path.localizedCaseInsensitiveContains("/Images/") == true else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("format") == .orderedSame }
        queryItems.append(URLQueryItem(name: "format", value: "png"))
        components.queryItems = queryItems
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            return nil
        }
        return data
    }
}

@MainActor
final class CarPlaySceneDelegate: UIResponder {
    private var interfaceController: CPInterfaceController?

    private var homeTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var radioTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var configuredTabs: [CarPlayMainTab] = []
    private var menuTemplates: [String: CPListTemplate] = [:]

    /// Root tab bar — kept so library refreshes can rebuild only the
    /// currently-selected tab and lazily refresh the others when the user
    /// switches to them.
    private weak var tabBarTemplate: CPTabBarTemplate?

    /// Root tab templates that became stale while a *different* tab was on
    /// screen. We skip rebuilding them on a library change and rebuild them
    /// lazily in `tabBarTemplate(_:didSelectTemplate:)` instead, so a scan
    /// over a large library doesn't re-sort + re-pinyin every tab on every
    /// batch. Tracked by identity because CPListTemplate isn't Hashable.
    private var staleRootTemplates: Set<ObjectIdentifier> = []

    /// Coalesces bursty library mutations (replaceSongs runs in batches and
    /// triggers rebuildVisibleCache repeatedly during a scan/backfill) into
    /// one refresh, so the main actor isn't pegged re-rendering CarPlay rows
    /// faster than anyone could read them.
    private var libraryRefreshTask: Task<Void, Never>?

    /// Currently visible queue page (if any). When the player advances, we
    /// patch its sections in place so the user sees the next track highlighted.
    private weak var openQueueTemplate: CPListTemplate?

    /// In-flight artwork-load tasks, keyed so each removes itself on completion.
    /// Search / drill-down / queue paths append here but don't go through
    /// `refreshRootTemplates` (the only wholesale purge), so without per-task
    /// self-removal finished tasks would accumulate unbounded between rebuilds.
    /// `cancelArtworkTasks()` still cancels the whole batch before a rebuild so
    /// a scan burst can't stack hundreds of live setImage tasks on the main
    /// actor (the CarPlay stutter root cause).
    private var artworkTasks: [UUID: Task<Void, Never>] = [:]
    private let artworkUpdates = CarPlayArtworkUpdates()

    /// 上一次据以重建列表的播放状态。用来判断这次变化是否真的改变了列表内容。
    private var lastPlayerState: CarPlayPlayerState?

    /// Only the newest row selection may finish the asynchronous playback wait
    /// and present the shared Now Playing template. Without this ownership, a
    /// delayed older request can push the template again just after the user
    /// taps Back, making the system button appear unresponsive.
    private var nowPlayingPresentationTask: Task<Void, Never>?
    private var nowPlayingPresentationRequestID: UUID?
    private var isNowPlayingTransitionInFlight = false
    private var navigationTransitionInFlight = false
    private let folderLibraryOwner = UUID()
    private var connectionGeneration = 0
    private var likeChangesObserver: NSObjectProtocol?

    private var layout: CarPlayLayoutConfiguration { CarPlaySettingsStore.shared.configuration }
}

// MARK: - Scene lifecycle

extension CarPlaySceneDelegate: CPTemplateApplicationSceneDelegate {
    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // CarKit 可能在非主线程回调; hop 到主线程再访问 @MainActor 状态,
        // 否则 iOS 26 的 swift_task_isCurrentExecutor 断言会 trap。
        Task { @MainActor [weak self] in
            guard let self else { return }
            carplayLog.notice("📱 CarPlay scene didConnect — beginning template setup")
            // CarPlay can launch the app before the phone creates its services.
            // Install the player's observers before announcing the connection.
            _ = AppServices.shared.playerService
            NotificationCenter.default.post(name: .primuseCarPlaySceneDidConnect, object: nil)
            self.interfaceController = interfaceController
            self.navigationTransitionInFlight = false
            self.isNowPlayingTransitionInFlight = false
            self.connectionGeneration &+= 1
            let generation = self.connectionGeneration
            interfaceController.delegate = self
            CarPlayFolderLibrary.shared.acquire(self.folderLibraryOwner)
            CarPlayEditorCatalog.shared.acquire(self.folderLibraryOwner)
            let library = AppServices.shared.musicLibrary
            guard library.isReady else {
                // Stage 2: 冷启动时资料库还在主线程之外装载。先装一个只读的
                // "正在准备"根模板 —— 每一个真正的标签页都要读库, 这时候建
                // 出来的只会是空列表。Now Playing 模板照常配置, 从 CarPlay
                // 直接恢复播放的路径不受影响。
                carplayLog.notice("📱 library still preparing — installing the loading root template")
                interfaceController.setRootTemplate(
                    Self.makeLibraryPreparingTemplate(),
                    animated: false
                ) { _, _ in }
                self.configureNowPlayingTemplate()
                library.onReady { [weak self] in
                    // 与其它观察者同样的世代守卫: 期间断开 / 重连过就不再改
                    // 这一代的模板。
                    guard let self, self.interfaceController != nil,
                          self.connectionGeneration == generation else { return }
                    self.installRootTabBar(on: interfaceController, generation: generation)
                    // Stage 2b: 观察者到这一刻才注册, 而 `withObservationTracking`
                    // 只会在"下一次"变更时触发。占位根模板挂着的这段时间里, 用户
                    // 完全可能在手机上切了 shuffle / repeat / 喜欢, 或者改了 CarPlay
                    // 布局。根模板本身刚由 `installRootTabBar` 按最新布局重建, 这里
                    // 补一次 Now Playing 按钮的刷新, 再装观察者。
                    self.refreshNowPlayingButtons()
                    self.installConnectionObservers(generation: generation)
                }
                return
            }
            self.installRootTabBar(on: interfaceController, generation: generation)
            self.configureNowPlayingTemplate()
            self.installConnectionObservers(generation: generation)
        }
    }

    /// 真正的根模板: 与历史版本逐行一致, 只是被抽出来供"准备完成"路径复用。
    @MainActor
    private func installRootTabBar(
        on interfaceController: CPInterfaceController,
        generation: Int
    ) {
        let root = makeRootTabBar()
        carplayLog.notice("📱 root tab bar built, setting as root template")
        interfaceController.setRootTemplate(root, animated: false) { [weak self] success, _ in
            Task { @MainActor in
                guard let self, success, self.connectionGeneration == generation,
                      self.layout.opensNowPlayingOnConnect else { return }
                self.showExistingNowPlaying()
            }
        }
    }

    /// 连接期的全部观察者注册。顺序与历史版本一致。
    @MainActor
    private func installConnectionObservers(generation: Int) {
        observeLibraryChanges(generation: generation)
        observePlayerState(generation: generation)
        observeLikeChanges()
        observeLayoutChanges(generation: generation)
        carplayLog.notice("📱 CarPlay scene fully initialized ✅")
    }

    /// 装载期的占位根模板: 一行不可选中的"正在准备资料库"。标题沿用既有的
    /// `library` 本地化键, 行文案是 Stage 2 新增的 `library_preparing`。
    @MainActor
    private static func makeLibraryPreparingTemplate() -> CPListTemplate {
        let item = CPListItem(text: String(localized: "library_preparing"), detailText: nil)
        item.isEnabled = false
        let template = CPListTemplate(
            title: String(localized: "library"),
            sections: [CPListSection(items: [item])]
        )
        return template
    }

    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            carplayLog.notice("📱 CarPlay scene didDisconnect")
            NotificationCenter.default.post(name: .primuseCarPlaySceneDidDisconnect, object: nil)
            CPNowPlayingTemplate.shared.remove(self)
            interfaceController.delegate = nil
            self.interfaceController = nil
            self.connectionGeneration &+= 1
            CarPlayFolderLibrary.shared.release(self.folderLibraryOwner)
            CarPlayEditorCatalog.shared.release(self.folderLibraryOwner)
            self.homeTemplate = nil
            self.libraryTemplate = nil
            self.radioTemplate = nil
            self.playlistsTemplate = nil
            self.tabBarTemplate = nil
            self.configuredTabs = []
            self.menuTemplates = [:]
            self.staleRootTemplates.removeAll()
            self.libraryRefreshTask?.cancel()
            self.libraryRefreshTask = nil
            self.nowPlayingPresentationTask?.cancel()
            self.nowPlayingPresentationTask = nil
            self.nowPlayingPresentationRequestID = nil
            self.isNowPlayingTransitionInFlight = false
            self.navigationTransitionInFlight = false
            self.openQueueTemplate = nil
            self.cancelArtworkTasks()
            self.artworkUpdates.removeAll()
            // 渲染好的封面要跨列表重建活着，只在断开连接时释放。
            CarPlayRenderedArtwork.removeAll()
            self.lastPlayerState = nil
            if let observer = self.likeChangesObserver { NotificationCenter.default.removeObserver(observer) }
            self.likeChangesObserver = nil
        }
    }
}

// MARK: - Navigation lifecycle

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if aTemplate === CPNowPlayingTemplate.shared {
                self.isNowPlayingTransitionInFlight = false
                // Nothing behind the full-screen player is visible. Stop hidden
                // rows from delivering a large batch of setImage calls on the
                // same main actor that must process the system Back button.
                self.cancelArtworkTasks()
                self.markRootTemplatesStale()
                return
            }
            self.refreshVisibleRootTemplateIfStale(aTemplate)
            self.refreshDrillDownTemplates()
        }
    }

    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor [weak self] in
            guard let self, aTemplate === CPNowPlayingTemplate.shared else { return }
            let remainsInStack = self.interfaceController?.templates.contains {
                $0 === CPNowPlayingTemplate.shared
            } ?? false
            guard !remainsInStack else { return }

            // A real pop means the user chose to leave full screen. Invalidate
            // any delayed row-selection waiter so it cannot immediately re-push
            // the shared singleton and visually undo the Back action.
            self.nowPlayingPresentationTask?.cancel()
            self.nowPlayingPresentationTask = nil
            self.nowPlayingPresentationRequestID = nil
            self.isNowPlayingTransitionInFlight = false
            if let visible = self.tabBarTemplate?.selectedTemplate {
                self.refreshVisibleRootTemplateIfStale(visible)
            }
        }
    }
}

// MARK: - Now Playing observer (Up Next + Album/Artist tap)

// Keep the SDK callbacks nonisolated and explicitly hop to the main actor;
// CarPlay may deliver them from a framework-owned executor.
extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard !AppServices.shared.playerService.isLiveRadio else { return }
            self?.pushQueueTemplate()
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let player = AppServices.shared.playerService
            guard !player.isLiveRadio, let song = player.currentSong else { return }
            let library = AppServices.shared.musicLibrary
            // Prefer the album view; fall back to artist if the song has no album.
            if let albumID = song.albumID,
               let album = library.visibleAlbums.first(where: { $0.id == albumID }) {
                self.pushAlbumDetail(album)
            } else if let artistID = song.artistID,
                      let artist = library.visibleArtists.first(where: { $0.id == artistID }) {
                self.pushArtistDetail(artist)
            }
        }
    }
}

// MARK: - Tab selection (lazy refresh of stale tabs)

extension CarPlaySceneDelegate: CPTabBarTemplateDelegate {
    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        Task { @MainActor [weak self] in
            self?.refreshVisibleRootTemplateIfStale(selectedTemplate)
        }
    }
}

// MARK: - Root tab bar + per-tab templates

extension CarPlaySceneDelegate {
    func makeRootTabBar(configuration: CarPlayLayoutConfiguration? = nil) -> CPTabBarTemplate {
        let configuration = configuration ?? layout
        configuredTabs = configuration.visibleTabs(maximumCount: CPTabBarTemplate.maximumTabCount)
        menuTemplates = [:]
        let templates = configuredTabs.map { tab -> CPListTemplate in
            let template = makeMenuTemplate(tab, configuration: configuration)
            menuTemplates[tab.id] = template
            staleRootTemplates.insert(ObjectIdentifier(template))
            return template
        }
        assignRootReferences()
        if let first = templates.first { rebuildRootTemplate(first, configuration: configuration) }
        let tabBar = CPTabBarTemplate(templates: templates)
        tabBar.delegate = self
        tabBarTemplate = tabBar
        return tabBar
    }

    private func makeMenuTemplate(_ tab: CarPlayMainTab, configuration: CarPlayLayoutConfiguration) -> CPListTemplate {
        let template = CPListTemplate(title: tab.displayTitle, sections: [])
        template.tabTitle = tab.displayTitle
        template.tabImage = Self.symbolImage(tab.symbol)
        if tab.kind == .search { template.userInfo = "carplay.search" }
        template.emptyViewTitleVariants = [String(localized: "carplay_no_content")]
        configureNavigation(on: template, configuration: configuration, isTabRoot: true)
        return template
    }

    private func assignRootReferences() {
        func template(_ kind: CarPlayMainTab.Kind) -> CPListTemplate? {
            configuredTabs.first { $0.kind == kind }.flatMap { menuTemplates[$0.id] }
        }
        homeTemplate = template(.home)
        libraryTemplate = template(.library)
        radioTemplate = template(.radio)
        playlistsTemplate = template(.playlists)
    }

    private func updateMenuTemplates() {
        guard let tabBarTemplate else { return }
        let next = layout.visibleTabs(maximumCount: CPTabBarTemplate.maximumTabCount)
        guard next != configuredTabs else { return }
        let selectedID = menuTemplates.first { $0.value === tabBarTemplate.selectedTemplate }?.key
        let previous = Dictionary(uniqueKeysWithValues: configuredTabs.map { ($0.id, $0) })
        var templates: [String: CPListTemplate] = [:]
        for tab in next {
            if let old = previous[tab.id], old.kind == tab.kind, old.content == tab.content,
               let template = menuTemplates[tab.id] {
                template.tabTitle = tab.displayTitle
                templates[tab.id] = template
            } else { templates[tab.id] = makeMenuTemplate(tab, configuration: layout) }
        }
        configuredTabs = next
        menuTemplates = templates
        assignRootReferences()
        staleRootTemplates = Set(templates.values.map(ObjectIdentifier.init))
        tabBarTemplate.updateTemplates(next.compactMap { templates[$0.id] })
        if let selectedID, let selected = templates[selectedID] { tabBarTemplate.select(selected) }
    }

    private func pushSearchTemplate() {
        let template = CPListTemplate(title: String(localized: "recent_searches"), sections: searchSections())
        template.userInfo = "carplay.search"
        safePush(template, label: "Search")
    }

    private func searchSections() -> [CPListSection] {
        let recentQueries = UserDefaults.standard
            .stringArray(forKey: CloudKVSKey.recentSearches) ?? []
        let items = recentQueries.prefix(12).map { query -> CPListItem in
            let item = CPListItem(
                text: query,
                detailText: nil,
                image: CarPlayTemplateImages.placeholder("magnifyingglass", artwork: false)
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushSearchResults(for: query)
                    completion()
                }
            }
            return item
        }

        let sectionItems: [CPListItem]
        if items.isEmpty {
            let empty = CPListItem(
                text: String(localized: "recent_searches"),
                detailText: String(localized: "carplay_search_no_results"),
                image: CarPlayTemplateImages.placeholder("iphone", artwork: false)
            )
            empty.isEnabled = false
            sectionItems = [empty]
        } else {
            sectionItems = items
        }

        return [CPListSection(items: sectionItems)]
    }

    private func pushSearchResults(for query: String) {
        let matches = searchMatches(query)
        let items = matches.enumerated().map { index, song -> CPListItem in
            let item = songItem(
                song,
                queueProvider: { (matches, index) },
                loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: index)
            )
            return item
        }
        let template = CPListTemplate(
            title: query,
            sections: [CPListSection(items: items)]
        )
        template.emptyViewTitleVariants = [String(localized: "carplay_search_no_results")]
        safePush(template, label: "SearchResults")
    }

    private func searchMatches(_ query: String) -> [Song] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let library = AppServices.shared.musicLibrary
        return Array(library.visibleSongs.lazy.filter { song in
            song.title.localizedCaseInsensitiveContains(normalized)
                || library.artistNames(for: song).contains {
                    $0.localizedCaseInsensitiveContains(normalized)
                }
                || (song.albumTitle?.localizedCaseInsensitiveContains(normalized) ?? false)
        }.prefix(100))
    }

    /// Serializes navigation and makes room before the five-level framework
    /// limit. A completion handler alone is insufficient: recent CarPlay builds
    /// can raise `clientExceededHierarchyDepthLimit` before returning an error.
    private func safePush(_ template: CPTemplate, label: String) {
        if let list = template as? CPListTemplate { configureNavigation(on: list) }
        guard let ic = interfaceController else { return }
        guard !navigationTransitionInFlight, !isNowPlayingTransitionInFlight else {
            carplayLog.notice("📱 pushTemplate(\(label, privacy: .public)) ignored while another transition is active")
            return
        }
        navigationTransitionInFlight = true
        switch CarPlayNavigationStackPolicy.action(currentDepth: ic.templates.count) {
        case .push:
            performPush(template, label: label, interfaceController: ic)
        case .replaceTop:
            ic.popTemplate(animated: false) { [weak self] success, error in
                Task { @MainActor in
                    guard let self, self.interfaceController === ic else { return }
                    guard success else {
                        self.finishNavigationTransition(label: label, error: error)
                        return
                    }
                    self.performPush(template, label: label, interfaceController: ic)
                }
            }
        case .resetToRoot:
            ic.popToRootTemplate(animated: false) { [weak self] success, error in
                Task { @MainActor in
                    guard let self, self.interfaceController === ic else { return }
                    guard success else {
                        self.finishNavigationTransition(label: label, error: error)
                        return
                    }
                    self.performPush(template, label: label, interfaceController: ic)
                }
            }
        }
    }

    private func performPush(
        _ template: CPTemplate,
        label: String,
        interfaceController: CPInterfaceController
    ) {
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.interfaceController === interfaceController else { return }
                self.finishNavigationTransition(label: label, error: error)
            }
        }
    }

    private func finishNavigationTransition(label: String, error: Error?) {
        navigationTransitionInFlight = false
        if let error {
            carplayLog.error("📱 navigation(\(label, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeHomeTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_home_title"),
            sections: homeSections()
        )
        template.tabTitle = String(localized: "carplay_home_title")
        template.tabImage = UIImage(systemName: "house")
        configureNavigation(on: template, isTabRoot: true)
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_library_title")]
        template.emptyViewSubtitleVariants = [String(localized: "carplay_empty_library_subtitle")]
        return template
    }

    private func makeRadioTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "radio_title"),
            sections: [radioStationsSection()]
        )
        template.tabTitle = String(localized: "radio_title")
        template.tabImage = UIImage(systemName: "radio.fill")
        template.userInfo = DetailContext.browse(.radio)
        configureNavigation(on: template, isTabRoot: true)
        template.emptyViewTitleVariants = [String(localized: "radio_empty_title")]
        template.emptyViewSubtitleVariants = [String(localized: "radio_empty_description")]
        return template
    }

    private func makePlaylistsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_playlists_title"),
            sections: playlistsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_playlists")
        template.tabImage = UIImage(systemName: "music.note.list")
        configureNavigation(on: template, isTabRoot: true)
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_playlists_title")]
        template.emptyViewSubtitleVariants = [String(localized: "carplay_empty_playlists_subtitle")]
        return template
    }
}

// MARK: - Section builders

extension CarPlaySceneDelegate {
    private func albumsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let albums = Array(library.visibleAlbums
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(500))
        let indexByID = Dictionary(
            albums.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sections = Self.sectionedByIndexLetter(albums, titleKey: \.title) { album in
            let item = CPListItem(text: album.title, detailText: album.artistName, image: CarPlayTemplateImages.placeholder("square.stack"))
            if CarPlayArtworkLoadPolicy.shouldLoad(index: indexByID[album.id] ?? 0) {
                self.loadArtwork(for: album, into: item)
            }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushAlbumDetail(album)
                    completion()
                }
            }
            return item
        }
        return sections
    }

    private func artistsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let artists = Array(library.visibleArtists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(500))
        let sections = Self.sectionedByIndexLetter(artists, titleKey: \.name) { artist in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushArtistDetail(artist)
                    completion()
                }
            }
            return item
        }
        return sections
    }

    private func songsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let songs = Array(library.visibleSongs
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(500))
        // queueProvider closures need a stable index into the whole sorted
        // array even after we group it into letter sections. Use the
        // duplicate-tolerant initializer — Song.id is supposed to be unique
        // but a corrupt scan or sync race shouldn't crash the whole tab.
        let indexByID = Dictionary(
            songs.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sections = Self.sectionedByIndexLetter(songs, titleKey: \.title) { song in
            let index = indexByID[song.id] ?? 0
            return self.songItem(
                song,
                queueProvider: { (songs, index) },
                loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: index)
            )
        }
        return sections
    }

    private func playlistsSections(browseOnly: Bool = false) -> [CPListSection] {
        let playlists = AppServices.shared.musicLibrary.playlists.sorted { $0.updatedAt > $1.updatedAt }
        return collectionSections(Array(playlists.prefix(CPListTemplate.maximumItemCount)).map { playlistEntry($0, browseOnly: browseOnly) },
                                  columns: layout.visualStyle == .wall ? 3 : 2)
    }
}

// MARK: - Adaptive home and collection layouts

extension CarPlaySceneDelegate {
    fileprivate enum BrowseContext: Sendable {
        case songs, albums, artists, playlists, radio
    }

    typealias CollectionArtwork = CarPlayContentArtwork

    struct CollectionEntry: Sendable {
        let title: String
        var subtitle: String? = nil
        var symbol = "music.note"
        var artwork: CollectionArtwork? = nil
        var enabled = true
        let action: @MainActor @Sendable () -> Void
    }

    func configureNavigation(on template: CPListTemplate, configuration: CarPlayLayoutConfiguration? = nil, isTabRoot: Bool = false) {
        let configuration = configuration ?? layout
        let siriPage = template.userInfo as? String == "carplay.siri"
        let searchPage = template.userInfo as? String == "carplay.search"
        var inlineSiri = configuration.siriPresentation == .row
        if #unavailable(iOS 26.0) { inlineSiri = true }
        let siriShortcut = configuration.showsSiri && !inlineSiri && !siriPage
        var buttons: [CPBarButton] = []
        if !isTabRoot {
            if !searchPage {
                buttons.append(CPBarButton(image: Self.symbolImage("magnifyingglass")) { [weak self] _ in self?.pushSearchTemplate() })
            }
            if siriShortcut {
                buttons.append(CPBarButton(image: Self.symbolImage("mic")) { [weak self] _ in self?.pushAssistantTemplate() })
            }
        }
        template.trailingNavigationBarButtons = buttons
        template.assistantCellConfiguration = siriPage || (configuration.showsSiri && inlineSiri) ? CPAssistantCellConfiguration(
            position: .top, visibility: .always, assistantAction: .playMedia
        ) : nil
        if #available(iOS 26.0, *) {
            var actions: [CPGridButton] = []
            if isTabRoot {
                if !searchPage {
                    actions.append(CPGridButton(titleVariants: [String(localized: "search_title")], image: Self.symbolImage("magnifyingglass")) { [weak self] _ in self?.pushSearchTemplate() })
                }
                if siriShortcut {
                    actions.append(CPGridButton(titleVariants: ["Siri"], image: Self.symbolImage("mic")) { [weak self] _ in self?.pushAssistantTemplate() })
                }
            }
            template.headerGridButtons = Array(actions.prefix(CPListTemplate.maximumHeaderGridButtonCount))
        }
    }

    private func pushAssistantTemplate() {
        let template = CPListTemplate(title: "Siri", sections: [])
        template.userInfo = "carplay.siri"
        safePush(template, label: "Siri")
    }

    private func makeLibraryTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "library"), sections: libraryMenuSections())
        template.tabTitle = String(localized: "library")
        template.tabImage = Self.symbolImage("square.stack")
        configureNavigation(on: template, isTabRoot: true)
        return template
    }

    private func libraryMenuSections() -> [CPListSection] {
        let entries: [CollectionEntry] = [
            CollectionEntry(title: String(localized: "library_browse_folder"), symbol: "folder") { [weak self] in
                self?.pushFolderBrowser()
            },
            CollectionEntry(title: String(localized: "carplay_playlists_title"), symbol: "music.note.list") { [weak self] in
                self?.pushBrowse(.playlists, title: String(localized: "carplay_playlists_title"))
            },
            CollectionEntry(title: String(localized: "carplay_songs_title"), symbol: "music.note") { [weak self] in
                self?.pushBrowse(.songs, title: String(localized: "carplay_songs_title"))
            },
            CollectionEntry(title: String(localized: "carplay_albums_title"), symbol: "square.stack") { [weak self] in
                self?.pushBrowse(.albums, title: String(localized: "carplay_albums_title"))
            },
            CollectionEntry(title: String(localized: "carplay_artists_title"), symbol: "music.mic") { [weak self] in
                self?.pushBrowse(.artists, title: String(localized: "carplay_artists_title"))
            },
            CollectionEntry(title: String(localized: "radio_title"), symbol: "radio") { [weak self] in
                guard let self else { return }
                self.safePush(self.makeRadioTemplate(), label: "Radio")
            },
            CollectionEntry(title: String(localized: "recent_searches"), symbol: "clock.arrow.circlepath") { [weak self] in
                self?.pushSearchTemplate()
            }
        ]
        return collectionSections(entries, style: .list)
    }

    private func pushBrowse(_ context: BrowseContext, title: String) {
        let template = CPListTemplate(title: title, sections: browseSections(context))
        template.userInfo = DetailContext.browse(context)
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_library_title")]
        safePush(template, label: "LibraryBrowse")
    }

    private func browseSections(_ context: BrowseContext) -> [CPListSection] {
        switch context {
        case .songs: songsSections()
        case .albums: albumsSections()
        case .artists: artistsSections()
        case .playlists: playlistsSections(browseOnly: true)
        case .radio: [radioStationsSection()]
        }
    }

    private func homeSections() -> [CPListSection] {
        var remainingArtworkBudget = CarPlayArtworkLoadPolicy.maximumEagerArtworkCount
        let sections = CarPlayHomeContent.resolve(layout).flatMap { block in
            let entries = block.items.map(homeEntry)
            let artworkBudget = min(remainingArtworkBudget, entries.count)
            remainingArtworkBudget -= artworkBudget
            return collectionSections(entries,
                                      title: block.configuration.showsTitle ? block.title : nil,
                                      style: block.configuration.style,
                                      columns: CarPlayHomeContent.rowSize(for: block.configuration),
                                      artworkBudget: artworkBudget)
        }
        var navigation = [
            CollectionEntry(title: String(localized: "library_browse_folder"), symbol: "folder") { [weak self] in
                self?.pushFolderBrowser()
            },
            CollectionEntry(title: String(localized: "library"), symbol: "square.stack") { [weak self] in
                guard let self else { return }
                self.safePush(self.makeLibraryTemplate(), label: "Library")
            },
            CollectionEntry(title: String(localized: "carplay_layout_title"),
                            symbol: "rectangle.3.group") { [weak self] in
                self?.pushLayoutPresets()
            }
        ]
        if #unavailable(iOS 26.0) {
            navigation.append(CollectionEntry(title: String(localized: "carplay_search_title"), symbol: "magnifyingglass") { [weak self] in self?.pushSearchTemplate() })
        }
        return sections + collectionSections(navigation, style: .list)
    }

    private func homeEntry(_ item: CarPlayHomeItem) -> CollectionEntry {
        CollectionEntry(title: item.title, subtitle: item.subtitle, symbol: item.symbol,
                        artwork: item.artwork, enabled: item.enabled) { [weak self] in
            self?.activateHomeItem(item)
        }
    }

    func activateHomeItem(_ item: CarPlayHomeItem) {
        let library = AppServices.shared.musicLibrary
        switch item.target {
        case .nowPlaying:
            showExistingNowPlaying()
        case .song(let id, _):
            let songs = CarPlayHomeContent.songs(for: item.target)
            guard let index = songs.firstIndex(where: { $0.id == id }) else {
                presentPlayFailureAlert(songTitle: item.title)
                return
            }
            play(queue: songs, startAt: index)
        case .playlist(let id, let directly):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else {
                presentPlayFailureAlert(songTitle: item.title)
                return
            }
            if directly { playCollection(library.songs(forPlaylist: id), title: playlist.name) }
            else { pushPlaylistDetail(playlist) }
        case .album(let id, let directly):
            guard let album = library.visibleAlbums.first(where: { $0.id == id }) else {
                presentPlayFailureAlert(songTitle: item.title)
                return
            }
            if directly { playCollection(CarPlayHomeContent.songs(for: item.target), title: album.title) }
            else { pushAlbumDetail(album) }
        case .folder(let id, let directly):
            if directly { playCollection(CarPlayHomeContent.songs(for: item.target), title: item.title) }
            else { pushFolderBrowser(nodeID: id) }
        case .radio(let id):
            let stations = AppServices.shared.radioStationsStore.stations
            guard let station = stations.first(where: { $0.id == id }) else {
                presentPlayFailureAlert(songTitle: item.title)
                return
            }
            play(station: station, within: stations)
        case .unavailable:
            break
        }
    }

    private func playlistEntry(_ playlist: Playlist, browseOnly: Bool = false, alwaysPlay: Bool = false) -> CollectionEntry {
        let count = AppServices.shared.musicLibrary.songSummary(forPlaylist: playlist.id).count
        return CollectionEntry(title: playlist.name, subtitle: songCountText(count),
                               symbol: playlist.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list",
                               artwork: .playlist(playlist), enabled: count > 0 || !alwaysPlay) { [weak self] in
            guard let self else { return }
            if alwaysPlay || (!browseOnly && self.layout.playsCollectionsDirectly) {
                let library = AppServices.shared.musicLibrary
                guard library.playlists.contains(where: { $0.id == playlist.id }) else {
                    self.presentPlayFailureAlert(songTitle: playlist.name)
                    return
                }
                self.playCollection(library.songs(forPlaylist: playlist.id), title: playlist.name)
            } else {
                self.pushPlaylistDetail(playlist)
            }
        }
    }

    private func albumEntry(_ album: Album) -> CollectionEntry {
        CollectionEntry(title: album.title, subtitle: album.artistName, symbol: "square.stack", artwork: .album(album)) { [weak self] in
            guard let self else { return }
            if self.layout.playsCollectionsDirectly {
                let songs = AppServices.shared.musicLibrary.songs(forAlbum: album.id)
                    .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
                self.playCollection(songs, title: album.title)
            } else {
                self.pushAlbumDetail(album)
            }
        }
    }

    private func songCountText(_ count: Int) -> String {
        String(format: String(localized: "carplay_playlist_song_count_format"), count)
    }

    private func collectionSections(_ entries: [CollectionEntry], title: String? = nil,
                                    style: CarPlayBrowseStyle? = nil, columns: Int = 6,
                                    artworkBudget: Int = CarPlayArtworkLoadPolicy.maximumEagerArtworkCount) -> [CPListSection] {
        guard !entries.isEmpty else { return [] }
        let entries = Array(entries.prefix(CPListTemplate.maximumItemCount))
        let style = style ?? layout.browseStyle
        if style == .list {
            return [CPListSection(items: entries.enumerated().map { index, entry in
                collectionItem(entry, loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: index, budget: artworkBudget))
            }, header: title, sectionIndexTitle: nil)]
        }
        let rowSize = max(1, min(Int(CPMaximumNumberOfGridImages), columns))
        let rows = stride(from: 0, to: entries.count, by: rowSize).map { offset in
            imageRow(
                Array(entries[offset..<min(offset + rowSize, entries.count)]),
                style: style,
                artworkBudget: max(0, artworkBudget - offset)
            )
        }
        return [CPListSection(items: rows, header: title, sectionIndexTitle: nil)]
    }

    func collectionItem(_ entry: CollectionEntry, loadsArtwork: Bool = true) -> CPListItem {
        let item = CPListItem(text: entry.title, detailText: entry.subtitle, image: CarPlayTemplateImages.placeholder(entry.symbol, scale: artworkScale, artwork: entry.artwork != nil))
        item.isEnabled = entry.enabled
        item.handler = { _, completion in
            let completion = CarPlaySendableBox(value: completion)
            Task { @MainActor in
                entry.action()
                completion.value()
            }
        }
        if loadsArtwork, let artwork = entry.artwork {
            let scale = artworkScale
            loadObservedArtwork(
                artwork,
                pixelSize: Int(CarPlayTemplateImages.listSide * scale),
                owner: item,
                render: { CarPlayTemplateImages.square($0, scale: scale) }
            ) { [weak item] image in
                item?.setImage(image)
            }
        }
        return item
    }

    private var artworkScale: CGFloat { max(1, interfaceController?.carTraitCollection.displayScale ?? 2) }

    func imageRow(
        _ entries: [CollectionEntry],
        style: CarPlayBrowseStyle,
        artworkBudget: Int = CarPlayArtworkLoadPolicy.maximumEagerArtworkCount
    ) -> CPListImageRowItem {
        let side = CarPlayTemplateImages.rowSide(for: style)
        let scale = artworkScale
        let placeholders = entries.map { CarPlayTemplateImages.placeholder($0.symbol, side: side, scale: scale) }
        let row: CPListImageRowItem
        if #available(iOS 26.0, *) {
            if style == .capsules {
                let elements = entries.enumerated().map { index, entry in
                    let element = CPListImageRowItemCondensedElement(
                        image: placeholders[index], imageShape: .roundedRectangle,
                        title: entry.title, subtitle: nil, accessorySymbolName: "play.fill"
                    )
                    element.isEnabled = entry.enabled
                    return element
                }
                row = CPListImageRowItem(text: nil, condensedElements: elements, allowsMultipleLines: true)
            } else if style == .cards {
                let elements = entries.enumerated().map { index, entry in
                    let element = CPListImageRowItemCardElement(
                        image: placeholders[index], showsImageFullHeight: false,
                        title: entry.title, subtitle: entry.subtitle, tintColor: nil
                    )
                    element.isEnabled = entry.enabled
                    return element
                }
                row = CPListImageRowItem(text: nil, cardElements: elements, allowsMultipleLines: true)
            } else {
                let elements = entries.enumerated().map { index, entry in
                    let element = CPListImageRowItemRowElement(image: placeholders[index], title: entry.title, subtitle: entry.subtitle)
                    element.isEnabled = entry.enabled
                    return element
                }
                row = CPListImageRowItem(text: nil, elements: elements, allowsMultipleLines: false)
            }
        } else {
            row = CPListImageRowItem(text: "", images: placeholders, imageTitles: entries.map(\.title))
        }
        row.listImageRowHandler = { _, index, completion in
            let completion = CarPlaySendableBox(value: completion)
            Task { @MainActor in
                if entries.indices.contains(index), entries[index].enabled { entries[index].action() }
                completion.value()
            }
        }
        var images = placeholders
        for (index, entry) in entries.enumerated() {
            guard CarPlayArtworkLoadPolicy.shouldLoad(index: index, budget: artworkBudget),
                  let artwork = entry.artwork else { continue }
            loadObservedArtwork(
                artwork,
                pixelSize: Int(side * scale),
                owner: row,
                render: { CarPlayTemplateImages.square($0, side: side, scale: scale) }
            ) { [weak row] image in
                guard let row else { return }
                images[index] = image
                if #available(iOS 26.0, *) {
                    let elements = row.elements
                    guard elements.indices.contains(index) else { return }
                    elements[index].image = images[index]
                    row.elements = elements
                } else { row.update(images) }
            }
        }
        return row
    }

    /// 取行内封面并交给 `apply`。
    ///
    /// `render` 把原图裁成该行需要的方图，结果按封面身份缓存 —— CarPlay 列表
    /// 每次重建都是一批全新的 CPListItem，先挂占位图再异步换真图；命中缓存时
    /// 直接同步塞最终图，中间那一帧占位图就不会出现，也就没有来回闪。
    private func loadObservedArtwork(_ artwork: CarPlayContentArtwork, pixelSize: Int,
                                     owner: AnyObject,
                                     render: @escaping @MainActor (UIImage) -> UIImage,
                                     apply: @escaping @MainActor (UIImage) -> Void) {
        let key = CarPlayArtworkCacheKey.make(
            identity: artwork.cacheIdentity,
            pixelSize: pixelSize,
            overrideRevision: AppServices.shared.musicLibrary.artworkOverrideRevision
        )
        let id = UUID()
        var pendingRefresh = false
        // `force` 用于「这首歌的封面刚落盘」这类通知:那时缓存里可能是上一轮的
        // 空结果，必须真的重取一次；列表重建走的是非 force 路径，直接吃缓存。
        let load: @MainActor (Bool) -> Void = { [weak self, weak owner] force in
            guard let self, owner != nil else { return }
            if !force, let cached = CarPlayRenderedArtwork.image(forKey: key) {
                apply(cached)
                return
            }
            pendingRefresh = true
            guard self.artworkTasks[id] == nil else { return }
            self.artworkTasks[id] = Task { [weak self, weak owner] in
                defer { self?.artworkTasks[id] = nil }
                repeat {
                    pendingRefresh = false
                    let image = await CarPlayArtworkScheduler.shared.image {
                        await CarPlayHomeContent.artwork(artwork, pixelSize: pixelSize)
                    }
                    guard !Task.isCancelled, owner != nil else { return }
                    if let image {
                        let rendered = render(image)
                        CarPlayRenderedArtwork.store(rendered, forKey: key)
                        apply(rendered)
                    }
                } while pendingRefresh
            }
        }
        artworkUpdates.bind(owner: owner, songIDs: CarPlayHomeContent.artworkSongIDs(artwork)) {
            load(true)
        }
        load(false)
    }

    private func playCollection(_ songs: [Song], title: String, shuffled: Bool = false) {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else {
            presentPlayFailureAlert(songTitle: title)
            return
        }
        AppServices.shared.playerService.shuffleEnabled = shuffled
        play(queue: shuffled ? playable.shuffled() : playable, startAt: 0)
    }

    private func showExistingNowPlaying() {
        let player = AppServices.shared.playerService
        guard player.currentSong != nil || player.currentRadioStation != nil else { return }
        pushNowPlayingIfNeeded()
    }

    private func pushLayoutPresets() {
        var entries = CarPlayVisualStyle.allCases.map { style in
            CollectionEntry(title: NSLocalizedString(style.titleKey, comment: ""),
                            symbol: layout.visualStyle == style ? "checkmark.circle.fill" : "rectangle.3.group") { [weak self] in
                CarPlaySettingsStore.shared.configuration.applyVisualStyle(style)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
        }
        entries += CarPlayLayoutPreset.allCases.map { preset in
            CollectionEntry(title: NSLocalizedString(preset.titleKey, comment: ""),
                            symbol: layout.matchingPreset == preset ? "checkmark.circle.fill" : "rectangle.3.group") { [weak self] in
                CarPlaySettingsStore.shared.configuration.apply(preset)
                self?.interfaceController?.popTemplate(animated: true) { [weak self] success, _ in
                    Task { @MainActor in
                        if success, preset == .focus { self?.showExistingNowPlaying() }
                    }
                }
            }
        }
        entries += CarPlaySettingsStore.shared.savedLayouts.map { saved in
            CollectionEntry(title: saved.name,
                            symbol: layout == saved.configuration ? "checkmark.circle.fill" : "rectangle.3.group") { [weak self] in
                CarPlaySettingsStore.shared.configuration = saved.configuration
                self?.interfaceController?.popTemplate(animated: true) { [weak self] success, _ in
                    Task { @MainActor in
                        if success, saved.configuration.opensNowPlayingOnConnect { self?.showExistingNowPlaying() }
                    }
                }
            }
        }
        safePush(CPListTemplate(title: String(localized: "carplay_layout_title"), sections: collectionSections(entries, style: .list)), label: "LayoutPresets")
    }

    private func observeLayoutChanges(generation: Int) {
        withObservationTracking {
            _ = CarPlaySettingsStore.shared.configuration
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.interfaceController != nil, self.connectionGeneration == generation else { return }
                self.updateMenuTemplates()
                self.refreshRootTemplates()
                self.refreshNowPlayingButtons()
                self.observeLayoutChanges(generation: generation)
            }
        }
    }
}

// MARK: - Folder browsing within one navigation level

extension CarPlaySceneDelegate {
    private func pushFolderBrowser(nodeID: LibraryFolderNodeID? = nil) {
        let template = CPListTemplate(title: String(localized: "library_browse_folder"), sections: [])
        updateFolderTemplate(template, nodeID: nodeID)
        safePush(template, label: "Folders")
    }

    private func updateFolderTemplate(_ template: CPListTemplate, nodeID: LibraryFolderNodeID?) {
        let folders = CarPlayFolderLibrary.shared
        let index = folders.index
        template.userInfo = DetailContext.folder(nodeID)
        template.emptyViewTitleVariants = [folders.isLoading ? String(localized: "carplay_loading_folders") : String(localized: "carplay_empty_folders")]
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = folders.isLoading }
        var entries: [CollectionEntry] = []
        if let nodeID {
            let node = index?.node(withID: nodeID)
            entries.append(CollectionEntry(title: String(localized: "carplay_parent_folder"), symbol: "arrow.up") { [weak self, weak template] in
                guard let self, let template else { return }
                self.updateFolderTemplate(template, nodeID: node?.parentID)
            })
            if let node, node.descendantSongCount > 0 {
                let title = HomeDiscoveryText.folderTitle(node)
                entries += [
                    CollectionEntry(title: String(localized: "carplay_play_all"), subtitle: title, symbol: "play.fill") { [weak self] in
                        self?.playCollection(CarPlayFolderLibrary.shared.songs(in: nodeID), title: title)
                    },
                    CollectionEntry(title: String(localized: "carplay_shuffle_all"), symbol: "shuffle") { [weak self] in
                        self?.playCollection(CarPlayFolderLibrary.shared.songs(in: nodeID), title: title, shuffled: true)
                    }
                ]
            }
        }
        let children = nodeID.map { index?.children(of: $0) ?? [] } ?? index?.sourceNodes ?? []
        entries += children.prefix(100).map { node in
            CollectionEntry(title: HomeDiscoveryText.folderTitle(node), subtitle: songCountText(node.descendantSongCount), symbol: "folder") { [weak self, weak template] in
                guard let self, let template else { return }
                self.updateFolderTemplate(template, nodeID: node.id)
            }
        }
        let title = nodeID.flatMap { index?.node(withID: $0) }.map(HomeDiscoveryText.folderTitle)
        var sections = collectionSections(entries, title: title, style: .list)
        if let nodeID {
            let songs = folders.songs(in: nodeID, scope: .direct)
            let items = songs.prefix(100).enumerated().map { index, song in
                songItem(
                    song,
                    queueProvider: { (songs, index) },
                    loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: index)
                )
            }
            if !items.isEmpty { sections.append(CPListSection(items: items)) }
        }
        template.updateSections(sections)
    }
}

// MARK: - Section indexing (A-Z + # bucket, with script-aware transliteration)

extension CarPlaySceneDelegate {
    /// Returns A–Z after transliterating the first character when needed.
    /// This keeps Persian, Arabic, Cyrillic and CJK titles out of a single
    /// catch-all bucket while preserving the compact Latin index required by
    /// the CarPlay list. Characters without a Latin representation use "#".
    nonisolated private static func indexLetter(forFirstCharacter first: Character) -> String {
        if first.isASCII, first.isLetter {
            return String(first).uppercased()
        }
        // `ToLatin` also yields pinyin for CJK while supporting scripts such
        // as Persian/Arabic and Cyrillic that the previous Mandarin-only
        // transform sent to the catch-all bucket.
        let mutable = NSMutableString(string: String(first))
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        for scalar in (mutable as String).unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                return String(scalar).uppercased()
            case 0x02BE, 0x02BF:
                // Hamza/Ayin transliterate to modifier letters without an
                // ASCII base; group their common A-like reading under A.
                return "A"
            default:
                continue
            }
        }
        return "#"
    }

    /// Memoizes the (relatively costly) transliteration keyed by
    /// the title's first character. On a large library every rebuild buckets
    /// up to ~1500 rows; cache hits dominate after the first pass so we avoid
    /// re-running the transform for every "周…" / "陈…" track. Main-actor
    /// isolated, so plain `[Character: String]` is safe without locking.
    @MainActor private static var indexLetterCache: [Character: String] = [:]

    @MainActor static func cachedIndexLetter(for str: String) -> String {
        guard let first = str.first else { return "#" }
        if let hit = indexLetterCache[first] { return hit }
        let letter = indexLetter(forFirstCharacter: first)
        indexLetterCache[first] = letter
        return letter
    }

    @MainActor static func sectionedByIndexLetter<T>(
        _ items: [T],
        titleKey: (T) -> String,
        makeItem: (T) -> CPListItem
    ) -> [CPListSection] {
        let grouped = Dictionary(grouping: items) { cachedIndexLetter(for: titleKey($0)) }
        let sortedKeys = grouped.keys.sorted { a, b in
            // "#" sinks to the bottom of the strip.
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return sortedKeys.map { letter in
            let sectionItems = (grouped[letter] ?? []).map(makeItem)
            return CPListSection(items: sectionItems, header: letter, sectionIndexTitle: letter)
        }
    }
}

// MARK: - Drill-down

extension CarPlaySceneDelegate {
    /// Tag attached to pushed detail templates via `userInfo`. Lets the
    /// library-change handler walk the interface controller's nav stack
    /// and refresh whichever drill-downs are still on screen.
    fileprivate enum DetailContext: Sendable {
        case album(String)   // album.id
        case artist(String)  // artist.id
        case playlist(String) // playlist.id
        case browse(BrowseContext)
        case folder(LibraryFolderNodeID?)
    }

    private func radioStationsSection() -> CPListSection {
        let stations = AppServices.shared.radioStationsStore.stations
        let player = AppServices.shared.playerService
        let items = stations.enumerated().map { index, station -> CPListItem in
            let isCurrent = player.isLiveRadio && player.currentRadioStation?.id == station.id
            let detail = isCurrent
                ? (player.radioMetadataTitle ?? station.playbackSubtitle)
                : station.playbackSubtitle
            let item = CPListItem(
                text: station.name,
                detailText: detail,
                image: CarPlayTemplateImages.placeholder("radio")
            )
            if isCurrent {
                item.isPlaying = player.isPlaying
                item.playingIndicatorLocation = .leading
            }
            if CarPlayArtworkLoadPolicy.shouldLoad(index: index) {
                loadArtwork(for: station, into: item)
            }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.play(station: station, within: stations)
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
    }

    private func pushAlbumDetail(_ album: Album) {
        let template = CPListTemplate(title: album.title, sections: [albumDetailSection(albumID: album.id)])
        template.userInfo = DetailContext.album(album.id)
        safePush(template, label: "AlbumDetail")
    }

    private func pushArtistDetail(_ artist: Artist) {
        let template = CPListTemplate(title: artist.name, sections: [artistDetailSection(artistID: artist.id)])
        template.userInfo = DetailContext.artist(artist.id)
        safePush(template, label: "ArtistDetail")
    }

    private func pushPlaylistDetail(_ playlist: Playlist) {
        let template = CPListTemplate(
            title: playlist.name,
            sections: [playlistDetailSection(playlistID: playlist.id)]
        )
        template.userInfo = DetailContext.playlist(playlist.id)
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_playlist_title")]
        safePush(template, label: "PlaylistDetail")
    }

    private func playlistDetailSection(playlistID: String) -> CPListSection {
        // playlistSongIDs 已经按用户排序保留, 不需要再 sort。
        let songs = AppServices.shared.musicLibrary.songs(forPlaylist: playlistID)
        let items = songs.prefix(max(0, CPListTemplate.maximumItemCount - 2)).enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) }, loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: idx))
        }
        return CPListSection(items: collectionPlaybackItems(songs) + items)
    }

    private func albumDetailSection(albumID: String) -> CPListSection {
        let songs = AppServices.shared.musicLibrary.songs(forAlbum: albumID)
            .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
        let items = songs.prefix(max(0, CPListTemplate.maximumItemCount - 2)).enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) }, loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: idx))
        }
        return CPListSection(items: collectionPlaybackItems(songs) + items)
    }

    private func artistDetailSection(artistID: String) -> CPListSection {
        let songs = AppServices.shared.musicLibrary.songs(forArtist: artistID)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let items = songs.prefix(max(0, CPListTemplate.maximumItemCount - 2)).enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) }, loadsArtwork: CarPlayArtworkLoadPolicy.shouldLoad(index: idx))
        }
        return CPListSection(items: collectionPlaybackItems(songs) + items)
    }

    private func collectionPlaybackItems(_ songs: [Song]) -> [CPListItem] {
        guard !songs.isEmpty else { return [] }
        return [false, true].map { shuffled in
            let title = shuffled ? String(localized: "carplay_shuffle_all") : String(localized: "carplay_play_all")
            return collectionItem(CollectionEntry(title: title, symbol: shuffled ? "shuffle" : "play.fill") { [weak self] in
                self?.playCollection(songs, title: title, shuffled: shuffled)
            })
        }
    }

    /// Hidden pages are refreshed when they appear again; rebuilding them
    /// behind Now Playing would compete with its playback and Back controls.
    fileprivate func refreshDrillDownTemplates() {
        guard let listTemplate = interfaceController?.topTemplate as? CPListTemplate,
              let context = listTemplate.userInfo as? DetailContext else { return }
        switch context {
        case .album(let id):
            listTemplate.updateSections([albumDetailSection(albumID: id)])
        case .artist(let id):
            listTemplate.updateSections([artistDetailSection(artistID: id)])
        case .playlist(let id):
            listTemplate.updateSections([playlistDetailSection(playlistID: id)])
        case .browse(let context):
            listTemplate.updateSections(browseSections(context))
        case .folder(let id):
            updateFolderTemplate(listTemplate, nodeID: id)
        }
    }
}

// MARK: - Item factory + playback

extension CarPlaySceneDelegate {
    private func songItem(
        _ song: Song,
        queueProvider: @escaping () -> ([Song], Int),
        loadsArtwork: Bool = true
    ) -> CPListItem {
        let item = CPListItem(
            text: song.title,
            detailText: AppServices.shared.musicLibrary.artistDisplayName(for: song)
                ?? song.albumTitle,
            image: CarPlayTemplateImages.placeholder("music.note")
        )
        if loadsArtwork { loadArtwork(for: song, into: item) }
        item.handler = { [weak self] _, completion in
            // queueProvider 不访问 @MainActor(只读捕获的 Sendable 值), 在外层调用;
            // 只把 Sendable 结果带进 hop, 避免把非 @Sendable 的 queueProvider 捕获进 Task。
            let (queue, index) = queueProvider()
            Task { @MainActor in
                self?.play(queue: queue, startAt: index)
                completion()
            }
        }
        return item
    }

    private func play(queue: [Song], startAt index: Int) {
        // Validate BEFORE mutating the player. setQueue() with a stale or
        // bogus index would otherwise replace the player's queue and leave
        // currentSong unset — the user would see a blank Now Playing screen
        // with no way back to the song they were actually playing.
        guard queue.indices.contains(index) else { return }
        let originalSong = queue[index]
        // Centralised playable filter — every CarPlay queue (recent /
        // search / songs / album detail / artist detail / Up Next) flows
        // through here. Drop Phase A bare cloud songs so auto-advance
        // can't land on a track the player can't render. The phone-side
        // SongRowView intercepts taps on these, but CarPlay rows have no
        // such guard.
        let filtered = queue.filteredPlayable()
        guard let newIndex = filtered.firstIndex(where: { $0.id == originalSong.id }) else {
            // The tapped row was the bare song itself — surface a clear
            // alert instead of silently doing nothing.
            presentPlayFailureAlert(songTitle: originalSong.title)
            return
        }
        let player = AppServices.shared.playerService
        let song = filtered[newIndex]
        let requestID = UUID()
        nowPlayingPresentationTask?.cancel()
        nowPlayingPresentationRequestID = requestID
        nowPlayingPresentationTask = Task { @MainActor [weak self] in
            await player.play(queue: filtered, startingAt: newIndex)
            // play() returns once setup is kicked off, but actual playback
            // (esp. for cloud sources) may take a few seconds. Poll briefly
            // for the loading-or-playing state, then either push Now Playing
            // or surface an alert. Without this, a 401 / network failure
            // leaves the user staring at a blank Now Playing screen.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard !Task.isCancelled else { return }
                if player.isPlaying || player.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self,
                  !Task.isCancelled,
                  self.nowPlayingPresentationRequestID == requestID else { return }
            if player.isPlaying || player.isLoading {
                if self.layout.opensNowPlayingAfterSelection { self.pushNowPlayingIfNeeded() }
            } else {
                self.presentPlayFailureAlert(songTitle: song.title)
            }
            if self.nowPlayingPresentationRequestID == requestID {
                self.nowPlayingPresentationTask = nil
                self.nowPlayingPresentationRequestID = nil
            }
        }
    }

    private func play(station: RadioStation, within stations: [RadioStation]) {
        let player = AppServices.shared.playerService
        SiriMediaInteractionDonor.donate(station: station)
        let requestID = UUID()
        nowPlayingPresentationTask?.cancel()
        nowPlayingPresentationRequestID = requestID
        nowPlayingPresentationTask = Task { @MainActor [weak self] in
            await player.play(station: station, within: stations)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard !Task.isCancelled else { return }
                if player.isPlaying || player.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self,
                  !Task.isCancelled,
                  self.nowPlayingPresentationRequestID == requestID else { return }
            if player.isPlaying || player.isLoading {
                if self.layout.opensNowPlayingAfterSelection { self.pushNowPlayingIfNeeded() }
            } else {
                self.presentPlayFailureAlert(songTitle: station.name)
            }
            if self.nowPlayingPresentationRequestID == requestID {
                self.nowPlayingPresentationTask = nil
                self.nowPlayingPresentationRequestID = nil
            }
        }
    }

    /// Shows `CPNowPlayingTemplate.shared` without ever inserting the
    /// singleton twice. It can already exist below an Up Next or search page;
    /// checking only `topTemplate` then pushes the same instance again and
    /// CarPlay rejects it. Pop to the existing instance when it is already in
    /// the navigation hierarchy, otherwise push it for the first time.
    private func pushNowPlayingIfNeeded() {
        guard let ic = interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if ic.topTemplate === nowPlaying {
            isNowPlayingTransitionInFlight = false
            navigationTransitionInFlight = false
            carplayLog.notice("📱 NowPlaying already on top, skipping push")
            return
        }
        guard !isNowPlayingTransitionInFlight, !navigationTransitionInFlight else {
            carplayLog.notice("📱 NowPlaying transition already in flight, skipping duplicate")
            return
        }
        isNowPlayingTransitionInFlight = true
        navigationTransitionInFlight = true
        let finish: @MainActor (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            self.isNowPlayingTransitionInFlight = false
            self.finishNavigationTransition(label: "NowPlaying", error: error)
        }
        if ic.templates.contains(where: { $0 === nowPlaying }) {
            ic.pop(to: nowPlaying, animated: true) { [weak self] success, error in
                Task { @MainActor in
                    guard self?.interfaceController === ic else { return }
                    finish(error)
                }
            }
            return
        }

        let push = { [weak self] in
            guard let self, self.interfaceController === ic else { return }
            ic.pushTemplate(nowPlaying, animated: true) { [weak self] _, error in
                Task { @MainActor in
                    guard self?.interfaceController === ic else { return }
                    finish(error)
                }
            }
        }
        if ic.templates.count >= CarPlayNavigationStackPolicy.maximumDepth {
            ic.popToRootTemplate(animated: false) { [weak self] success, error in
                Task { @MainActor in
                    guard self?.interfaceController === ic else { return }
                    guard success else {
                        finish(error)
                        return
                    }
                    push()
                }
            }
        } else {
            push()
        }
    }

    private func presentPlayFailureAlert(songTitle: String) {
        let title = String(format: String(localized: "carplay_play_failed_format"), songTitle)
        let alert = CPAlertTemplate(
            titleVariants: [title],
            actions: [
                CPAlertAction(
                    title: String(localized: "carplay_ok"),
                    style: .default
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    }
                }
            ]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}

// MARK: - Artwork (async, lazily fills CPListItem after creation)

// Each row spawns one Task to fetch its cover. We rely on `weak item`
// for cleanup: when a template is replaced (refresh / drill-down pop),
// its CPListItems get released and the trailing `setImage` becomes a
// no-op. This means the actor hop to MetadataAssetStore is "wasted" for
// stale rows but the cache itself is fast. If profiling on a large
// library shows this dominating, switch to per-item Task tracking with
// explicit cancel on item disposal.
extension CarPlaySceneDelegate {
    private func loadArtwork(for song: Song, into item: CPListItem) {
        let scale = artworkScale
        loadObservedArtwork(
            .song(song),
            pixelSize: Int(CarPlayTemplateImages.listSide * scale),
            owner: item,
            render: { CarPlayTemplateImages.square($0, scale: scale) }
        ) { [weak item] image in
            item?.setImage(image)
        }
    }

    /// Cancels the previous batch of cover-load tasks before a rebuild. A scan /
    /// backfill rebuilds the visible tab repeatedly; without this, each rebuild
    /// spawned a fresh set of per-row setImage tasks while the old ones were
    /// still queued on the main actor, snowballing into the CarPlay stutter.
    private func cancelArtworkTasks() {
        for task in artworkTasks.values { task.cancel() }
        artworkTasks.removeAll()
    }

    private func loadArtwork(for album: Album, into item: CPListItem) {
        let scale = artworkScale
        loadObservedArtwork(
            .album(album),
            pixelSize: Int(CarPlayTemplateImages.listSide * scale),
            owner: item,
            render: { CarPlayTemplateImages.square($0, scale: scale) }
        ) { [weak item] image in
            item?.setImage(image)
        }
    }

    private func loadArtwork(for station: RadioStation, into item: CPListItem) {
        guard let data = station.logoData else { return }
        let id = UUID()
        let task = Task { [weak self, weak item] in
            defer { self?.artworkTasks[id] = nil }
            let image = await CarPlayArtworkScheduler.shared.image {
                await CarPlayArtworkDecoder.shared.thumbnail(forRadioID: station.id, data: data)
            }
            guard !Task.isCancelled, let image, let item else { return }
            item.setImage(CarPlayTemplateImages.square(image, scale: self?.artworkScale ?? 2))
        }
        artworkTasks[id] = task
    }
}

// MARK: - Now Playing template configuration

extension CarPlaySceneDelegate {
    private func configureNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        template.upNextTitle = String(localized: "carplay_up_next")
        template.isUpNextButtonEnabled = true
        template.isAlbumArtistButtonEnabled = true
        template.add(self)
        refreshNowPlayingButtons()
    }

    /// Re-renders the shuffle/repeat/like buttons so their icons reflect the
    /// player's current state. Called on first setup and whenever
    /// shuffleEnabled / repeatMode / currentSong / 喜欢状态 changes.
    private func refreshNowPlayingButtons() {
        let player = AppServices.shared.playerService
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = !player.isLiveRadio
        template.isAlbumArtistButtonEnabled = !player.isLiveRadio && !layout.minimalNowPlaying
        guard !player.isLiveRadio else {
            template.updateNowPlayingButtons([])
            return
        }
        let shuffleIcon = player.shuffleEnabled ? "shuffle.circle.fill" : "shuffle"
        let repeatIcon: String
        switch player.repeatMode {
        case .off: repeatIcon = "repeat"
        case .all: repeatIcon = "repeat.circle.fill"
        case .one: repeatIcon = "repeat.1.circle.fill"
        }
        let shuffleButton = CPNowPlayingImageButton(
            image: Self.symbolImage(shuffleIcon)
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleShuffle()
            }
        }
        let repeatButton = CPNowPlayingImageButton(
            image: Self.symbolImage(repeatIcon)
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cycleRepeat()
            }
        }

        // 直播流不入库,没有"喜欢"可言 —— 上面的 guard 已经挡掉了。
        var buttons = layout.minimalNowPlaying ? [] : [shuffleButton, repeatButton]
        if let songID = player.currentSong?.id, !layout.minimalNowPlaying {
            let liked = AppServices.shared.musicLibrary.isLiked(songID: songID)
            let likeButton = CPNowPlayingImageButton(
                image: Self.symbolImage(liked ? "heart.fill" : "heart")
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.toggleLiked()
                }
            }
            buttons.append(likeButton)
        }
        template.updateNowPlayingButtons(buttons)
    }

    /// Resolves an SF Symbol name to a `UIImage`, returning a 1x1 blank
    /// fallback if the name is wrong. Avoids force-unwrapping inline
    /// (which would crash on a typo) and keeps call sites tidy.
    nonisolated static func symbolImage(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }

    private func toggleShuffle() {
        AppServices.shared.playerService.shuffleEnabled.toggle()
    }

    /// 喜欢当前曲目。改完库以后要立刻重绘按钮 —— `playlistSongIDs` 是
    /// private 的, observePlayerState 观察不到它, 靠通知或这里手动刷新。
    private func toggleLiked() {
        let player = AppServices.shared.playerService
        guard let songID = player.currentSong?.id else { return }
        AppServices.shared.musicLibrary.toggleLiked(songID: songID)
        player.republishNowPlayingSurfaces()
        refreshNowPlayingButtons()
    }

    private func cycleRepeat() {
        let player = AppServices.shared.playerService
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }
}

// MARK: - Up Next (queue) template

extension CarPlaySceneDelegate {
    private func pushQueueTemplate() {
        guard !AppServices.shared.playerService.isLiveRadio else { return }
        let template = CPListTemplate(
            title: String(localized: "carplay_up_next"),
            sections: [queueSection()]
        )
        template.emptyViewTitleVariants = [String(localized: "carplay_queue_empty")]
        openQueueTemplate = template
        safePush(template, label: "Queue")
    }

    private func refreshOpenQueueTemplate() {
        guard let openQueueTemplate else { return }
        openQueueTemplate.updateSections([queueSection()])
    }

    private func queueSection() -> CPListSection {
        let player = AppServices.shared.playerService
        let queue = player.queue
        // Clamp on BOTH ends. `Array.suffix(from:)` requires
        // i ∈ [0, count] — passing a stale currentIndex larger than count
        // (queue replaced before currentIndex caught up) would crash.
        let safeIdx = min(max(0, player.currentIndex), queue.count)
        let upcoming = Array(queue.suffix(from: safeIdx).prefix(CPListTemplate.maximumItemCount))
        let items = upcoming.enumerated().map { offset, song -> CPListItem in
            let item = CPListItem(
                text: song.title,
                detailText: AppServices.shared.musicLibrary.artistDisplayName(for: song)
                    ?? song.albumTitle,
                image: CarPlayTemplateImages.placeholder("music.note")
            )
            if CarPlayArtworkLoadPolicy.shouldLoad(index: offset) {
                loadArtwork(for: song, into: item)
            }
            // First row corresponds to currently-playing track — show indicator.
            if offset == 0 {
                item.isPlaying = true
                item.playingIndicatorLocation = .leading
            }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    // The page was built from a queue snapshot, but observePlayerState()
                    // intentionally doesn't track player.queue — so phone-side
                    // insertNextInQueue/appendToQueue/removeFromQueue changes that
                    // don't move currentIndex won't have refreshed this open page.
                    // Read the live queue at tap time and re-locate the tapped song
                    // by id, so playing a row never replays a stale snapshot (which
                    // would silently drop tracks added on the phone since the page
                    // opened).
                    let live = AppServices.shared.playerService.queue
                    if let liveIndex = live.firstIndex(where: { $0.id == song.id }) {
                        self?.play(queue: live, startAt: liveIndex)
                    } else {
                        // Song no longer in the live queue (removed on the phone) —
                        // play it as a single-item queue rather than doing nothing.
                        self?.play(queue: [song], startAt: 0)
                    }
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
    }
}

// MARK: - Live updates (library + player)

extension CarPlaySceneDelegate {
    /// 心形按钮的状态来自 `MusicLibrary.isLiked`, 底层是 private 的
    /// `playlistSongIDs` —— `withObservationTracking` 看不见它。所以改从
    /// 歌单变更通知走: 在手机上、小组件上点喜欢时, 车机的心也要跟着变。
    private func observeLikeChanges() {
        likeChangesObserver = NotificationCenter.default.addObserver(
            forName: .primusePlaylistsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let ids = note.userInfo?["ids"] as? [String]
            guard ids?.contains(MusicLibrary.likedSongsPlaylistID) ?? true else { return }
            Task { @MainActor [weak self] in
                self?.refreshNowPlayingButtons()
            }
        }
    }

    /// Re-renders the four root list templates whenever the library's
    /// visible collections change. `withObservationTracking` fires once
    /// per change set, so we re-register at the end to keep listening.
    private func observeLibraryChanges(generation: Int) {
        let library = AppServices.shared.musicLibrary
        let radioStore = AppServices.shared.radioStationsStore
        withObservationTracking {
            _ = library.visibleSongs
            _ = library.visibleAlbums
            _ = library.visibleArtists
            _ = library.allPlaylists  // 包含已删除的 — 影响 playlists 计算
            _ = library.playlistCollectionRevision
            _ = library.artworkOverrideRevision
            _ = radioStore.stations
            _ = CarPlayFolderLibrary.shared.index
            _ = CarPlayEditorCatalog.shared.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil, self.connectionGeneration == generation else { return }
                self.scheduleRootTemplateRefresh()
                self.observeLibraryChanges(generation: generation)
            }
        }
    }

    /// Debounces library changes. `replaceSongs` runs in batches during a
    /// scan/backfill and triggers `rebuildVisibleCache` repeatedly; without
    /// coalescing, each batch would re-sort + re-pinyin the tab and respawn
    /// hundreds of cover tasks on the main actor (the same one driving the
    /// phone UI + CarPlay) — the stutter. A 1s window collapses a scan's burst
    /// into one rebuild; CarPlay list freshness isn't time-critical.
    private func scheduleRootTemplateRefresh() {
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled, let self else { return }
            self.refreshRootTemplates()
        }
    }

    /// Tracks player state that affects CarPlay UI: the shuffle/repeat
    /// button icons, and the contents of an open Up Next page.
    /// Intentionally does NOT track `player.queue` directly — observing
    /// the whole array fires on every shuffle/setQueue and we'd thrash.
    /// `currentIndex` + `currentSong?.id` cover the cases that affect UI.
    /// CarPlay 关心的播放状态快照。
    private func currentPlayerState() -> CarPlayPlayerState {
        let player = AppServices.shared.playerService
        return CarPlayPlayerState(
            songID: player.currentSong?.id,
            songTitle: player.currentSong?.title,
            stationID: player.currentRadioStation?.id,
            stationName: player.currentRadioStation?.name,
            isPlaying: player.isPlaying,
            shuffleEnabled: player.shuffleEnabled,
            repeatModeRawValue: String(describing: player.repeatMode),
            currentIndex: player.currentIndex,
            radioMetadataTitle: player.radioMetadataTitle
        )
    }

    private func observePlayerState(generation: Int) {
        let player = AppServices.shared.playerService
        withObservationTracking {
            _ = player.shuffleEnabled
            _ = player.repeatMode
            _ = player.currentSong?.id
            _ = player.currentIndex
            _ = player.isLiveRadio
            _ = player.currentRadioStation?.id
            _ = player.radioMetadataTitle
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil, self.connectionGeneration == generation else { return }
                self.refreshNowPlayingButtons()
                self.refreshOpenQueueTemplate()

                // 播放暂停、随机、循环、队列位置每变一次就重建整张列表，等于把
                // 所有行退回占位图再逐个重取。只有「在放哪一首 / 哪个台」变了才
                // 需要重建 —— 首页那条「正在播放」的副标题和封面取的就是它。
                let state = self.currentPlayerState()
                let rebuildsLists = CarPlayListRefreshPolicy.listsNeedRebuild(
                    from: self.lastPlayerState, to: state
                )
                self.lastPlayerState = state
                if rebuildsLists {
                    self.refreshDrillDownTemplates()
                    if let home = self.homeTemplate {
                        self.staleRootTemplates.insert(ObjectIdentifier(home))
                        if self.interfaceController?.templates.count == 1,
                           self.tabBarTemplate?.selectedTemplate === home {
                            self.scheduleRootTemplateRefresh()
                        }
                    }
                }
                // 电台列表是例外：它要显示正在播放指示和当前曲目名，两者都跟着
                // 播放状态与电台元数据走。
                if let radio = self.radioTemplate,
                   self.interfaceController?.templates.count == 1,
                   self.tabBarTemplate?.selectedTemplate === radio {
                    self.rebuildRootTemplate(radio)
                    self.staleRootTemplates.remove(ObjectIdentifier(radio))
                } else if let radio = self.radioTemplate {
                    self.staleRootTemplates.insert(ObjectIdentifier(radio))
                }
                self.observePlayerState(generation: generation)
            }
        }
    }

    /// Rebuilds only the currently-visible tab (plus any open drill-downs),
    /// and marks the other root tabs stale so they're rebuilt lazily the next
    /// time the user switches to them (see `tabBarTemplate(_:didSelectTemplate:)`).
    /// Rebuilding all 5 tabs eagerly on every change pegs the main actor on a
    /// large library — each tab does a full sort + per-row pinyin transform and
    /// allocates hundreds of CPListItems.
    private func refreshRootTemplates() {
        // Cancel the prior cover-load batch before rebuilding — otherwise a
        // scan firing a refresh every cycle leaves hundreds of orphaned
        // setImage tasks stacked on the main actor (the stutter root cause).
        cancelArtworkTasks()
        let roots = configuredTabs.compactMap { menuTemplates[$0.id] }
        // Identify which tab is on screen. If we can't tell (no tab bar yet),
        // treat "home" as visible — it's the default first tab — so we
        // always rebuild at least one tab now; the rest refresh lazily on
        // selection via the tab-bar delegate.
        let selected = (tabBarTemplate?.selectedTemplate as? CPListTemplate) ?? roots.first
        let rootIsVisible = interfaceController?.templates.count == 1
        for template in roots {
            if rootIsVisible, template === selected {
                rebuildRootTemplate(template)
                staleRootTemplates.remove(ObjectIdentifier(template))
            } else {
                staleRootTemplates.insert(ObjectIdentifier(template))
            }
        }
        refreshDrillDownTemplates()
    }

    private func markRootTemplatesStale() {
        let roots = configuredTabs.compactMap { menuTemplates[$0.id] }
        for template in roots {
            staleRootTemplates.insert(ObjectIdentifier(template))
        }
    }

    /// Refreshes a stale selected tab only after it is actually visible again.
    /// A tab-bar root is represented by the selected child on some head units
    /// and by the tab-bar template itself on others, so accept either callback.
    private func refreshVisibleRootTemplateIfStale(_ appearedTemplate: CPTemplate) {
        let list: CPListTemplate?
        if appearedTemplate === tabBarTemplate {
            list = tabBarTemplate?.selectedTemplate as? CPListTemplate
        } else {
            list = appearedTemplate as? CPListTemplate
        }
        guard let list else { return }
        let key = ObjectIdentifier(list)
        guard staleRootTemplates.contains(key) else { return }
        rebuildRootTemplate(list)
        staleRootTemplates.remove(key)
    }

    private func rebuildRootTemplate(_ template: CPListTemplate, configuration: CarPlayLayoutConfiguration? = nil) {
        guard let tab = configuredTabs.first(where: { menuTemplates[$0.id] === template }) else { return }
        configureNavigation(on: template, configuration: configuration, isTabRoot: true)
        switch tab.kind {
        case .home: template.updateSections(homeSections())
        case .library: template.updateSections(libraryMenuSections())
        case .radio: template.updateSections([radioStationsSection()])
        case .playlists: template.updateSections(playlistsSections())
        case .songs: template.updateSections(songsSections())
        case .albums: template.updateSections(albumsSections())
        case .artists: template.updateSections(artistsSections())
        case .search: template.updateSections(searchSections())
        case .folders:
            if case .folder(let id) = template.userInfo as? DetailContext { updateFolderTemplate(template, nodeID: id) }
            else { updateFolderTemplate(template, nodeID: nil) }
        case .collection:
            guard let content = tab.content else { return }
            switch content.kind {
            case .playlist: template.updateSections([playlistDetailSection(playlistID: content.targetID)])
            case .album: template.updateSections([albumDetailSection(albumID: content.targetID)])
            case .folder:
                if case .folder(let id) = template.userInfo as? DetailContext { updateFolderTemplate(template, nodeID: id) }
                else { updateFolderTemplate(template, nodeID: content.folderID) }
            default: break
            }
        }
        staleRootTemplates.remove(ObjectIdentifier(template))
    }

}

#endif
