#if os(tvOS)
import SwiftUI
import Observation
import CryptoKit
import PrimuseKit

extension Notification.Name {
    static let primuseTVSiriRadioCatalogDidChange = Notification.Name(
        "primuse.tv.siriRadioCatalog.changed"
    )
}

struct TVTrackNavigationAvailability: Equatable, Sendable {
    let canGoPrevious: Bool
    let canGoNext: Bool

    static let unavailable = TVTrackNavigationAvailability(
        canGoPrevious: false,
        canGoNext: false
    )
}

enum TVTrackNavigationAvailabilityPolicy {
    static func availability(
        hasNowPlaying: Bool,
        isLiveRadio: Bool,
        hasCurrentRadioStation: Bool,
        radioStationCount: Int,
        queueCount: Int,
        currentIndex: Int,
        wrapsNext: Bool,
        isQueueItemAvailable: (Int) -> Bool
    ) -> TVTrackNavigationAvailability {
        guard hasNowPlaying else { return .unavailable }
        if isLiveRadio {
            let canChangeStation = hasCurrentRadioStation && radioStationCount > 1
            return TVTrackNavigationAvailability(
                canGoPrevious: canChangeStation,
                canGoNext: canChangeStation
            )
        }

        guard queueCount > 0, (0..<queueCount).contains(currentIndex) else {
            return .unavailable
        }
        let nextIndex = QueueTraversalPolicy.nextAvailableIndex(
            queueCount: queueCount,
            after: currentIndex,
            wraps: wrapsNext,
            isAvailable: isQueueItemAvailable
        )
        // Previous remains actionable at the first item because it restarts
        // the current track, matching TVStore.previous().
        return TVTrackNavigationAvailability(
            canGoPrevious: true,
            canGoNext: nextIndex != nil
        )
    }
}

/// 点选单曲进入播放时的队列排布(纯函数,便于单测):
/// - 未开随机:保持列表原顺序,停在被点选的位置;
/// - 已开随机:被点选的那首排到队首,其余打乱跟随,避免它前面的歌被当成已播过;
/// - 未指定点选曲且开随机:整表打乱后从头播。
enum TVPlaybackQueuePolicy {
    struct Plan: Equatable, Sendable {
        var canonicalIndices: [Int]
        var queueIndex: Int

        static let empty = Plan(canonicalIndices: [], queueIndex: 0)
    }

    nonisolated static func plan(
        count: Int,
        selectedIndex: Int?,
        shuffled: Bool
    ) -> Plan {
        var generator = SystemRandomNumberGenerator()
        return plan(
            count: count,
            selectedIndex: selectedIndex,
            shuffled: shuffled,
            using: &generator
        )
    }

    nonisolated static func plan<G: RandomNumberGenerator>(
        count: Int,
        selectedIndex: Int?,
        shuffled: Bool,
        using generator: inout G
    ) -> Plan {
        guard count > 0 else { return .empty }
        let indices = Array(0..<count)
        let selected = selectedIndex.flatMap { indices.indices.contains($0) ? $0 : nil }
        guard shuffled else {
            return Plan(canonicalIndices: indices, queueIndex: selected ?? 0)
        }
        guard let selected else {
            return Plan(
                canonicalIndices: indices.shuffled(using: &generator),
                queueIndex: 0
            )
        }
        return Plan(
            canonicalIndices: [selected]
                + indices.filter { $0 != selected }.shuffled(using: &generator),
            queueIndex: 0
        )
    }
}

enum TVSourceLocalLibraryCapability: Equatable, Sendable {
    /// Apple TV can authenticate, enumerate the source, and build its own catalogue.
    case directScan
    /// The source can be consumed after a completed library is paired or synced from another device.
    case pairedLibrary
    /// The provider API is not available, so the UI must not present it as usable.
    case unavailable
}

enum TVSourceLocalLibraryPolicy {
    /// 电视端能自己列目录、自己建库的类型。唯一真源:这里加一种,
    /// `TVSourceScanner.makeSingleLister` 必须同时给出对应的列举器。
    static let directScanTypes: Set<MusicSourceType> = [
        .smb, .synology, .qnap, .ugreen, .webdav, .ftp, .sftp, .nfs, .s3, .upnp,
        .jellyfin, .emby, .plex,
        .subsonic, .navidrome, .airsonic, .gonic,
        .fnMusic, .daoliyu, .songloft, .synologyAudioStation,
        .oneDrive, .dropbox, .aliyunDrive, .googleDrive,
        .baiduPan, .pan115, .pan123, .drime, .guangya,
    ]

    static func capability(for type: MusicSourceType) -> TVSourceLocalLibraryCapability {
        if type.isAwaitingPublicAPI { return .unavailable }
        return directScanTypes.contains(type) ? .directScan : .pairedLibrary
    }
}

/// 「重新读取全部标签」的批量进度。逐个源顺序重读,同一时刻只有一个源在扫描。
struct TVRereadAllTagsProgress: Equatable, Sendable {
    /// 第几个源(从 1 开始),用于显示 1/6 这样的计数。
    let index: Int
    let total: Int
    let sourceName: String
}

// MARK: - 轻量 view-model 类型
//
// UI 层数据契约。TVStore 现在由真实 MusicLibrary + SourcesStore 驱动(读取
// 同步下来的 library-cache.json / sources.json);快照为空时回退到样例数据,
// 这样全新安装、还没同步到曲库时 UI 仍可预览。Now Playing / 歌词 / 队列暂用
// 样例(tvOS 播放后续接入)。

struct TVAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    var tint: Color
    var tint2: Color
    let glyph: String
}

struct TVSong: Identifiable, Hashable {
    let id: String
    let albumID: String
    let coverRef: String?
    let title: String
    let artist: String
    let duration: Double
    let format: String
    let bitrate: Int
    let sampleRate: Double
    let sourceID: String
    let displayPath: String?
    let plays: Int
    let liked: Bool
}

struct TVArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let tint: Color
    let tint2: Color
    let glyph: String
    let songCount: Int
}

enum TVPlaylistKind { case normal, smart, liked }

struct TVPlaylistArtworkCandidate: Identifiable, Hashable {
    let id: String
    let kind: PlaylistArtworkCandidate.Kind
    let songID: String
    let coverRef: String?
    let sourceID: String?
}

struct TVPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: TVPlaylistKind
    let count: Int
    let artworkSignature: String
    let artworkCandidates: [TVPlaylistArtworkCandidate]
    static func == (l: TVPlaylist, r: TVPlaylist) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum TVSourceStatus { case connected, scanning, authFailed, disabled }

enum TVSourceInitialScanState: Equatable, Sendable {
    case notRequired
    case pending
    case complete
}

enum TVSourceInitialScanPolicy {
    static func state(
        canScan: Bool,
        lastScannedAt: Date?,
        actualSongCount: Int
    ) -> TVSourceInitialScanState {
        guard canScan else { return .notRequired }
        return lastScannedAt == nil && actualSongCount == 0 ? .pending : .complete
    }
}

enum TVScanAdmissionPolicy {
    static func canStart(activeSourceID: String?, requestedSourceID _: String) -> Bool {
        activeSourceID == nil
    }
}

/// 该源能否在 Apple TV 上直接播放。
enum TVPlayability: Equatable {
    case ok                 // 有可用凭据(或 relay 端点),类型受支持
    case missingCredential  // 类型受支持但缺凭据(不在 bundle、无本地输入、无同步密码)
    case needsRelay         // 手机本机文件 / NFSv4 的 NFS 源需经 iPhone 中继,但中继端点未同步到
    case unsupported        // 类型在 TV 上无 resolver(如 macOS Apple Music 资料库)
}

struct TVSource: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let iconName: String   // 与手机端一致:MusicSourceType.iconName 的 SF Symbol
    let host: String
    let status: TVSourceStatus
    let songs: Int
    let color: Color
    let availabilityNote: String?     // 尚未开放的厂商 API 状态说明
    let playability: TVPlayability   // 能否在 TV 播放(徽标用)
    let canEnterCredential: Bool     // 是否适合在 TV 上手动输入账号密码(服务端登录类源)
    let supports2FA: Bool            // NAS 类:支持两步验证(可在 TV 上输 OTP 申请受信设备)
    let canScan: Bool                // 能否在 TV 上执行本机扫描(SMB 目录或飞牛音乐整库)
    let initialScanState: TVSourceInitialScanState
    var needsInitialScan: Bool { initialScanState == .pending }
    static func == (l: TVSource, r: TVSource) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct TVSyllable: Hashable {
    let w: String
    let start: TimeInterval
    let end: TimeInterval
    let endTiming: LyricSyllableEndTiming

    init(
        w: String,
        start: TimeInterval,
        end: TimeInterval,
        endTiming: LyricSyllableEndTiming = .legacy
    ) {
        self.w = w
        self.start = start
        self.end = end
        self.endTiming = endTiming
    }

    var lyricSyllable: LyricSyllable {
        LyricSyllable(
            text: w,
            start: start,
            end: end,
            endTiming: endTiming
        )
    }
}

struct TVLyricLine: Identifiable, Hashable {
    let id: String
    let time: Double
    let text: String
    let isSynchronized: Bool
    let syllables: [TVSyllable]
    let translation: String
    /// Authored romanization of the line, shown between the sung text and the
    /// translation.
    let romanization: String
    let writingDirection: LyricWritingDirection
    /// Which singer a duet row belongs to.
    let voice: LyricVoice
    /// Backing vocals answering this line. They keep their own time window, so
    /// they are nested rather than placed in the list as rows of their own.
    let background: [TVLyricLine]

    init(
        id: String = UUID().uuidString,
        time: Double,
        text: String,
        isSynchronized: Bool = true,
        syllables: [TVSyllable] = [],
        translation: String = "",
        romanization: String = "",
        writingDirection: LyricWritingDirection = .natural,
        voice: LyricVoice = .primary,
        background: [TVLyricLine] = []
    ) {
        self.id = id
        self.time = time
        self.text = text
        self.isSynchronized = isSynchronized
        self.syllables = syllables
        self.translation = translation
        self.romanization = romanization
        self.writingDirection = writingDirection
        self.voice = voice
        self.background = background
    }
}

struct TVNowPlaying {
    var songID: String
    var coverRef: String?
    var title: String
    var artist: String
    var album: String
    var albumID: String
    var tint: Color
    var tint2: Color
    var glyph: String
    var duration: Double
    var currentTime: Double
    var format: String
    var bitrate: Int
    var sampleRate: Double
    var sourcePath: String
}

/// 一次 Apple TV 同步引导的结果。失败原因必须能落到设置页上的一句话:无账号、
/// 连不上 iCloud、云端还没有快照、本机写不进去在用户那里的处置方式完全不同,
/// 全都显示成「未找到曲库快照」等于什么都没说。
enum TVSyncOutcome: Equatable, Sendable {
    /// 装上了云端快照,本机现在有可浏览的曲库。
    case installed
    /// 快照装上了,但没有一首歌能在 Apple TV 上用 —— 手机侧的本机文件源按设计
    /// 不跨设备同步,这种情况要单独告诉用户,否则看起来就像同步没生效。
    case installedWithoutTransferableSongs
    /// iCloud 账号不可用(未登录 / 受限 / 本次构建拿不到 CloudKit 容器)。
    case accountUnavailable
    /// CloudKit 请求失败:网络不通、超配额,或服务端报错。
    case cloudUnreachable
    /// 连上了,但账号里还没有任何曲库快照。
    case noSnapshot
    /// 本机这一侧装不进去:sources.json 残缺,或上一次导入事务没收尾。
    case localStorageUnavailable
    /// 用户自己关掉了 iCloud 同步总开关,这次什么都没往云端要。
    case syncDisabled

    /// 兼容旧调用点的「这次有没有装上新快照」。
    var didInstall: Bool {
        switch self {
        case .installed, .installedWithoutTransferableSongs: return true
        case .accountUnavailable, .cloudUnreachable, .noSnapshot,
             .localStorageUnavailable, .syncDisabled:
            return false
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class TVStore {
    let library: MusicLibrary
    let sourcesStore: SourcesStore
    private let defaults: UserDefaults
    @ObservationIgnored private let snapshotRecovery: @MainActor () throws -> Bool
    @ObservationIgnored private let scanPersistence: @MainActor @Sendable (MusicLibrary) async -> Result<Void, AppleTVTransferFailure>
    @ObservationIgnored let engine = TVAudioEngine()
    @ObservationIgnored private lazy var coordinator = TVPlaybackCoordinator(store: self, engine: engine)
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var activePlaybackRequestID: UUID?
    @ObservationIgnored private var radioReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var radioReconnectAttempt = 0
    @ObservationIgnored private lazy var radioStore = RadioStationsStore()
    @ObservationIgnored private lazy var serverFeedback = TVServerFeedbackService(
        sourceProvider: { [weak self] id in
            guard let self, !self.locallyRemovedSourceIDs.contains(id),
                  let source = self.sourcesStore.source(id: id), source.isEnabled, !source.isDeleted else { return nil }
            return source
        },
        credentialProvider: { [weak self] source in
            TVCredentialStore.credential(for: source, bundle: self?.credentialBundle)
        },
        currentLikedState: { [weak self] id in self?.library.isLiked(songID: id) ?? false },
        applyLikedState: { [weak self] id, desired in
            self?.library.setLiked(songID: id, isLiked: desired, propagatesServerMutation: false)
        },
        reportError: { [weak self] message in self?.playbackIssue = .failed(message) }
    )
    @ObservationIgnored private lazy var cloudSync = CloudKitSyncService(
        library: library, sourcesStore: sourcesStore,
        radioStationsStore: radioStore, scraperSettingsStore: ScraperSettingsStore()
    )

    init(sourcesStore: SourcesStore? = nil, library: MusicLibrary? = nil,
         defaults: UserDefaults = .standard,
         sessionStore: PlaybackSessionStore = PlaybackSessionStore(),
         snapshotRecovery: (@MainActor () throws -> Bool)? = nil,
         scanPersistence: @escaping @MainActor @Sendable (MusicLibrary) async -> Result<Void, AppleTVTransferFailure> = {
             await $0.persistNowAndWait()
         }) {
        var pendingSnapshotImport = false
        var pendingSnapshotRecovery = false
        let recover = snapshotRecovery ?? { try LibrarySnapshotSync.recoverTVSnapshot() }
        if snapshotRecovery != nil || (sourcesStore == nil && library == nil) {
            do { pendingSnapshotImport = try recover() }
            catch {
                pendingSnapshotRecovery = true
                plog("TV snapshot recovery pending: \(error.localizedDescription)")
            }
        }
        self.sourcesStore = sourcesStore ?? SourcesStore()
        self.library = library ?? MusicLibrary(preferExternalSnapshot: pendingSnapshotImport)
        self.defaults = defaults
        self.snapshotRecovery = recover
        self.scanPersistence = scanPersistence
        self.sessionStore = sessionStore
        hasPendingSnapshotImport = pendingSnapshotImport
        hasPendingSnapshotRecovery = pendingSnapshotRecovery
        locallyRemovedSourceIDs = Set(defaults.stringArray(forKey: "tv.removedSourceIDs") ?? [])
        locallyScannedSourceIDs = Set(defaults.stringArray(forKey: "tv.scannedSourceIDs") ?? [])
        scanner.readingEnvironment = { [weak self] offline in
            .current(playbackActive: self?.isPlaying == true || self?.isLoading == true,
                     offlineSource: offline)
        }
        engine.onEnded = { [weak self] in self?.handlePlaybackEnded() }
        engine.onFailure = { [weak self] message in
            self?.handlePlaybackFailure(message)
        }
        engine.onLiveMetadata = { [weak self] title in
            guard let self, self.isLiveRadio else { return }
            self.radioMetadataTitle = title
            self.nowPlaying.artist = title
            self.playbackIssue = nil
            self.radioReconnectAttempt = 0
        }
        engine.onRemotePlay = { [weak self] in self?.resumePlayback() }
        engine.onRemotePause = { [weak self] in self?.pausePlayback() }
        engine.onRemoteTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        engine.onRemotePreviousTrack = { [weak self] in self?.previous() }
        engine.onRemoteNextTrack = { [weak self] in self?.next() }
        self.library.likedStateMutationHandler = { [weak self] song, previous, desired in
            self?.serverFeedback.setLiked(song: song, previous: previous, desired: desired)
        }
        syncTrackNavigationCommands()
        observeLibraryChanges()
        observeRadioStoreChanges()
        observePlaybackChanges()
        if pendingSnapshotImport || pendingSnapshotRecovery {
            Task { [weak self] in
                _ = await self?.retryPendingSnapshotImport()
            }
        }
        Task { [weak self] in
            await StreamResolverRegistry.shared.setCloudCredentialRefreshHandler {
                [weak self] sourceID, refresh in
                await self?.persistRefreshedCloudCredential(
                    sourceID: sourceID,
                    refresh: refresh
                )
            }
        }
    }

    var hasRealLibrary: Bool {
        _ = libraryContentRevision
        return VisibleLibraryPresencePolicy.hasContent(
            songCount: cachedSongs.count,
            albumCount: cachedAlbums.count
        )
    }

    /// 当前选中的歌曲或电台；未选中时“正在播放”tab 展示空态。
    var nowPlaying: TVNowPlaying = .none
    var hasNowPlaying: Bool = false {
        didSet { syncTrackNavigationCommands() }
    }
    var lyricsRevision = 0
    var lyrics: [TVLyricLine] = [] {
        didSet {
            if oldValue != lyrics { lyricsRevision &+= 1 }
        }
    }
    var queueUpNextIDs: [String] = []
    var playbackIssue: TVPlaybackIssue?   // 解析/播放受阻原因(展示用)
    var radioStations: [RadioStation] = [] {
        didSet {
            rebuildRadioDerivedState()
            syncTrackNavigationCommands()
            NotificationCenter.default.post(name: .primuseTVSiriRadioCatalogDidChange, object: nil)
        }
    }
    /// 以下由 `radioStations` 推出,列表一变整份重建,视图里直接读,不再逐台遍历。
    /// 电台里出现过的文件夹(资料库「电台」的筛选条)。文件夹只能在 iPhone / Mac 上建,电视端只读。
    private(set) var radioFolders: [RadioStationFolderSummary] = []
    private(set) var radioUngroupedCount = 0
    /// 按文件夹比较键分好的电台,未分组的在 "" 下,顺序与 `radioStations` 一致。
    private(set) var radioStationsByFolderKey: [String: [RadioStation]] = [:]
    /// 全部电台的流判重键。搜索结果每一行都要问「加过没有」。
    private var radioStreamIdentityKeys: Set<String> = []
    /// 上一台 / 下一台沿用的顺序(电台 id)。用户自己选台时记下当时电视上的顺序,
    /// 自动切台不刷新它:起播会把刚播的台按最近播放排到最前,拿实时列表找相邻台
    /// 就会在两个台之间来回跳(与 iPhone 的 `radioStationOrder` 同一个做法)。
    @ObservationIgnored private var radioNavigationOrder: [String] = []
    var isLiveRadio = false {
        didSet { syncTrackNavigationCommands() }
    }
    var currentRadioStationID: String? {
        didSet { syncTrackNavigationCommands() }
    }
    var radioMetadataTitle = ""
    var credentialBundle: CredentialBundle?   // 经 iCloud(CloudKit 加密)同步下来 / 局域网直传来的源凭据
    @ObservationIgnored private var cloudCredentialSourceIDs: Set<String> = []
    var sourcesRevision = 0 {   // 源启用/删除后 bump,强制 sources 视图重渲染(嵌套 store 观察传导不稳)
        didSet {
            NotificationCenter.default.post(name: .primuseTVSiriRadioCatalogDidChange, object: nil)
        }
    }

    // 局域网「扫码直传」接收端(绕开 iCloud)。二维码内容随端点就绪更新。
    @ObservationIgnored let configServer = TVConfigServer()
    @ObservationIgnored private var pairingStarted = false
    /// 源页是否在屏幕上。传到一半离开源页时,接收服务要撑到这次传输结束。
    @ObservationIgnored private var pairingPageVisible = false
    @ObservationIgnored private var pairingGeneration = 0
    var pairingQRContent: String = "primuse://add-source"   // 服务未起时退回旧的 iCloud 扫码引导串
    var pairingCode: String = ""
    /// 扫码直传的进度;nil 表示没有进行中的传输。
    private(set) var pairingTransfer: LANReceiveStatus?
    @ObservationIgnored private var pairingTransferClearTask: Task<Void, Never>?
    /// 本次分段会话里可安装封面的缓存名;曲库一变就作废。
    @ObservationIgnored private var lanArtworkEligibleNames: Set<String>?

    // TV 本机扫描(SMB 路径快扫 / 飞牛音乐整库)。视图观察 scanner.phase/indexed/currentFile。
    @ObservationIgnored let scanner = TVSourceScanner()
    private(set) var activeScanSourceID: String?
    /// 批量重读进行中的进度;为 nil 表示没有在批量重读。
    private(set) var rereadAllTagsProgress: TVRereadAllTagsProgress?
    @ObservationIgnored private var rereadAllTagsTask: Task<Void, Never>?
    var transferIsIndexing = false
    var transferScanError: String?
    @ObservationIgnored private var transferScanTask: Task<Void, Never>?
    @ObservationIgnored private var transferNeedsScan = false
    @ObservationIgnored private var transferLyricsStems: Set<String> = []
    @ObservationIgnored private var scanTask: Task<Bool, Never>?
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var pendingScanSongs: [Song] = []
    @ObservationIgnored private var scanExistingIDsByFile: [String: String] = [:]
    @ObservationIgnored private var lastScanFlush = Date.distantPast
    private struct ScanCheckpoint: Codable {
        let connectionIdentity: String
        let roots: [String]
        let state: SourceScanResumeState
    }
    private var isApplyingSnapshot = false
    /// 每次进入 `installSnapshot` 自增。安装的纯计算挪到主 actor 之外后,回到主
    /// actor 的那一段要靠它确认自己仍然是当前这次安装。
    private var installGeneration = 0
    private var hasPendingSnapshotImport = false
    private var hasPendingSnapshotRecovery = false
    private var canMutateLibrary: Bool {
        !isApplyingSnapshot && !hasPendingSnapshotRecovery && sourcesStore.hasCompleteSnapshot
    }
    @ObservationIgnored private var pendingImportTask: Task<Bool, Never>?
    @ObservationIgnored private var syncTask: Task<TVSyncOutcome, Never>?
    private var locallyRemovedSourceIDs: Set<String>
    private var locallyScannedSourceIDs: Set<String>
    private var sourceAuthenticationFailures: Set<String> = []

    // 内网自动发现(Bonjour),与 iOS/macOS 同一实现。
    @ObservationIgnored let discovery = NetworkDiscoveryService()
    /// 过滤掉打印机 / 路由器等噪声(_http/_https 猜成 webdav 的),但保留所有正常文件/NAS 源。
    var discoveredDevices: [DiscoveredDevice] { discovery.devices.filter(Self.isLikelyMusicSource) }
    func startDeviceDiscovery() { discovery.startDiscovery() }
    func stopDeviceDiscovery() { discovery.stopDiscovery() }

    /// 明确的文件/NAS 协议服务一律保留(SMB/WebDAV/FTP/SFTP/NFS/群晖广播);只有 `_http/_https`
    /// 猜出来的(端口 80/443→webdav,常是打印机/路由器/网页)才需要名字或端口佐证才保留。
    nonisolated static func isLikelyMusicSource(_ d: DiscoveredDevice) -> Bool {
        let explicit: Set<String> = [
            "_smb._tcp.", "_webdav._tcp.", "_webdavs._tcp.", "_ftp._tcp.",
            "_sftp-ssh._tcp.", "_nfs._tcp.", "_diskstation._tcp.", "_synology-dsm._tcp.",
        ]
        if explicit.contains(d.serviceType) { return true }
        // _http/_https:名字含 NAS/媒体关键词,或端口是已知媒体/NAS 端口,才认为是源。
        // 飞牛必须明确广播为音乐服务；通用 fnOS 名称或 5666 端口不能证明已安装飞牛音乐。
        let n = d.name.lowercased()
        let keywords = ["synology", "diskstation", "qnap", "ugreen", "fnmusic", "feiniu music", "飞牛音乐", "nas",
                        "jellyfin", "emby", "plex", "navidrome", "subsonic", "airsonic", "truenas"]
        if keywords.contains(where: { n.contains($0) }) { return true }
        let mediaPorts: Set<Int> = [5000, 5001, 8080, 9999, 8096, 32400, 4040, 4533, 4747]
        return mediaPorts.contains(d.port)
    }
    private var queue: [String] = [] {    // 当前队列(真实 Song id)
        didSet { syncTrackNavigationCommands() }
    }
    private var queueIndex = 0 {
        didSet { syncTrackNavigationCommands() }
    }
    private var canonicalQueue: [String] = []
    private var queueCanonicalIndices: [Int] = []
    @ObservationIgnored private var topShelfTask: Task<Void, Never>?
    @ObservationIgnored private var playbackSessionTask: Task<Void, Never>?
    @ObservationIgnored private var playbackMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var radioRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var historyRequestID: UUID?
    @ObservationIgnored private var playbackRecoveryAttempt = 0
    @ObservationIgnored private var playbackRestoreAttempted = false
    @ObservationIgnored private var sessionStore = PlaybackSessionStore()

    // 单条查询索引:song(_:)/album(_:) 命中字典而非全量 map 整库。
    // 在 refreshVisibility()(reload / 改源后)重建,曲库快照变更即失效。
    @ObservationIgnored private var songByID: [String: TVSong] = [:]
    @ObservationIgnored private var albumByID: [String: TVAlbum] = [:]
    @ObservationIgnored private var cachedAlbumIndexByID: [String: Int] = [:]
    @ObservationIgnored private var cachedSongs: [TVSong] = []
    @ObservationIgnored private var cachedSongIDs: [String] = []
    @ObservationIgnored private var cachedAlbums: [TVAlbum] = []
    @ObservationIgnored private var cachedArtists: [TVArtist] = []
    @ObservationIgnored private var cachedNormalPlaylists: [TVPlaylist] = []
    @ObservationIgnored private var cachedSmartPlaylists: [TVPlaylist] = []
    @ObservationIgnored private var smartPlaylistSongIDs: [String: [String]] = [:]
    @ObservationIgnored private var playCountsBySongID: [String: Int] = [:]
    @ObservationIgnored private var normalPlaylistCacheRevision = -1
    @ObservationIgnored private var smartPlaylistCacheRevision = -1
    @ObservationIgnored private var normalPlaylistCollectionRevision = -1
    @ObservationIgnored private var smartPlaylistCollectionRevision = -1
    @ObservationIgnored private var visibleSongCountsBySource: [String: Int] = [:]
    @ObservationIgnored private var artworkPalettes: [String: TVArtworkPalette] = [:]
    private enum ArtworkPaletteInvalidationScope: Hashable {
        case album
        case song
    }
    @ObservationIgnored private var pendingArtworkPaletteInvalidationScopes:
        Set<ArtworkPaletteInvalidationScope> = []
    @ObservationIgnored private var artworkPaletteInvalidationTask: Task<Void, Never>?
    @ObservationIgnored private var recommendationWorker: Task<[Song], Never>?
    @ObservationIgnored private var recommendationWorkerGeneration = 0
    private var libraryContentRevision = 0
    private var albumArtworkPaletteRevision = 0
    private var songArtworkPaletteRevision = 0

    // uploadNow 单飞:串行化改源后的快照上传,避免快速连续切源时
    // 两个 detached 任务交错 delete + save。
    @ObservationIgnored private var pendingUpload: Task<Void, Never>?

    // 播放模式(随机 / 循环)——供正在播放页传输键展示与切换。
    enum RepeatMode { case off, all, one }
    var shuffleEnabled = false
    var repeatMode: RepeatMode = .off {
        didSet { syncTrackNavigationCommands() }
    }
    var isMusicVideoModeEnabled = false
    var sleepTimerMinutes = 0   // 0 = 关闭

    // 有声内容的续播:每一条记住自己听到哪一秒(与 iPhone / Mac 共用 SpokenWordStore)。
    /// 正在播的这条是有声内容。正在播放页据此把上一首 / 下一首换成后退 15 / 前进 30 秒。
    private(set) var currentItemIsSpokenWord = false
    /// 这一条已经真正开始出声:之前时钟报的是解码器起点,写进去会把保存的位置抹掉。
    @ObservationIgnored private var spokenWordPositionArmed = false
    /// 续播目标还没落地(引擎没按起点开播时,开播后再补一次定位)。
    @ObservationIgnored private var pendingSpokenWordResume: (songID: String, position: Double)?
    @ObservationIgnored private var lastSpokenWordPositionSave: Double = 0
    @ObservationIgnored private var sleepWorkItem: DispatchWorkItem?

    /// 当前正在播放的真实 Song id(队列当前位)。
    var currentSongID: String? { queue.indices.contains(queueIndex) ? queue[queueIndex] : nil }
    var queueSongIDs: [String] { queue }

    /// 播放状态镜像自引擎(@Observable 组合,视图读取即订阅引擎变化)。
    var isPlaying: Bool { engine.isPlaying }
    var isLoading: Bool { engine.status == .loading }
    var currentTime: Double { engine.currentTime }
    /// 逐字歌词等按帧推进的绘制要用的播放时钟:在两次时间回调之间按墙上时钟补值。
    /// 直接读 `currentTime` 每秒只有 4 个台阶,扫光会一格一格跳。
    func interpolatedTime(at date: Date = Date()) -> TimeInterval {
        engine.interpolatedTime(at: date)
    }
    var duration: Double { engine.duration > 0 ? engine.duration : nowPlaying.duration }
    var isMusicVideoPlaybackActive: Bool { engine.isVideoMode }
    var currentRadioStation: RadioStation? {
        guard let currentRadioStationID else { return nil }
        return radioStations.first { $0.id == currentRadioStationID }
    }
    var trackNavigationAvailability: TVTrackNavigationAvailability {
        TVTrackNavigationAvailabilityPolicy.availability(
            hasNowPlaying: hasNowPlaying,
            isLiveRadio: isLiveRadio,
            hasCurrentRadioStation: currentRadioStation != nil,
            radioStationCount: radioStations.count,
            queueCount: queue.count,
            currentIndex: queueIndex,
            wrapsNext: repeatMode == .all,
            isQueueItemAvailable: { song(queue[$0]) != nil }
        )
    }
    var nowPlayingPresentationColors: (primary: Color, secondary: Color) {
        isLiveRadio
            ? (TVColor.brand, TVColor.brandSecondary)
            : (nowPlaying.tint, nowPlaying.tint2)
    }
    var canPlayMusicVideo: Bool {
        guard !isLiveRadio else { return false }
        guard let id = currentSongID,
              let song = library.song(id: id),
              song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return true
    }

    // MARK: 浏览数据(全部来自真实曲库;为空即显示空态)

    var albums: [TVAlbum] {
        _ = libraryContentRevision
        _ = albumArtworkPaletteRevision
        return cachedAlbums
    }
    var songs: [TVSong] { _ = libraryContentRevision; return cachedSongs }
    var songIDs: [String] { _ = libraryContentRevision; return cachedSongIDs }
    var artists: [TVArtist] { _ = libraryContentRevision; return cachedArtists }
    var normalPlaylists: [TVPlaylist] {
        _ = libraryContentRevision
        rebuildNormalPlaylistCacheIfNeeded()
        return cachedNormalPlaylists
    }
    var smartPlaylists: [TVPlaylist] {
        _ = libraryContentRevision
        rebuildSmartPlaylistCacheIfNeeded()
        return cachedSmartPlaylists
    }
    var playlists: [TVPlaylist] { normalPlaylists + smartPlaylists }
    var sources: [TVSource] {
        _ = sourcesRevision   // 建立观察依赖:bump 即触发本视图刷新
        return sourcesStore.sources.filter { !locallyRemovedSourceIDs.contains($0.id) }.map { self.map($0) }
    }

    // MARK: 查询

    func album(_ id: String) -> TVAlbum? { albumByID[id] }
    func song(_ id: String) -> TVSong? { songByID[id] }

    func songs(forArtistID id: String) -> [TVSong] {
        let spokenWordIDs = library.spokenWordSongIDs
        return library.songs(forArtist: id).compactMap {
            spokenWordIDs.contains($0.id) ? nil : song($0.id)
        }
    }

    /// 这首是不是有声内容(有声书、评书、讲座)。音乐页面据此把它排除在外。
    func isSpokenWord(songID: String) -> Bool {
        library.spokenWordSongIDs.contains(songID)
    }

    // MARK: 搜索(含歌词级,与 iOS/macOS 共用 LibrarySearchWorker)

    struct TVSearchHit: Identifiable {
        let song: TVSong
        let isLyric: Bool          // 命中的是歌词内容(展示片段)
        let lyricSnippet: String?
        let relatedConcept: String?
        var id: String { song.id }
    }

    @ObservationIgnored private var searchCache = LibrarySearchCache()

    struct TVSearchResults {
        let artists: [TVArtist]
        let albums: [TVAlbum]
        let songs: [TVSearchHit]
    }

    func searchResults(_ query: String, relatedConcepts: [String] = []) async -> TVSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !Task.isCancelled else { return .init(artists: [], albums: [], songs: []) }
        let songSnapshot = library.visibleSongs
        let albumSnapshot = library.visibleAlbums
        let cache = searchCache
        let revision = library.searchRevision
        let worker = Task.detached(priority: .userInitiated) {
            let primary = LibrarySearchWorker.compute(query: q, songs: songSnapshot,
                                                      albums: albumSnapshot, cache: cache)
            var secondary: [(String, LibrarySearchOutput)] = []
            for concept in relatedConcepts.prefix(5) where !Task.isCancelled {
                secondary.append((concept, LibrarySearchWorker.compute(query: concept,
                    songs: songSnapshot, albums: albumSnapshot, cache: primary.cache)))
            }
            return (primary, secondary)
        }
        let (primary, secondary) = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, revision == library.searchRevision else {
            return .init(artists: [], albums: [], songs: [])
        }
        searchCache = primary.cache
        let spokenWordIDs = library.spokenWordSongIDs
        var seen = Set<String>()
        var hits: [TVSearchHit] = []
        for (concept, output) in [(Optional<String>.none, primary)] + secondary.map({ (Optional($0.0), $0.1) }) {
            for hit in output.songResults where hits.count < 24 {
                guard !spokenWordIDs.contains(hit.song.id),
                      seen.insert(hit.song.id).inserted, let song = song(hit.song.id) else { continue }
                hits.append(.init(song: song, isLyric: hit.matchKind == .lyrics,
                                  lyricSnippet: hit.lyricSnippet, relatedConcept: concept))
            }
        }
        return .init(artists: Array(artists.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(12)),
                     albums: primary.albumResults.prefix(12).compactMap { album($0.id) }, songs: hits)
    }

    /// 元数据 + 路径 + 拼音/模糊 + 歌词匹配(歌词数据来自同步过来的缓存)。
    func searchHits(_ query: String) -> (top: TVArtist?, songs: [TVSearchHit]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return (nil, []) }
        let out = LibrarySearchWorker.compute(query: q, songs: library.visibleSongs,
                                              albums: library.visibleAlbums, cache: searchCache)
        searchCache = out.cache
        let spokenWordIDs = library.spokenWordSongIDs
        var hits: [TVSearchHit] = []
        for r in out.songResults where hits.count < 24 {
            guard !spokenWordIDs.contains(r.song.id), let tv = song(r.song.id) else { continue }
            hits.append(TVSearchHit(
                song: tv,
                isLyric: r.matchKind == .lyrics,
                lyricSnippet: r.lyricSnippet,
                relatedConcept: nil
            ))
        }
        let top = artists.first { $0.name.localizedCaseInsensitiveContains(q) }
        return (top, hits)
    }

    func searchHits(
        _ query: String,
        relatedConcepts: [String]
    ) -> (top: TVArtist?, songs: [TVSearchHit]) {
        let primary = searchHits(query)
        var intelligentCandidates: [TVSearchHit] = []

        for concept in relatedConcepts {
            let related = searchHits(concept)
            for hit in related.songs {
                intelligentCandidates.append(TVSearchHit(
                    song: hit.song,
                    isLyric: hit.isLyric,
                    lyricSnippet: hit.lyricSnippet,
                    relatedConcept: concept
                ))
            }
        }

        let composition = LibrarySearchCompositionPolicy.compose(
            primaryResultIDs: primary.songs.map(\.id),
            intelligentResultIDs: intelligentCandidates.map(\.id),
            intelligentAvailable: true,
            supplementLimit: max(0, 24 - primary.songs.count)
        )
        let candidatesByID = Dictionary(
            intelligentCandidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let supplement = composition.intelligentSupplementIDs.compactMap { candidatesByID[$0] }
        return (primary.top, primary.songs + supplement)
    }

    /// 空查询时的建议(艺术家名),与旧逻辑一致。
    func searchSuggestions(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let names = artists.map(\.name)
        let hits = q.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(q) }
        return Array((hits.isEmpty ? names : hits).prefix(5))
    }
    func albumOf(_ song: TVSong) -> TVAlbum? { album(song.albumID) }
    func songs(forAlbum id: String) -> [TVSong] {
        library.songs(forAlbum: id).map { self.map($0) }
    }

    var recentlyPlayed: [TVSong] {
        // 多取一些再滤掉有声内容,听书的记录不挤占「最近播放」的音乐。
        let spokenWordIDs = library.spokenWordSongIDs
        let songs = library.recentlyPlayedSongs(limit: spokenWordIDs.isEmpty ? 12 : 40)
            .filter { !spokenWordIDs.contains($0.id) }
        return songs.prefix(12).map { self.map($0) }
    }
    var recentlyAddedAlbums: [TVAlbum] {
        _ = libraryContentRevision
        _ = albumArtworkPaletteRevision
        return library.recentlyAddedAlbums(limit: 12).map { self.map($0) }
    }
    var recommended: [TVAlbum] {
        _ = libraryContentRevision
        _ = albumArtworkPaletteRevision
        return cachedAlbums.count > 6 ? Array(cachedAlbums.suffix(6)) : cachedAlbums
    }

    var recommendationRevision: Int { libraryContentRevision }
    var artworkPalettePublicationRevisions: (album: Int, song: Int) {
        (albumArtworkPaletteRevision, songArtworkPaletteRevision)
    }

    func recommendationCandidates(limit: Int = 12) async -> [Song] {
        recommendationWorkerGeneration &+= 1
        let generation = recommendationWorkerGeneration
        let previousWorker = recommendationWorker
        recommendationWorker = nil
        previousWorker?.cancel()
        if let previousWorker {
            _ = await previousWorker.value
        }
        guard !Task.isCancelled, generation == recommendationWorkerGeneration else {
            return []
        }

        let input = MusicDiscoveryEngine.recommendationInput(in: library)
        let worker = Task.detached(priority: .utility) {
            MusicDiscoveryEngine.dailyRecommendations(
                from: input,
                limit: limit,
                isCancelled: { Task.isCancelled }
            ).map(\.song)
        }
        recommendationWorker = worker
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        if generation == recommendationWorkerGeneration {
            recommendationWorker = nil
        }
        guard !Task.isCancelled, generation == recommendationWorkerGeneration else {
            return []
        }
        let spokenWordIDs = library.spokenWordSongIDs
        return spokenWordIDs.isEmpty ? result : result.filter { !spokenWordIDs.contains($0.id) }
    }

    func isLiked(_ id: String) -> Bool { library.isLiked(songID: id) }
    func toggleLiked(_ id: String) {
        guard canMutateLibrary else {
            playbackIssue = .failed(PMString("ext.tv.persistence.failed"))
            return
        }
        library.toggleLiked(songID: id)
        rebuildLookupCaches()
    }

    // MARK: 真实模型 → TV view-model 映射
    //
    // 真实封面可由快照同步缓存或源端引用载入；按 id 派生的渐变只作为加载中/
    // 无封面时的稳定兜底，标题、艺术家、年份等元数据都来自真实曲库。

    private func map(_ a: Album) -> TVAlbum {
        let fallback = Self.tint(a.id.isEmpty ? a.title : a.id)
        let palette = artworkPalettes[a.id]
        let t1 = palette?.primary.color ?? fallback.0
        let t2 = palette?.secondary.color ?? fallback.1
        return TVAlbum(id: a.id, title: a.title, artist: a.artistName ?? PMString("ext.tv.unknownArtist"),
                       year: a.year ?? 0, tint: t1, tint2: t2, glyph: Self.glyph(a.title))
    }

    /// TVArtworkView 载入真实封面后回写主题色。专辑缓存、查询索引和当前播放态
    /// 一次更新，所有已经使用 album.tint / nowPlaying.tint 的页面会自动重绘。
    func applyArtworkPalette(_ palette: TVArtworkPalette, forAlbumID albumID: String) {
        guard !albumID.isEmpty, artworkPalettes[albumID] != palette else { return }
        artworkPalettes[albumID] = palette
        let primary = palette.primary.color
        let secondary = palette.secondary.color

        var updatedAlbum = false
        if let index = cachedAlbumIndexByID[albumID],
           cachedAlbums.indices.contains(index),
           cachedAlbums[index].id == albumID {
            cachedAlbums[index].tint = primary
            cachedAlbums[index].tint2 = secondary
            albumByID[albumID] = cachedAlbums[index]
            updatedAlbum = true
        }
        if nowPlaying.albumID == albumID {
            nowPlaying.tint = primary
            nowPlaying.tint2 = secondary
            updateAutomaticThemePalette(palette)
        }
        if updatedAlbum { scheduleArtworkPaletteInvalidation(.album) }
    }

    /// 歌曲级真实封面的调色板按 Song.id 独立缓存；播放器和歌曲卡片都
    /// 通过同一 revision 立即重绘。
    /// key 加命名空间，避免极端情况下歌曲 ID 与专辑 ID 相同而串色。
    func applyArtworkPalette(_ palette: TVArtworkPalette, forSongID songID: String) {
        guard !songID.isEmpty else { return }
        let key = Self.songArtworkPaletteKey(songID)
        guard artworkPalettes[key] != palette else { return }
        artworkPalettes[key] = palette
        if nowPlaying.songID == songID {
            nowPlaying.tint = palette.primary.color
            nowPlaying.tint2 = palette.secondary.color
            updateAutomaticThemePalette(palette)
        }
        scheduleArtworkPaletteInvalidation(.song)
    }

    func artworkColors(forSongID songID: String) -> (primary: Color, secondary: Color)? {
        _ = songArtworkPaletteRevision
        guard let palette = artworkPalettes[Self.songArtworkPaletteKey(songID)] else {
            return nil
        }
        return (palette.primary.color, palette.secondary.color)
    }

    /// Artwork resolves independently for every visible card. Coalesce those
    /// completions so a large grid/list cannot rebuild once per decoded image,
    /// and keep album and song observers isolated from one another.
    private func scheduleArtworkPaletteInvalidation(_ scope: ArtworkPaletteInvalidationScope) {
        pendingArtworkPaletteInvalidationScopes.insert(scope)
        guard artworkPaletteInvalidationTask == nil else { return }
        artworkPaletteInvalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            let scopes = pendingArtworkPaletteInvalidationScopes
            pendingArtworkPaletteInvalidationScopes.removeAll(keepingCapacity: true)
            artworkPaletteInvalidationTask = nil
            if scopes.contains(.album) { albumArtworkPaletteRevision &+= 1 }
            if scopes.contains(.song) { songArtworkPaletteRevision &+= 1 }
        }
    }

    private static func songArtworkPaletteKey(_ songID: String) -> String {
        "song:\(songID)"
    }

    private func updateAutomaticThemePalette(_ palette: TVArtworkPalette?) {
        guard let palette else {
            TVThemeState.shared.resetArtworkPalette()
            return
        }
        TVThemeState.shared.setArtworkPalette(
            primaryHex: palette.primary.hex,
            secondaryHex: palette.secondary.hex
        )
    }
    private func map(_ s: Song) -> TVSong {
        TVSong(id: s.id, albumID: s.albumID ?? "", coverRef: s.coverArtFileName, title: s.title,
               artist: library.artistDisplayName(for: s) ?? PMString("ext.tv.unknownArtist"), duration: s.duration,
               format: s.fileFormat.displayName, bitrate: s.bitRate ?? 0,
               sampleRate: Double(s.sampleRate ?? 0) / 1000,
               sourceID: s.sourceID,
               displayPath: SongPathPresentationPolicy.displayPath(
                   filePath: s.filePath,
                   sourceID: s.sourceID,
                   sourceType: sourcesStore.source(id: s.sourceID)?.type
               ),
               plays: playCountsBySongID[s.id] ?? 0,
               liked: library.isLiked(songID: s.id))
    }
    private func map(_ a: Artist) -> TVArtist {
        let (t1, t2) = Self.tint(a.id.isEmpty ? a.name : a.id)
        return TVArtist(id: a.id, name: a.name, tint: t1, tint2: t2,
                        glyph: Self.glyph(a.name), songCount: a.songCount)
    }
    static let playlistArtworkCandidateLimit = 16

    private func mapPlaylist(_ p: Playlist, kind: TVPlaylistKind) -> TVPlaylist {
        let summary = library.playlistBrowseSummary(
            forPlaylist: p.id,
            artworkCandidateLimit: Self.playlistArtworkCandidateLimit
        )
        let plan = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: p,
            songs: summary.artworkCandidates
        )
        let limitedPlanCandidates = Array(plan.candidates.prefix(Self.playlistArtworkCandidateLimit))
        let neededSongIDs = Set(limitedPlanCandidates.compactMap(\.songID))
        let songsByID = Dictionary(
            summary.artworkCandidates.lazy
                .filter { neededSongIDs.contains($0.id) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dedicatedSourceID = MirrorPlaylistSuppressionPolicy
            .key(forPlaylistID: p.id)?
            .sourceID
        let candidates = limitedPlanCandidates.compactMap { candidate -> TVPlaylistArtworkCandidate? in
            switch candidate.kind {
            case .dedicated:
                return TVPlaylistArtworkCandidate(
                    id: candidate.id,
                    kind: .dedicated,
                    songID: "playlist:\(p.id)",
                    coverRef: candidate.artworkReference,
                    sourceID: dedicatedSourceID
                )
            case .song:
                guard let songID = candidate.songID,
                      let song = songsByID[songID] else { return nil }
                return TVPlaylistArtworkCandidate(
                    id: candidate.id,
                    kind: .song,
                    songID: song.id,
                    coverRef: candidate.artworkReference,
                    sourceID: song.sourceID
                )
            }
        }
        return TVPlaylist(
            id: p.id,
            name: p.name,
            kind: kind,
            count: summary.count,
            artworkSignature: "\(library.playlistCollectionRevision):\(p.syncRevision):\(plan.signature)",
            artworkCandidates: candidates
        )
    }
    private func mapSmart(_ sp: SmartPlaylist) -> TVPlaylist {
        let matches = SmartPlaylistEngine.match(sp, in: library, history: .shared)
        smartPlaylistSongIDs[sp.id] = matches.map(\.id)
        return TVPlaylist(id: sp.id, name: sp.name, kind: .smart, count: matches.count,
                          artworkSignature: "smart:\(sp.id):\(libraryContentRevision)",
                          artworkCandidates: matches.prefix(4).map {
            TVPlaylistArtworkCandidate(id: $0.id, kind: .song, songID: $0.id,
                                        coverRef: $0.coverArtFileName, sourceID: $0.sourceID)
        })
    }

    private func rebuildNormalPlaylistCacheIfNeeded() {
        let playlistRevision = library.playlistCollectionRevision
        guard normalPlaylistCacheRevision != libraryContentRevision
                || normalPlaylistCollectionRevision != playlistRevision else {
            return
        }
        let normal = library.playlists.map {
            mapPlaylist(
                $0,
                kind: $0.id == MusicLibrary.likedSongsPlaylistID ? .liked : .normal
            )
        }
        let liked = normal.filter { $0.kind == .liked }
        cachedNormalPlaylists = liked + normal.filter { $0.kind != .liked }
        normalPlaylistCacheRevision = libraryContentRevision
        normalPlaylistCollectionRevision = playlistRevision
    }

    private func rebuildSmartPlaylistCacheIfNeeded() {
        let playlistRevision = library.playlistCollectionRevision
        guard smartPlaylistCacheRevision != libraryContentRevision
                || smartPlaylistCollectionRevision != playlistRevision else {
            return
        }
        cachedSmartPlaylists = library.smartPlaylists.map { self.mapSmart($0) }
        smartPlaylistCacheRevision = libraryContentRevision
        smartPlaylistCollectionRevision = playlistRevision
    }
    private func map(_ s: MusicSource) -> TVSource {
        let cnt = library.songs.lazy.filter { $0.sourceID == s.id }.count
        let (c, _) = Self.tint(s.id)
        let canScan = canScanOnTV(s)
        return TVSource(id: s.id, name: s.name, type: s.type.rawValue,
                         iconName: s.type.iconName,
                         host: s.connectionSummary ?? s.basePath ?? s.type.displayName,
                         status: !s.isEnabled ? .disabled : (activeScanSourceID == s.id ? .scanning
                            : (sourceAuthenticationFailures.contains(s.id) || playability(for: s) == .missingCredential
                               ? .authFailed : .connected)),
                         songs: cnt, color: c,
                         availabilityNote: s.type.isAwaitingPublicAPI ? s.type.subtitle : nil,
                         playability: playability(for: s),
                         canEnterCredential: !s.type.isAwaitingPublicAPI && Self.manualCredentialTypes.contains(s.type),
                         supports2FA: !s.type.isAwaitingPublicAPI && s.type.supports2FA
                            && StreamResolverRegistry.tvSupportedTypes.contains(s.type),
                         canScan: canScan,
                         initialScanState: TVSourceInitialScanPolicy.state(
                            canScan: canScan,
                            lastScannedAt: s.lastScannedAt,
                            actualSongCount: cnt
                         ))
    }

    /// NAS 两步验证:用一次性验证码登录,成功则把申请到的「受信设备」令牌(deviceId)存进源,
    /// 之后该设备登录即可跳过 OTP。返回 nil 表示成功,否则返回错误文案。
    func login2FA(sourceID: String, otp: String) async -> String? {
        guard canMutateLibrary else { return PMString("ext.tv.persistence.failed") }
        guard let source = sourcesStore.source(id: sourceID) else { return PMString("ext.tv.test.sourceNotFound") }
        let cred = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        do {
            let did = try await StreamResolverRegistry.shared.loginForDeviceToken(
                source: source, credential: cred, otp: otp)
            // 登录是一次网络往返,这期间后台同步或扫描可能改过这条源的 `modifiedAt`、
            // `songCount` 之类与验证无关的字段。`MusicSource` 的相等是全字段合成的,
            // 拿整个结构体比会把这类无关改动当成「源变了」,于是一次成功的验证被报成
            // 失败。真正要确认的只是这条源还在 —— 后面写 deviceId 本来就是按 id 持久化的。
            guard canMutateLibrary, !Task.isCancelled,
                  sourcesStore.source(id: sourceID) != nil else { return PMString("ext.tv.persistence.failed") }
            guard let did, !did.isEmpty else { return PMString("ext.tv.otp.failed") }
            do {
                guard try sourcesStore.updateLocalDurably(sourceID, mutate: { $0.deviceId = did }) else {
                    return PMString("ext.tv.persistence.failed")
                }
            } catch {
                return PMString("ext.tv.persistence.failed")
            }
            await StreamResolverRegistry.shared.invalidateSession(for: source)
            sourcesRevision += 1
            enqueueSnapshotUpload()
            return nil
        } catch let e as StreamResolveError {
            switch e {
            case .needs2FA: return PMString("ext.tv.otp.invalid")
            case .missingCredential: return PMString("ext.tv.otp.missingCredential")
            case .authFailed: return PMString("ext.tv.otp.authFailed")
            default: return PMString("ext.tv.otp.failed")
            }
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - TV 可播放性判断 + 手动凭据

    /// 用「服务端账号 + 密码」登录、且能在 TV 直连的源类型 —— 适合在 TV 上手动输入凭据。
    /// 云盘(OAuth)、relay 类(凭据在 iPhone 侧)、原生库源不在此列。
    private static let manualCredentialTypes: Set<MusicSourceType> = [
        .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu, .songloft,
        .synology, .synologyAudioStation, .qnap, .ugreen,
        .jellyfin, .emby, .plex,
    ]

    /// 判断一个源能否在 Apple TV 上播放(注册表支持类型 + 凭据/中继可用性)。
    /// 在 TV 上本机直连播放(不经 iPhone 中继)的协议类型。与 TVPlaybackCoordinator.makeDirectReader 对应。
    static let directProtocolTypes: Set<MusicSourceType> = [.smb, .nfs, .ftp, .sftp]
    private static var tvScannableTypes: Set<MusicSourceType> {
        TVSourceLocalLibraryPolicy.directScanTypes
    }

    private func playability(for s: MusicSource) -> TVPlayability {
        if TVLocalTransferSource.isOwned(s) { return .ok }
        let type = s.type
        // 厂商尚未提供可依赖的公开 API；保留同步记录和 UI 状态，但不宣称可播放。
        if type.isAwaitingPublicAPI { return .unsupported }
        // TV 本机 NFS reader 目前只实现 v3。显式 v4 仍可经 iPhone relay
        // 播放，但不能标记成无需中继的本机直连。
        if type == .nfs, !(s.nfsVersion ?? .auto).canStartWithV3OnlyBackend {
            return credentialBundle?.relay != nil ? .ok : .needsRelay
        }
        // 协议直连(SMB/NFS/FTP):TV 本机直读,无需中继 → 可直接播放。
        if Self.directProtocolTypes.contains(type) {
            return type == .nfs || s.authType == .none || hasUsableCredential(for: s)
                ? .ok : .missingCredential
        }
        // Apple Music:由 MusicKit 的系统播放器直接播,不需要凭据也不经中继。
        // 真正能不能出声取决于授权与订阅,那要到起播时才知道,不在这里预判。
        if AppleMusicTVPlaybackPolicy.usesSystemPlayer(sourceType: type, sourceID: s.id) {
            return .ok
        }
        // 其余 relay 类(SFTP/local):能否播放取决于 iPhone 中继端点是否已同步过来。
        if RelayStreamResolver.relayTypes.contains(type) {
            return credentialBundle?.relay != nil ? .ok : .needsRelay
        }
        // 注册表里没有 resolver 的类型(如 macOS Apple Music 资料库)。
        if !StreamResolverRegistry.tvSupportedTypes.contains(type) {
            return .unsupported
        }
        return hasUsableCredential(for: s) ? .ok : .missingCredential
    }

    /// 是否有可用凭据:TV 本地输入 > 同步凭据包条目 > 同步 iCloud 钥匙串密码。
    private func hasUsableCredential(for s: MusicSource) -> Bool {
        if s.authType == .none { return true }
        if s.type.isCloudDrive {
            let credential = TVCredentialStore.credential(for: s, bundle: credentialBundle)
            if credential.token?.isEmpty == false { return true }
            if s.type == .pan123 {
                return credential.clientID?.isEmpty == false
                    && credential.clientSecret?.isEmpty == false
            }
            return credential.refreshToken?.isEmpty == false
                && credential.clientID?.isEmpty == false
        }
        if s.type == .fnMusic || s.type == .daoliyu || s.type == .songloft || s.type == .synologyAudioStation {
            let credential = TVCredentialStore.credential(for: s, bundle: credentialBundle)
            return credential.username?.isEmpty == false && credential.password?.isEmpty == false
        }
        if TVCredentialStore.hasLocalCredential(sourceID: s.id) { return true }
        if let e = credentialBundle?.entries[s.id], !e.isEmpty { return true }
        return TVCredentialStore.hasSyncedPassword(sourceID: s.id)
    }

    /// 手机侧密码有没有同步到这台 TV —— 凭据输入页据此告诉用户该不该拿遥控器手输。
    func syncedCredentialAvailability(sourceID: String) -> SyncedCredentialAvailability {
        SyncedCredentialAvailabilityPolicy.availability(bundle: credentialBundle, sourceID: sourceID)
    }

    /// 当前用于预填输入框的用户名(本地输入 > bundle > 源自带 username)。
    func manualCredentialUsername(sourceID: String) -> String {
        if let local = TVCredentialStore.loadLocalCredential(sourceID: sourceID), !local.username.isEmpty {
            return local.username
        }
        if let u = credentialBundle?.entries[sourceID]?.username, !u.isEmpty { return u }
        return sourcesStore.source(id: sourceID)?.username ?? ""
    }

    /// 保存用户在 TV 上手动输入的账号密码(本地钥匙串),并失效旧会话、刷新徽标。
    @discardableResult
    func saveManualCredential(
        sourceID: String,
        username: String,
        password: String
    ) -> Bool {
        guard canMutateLibrary else { return false }
        guard TVCredentialStore.saveLocalCredential(
            sourceID: sourceID,
            username: username,
            password: password
        ) else { return false }
        cancelScan(sourceID: sourceID)
        serverFeedback.cancel(sourceID: sourceID)
        scanner.invalidateFnMusicClient(sourceID: sourceID)
        sourcesRevision += 1
        if let src = sourcesStore.source(id: sourceID) {
            Task { await StreamResolverRegistry.shared.invalidateSession(for: src) }
        }
        return true
    }

    /// 清除 TV 本地手动输入凭据(回退到同步凭据)。
    func clearManualCredential(sourceID: String) {
        guard canMutateLibrary,
              TVCredentialStore.clearLocalCredential(sourceID: sourceID) else { return }
        cancelScan(sourceID: sourceID)
        serverFeedback.cancel(sourceID: sourceID)
        scanner.invalidateFnMusicClient(sourceID: sourceID)
        sourcesRevision += 1
        if let src = sourcesStore.source(id: sourceID) {
            Task { await StreamResolverRegistry.shared.invalidateSession(for: src) }
        }
    }

    /// 「测试连接」:用当前凭据尝试解析该源的一首歌,返回给用户看的结果文案。
    func testConnection(forSourceID id: String) async -> String {
        guard let source = sourcesStore.source(id: id) else { return PMString("ext.tv.test.sourceNotFound") }
        let credential = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        let result = await testConnection(source: source, credential: credential)
        guard !Task.isCancelled, sourcesStore.source(id: id) == source else { return result }
        if result == PMString("ext.tv.test.authFailed") || result == PMString("ext.tv.test.missingCredential")
            || result == PMString("ext.tv.test.needs2FA") {
            sourceAuthenticationFailures.insert(id)
        } else if result.hasPrefix(PMString("ext.tv.test.connectedPrefix")) {
            sourceAuthenticationFailures.remove(id)
        }
        sourcesRevision &+= 1
        return result
    }

    /// Test an unsaved edit with the form's host, port and credentials. Blank
    /// secret fields intentionally keep the currently stored values.
    func testConnection(
        source: MusicSource,
        password: String?,
        fnConnectAccessCode: String? = nil
    ) async -> String {
        var credential = TVCredentialStore.credential(
            for: source,
            bundle: credentialBundle,
            password: password,
            fnConnectAccessCode: fnConnectAccessCode
        )
        if source.authType == .none {
            credential = SourceCredential()
        } else if let username = source.username, !username.isEmpty {
            credential.username = username
        }
        return await testConnection(source: source, credential: credential)
    }

    private func testConnection(
        source: MusicSource,
        credential cred: SourceCredential
    ) async -> String {
        let id = source.id
        if source.type == .fnMusic {
            do {
                _ = try await scanner.validateFnMusicConnection(source: source, credential: cred)
                return PMString("ext.tv.test.connectedPrefix")
                    + (source.host ?? PMString("ext.tv.test.resolved"))
            } catch let error as FnMusicServiceError {
                switch error {
                case .missingCredential:
                    return PMString("ext.tv.test.missingCredential")
                case .authenticationFailed:
                    return PMString("ext.tv.test.authFailed")
                default:
                    return PMString("ext.tv.test.failedDetail", error.localizedDescription)
                }
            } catch {
                return PMString("ext.tv.test.failedDetail", error.localizedDescription)
            }
        }
        if source.type == .daoliyu {
            do {
                _ = try await scanner.validateDaoLiYuConnection(source: source, credential: cred)
                return PMString("ext.tv.test.connectedPrefix")
                    + (source.host ?? PMString("ext.tv.test.resolved"))
            } catch let error as DaoLiYuServiceError {
                switch error {
                case .missingCredential:
                    return PMString("ext.tv.test.missingCredential")
                case .authenticationFailed:
                    return PMString("ext.tv.test.authFailed")
                default:
                    return PMString("ext.tv.test.failedDetail", error.localizedDescription)
                }
            } catch {
                return PMString("ext.tv.test.failedDetail", error.localizedDescription)
            }
        }
        if source.type == .songloft {
            do {
                _ = try await scanner.validateSongloftConnection(source: source, credential: cred)
                return PMString("ext.tv.test.connectedPrefix")
                    + (source.host ?? PMString("ext.tv.test.resolved"))
            } catch let error as SongloftServiceError {
                switch error {
                case .missingCredential:
                    return PMString("ext.tv.test.missingCredential")
                case .authenticationFailed:
                    return PMString("ext.tv.test.authFailed")
                default:
                    return PMString("ext.tv.test.failedDetail", error.localizedDescription)
                }
            } catch {
                return PMString("ext.tv.test.failedDetail", error.localizedDescription)
            }
        }
        guard let song = library.songs.first(where: { $0.sourceID == id }) else {
            // 曲库里还没有这个源的歌,不代表连不上 —— 刚添加完还没扫描就是这种情况。
            // 凡是电视端自己能列目录的类型,就用真实的一次列举来验证连接,
            // 别再用「暂无歌曲,无法测试」把用户挡回去。
            if let lister = scanner.makeLister(source: source, credential: cred) {
                do {
                    _ = try await lister.list("/")
                    return PMString("ext.tv.test.connectedPrefix")
                        + (source.host ?? PMString("ext.tv.test.resolved"))
                } catch {
                    return TVSourceErrorText.message(error: error)
                }
            }
            return PMString("ext.tv.test.noSongs")
        }
        // 协议直连(SMB/NFS/FTP):测真实字节读取器(与播放同路径),不走中继。
        if let reader = TVPlaybackCoordinator.makeDirectReader(source: source, song: song, credential: cred) {
            do {
                let len = try await reader.contentLength()
                return PMString(
                    "ext.tv.test.directConnected",
                    source.host ?? "",
                    TVFmt.count(Int(len / 1024))
                )
            } catch {
                return TVSourceErrorText.message(error: error)
            }
        }
        do {
            // Draft credentials must not reuse or replace the playback
            // registry's cached session for the saved source.
            let isolatedRegistry = StreamResolverRegistry()
            let resolved = try await isolatedRegistry.resolve(for: song, source: source, credential: cred)
            return PMString("ext.tv.test.connectedPrefix") + (resolved.url.host ?? PMString("ext.tv.test.resolved"))
        } catch let e as StreamResolveError {
            switch e {
            case .unsupportedSourceType(let t):
                return PMString("ext.tv.test.unsupported", t.displayName)
            case .missingCredential:
                return PMString("ext.tv.test.missingCredential")
            case .needs2FA:
                return PMString("ext.tv.test.needs2FA")
            case .authFailed:
                return PMString("ext.tv.test.authFailed")
            case .badServerResponse(let code):
                return PMString("ext.tv.playback.httpError", code)
            case .cannotBuildURL:
                return PMString("ext.tv.playback.cannotBuildURL")
            case .relayUnavailable:
                return PMString("ext.tv.test.relayUnavailable")
            }
        } catch {
            return TVSourceErrorText.message(error: error)
        }
    }

    /// 由字符串确定性选择低饱和占位色。只使用适合电视背景的珊瑚、松绿、
    /// 藏蓝、靛蓝和梅紫，避免全色相随机后大量落入泥棕色。
    private static func tint(_ seed: String) -> (Color, Color) {
        var h: UInt64 = 5381
        for b in seed.utf8 { h = (h &* 33) &+ UInt64(b) }
        let hues: [Double] = [0.02, 0.46, 0.58, 0.69, 0.86]
        let hue = hues[Int(h % UInt64(hues.count))]
        return (Color(hue: hue, saturation: 0.38, brightness: 0.58),
                Color(hue: hue, saturation: 0.30, brightness: 0.22))
    }
    private static func glyph(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "♪" : String(t.prefix(1))
    }

    // MARK: 启动引导(从 iCloud 拉取快照并重载真实曲库)

    /// 兼容入口:只关心「这次有没有装上新快照」的调用点继续用它。
    @discardableResult
    func bootstrap() async -> Bool {
        await bootstrapWithOutcome().didInstall
    }

    /// 带失败原因的引导。设置页要靠它把「没登录 / 连不上 / 云端没快照 / 本机写不进去」
    /// 分开显示,不要再统一收敛成一句「未找到曲库快照」。
    @discardableResult
    func bootstrapWithOutcome() async -> TVSyncOutcome {
        if let syncTask { return await syncTask.value }
        let task = Task { await self.performBootstrap() }
        syncTask = task
        let outcome = await task.value
        syncTask = nil
        return outcome
    }

    private func performBootstrap() async -> TVSyncOutcome {
        // 这里必须在引擎起来之前就返回。本机快照事务没收尾时,`library-cache.json`
        // 与 `tv-pending-library-import.json` 谁是真相还没定:此刻让 CKSyncEngine
        // 跑起来,它拉回来的歌单会写进 library-cache.json,而下次启动
        // `recoverTVSnapshot()` 会拿 pending 整份盖回去,刚同步下来的改动就没了;
        // 它同样会把这台机器半残的 sources 推上云端。歌单/设置的同步要等导入收尾,
        // 由下一次 bootstrap(或 reload() 里那次重试成功后的下一次)把引擎带起来。
        guard await retryPendingSnapshotImport() else { return .localStorageUnavailable }
        #if DEBUG
        injectDebugCredential()   // 先注入,避免与自动播放钩子竞态(CloudKit await 期间)
        #endif
        reload()
        // 总开关关掉后就不该再向 iCloud 要东西 —— 整库快照不属于任何一个
        // channel,`downloadTVPayload()` 自己不看这个开关,只能在这里挡。
        // 局域网扫码直传走 `applyLANPayload`,不经过这里,不受影响。
        guard CloudSyncChannel.isMasterEnabled(defaults: defaults) else {
            refreshVisibility()
            finishPendingRadioDeepLink()
            return .syncDisabled
        }
        resumePendingSourceUpload()
        let payload = await LibrarySnapshotSync.shared.downloadTVPayload()
        var installed = false
        if let payload {
            // 云端记录没变就不重装; 局域网刚直传过更新的库, 云端那份旧的也不装。
            switch TVCloudSnapshotInstallPolicy.disposition(
                cloudChangeTag: payload.cloudChangeTag,
                installedChangeTag: defaults.string(forKey: Self.installedCloudSnapshotTagKey),
                cloudModifiedAt: payload.cloudModifiedAt,
                lastLANInstallAt: defaults.object(forKey: Self.lastLANInstallKey) as? Date
            ) {
            case .install:
                installed = await installSnapshot(payload, fromCloud: true)
                if installed, let tag = payload.cloudChangeTag {
                    defaults.set(tag, forKey: Self.installedCloudSnapshotTagKey)
                }
            case .alreadyInstalled, .olderThanLANTransfer:
                installed = true
            }
        }
        // `start()` 只有第一次会真的跑 fetch + send,之后凭 `engine != nil` 直接早退。
        // 设置页的手动同步要想把 CKSyncEngine 那半边也拉一遍,只能在引擎已经起来的
        // 情况下自己补一次 `syncNow()`;首次引导交给 `start()`,别重复拉两遍。
        let engineWasRunning = cloudSync.isStarted
        await cloudSync.start()
        if engineWasRunning { await cloudSync.syncNow() }
        refreshVisibility()
        // `start()` 等 fetch 跑完才返回(账号不可用时直接返回、不会再有电台拉下来),
        // 此刻电台列表已经到齐。
        finishPendingRadioDeepLink()
        if installed {
            return hasRealLibrary ? .installed : .installedWithoutTransferableSongs
        }
        // 下载到了却装不上,是本机这一侧的问题(sources.json 残缺 / 事务没收尾),
        // 与「云端没给出快照」是两回事。
        if payload != nil { return .localStorageUnavailable }
        return unreachableSnapshotOutcome()
    }

    /// 快照没拉下来时,用 CloudKit 引擎刚刷新过的账号状态把「没登录」「连不上」和
    /// 「云端确实还没有快照」区分开 —— 这三种给用户的建议完全不同。状态要在
    /// `cloudSync.start()` 之后再读:首次引导时下载跑在 `start()` 之前,那会儿
    /// `status` 还停在 `.disabled`。
    private func unreachableSnapshotOutcome() -> TVSyncOutcome {
        switch cloudSync.status {
        case .accountUnavailable, .unavailableInBuild:
            return .accountUnavailable
        case .networkUnavailable, .quotaExceeded, .error:
            return .cloudUnreachable
        case .disabled, .idle, .syncing, .upToDate:
            return .noSnapshot
        }
    }

    /// 设置页的 iCloud 同步总开关。CloudKit 在账号退出 / 切换时会把
    /// `primuse.iCloudSyncEnabled` 强制关掉(`CloudKitSyncService.handleAccountChange`),
    /// 而 Apple TV 上原本没有任何入口能再打开它。与 iOS 的开关一样:改完偏好还要
    /// 让引擎跟着起停,只写 UserDefaults 不生效。
    func setCloudSyncEnabled(_ enabled: Bool) async {
        if enabled {
            await cloudSync.startAfterUserEnabledSync()
        } else {
            cloudSync.stop()
        }
    }

    /// 收到 CloudKit 私有库变更推送。推送可能比引导先到(系统为了投递它把 app
    /// 拉起来),所以引擎没起来时先 `start()`(它自己会跑一次 fetch),起来了才补
    /// 一次 `syncNow()` —— 与 `performBootstrap()` 里的判断同一条规则。总开关关着
    /// 时什么都不做,免得一条推送把用户刚关掉的同步又打开。
    func handleCloudKitPush() async {
        guard CloudSyncChannel.isMasterEnabled(defaults: defaults) else { return }
        if cloudSync.isStarted {
            await cloudSync.syncNow()
        } else {
            await cloudSync.start()
        }
    }

    /// 启动局域网「扫码直传」接收端(幂等)。源页出现时调用;收到载荷即落盘 + reload,
    /// 端点就绪后刷新二维码内容。
    func startPairingServer() {
        pairingPageVisible = true
        guard !pairingStarted else { return }
        pairingStarted = true
        pairingGeneration &+= 1
        configServer.onReceive = { [weak self] payload, serial in
            guard let self else { return false }
            return await self.applyLANPayload(payload, requestSerial: serial)
        }
        configServer.onStage = { [weak self] request, serial in
            guard let self else { return false }
            return await self.applyLANStage(request, requestSerial: serial)
        }
        configServer.onReceiveProgress = { [weak self] progress in
            Task { @MainActor in self?.noteLANReceiveProgress(progress) }
        }
        configServer.onSessionEnded = { [weak self] completed in
            Task { @MainActor in self?.endLANSession(completed: completed) }
        }
        configServer.onEndpointReady = { [weak self] link in
            Task { @MainActor in
                self?.pairingQRContent = link?.qrContent ?? "primuse://add-source"
                self?.pairingCode = link?.displayPairCode ?? ""
            }
        }
        configServer.start()
    }

    /// 源页消失时调用。分段传到一半时先不停:服务一停密钥就作废,手机后面的段全会失败;
    /// 等这次传输完成、失败提示收起或会话过期再停。
    func stopPairingServer() {
        pairingPageVisible = false
        guard pairingStarted else { return }
        if let phase = pairingTransfer?.phase, phase == .receiving || phase == .saving || phase == .saved {
            return
        }
        pairingStarted = false
        pairingGeneration &+= 1
        configServer.stop()
        pairingQRContent = "primuse://add-source"
        pairingCode = ""
        pairingTransferClearTask?.cancel()
        pairingTransfer = nil
        lanArtworkEligibleNames = nil
    }

    /// 收到 iPhone 经局域网直传来的整库 + 源 + 凭据:落盘、持久化凭据、合并重载曲库。
    @discardableResult
    func applyLANPayload(_ payload: LANSyncPayload, requestSerial: Int) async -> Bool {
        guard payload.isCompleteForTransfer else {
            plog("TVStore: rejected incomplete LAN payload")
            return false
        }
        let generation = pairingGeneration
        setPairingTransfer(LANReceiveStatus(phase: .saving, stage: .library, requestSerial: requestSerial),
                           generation: generation)
        let installed = await installSnapshot(payload, fromCloud: false)
        if installed {
            finishPairingTransfer(requestSerial: requestSerial, generation: generation)
        } else {
            setPairingTransfer(LANReceiveStatus(phase: .failed, stage: .library, requestSerial: requestSerial),
                               generation: generation)
        }
        return installed
    }

    /// 分段直传的一段:先音乐源与凭据(马上可用),再曲库,再分批封面,最后收尾。
    func applyLANStage(_ request: TVConfigServer.StageRequest, requestSerial: Int) async -> Bool {
        let generation = pairingGeneration
        func show(_ phase: LANReceiveStatus.Phase, _ stage: LANTransferStage, fraction: Double? = nil,
                  batchIndex: Int? = nil, batchCount: Int? = nil, songCount: Int? = nil) {
            setPairingTransfer(LANReceiveStatus(phase: phase, stage: stage, fraction: fraction,
                                                batchIndex: batchIndex, batchCount: batchCount,
                                                songCount: songCount, requestSerial: requestSerial),
                               generation: generation)
        }
        switch request {
        case .sources(let payload):
            show(.saving, .sources)
            let installed = await installSourcesStage(payload)
            show(installed ? .saved : .failed, .sources)
            return installed
        case .library(let payload):
            show(.saving, .library)
            let installed = await installSnapshot(payload, fromCloud: false)
            lanArtworkEligibleNames = nil
            show(installed ? .saved : .failed, .library, songCount: installed ? library.songs.count : nil)
            return installed
        case .artwork(let batch, let index, let count):
            let songCount = pairingTransfer?.songCount
            let fraction = Double(index) / Double(count)
            show(.saving, .artwork, fraction: fraction, batchIndex: index, batchCount: count, songCount: songCount)
            await installLANArtworkBatch(batch)
            show(.saved, .artwork, fraction: fraction, batchIndex: index, batchCount: count, songCount: songCount)
            return true
        case .finish:
            finishPairingTransfer(requestSerial: requestSerial, generation: generation)
            return true
        }
    }

    private func noteLANReceiveProgress(_ progress: TVConfigServer.ReceiveProgress) {
        guard pairingStarted else { return }
        if let current = pairingTransfer, current.supersedes(progressSerial: progress.requestSerial) { return }
        setPairingTransfer(LANReceiveStatus(
            phase: .receiving,
            stage: progress.stage,
            fraction: LANReceiveStatus.receivedFraction(
                receivedBytes: progress.receivedBytes, totalBytes: progress.totalBytes,
                batchIndex: progress.batchIndex, batchCount: progress.batchCount
            ),
            batchIndex: progress.batchIndex,
            batchCount: progress.batchCount,
            songCount: pairingTransfer?.songCount,
            requestSerial: progress.requestSerial
        ), generation: pairingGeneration)
    }

    /// 闲置过期时还停在半路的进度收起来;二维码已经换新,手机需重新扫码。
    private func endLANSession(completed: Bool) {
        lanArtworkEligibleNames = nil
        guard !completed, pairingTransfer?.phase != .finished else { return }
        clearPairingTransfer()
    }

    /// `generation` 是这次状态所属的源页会话;停过再开之后,上一轮迟到的结果不再显示。
    /// 正在接收却不再有数据(连接断了)、以及失败提示,过一会儿自动收起,露出确认码。
    private func setPairingTransfer(_ status: LANReceiveStatus, generation: Int) {
        guard pairingStarted, generation == pairingGeneration else { return }
        pairingTransferClearTask?.cancel()
        pairingTransferClearTask = nil
        pairingTransfer = status
        let expiry: Duration?
        switch status.phase {
        case .receiving: expiry = .seconds(45)
        case .failed: expiry = .seconds(20)
        case .finished: expiry = .seconds(10)
        case .saving, .saved: expiry = nil
        }
        guard let expiry else { return }
        let serial = status.requestSerial
        let phase = status.phase
        pairingTransferClearTask = Task { [weak self] in
            try? await Task.sleep(for: expiry)
            guard !Task.isCancelled, let self,
                  self.pairingTransfer?.requestSerial == serial,
                  self.pairingTransfer?.phase == phase else { return }
            self.clearPairingTransfer()
        }
    }

    /// 收起进度;源页已经离开的话,这时才真正停掉接收服务。
    private func clearPairingTransfer() {
        pairingTransferClearTask?.cancel()
        pairingTransferClearTask = nil
        pairingTransfer = nil
        if !pairingPageVisible { stopPairingServer() }
    }

    /// 完成提示停留一会儿再收起,露出换新的二维码。
    /// 上一次装好的云端快照记录的 changeTag, 与上一次局域网直传装库的时刻:
    /// 引导时据此决定云端快照装不装(`TVCloudSnapshotInstallPolicy`)。
    private static let installedCloudSnapshotTagKey = "tv.installedCloudSnapshotTag"
    private static let lastLANInstallKey = "tv.lastLANInstallAt"

    private func finishPairingTransfer(requestSerial: Int, generation: Int) {
        defaults.set(Date(), forKey: Self.lastLANInstallKey)
        setPairingTransfer(LANReceiveStatus(phase: .finished, stage: .finish, songCount: library.songs.count,
                                            requestSerial: requestSerial),
                           generation: generation)
        if !pairingPageVisible { clearPairingTransfer() }
    }

    /// 分段直传第一段:音乐源、凭据与电台先落盘,源马上能用;曲库在下一段到。
    private func installSourcesStage(_ payload: LANSyncPayload) async -> Bool {
        guard payload.isCompleteSourcesStage, let incoming = payload.credentials else { return false }
        guard await retryPendingSnapshotImport() else { return false }
        guard !isApplyingSnapshot else { return false }
        guard sourcesStore.hasCompleteSnapshot else { return false }
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        _ = await scanTask?.value
        // 从这里到重载音乐源之间不能再让出主 actor,否则 SourcesStore 的一次持久化
        // 可能落在读基线与事务写盘之间被覆盖。
        guard let localSources = try? sourcesStore.validatedSourcesForSnapshot() else { return false }
        let previousCredentialReference = try? Data(contentsOf: TVCredentialStore.pairedBundleReferenceURL)
        guard let staged = stageIncomingCredentials(incoming, fromCloud: false) else { return false }
        let sync = LibrarySnapshotSync.shared
        guard let plan = sync.prepareTVSourcesInstall(
                  payload, credentialReference: staged.reference, localSources: localSources,
                  hasExistingRadioStations: sync.hasTVRadioStations()
              ),
              sync.applyTVPayloadInstall(plan.files) else {
            TVCredentialStore.discardInactiveStagedBundle(reference: staged.reference)
            return false
        }
        commitStagedCredentials(staged, incoming: incoming, previousReference: previousCredentialReference,
                                fromCloud: false)
        scanner.invalidateFnMusicClients()
        sourcesStore.reloadFromDisk()
        installRadioStations(from: plan)
        pruneCredentialBundlesToActiveSources()
        refreshVisibility()
        sourcesRevision += 1
        return true
    }

    /// 一批封面在主 actor 之外写盘。装不上的(引用不属于本机曲库)直接略过,不算失败。
    /// 自定义封面存盘时已逐张通知,这里只为缓存封面补一次整体刷新。
    private func installLANArtworkBatch(_ batch: LANArtworkBatch) async {
        let assetStore = MetadataAssetStore.shared
        let eligibleNames: Set<String>
        if let cached = lanArtworkEligibleNames {
            eligibleNames = cached
        } else {
            let songs = library.songs
            eligibleNames = await Task.detached(priority: .userInitiated) {
                MusicLibrary.portableArtworkEligibleNames(songs: songs, assetStore: assetStore)
            }.value
            lanArtworkEligibleNames = eligibleNames
        }
        let restored = await Task.detached(priority: .userInitiated) {
            MusicLibrary.restorePortableArtwork(
                customAssets: batch.customAssets,
                cachedAssets: batch.cachedAssets,
                references: batch.references,
                eligibleNames: eligibleNames,
                assetStore: assetStore
            )
        }.value
        if restored.cached > 0 {
            NotificationCenter.default.post(name: .primuseArtworkDidCache, object: nil, userInfo: ["all": true])
        }
    }

    private struct StagedCredentials {
        let reference: Data
        let bundle: CredentialBundle
    }

    /// 把收到的凭据并进现有凭据包,先写进一条独立的钥匙串项;只有事务落盘了它的引用才生效。
    private func stageIncomingCredentials(_ incoming: CredentialBundle, fromCloud: Bool) -> StagedCredentials? {
        let key = fromCloud ? "tv.credentialSources.cloud" : "tv.credentialSources.paired"
        let oldScope = Set(defaults.stringArray(forKey: key) ?? [])
        var baseline = credentialBundle ?? TVCredentialStore.loadPairedBundle() ?? CredentialBundle()
        for id in oldScope where incoming.entries[id] == nil { baseline.entries.removeValue(forKey: id) }
        baseline.relay = incoming.relay
        for (id, entry) in incoming.entries { baseline.entries[id] = entry }
        guard let reference = TVCredentialStore.stagePairedBundle(baseline) else { return nil }
        return StagedCredentials(reference: reference, bundle: baseline)
    }

    private func commitStagedCredentials(_ staged: StagedCredentials, incoming: CredentialBundle,
                                         previousReference: Data?, fromCloud: Bool) {
        if let previousReference {
            TVCredentialStore.discardInactiveStagedBundle(reference: previousReference)
        }
        credentialBundle = staged.bundle
        defaults.set(Array(incoming.entries.keys),
                     forKey: fromCloud ? "tv.credentialSources.cloud" : "tv.credentialSources.paired")
        if fromCloud { cloudCredentialSourceIDs = Set(incoming.entries.keys) }
    }

    private func installSnapshot(_ payload: LANSyncPayload, fromCloud: Bool) async -> Bool {
        guard await retryPendingSnapshotImport() else { return false }
        guard !isApplyingSnapshot else { return false }
        guard sourcesStore.hasCompleteSnapshot else { return false }
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        installGeneration &+= 1
        let generation = installGeneration
        // A downloaded payload is staged; it cannot race scan writes or use a
        // baseline captured before those writes completed.
        _ = await scanTask?.value
        guard case .success = await library.persistNowAndWait() else { return false }
        // 栅栏必须在这一刻关上 —— 之后 preparedSnapshotFiles 会让出主 actor,
        // 播放记账与生命周期落盘都能在那段时间里出发自己的后台写入, 而它们
        // 写的是事务要整份替换的同一个 library-cache.json。栅栏一关: 在途的
        // 写入已经等干净, 新的写入要么推迟要么排队, 直到整库装好并重载完成。
        await library.beginExternalSnapshotWrite()
        var holdsSnapshotWrite = true
        defer { if holdsSnapshotWrite { library.endExternalSnapshotWrite() } }
        guard let localSources = try? sourcesStore.validatedSourcesForSnapshot() else { return false }
        let before = library.songs
        let previousCredentialReference = try? Data(contentsOf: TVCredentialStore.pairedBundleReferenceURL)
        var staged: StagedCredentials?
        if let incoming = payload.credentials {
            guard let value = stageIncomingCredentials(incoming, fromCloud: fromCloud) else { return false }
            staged = value
        }
        let reference = staged?.reference
        // 安装拆成两段:gunzip + 多次 JSON 解析/编码 放到主 actor 之外算,事务写盘
        // 仍留在主 actor 上,不与 MusicLibrary 的持久化交叉。区间名对 Instruments
        // 稳定不要改。
        let installSignpost = PrimuseSignposts.hitch.beginInterval("tv.installPayload")
        let prepared = await preparedSnapshotFiles(
            payload, credentialReference: reference, fromCloud: fromCloud,
            preservingSongs: before.filter { locallyScannedSourceIDs.contains($0.sourceID) },
            localSources: localSources, generation: generation
        )
        let didInstall = prepared.map { LibrarySnapshotSync.shared.applyTVPayloadInstall($0.files) } ?? false
        PrimuseSignposts.hitch.endInterval("tv.installPayload", installSignpost)
        guard didInstall, let prepared else {
            if let reference { TVCredentialStore.discardInactiveStagedBundle(reference: reference) }
            return false
        }
        hasPendingSnapshotImport = true
        if let staged, let incoming = payload.credentials {
            commitStagedCredentials(staged, incoming: incoming, previousReference: previousCredentialReference,
                                    fromCloud: fromCloud)
        }
        // 与安装步骤对照:reloadFromDisk 是设计上就同步的整库重载,先量清楚
        // 两者各占多少,再决定要不要动安装步骤。
        let reloadSignpost = PrimuseSignposts.hitch.beginInterval("tv.reloadMerging")
        reloadMerging(before: before, installed: prepared)
        PrimuseSignposts.hitch.endInterval("tv.reloadMerging", reloadSignpost)
        await library.waitForPendingIndex()
        // 重载 + 合并之后内存里就是导入结果与本地改动合并后的真相, 这时候放行
        // 被挡住的写入方是安全的 —— 它们写的正是这份结果。栅栏必须在下面那次
        // 屏障落盘之前交还, 否则那次落盘会等一个永远不会到来的放行。
        holdsSnapshotWrite = false
        library.endExternalSnapshotWrite()
        guard case .success = await library.persistNowAndWait() else { return false }
        do { try LibrarySnapshotSync.finishTVSnapshotImport() }
        catch { return false }
        hasPendingSnapshotImport = false
        refreshVisibility()
        sourcesRevision += 1
        return true
    }

    /// 安装的纯计算部分:先在主 actor 上读基线并记下 `library-cache.json` 的身份,
    /// 算完回到主 actor 再确认这次安装仍然是当前这次、自己仍持有 `isApplyingSnapshot`、
    /// 且基线没被中途的持久化改写,才把结果交给事务落盘。基线对不上就整段重算一次,
    /// 仍然对不上就放弃这次安装,由调用方按失败处理(LAN 发送端会重传,云端下次
    /// 引导会重新下载)。
    /// 离开主 actor 算出来的安装结果, 外加算它时用的两份基线身份。
    private struct PreparedSnapshotInstall: Sendable {
        let plan: LibrarySnapshotSync.TVPayloadInstallPlan
        let libraryIdentity: SnapshotFileIdentity?
        let sourcesIdentity: SnapshotFileIdentity?
    }

    private func preparedSnapshotFiles(
        _ payload: LANSyncPayload, credentialReference: Data?, fromCloud: Bool,
        preservingSongs: [Song], localSources: [MusicSource], generation: Int
    ) async -> LibrarySnapshotSync.TVPayloadInstallPlan? {
        let sync = LibrarySnapshotSync.shared
        for attempt in 0..<2 {
            // 基线的读取也放进这个任务: `library-cache.json` 可以有几十 MB,
            // 在主 actor 上读它 (而且负载无效时白读一次、重算时再读一次) 正是
            // 这次改动要去掉的开销。身份仍然先于字节抓取, 落盘前再回主 actor 复核。
            let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedSnapshotInstall? in
                guard let baseline = sync.readTVPayloadInstallBaseline(localSources: localSources) else {
                    return nil
                }
                guard let plan = sync.prepareTVPayloadInstall(
                    payload, credentialReference: credentialReference, fromCloud: fromCloud,
                    preservingSongs: preservingSongs, localSources: localSources,
                    existingLibraryData: baseline.existingLibraryData,
                    existingSourcesData: baseline.existingSourcesData,
                    hasExistingRadioStations: baseline.hasExistingRadioStations
                ) else { return nil }
                return PreparedSnapshotInstall(plan: plan,
                                               libraryIdentity: baseline.libraryIdentity,
                                               sourcesIdentity: baseline.sourcesIdentity)
            }.value
            guard generation == installGeneration, isApplyingSnapshot else { return nil }
            guard let prepared else { return nil }
            // 事务会重写 library-cache.json 和 sources.json 两个文件, 两份基线
            // 都要还没被改过才能落盘。
            if SnapshotBaselineGate.isStillValid(captured: prepared.libraryIdentity,
                                                 current: sync.currentTVLibraryIdentity()),
               SnapshotBaselineGate.isStillValid(captured: prepared.sourcesIdentity,
                                                 current: sync.currentTVSourcesIdentity()) {
                return prepared.plan
            }
            if attempt == 0 { plog("TVStore: library baseline changed during install, recomputing") }
        }
        plog("TVStore: library baseline kept changing during install, snapshot deferred")
        return nil
    }

    func retryPendingSnapshotImport() async -> Bool {
        guard hasPendingSnapshotImport || hasPendingSnapshotRecovery else { return true }
        if let pendingImportTask { return await pendingImportTask.value }
        guard !isApplyingSnapshot else { return false }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            self.isApplyingSnapshot = true
            defer { self.isApplyingSnapshot = false }
            if self.hasPendingSnapshotRecovery {
                // 恢复同样是整份替换 (完成或回滚上一次事务), 走同一道栅栏,
                // 否则一笔在途的后台写入可以盖掉刚恢复出来的文件。
                await self.library.beginExternalSnapshotWrite()
                var holdsSnapshotWrite = true
                defer { if holdsSnapshotWrite { self.library.endExternalSnapshotWrite() } }
                do {
                    self.hasPendingSnapshotImport = try self.snapshotRecovery()
                    self.hasPendingSnapshotRecovery = false
                    self.library.reloadFromDisk(preferExternalSnapshot: self.hasPendingSnapshotImport)
                    self.sourcesStore.reloadFromDisk()
                    // 完成或回滚的那次事务里可能带着电台文件(首次引导整份写入的那种)。
                    self.reloadRadioStations(fromDisk: true)
                    self.refreshVisibility()
                } catch {
                    self.playbackIssue = .failed(PMString("ext.tv.persistence.failed"))
                    return false
                }
                holdsSnapshotWrite = false
                self.library.endExternalSnapshotWrite()
            }
            guard self.hasPendingSnapshotImport else { return true }
            guard case .success = await self.library.persistNowAndWait() else {
                self.playbackIssue = .failed(PMString("ext.tv.persistence.failed"))
                return false
            }
            do {
                try LibrarySnapshotSync.finishTVSnapshotImport()
                self.hasPendingSnapshotImport = false
                return true
            } catch {
                self.playbackIssue = .failed(PMString("ext.tv.persistence.failed"))
                return false
            }
        }
        pendingImportTask = task
        let succeeded = await task.value
        pendingImportTask = nil
        return succeeded
    }

    /// 应用手机快照后重载,并把「TV 本机扫的、手机快照里没有的源」的歌合并回来,
    /// 避免整库覆盖冲掉 TV 扫描结果(song id 确定性派生,addSongs 自动去重)。
    private func reloadMerging(before: [Song], installed plan: LibrarySnapshotSync.TVPayloadInstallPlan) {
        scanner.invalidateFnMusicClients()
        library.reloadFromDisk()
        let incomingIDs = Set(library.songs.map(\.id))
        let tvOnly = before.filter {
            locallyScannedSourceIDs.contains($0.sourceID) && !incomingIDs.contains($0.id)
        }
        if !tvOnly.isEmpty {
            library.addSongs(tvOnly, affectedSourceIDs: nil, notifyRemovals: false, pruneMissingSongs: false)
            library.persistNow()
            plog("TVStore: merged \(tvOnly.count) TV-scanned songs back after sync")
        }
        sourcesStore.reloadFromDisk()
        installRadioStations(from: plan)
        refreshVisibility()
        publishTopShelf()
        flushPendingDeepLink()
        pruneCredentialBundlesToActiveSources()
    }

    /// 快照里的电台进本机。本机已有清单时逐条按修改时间合并:电视上的增删改名排序、
    /// 还没传上去的改动都留着,快照里更新的行照收。首次引导随事务整份写入,从磁盘重读。
    private func installRadioStations(from plan: LibrarySnapshotSync.TVPayloadInstallPlan) {
        if let raw = plan.radioStationsToMerge {
            do {
                try radioStore.applySnapshot(raw)
            } catch {
                plog("TVStore: radio snapshot merge failed: \(error.localizedDescription)")
            }
            reloadRadioStations(fromDisk: false)
        } else {
            reloadRadioStations(fromDisk: plan.replacesRadioStations)
        }
    }

    #if DEBUG
    /// 模拟器/截图测试:`TV_DEMO_CRED="sourceID:username:password"` 注入一条凭据,
    /// 绕过 CloudKit(模拟器无 iCloud 账号)直接演示真实流式播放。
    private func injectDebugCredential() {
        guard let raw = ProcessInfo.processInfo.environment["TV_DEMO_CRED"] else { return }
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        var bundle = credentialBundle ?? CredentialBundle()
        bundle.entries[parts[0]] = CredentialEntry(username: parts[1], password: parts[2])
        credentialBundle = bundle
        scanner.invalidateFnMusicClient(sourceID: parts[0])
    }
    #endif

    #if DEBUG
    /// 截图用:直接注入一条「正在播放」+ 演示歌词,不走真实播放(模拟器无可达源)。
    /// `preferSongArtwork` 用来专门覆盖无 albumID 散曲的歌曲缓存/远程封面路径。
    @discardableResult
    func loadDemoNowPlaying(preferSongArtwork: Bool = false) async -> Bool {
        let usesImmersiveEvidence = ProcessInfo.processInfo.environment["TV_IMMERSIVE_EFFECT"] != nil
        var rawSong: Song?
        var selectedAlbum: TVAlbum?

        if preferSongArtwork {
            rawSong = await demoStandaloneArtworkSong()
            guard rawSong != nil else {
                plog("TV debug artwork route failed: no standalone song with loadable artwork")
                return false
            }
        }
        if rawSong == nil,
           let album = albums.first(where: {
               MetadataAssetStore.shared.hasAlbumCover(forAlbumID: $0.id)
           }) ?? albums.first {
            selectedAlbum = album
            rawSong = library.visibleSongs.first(where: { $0.albumID == album.id })
        }
        if rawSong == nil {
            rawSong = library.visibleSongs.first
        }
        if rawSong == nil, usesImmersiveEvidence {
            let fallback = Self.tint("immersive-evidence")
            nowPlaying = TVNowPlaying(
                songID: "immersive-evidence",
                coverRef: nil,
                title: ImmersiveDemoContent.title,
                artist: ImmersiveDemoContent.artist,
                album: ImmersiveDemoContent.album,
                albumID: "",
                tint: fallback.0,
                tint2: fallback.1,
                glyph: "♪",
                duration: Double(Self.immersiveEvidenceLyrics.count + 1) * 4,
                currentTime: 0,
                format: "FLAC",
                bitrate: 1411,
                sampleRate: 96,
                sourcePath: ""
            )
            updateAutomaticThemePalette(nil)
            playbackIssue = nil
            hasNowPlaying = true
            queueUpNextIDs = []
            lyrics = Self.immersiveEvidenceLyrics
            return true
        }
        guard let rawSong, let song = song(rawSong.id) else { return false }

        let album = selectedAlbum ?? album(song.albumID)
        let fallback = Self.tint(song.id)
        let albumPalette = artworkPalettes[song.albumID]
        let songPalette = artworkPalettes[Self.songArtworkPaletteKey(song.id)]
        let tint = albumPalette?.primary.color ?? songPalette?.primary.color
            ?? album?.tint ?? fallback.0
        let tint2 = albumPalette?.secondary.color ?? songPalette?.secondary.color
            ?? album?.tint2 ?? fallback.1
        nowPlaying = TVNowPlaying(
            songID: song.id,
            coverRef: rawSong.coverArtFileName,
            title: usesImmersiveEvidence ? ImmersiveDemoContent.title : song.title,
            artist: usesImmersiveEvidence ? ImmersiveDemoContent.artist : song.artist,
            album: usesImmersiveEvidence
                ? ImmersiveDemoContent.album
                : (album?.title ?? rawSong.albumTitle ?? ""),
            albumID: song.albumID,
            tint: tint, tint2: tint2, glyph: album?.glyph ?? Self.glyph(song.title),
            duration: song.duration > 0 ? song.duration : 245,
            currentTime: 0,
            format: song.format,
            bitrate: song.bitrate > 0 ? song.bitrate : 1411,
            sampleRate: song.sampleRate > 0 ? song.sampleRate : 96,
            sourcePath: "")
        updateAutomaticThemePalette(albumPalette ?? songPalette)
        hasNowPlaying = true
        queueUpNextIDs = songs.lazy
            .filter { $0.id != song.id }
            .prefix(12)
            .map(\.id)
        lyrics = usesImmersiveEvidence ? Self.immersiveEvidenceLyrics : Self.demoLyrics
        return true
    }

    private func demoStandaloneArtworkSong() async -> Song? {
        let candidates = library.visibleSongs.filter {
            $0.albumID?.isEmpty != false && $0.coverArtFileName?.isEmpty == false
        }
        for song in candidates {
            if await TVArtworkLoader.shared.songCover(
                songID: song.id,
                coverRef: song.coverArtFileName
            ) != nil {
                return song
            }
        }
        return nil
    }

    static let demoLyrics: [TVLyricLine] = [
        .init(time: 0, text: PMString("ext.tv.demo.lyric1"), syllables: [], translation: ""),
        .init(time: 4, text: PMString("ext.tv.demo.lyric2"), syllables: [], translation: ""),
        .init(time: 9, text: PMString("ext.tv.demo.lyric3"), syllables: [], translation: ""),
        .init(time: 14, text: PMString("ext.tv.demo.lyric4"), syllables: [], translation: ""),
        .init(time: 19, text: PMString("ext.tv.demo.lyric5"), syllables: [], translation: ""),
        .init(time: 24, text: PMString("ext.tv.demo.lyric6"), syllables: [], translation: ""),
        .init(time: 29, text: PMString("ext.tv.demo.lyric7"), syllables: [], translation: ""),
        .init(time: 34, text: PMString("ext.tv.demo.lyric8"), syllables: [], translation: ""),
    ]

    static let immersiveEvidenceLyrics: [TVLyricLine] = ImmersiveDemoContent.lyrics
        .enumerated()
        .map { index, text in
            let lineStart = Double(index) * 4
            let syllables: [TVSyllable]
            if index == 1 {
                let characters = text.map(String.init)
                let duration = 4 / Double(max(characters.count, 1))
                syllables = characters.enumerated().map { offset, character in
                    let start = lineStart + Double(offset) * duration
                    return TVSyllable(
                        w: character,
                        start: start,
                        end: start + duration,
                        endTiming: .explicit
                    )
                }
            } else {
                syllables = []
            }
            return TVLyricLine(
                id: "immersive-evidence-\(index)",
                time: lineStart,
                text: text,
                isSynchronized: true,
                syllables: syllables,
                translation: ""
            )
        }
    #endif

    /// 仅从本地磁盘重载(不联网),用于关闭自动同步时的启动。
    func reload() {
        guard !hasPendingSnapshotRecovery else {
            playbackIssue = .failed(PMString("ext.tv.persistence.failed"))
            Task { _ = await self.retryPendingSnapshotImport() }
            return
        }
        scanner.invalidateFnMusicClients()
        // Normal launch uses the canonical song store. Only a successfully
        // installed external snapshot may replace it from the portable JSON.
        if activeScanSourceID == nil, !isApplyingSnapshot, !hasPendingSnapshotImport {
            library.reloadFromDisk(preferExternalSnapshot: false)
        }
        migrateLegacySongIDs()
        sourcesStore.reloadFromDisk()
        // 电台文件只有本进程的电台存储会写(快照事务整份写入时由各安装入口自己重读),
        // 内存里就是最新的,这里不必从磁盘重读。
        reloadRadioStations(fromDisk: false)
        refreshVisibility()
        publishTopShelf()
        flushPendingDeepLink()
        // 凭据未就绪时载入局域网直传持久化下来的配对包，并以本地活跃来源
        // 为边界裁剪。CloudKit 下载失败不会被当成空包，也不会清掉活跃源凭据。
        pruneCredentialBundlesToActiveSources()
        restorePlaybackSessionIfNeeded()
        if hasPendingSnapshotImport { Task { _ = await self.retryPendingSnapshotImport() } }
    }

    private func reloadRadioStations(fromDisk: Bool) {
        if fromDisk { radioStore.reloadFromDisk() }
        var decoded = radioStore.allStations

        let recency = UserDefaults.standard.dictionary(forKey: "tvRadioLastPlayedAt") ?? [:]
        for index in decoded.indices {
            if let timestamp = recency[decoded[index].id] as? NSNumber {
                let legacy = Date(timeIntervalSince1970: timestamp.doubleValue)
                decoded[index].lastPlayedAt = max(decoded[index].lastPlayedAt ?? .distantPast, legacy)
            }
        }
        var visible = RadioStationOrdering.sorted(
            decoded.filter {
                !$0.isDeleted
                    && RadioStationValidation.hasConsistentServerIdentity($0)
                    && RadioStationValidation.hasValidPlaybackReference($0)
                    && ($0.sourceID.map { id in isRadioSourceAvailable(id) } ?? true)
            }
        )
        #if DEBUG
        if Self.showsDemoRadioStations {
            let demo = Self.demoRadioStations
            let demoIDs = Set(demo.map(\.id))
            visible = demo + visible.filter { !demoIDs.contains($0.id) }
        }
        #endif
        // 没变就不赋值:didSet 里的派生重建、Siri 词表通知和 Top Shelf 发布都跟着省掉。
        // 电视端的增删改会先同步重载一次,随后电台存储的观察回调再来一次,那一次多半没变。
        if radioStations != visible {
            radioStations = visible
            publishTopShelf()
        }

        if isLiveRadio,
           let currentRadioStationID,
           !radioStations.contains(where: { $0.id == currentRadioStationID }) {
            radioReconnectTask?.cancel()
            playbackTask?.cancel()
            playbackTask = nil
            activePlaybackRequestID = nil
            engine.stop()
            isLiveRadio = false
            self.currentRadioStationID = nil
            radioMetadataTitle = ""
            hasNowPlaying = false
        }
        // 正在播的台改了名(电视上改的,或 iPhone / Mac 经 iCloud 改的):底栏、正在播放页
        // 和系统「正在播放」信息跟着换,不重连。
        if isLiveRadio, let station = currentRadioStation, nowPlaying.title != station.name {
            nowPlaying.title = station.name
            engine.updateLiveTitle(station.name)
        }
        // 系统清掉缓存后电台要等 CloudKit 一条条拉回来;这期间从 Top Shelf 点进来的电台
        // 深链一直暂存着,每次列表有变化就再找一次目标台。
        if pendingDeepLink?.host == "radio" {
            flushPendingDeepLink()
        }
    }

    private func rebuildRadioDerivedState() {
        let stations = radioStations
        // 镜像台动辄几千个,文件夹名却只有几十种:同一个原始文件夹名只归一化、折叠一次。
        var keyByRawFolder: [String: String] = [:]
        var displayNameByKey: [String: String] = [:]
        var byFolder: [String: [RadioStation]] = [:]
        for station in stations {
            let raw = station.folderName ?? ""
            let key: String
            if let known = keyByRawFolder[raw] {
                key = known
            } else {
                if let name = RadioStationOrganization.normalizedFolderName(raw) {
                    key = RadioStationOrganization.comparisonKey(name)
                    // 与 `folders(in:)` 一样,文件夹显示名取这个文件夹里第一个台的写法。
                    if displayNameByKey[key] == nil { displayNameByKey[key] = name }
                } else {
                    key = ""
                }
                keyByRawFolder[raw] = key
            }
            byFolder[key, default: []].append(station)
        }
        if radioStationsByFolderKey != byFolder { radioStationsByFolderKey = byFolder }
        // 排序与显示名交给 `folders(in:additionalNames:)`(只传几十个显示名,不再逐台归一化),
        // 计数直接用上面分好的组。
        let folders = RadioStationOrganization
            .folders(in: [], additionalNames: Array(displayNameByKey.values))
            .map { summary in
                RadioStationFolderSummary(
                    name: summary.name,
                    stationCount: byFolder[RadioStationOrganization.comparisonKey(summary.name)]?.count ?? 0
                )
            }
        if radioFolders != folders { radioFolders = folders }
        let ungrouped = byFolder[""]?.count ?? 0
        if radioUngroupedCount != ungrouped { radioUngroupedCount = ungrouped }
        let keys = Set(stations.compactMap { RadioImportParser.streamIdentityKey($0.streamURL) })
        if radioStreamIdentityKeys != keys { radioStreamIdentityKeys = keys }
    }

    #if DEBUG
    /// 截图用:`TV_DEMO_RADIO=1` 时在内存里的电台列表前面放几个演示台。
    /// 只进 `radioStations`,不写电台存储,不会落盘也不会同步。
    private static let showsDemoRadioStations =
        ProcessInfo.processInfo.environment["TV_DEMO_RADIO"] == "1"

    private static let demoRadioStations: [RadioStation] = {
        let now = Date()
        func demo(
            _ index: Int,
            _ name: String,
            folder: String? = nil,
            logo: String? = nil
        ) -> RadioStation {
            RadioStation(
                id: "tv-demo-radio-\(index)",
                name: name,
                streamURL: "https://demo.primuse.invalid/radio/\(index)",
                createdAt: now,
                modifiedAt: now,
                sortOrder: index,
                remoteLogoURL: logo,
                remoteLogoSource: logo == nil ? nil : .directoryFavicon,
                folderName: folder
            )
        }
        return [
            demo(0, "Groove Salad", folder: "Music",
                 logo: "https://somafm.com/img3/groovesalad-400.jpg"),
            demo(1, "Drone Zone", folder: "Music",
                 logo: "https://somafm.com/img3/dronezone-400.jpg"),
            demo(2, "Morning News", folder: "News"),
            demo(3, "World News Hour", folder: "News"),
            demo(4, "City Jazz FM"),
            demo(5, "Classic Rock 101"),
            demo(6, "Lo-Fi Beats"),
            demo(7, "Evening Talk"),
        ]
    }()
    #endif

    // MARK: 电台管理(电视端添加 / 删除 / 置顶)

    /// 音乐源镜像的台由服务端管,电视端只能播,不能改。
    func canManageRadioStation(_ station: RadioStation) -> Bool {
        !station.isServerMirror
    }

    /// 镜像台所属的音乐源还在用:没在电视上移除、启用着、没被删。电台列表的过滤和
    /// 镜像台台标的取图共用这一处判断。
    private func isRadioSourceAvailable(_ sourceID: String) -> Bool {
        guard !locallyRemovedSourceIDs.contains(sourceID),
              let source = sourcesStore.source(id: sourceID) else { return false }
        return source.isEnabled && !source.isDeleted
    }

    /// 取镜像台台标要用的音乐源和凭据;源不可用或电视上没有能取封面的连接器时为 nil。
    /// 会读钥匙串,所以只由台标加载器在缓存没命中时调用。不设「密码或令牌非空」的门槛:
    /// Jellyfin / Emby 允许没有密码的具名账号。
    func radioLogoSourceContext(sourceID: String) -> TVRadioLogoSourceContext? {
        guard isRadioSourceAvailable(sourceID),
              let source = sourcesStore.source(id: sourceID),
              TVSourceAssetReader.supports(source.type) else { return nil }
        return TVRadioLogoSourceContext(
            source: source,
            credential: TVCredentialStore.credential(for: source, bundle: credentialBundle)
        )
    }

    /// 镜像台台标所依赖的音乐源状态的指纹,台标卡片拿它决定要不要重新取图。只读内存。
    /// 普通电台和没有封面引用的镜像台(群晖 Audio Station 的台都没有)直接返回 0,
    /// 几千张这样的卡片不会因此订阅音乐源和凭据的变化。
    func radioLogoSourceFingerprint(for station: RadioStation) -> Int {
        guard station.isServerMirror,
              station.logoFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let sourceID = station.sourceID else { return 0 }
        var hasher = Hasher()
        hasher.combine(sourceID)
        // 在电视上手动改凭据、启停音乐源都会让它加一。
        hasher.combine(sourcesRevision)
        hasher.combine(sourcesStore.source(id: sourceID))
        // 经 iCloud 或扫码直传到的凭据。只进本进程内随机种子的哈希,不落盘。
        if let entry = credentialBundle?.entries[sourceID] {
            hasher.combine(entry.username)
            hasher.combine(entry.password)
            hasher.combine(entry.token)
        }
        return hasher.finalize()
    }

    /// 同一个流(不计 http/https、末尾斜杠)是否已经在电台列表里。
    func hasRadioStation(streamURL: String) -> Bool {
        guard let key = RadioImportParser.streamIdentityKey(streamURL) else { return false }
        return radioStreamIdentityKeys.contains(key)
    }

    /// 添加一个电台。写进与 iPhone / Mac 同一份电台存储,开着 iCloud 同步时
    /// 会同步到其他设备。返回新电台;名称或地址无效、流已存在时返回 nil。
    @discardableResult
    func addRadioStation(
        name: String,
        streamURL: String,
        homepageURL: String? = nil,
        logoURL: String? = nil,
        logoSource: RadioLogoSource? = nil
    ) -> RadioStation? {
        guard RadioStationValidation.isValid(name: name, urlString: streamURL),
              !hasRadioStation(streamURL: streamURL) else { return nil }
        let logo = RadioLogoURLPolicy.normalized(logoURL)
        let station = RadioStation(
            name: name,
            streamURL: streamURL,
            streamFormat: URL(string: streamURL)
                .map { RadioStreamFormat.inferred(from: $0) } ?? .automatic,
            homepageURL: RadioLogoURLPolicy.normalized(homepageURL),
            remoteLogoURL: logo,
            remoteLogoSource: logo == nil ? nil : logoSource
        )
        radioStore.upsert(station)
        guard radioStore.station(id: station.id) != nil else { return nil }
        reloadRadioStations(fromDisk: false)
        if logo == nil { lookUpDirectoryLogo(stationID: station.id, streamURL: station.streamURL) }
        return station
    }

    /// 手动输入地址的台没有台标;iPhone 端的台标自动发现不在电视上,至少拿流地址回查一次目录。
    /// 查不到是常态,静默结束。
    private func lookUpDirectoryLogo(stationID: String, streamURL: String) {
        Task { @MainActor [weak self] in
            guard let found = await RadioDirectoryClient.lookup(streamURL: streamURL),
                  let logo = RadioLogoURLPolicy.normalized(found.faviconURL) else { return }
            // 目录给的 favicon 大约四成是坏的,先取回来确认是张图再写:台标地址会同步到
            // 所有设备,而 iPhone 看到已有地址就不再自己去找台标,坏地址会一直占着位置。
            guard await TVRadioLogoLoader.probeRemoteLogo(logo, forStationID: stationID),
                  let self,
                  let current = self.radioStore.station(id: stationID),
                  current.remoteLogoURL == nil else { return }
            // 只补台标和缺失的主页;期间用户或别的设备自己设了图就作废。
            self.radioStore.applyDiscoveredLogo(
                id: stationID,
                urlString: logo,
                source: .directoryLookup,
                homepageURL: found.homepageURL
            )
            self.reloadRadioStations(fromDisk: false)
        }
    }

    func removeRadioStation(id: String) {
        guard let station = radioStations.first(where: { $0.id == id }),
              canManageRadioStation(station) else { return }
        radioStore.remove(id: id)
        reloadRadioStations(fromDisk: false)
    }

    /// 在同一排的台之间前后挪一格(`offset` 为负是往前)。排序与 iPhone / Mac 共用。
    /// `siblingIDs` 是卡片所在那一排 / 那一格实际显示的台(首页只放前几个,资料库可能
    /// 按文件夹筛过),只越过其中的相邻台;不给就是电视上的全部电台。
    func moveRadioStation(id: String, by offset: Int, within siblingIDs: [String]?) {
        guard offset != 0 else { return }
        reorderRadioStation(id: id, within: siblingIDs) { index, count in
            max(0, min(count - 1, index + offset))
        }
    }

    /// 改电台名称。订阅来的台名字归清单管、镜像台归服务端管,都不走这里。
    func renameRadioStation(id: String, to rawName: String) {
        let name = RadioStationValidation.normalizedName(rawName)
        guard !name.isEmpty,
              let station = radioStations.first(where: { $0.id == id }),
              canManageRadioStation(station),
              !station.isSubscribed else { return }
        radioStore.update(id) { $0.name = name }
        reloadRadioStations(fromDisk: false)
    }

    /// 移到同一排的最前面(`siblingIDs` 同上;资料库按文件夹筛选时就是移到这个文件夹最前)。
    /// 排序与 iPhone / Mac 共用,会一起同步过去。
    func moveRadioStationToTop(id: String, within siblingIDs: [String]?) {
        reorderRadioStation(id: id, within: siblingIDs) { _, _ in 0 }
    }

    /// 把 `id` 挪到同一排的第 `target(当前位置, 同排台数)` 个位置。
    ///
    /// 基准是电视上显示的顺序(`radioStations`),不是存储自己的排序:这台电视记的最近
    /// 播放时间可能与存储里的不同,两边按它排出来的先后就不一样,按存储顺序挪会挪错邻居。
    /// 只留存储里确实有的台(DEBUG 演示台不在存储里,混进去会顶掉真台的位置)。
    /// 挪动落在整份显示顺序上:越过同一排的相邻台,中间夹着的其他台原地不动,存储固化
    /// 下来的顺序因此就是电视上看到的样子,首页和资料库的其他台不会因为这一挪整排跳变。
    private func reorderRadioStation(
        id: String,
        within siblingIDs: [String]?,
        target: (_ index: Int, _ count: Int) -> Int
    ) {
        let storedIDs = Set(radioStore.allStations.lazy.filter { !$0.isDeleted }.map(\.id))
        let movable = radioStations.filter { storedIDs.contains($0.id) }
        let siblings = siblingIDs.map { Set($0) }
        // 同一排各台在 `movable` 里的下标,保持显示顺序。
        let row = movable.indices.filter { siblings?.contains(movable[$0].id) ?? true }
        guard let index = row.firstIndex(where: { movable[$0].id == id }) else { return }
        let goal = target(index, row.count)
        guard row.indices.contains(goal), goal != index else { return }
        // SwiftUI onMove 语义的目标下标:往后挪插到目标台之后,往前挪插到目标台之前。
        let destination = goal > index ? row[goal] + 1 : row[goal]
        radioStore.moveStations(
            from: IndexSet(integer: row[index]),
            to: destination,
            within: movable
        )
        reloadRadioStations(fromDisk: false)
    }

    private func markRadioPlayed(_ id: String) {
        // DEBUG 演示台和已经不在存储里的台不留痕:不写最近播放,也不重排。
        guard radioStore.station(id: id) != nil else { return }
        // 存储、UserDefaults 和内存列表用同一个时间值。重载时两边取较大值,值一致,
        // 随后电台存储观察回调的那次重载才会判定「没变」。
        let playedAt = Date().timeIntervalSince1970
        let now = Date(timeIntervalSince1970: playedAt)
        radioStore.markPlayed(id, at: now)
        var recency = UserDefaults.standard.dictionary(forKey: "tvRadioLastPlayedAt") ?? [:]
        recency[id] = playedAt
        UserDefaults.standard.set(recency, forKey: "tvRadioLastPlayedAt")
        guard let index = radioStations.firstIndex(where: { $0.id == id }) else { return }
        // 改副本、排一次、赋值一次:每赋值一次 didSet 就整份重建一次派生状态。
        var next = radioStations
        next[index].lastPlayedAt = now
        radioStations = RadioStationOrdering.sorted(next)
        // Top Shelf 的电台按最近播放排在前面。
        publishTopShelf()
    }

    private var activeCredentialSourceIDs: Set<String> {
        Set(sourcesStore.allSources.map(\.id))
    }

    private func pruneCredentialBundlesToActiveSources() {
        guard !hasPendingSnapshotRecovery, sourcesStore.hasCompleteSnapshot else { return }
        let activeSourceIDs = activeCredentialSourceIDs
        var paired: CredentialBundle?
        if let stored = TVCredentialStore.loadPairedBundle() {
            let pruned = CredentialBundlePolicy.pruning(stored, activeSourceIDs: activeSourceIDs)
            if pruned != stored
                || CredentialBundlePolicy.writeAction(for: pruned) == .deleteRecord {
                TVCredentialStore.savePairedBundle(pruned)
            }
            paired = pruned
        }
        if let current = credentialBundle {
            credentialBundle = CredentialBundlePolicy.pruning(
                current,
                activeSourceIDs: activeSourceIDs
            )
        } else {
            credentialBundle = paired
        }
    }

    @discardableResult
    private func mergeCredentialBundle(
        _ incoming: CredentialBundle,
        persistAsPaired: Bool
    ) -> Bool {
        let activeSourceIDs = activeCredentialSourceIDs
        let previous = credentialBundle ?? CredentialBundle()
        let provenanceKey = persistAsPaired ? "tv.credentialSources.paired" : "tv.credentialSources.cloud"
        let oldScope = Set(defaults.stringArray(forKey: provenanceKey) ?? [])
        var baseline = previous
        for sourceID in oldScope where incoming.entries[sourceID] == nil {
            baseline.entries.removeValue(forKey: sourceID)
        }
        baseline.relay = incoming.relay
        var persisted = true
        if persistAsPaired {
            var stored = TVCredentialStore.loadPairedBundle() ?? CredentialBundle()
            for sourceID in oldScope where incoming.entries[sourceID] == nil {
                stored.entries.removeValue(forKey: sourceID)
            }
            stored.relay = incoming.relay
            let paired = CredentialBundlePolicy.merging(
                current: stored,
                incoming: incoming,
                activeSourceIDs: activeSourceIDs
            )
            persisted = TVCredentialStore.savePairedBundle(paired)
        }
        guard persisted else { return false }
        let merged = CredentialBundlePolicy.merging(
            current: baseline,
            incoming: incoming,
            activeSourceIDs: activeSourceIDs
        )
        credentialBundle = merged
        defaults.set(Array(incoming.entries.keys), forKey: provenanceKey)
        scanner.invalidateFnMusicClients()
        for sourceID in activeSourceIDs where previous.entries[sourceID] != merged.entries[sourceID] {
            guard let source = sourcesStore.source(id: sourceID) else { continue }
            Task { await StreamResolverRegistry.shared.invalidateSession(for: source) }
        }
        return persisted
    }

    /// OAuth provider 成功刷新后先把轮换后的 token pair 落到本机，再异步窄化回写
    /// iCloud。CloudKit 不可用不会阻塞当前播放，下一次启动仍可用本地 Keychain 副本。
    private func persistRefreshedCloudCredential(
        sourceID: String,
        refresh: CloudCredentialRefresh
    ) {
        let shouldUseSynchronizableKeychain = cloudCredentialSourceIDs.contains(sourceID)
            || TVCredentialStore.hasSynchronizableOAuthCredential(sourceID: sourceID)
        let keychainPersisted = TVCredentialStore.saveOAuthRefresh(
            sourceID: sourceID,
            refresh: refresh,
            synchronizable: shouldUseSynchronizableKeychain
        )

        let current = credentialBundle
            ?? TVCredentialStore.loadPairedBundle()
            ?? CredentialBundle()
        let updated = CredentialBundlePolicy.pruning(
            CredentialBundlePolicy.refreshingOAuthCredential(
                sourceID: sourceID,
                credential: refresh.credential,
                in: current
            ),
            activeSourceIDs: activeCredentialSourceIDs
        )
        credentialBundle = updated
        let bundlePersisted = TVCredentialStore.savePairedBundle(updated)
        if !keychainPersisted || !bundlePersisted {
            plog("TVStore: refreshed OAuth credential kept in memory; durable persistence incomplete source=\(sourceID.prefix(8))…")
        }
        sourcesRevision &+= 1

        let credential = refresh.credential
        Task {
            await LibrarySnapshotSync.shared.updateRefreshedCredential(
                credential,
                forSourceID: sourceID
            )
        }
    }

    /// 生成 Top Shelf 展示数据(最近播放 + 电台 + 资料库专辑),后台预取封面并写入 App Group,
    /// 供 Apple TV 主屏「顶部内容展示」扩展读取。没配 App Group 时发布器自身会跳过。
    func publishTopShelf() {
        let recent: [TopShelfPublisher.Draft] = recentlyPlayed.prefix(8).map { s in
            let alb = albumOf(s)
            return .init(id: s.id, title: s.title, subtitle: s.artist, artist: s.artist,
                         album: alb?.title ?? "", coverKey: alb?.id ?? "",
                         songID: s.id, coverRef: s.coverRef,
                         playURL: Self.topShelfLink(host: "play", key: "song", s.id))
        }
        // 最近听过的台排前面,其余按电台页顺序补足。
        let playedStations = radioStations
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        let playedIDs = Set(playedStations.map(\.id))
        let stationList = playedStations + radioStations.filter { !playedIDs.contains($0.id) }
        let radio: [TopShelfPublisher.RadioDraft] = stationList.prefix(10).map { station in
            .init(station: station,
                  playURL: Self.topShelfLink(host: "radio", key: "id", station.id))
        }
        let albumList = recentlyAddedAlbums.isEmpty ? albums : recentlyAddedAlbums
        let lib: [TopShelfPublisher.Draft] = albumList.prefix(12).map { a in
            .init(id: a.id, title: a.title, subtitle: a.artist, artist: a.artist,
                  album: a.title, coverKey: a.id, songID: nil, coverRef: nil,
                  playURL: Self.topShelfLink(host: "album", key: "id", a.id))
        }
        // 镜像台的音乐源凭据不在这里预先解析:台标缓存没命中时发布器才回主线程要,
        // 这时去抖已过,冷启动时配对凭据包也已装好。
        let radioLogoSource: @MainActor @Sendable (String) -> TVRadioLogoSourceContext? = { [weak self] id in
            self?.radioLogoSourceContext(sourceID: id)
        }
        topShelfTask?.cancel()
        topShelfTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await TopShelfPublisher.publish(
                recent: recent,
                radio: radio,
                albums: lib,
                radioLogoSource: radioLogoSource
            )
        }
    }

    private static func topShelfLink(host: String, key: String, _ value: String) -> String {
        var c = URLComponents()
        c.scheme = "primuse"; c.host = host
        c.queryItems = [URLQueryItem(name: key, value: value)]
        return c.url?.absoluteString ?? "primuse://\(host)"
    }

    // MARK: 深链(主屏 Top Shelf 点击 → 播放)

    /// 曲库未就绪时暂存的深链,reload/bootstrap 完成后再执行。
    @ObservationIgnored private var pendingDeepLink: URL?
    /// 这次启动的电台列表已经到齐过(首轮同步结束,或这次启动不会同步)。
    /// 之后再来的电台深链找不到目标台,就不必再等。
    @ObservationIgnored private var hasSettledRadioList = false

    /// 处理 primuse:// 深链(主屏 Top Shelf 点击)。冷启动时曲库可能还没加载好,
    /// 先暂存,bootstrap/reload 完成后由 flushPendingDeepLink 执行。
    func handleDeepLink(_ url: URL) {
        pendingDeepLink = url
        flushPendingDeepLink(isFinalAttempt: hasSettledRadioList)
    }

    /// `isFinalAttempt`:电台列表已经到齐,这次仍找不到目标台就放弃并告诉用户。
    func flushPendingDeepLink(isFinalAttempt: Bool = false) {
        guard let url = pendingDeepLink, url.scheme == "primuse" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        // 电台不依赖曲库:只听电台的用户点主屏上的台也要能播。
        if url.host == "radio" {
            guard let id = q("id") else {
                pendingDeepLink = nil
                return
            }
            // 系统清掉缓存后电台是 CloudKit 一条条拉回来的,列表还不全时找不到很正常:
            // 链接留着,等下一次列表变化再找。只有找到了才消费它。
            guard let station = radioStations.first(where: { $0.id == id }) else {
                if isFinalAttempt {
                    pendingDeepLink = nil
                    playbackIssue = .failed(PMString("ext.tv.radio.deepLinkUnavailable"))
                }
                return
            }
            pendingDeepLink = nil
            play(station)
            return
        }
        guard hasRealLibrary else { return }
        pendingDeepLink = nil
        switch url.host {
        case "play":
            if let id = q("song"), let s = song(id) { play(s) }
        case "album":
            if let id = q("id"), let a = album(id) { play(album: a) }
        default:
            break
        }
    }

    /// 电台列表已经到齐(首轮同步结束,或这次启动根本不会同步)时,最后找一次挂着的
    /// 电台深链;仍找不到就放弃并说明,不让它一直挂着、几分钟后突然顶掉用户正在听的。
    func finishPendingRadioDeepLink() {
        hasSettledRadioList = true
        guard pendingDeepLink?.host == "radio" else { return }
        // 电台存储观察回调的那次重载可能还排在 yield 后面,先把刚拉下来的台并进列表。
        reloadRadioStations(fromDisk: false)
        flushPendingDeepLink(isFinalAttempt: true)
    }

    /// 隐藏「停用 / 已删除」音乐源的歌曲——资料库只显示有效源的内容。
    private func refreshVisibility() {
        let known = Set(sourcesStore.allSources.map(\.id))
        let orphaned = Set(library.songs.map(\.sourceID)).subtracting(known)
        // 电视端还解析不了的类型(如 Mac 本机资料库),它的歌同样不显示。
        let hidden = Set(sourcesStore.allSources.filter {
            $0.isDeleted || !$0.isEnabled || !StreamResolverRegistry.tvSupportedTypes.contains($0.type)
        }.map(\.id))
            .union(locallyRemovedSourceIDs).union(orphaned)
        library.updateDisabledSourceIDs(hidden)
        rebuildLookupCaches()
        publishTopShelf()
    }

    private func observeLibraryChanges() {
        withObservationTracking {
            _ = library.visibleSongCollectionRevision
            _ = library.songReplacementToken
            _ = library.albumArtworkLookupRevision
            _ = library.playlistCollectionRevision
            _ = sourcesStore.allSources
            _ = PlayHistoryStore.shared.entries
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLibraryChanges()
                guard self.libraryRefreshTask == nil else { return }
                self.libraryRefreshTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self else { return }
                    self.libraryRefreshTask = nil
                    self.refreshVisibility()
                    // 电台的可见性跟着音乐源的启用 / 删除走,源一变电台列表也要重算。
                    self.reloadRadioStations(fromDisk: false)
                }
            }
        }
    }

    /// 电台存储单独观察。CloudKit 拉回来的台、播放记录写回、别的入口的增删改都只需要
    /// 重算电台列表,不该带着整库 `refreshVisibility()` / `rebuildLookupCaches()` 再跑一遍
    /// (上千个镜像台时,原来每播一次台都要把整个曲库重新映射一遍)。
    private func observeRadioStoreChanges() {
        withObservationTracking {
            _ = radioStore.allStations
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeRadioStoreChanges()
                guard self.radioRefreshTask == nil else { return }
                self.radioRefreshTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self else { return }
                    self.radioRefreshTask = nil
                    self.reloadRadioStations(fromDisk: false)
                }
            }
        }
    }

    /// 重建 song(_:)/album(_:) 的单条查询索引。曲库可见集变化后调用一次,
    /// 之后单条查询为 O(1),不再每次访问都全量 map 整库。
    private func rebuildLookupCaches() {
        playCountsBySongID = Dictionary(grouping: PlayHistoryStore.shared.entries, by: \.songID).mapValues(\.count)
        let visibleSongs = library.visibleSongs
        // 有声内容不进音乐的曲库列表 / 首页 / 整库播放,但仍能按 id 查到 ——
        // 有声页、续播和队列都靠 song(_:) 取它。
        let spokenWordIDs = library.spokenWordSongIDs
        let allMapped = visibleSongs.map { self.map($0) }
        cachedSongs = spokenWordIDs.isEmpty
            ? allMapped
            : allMapped.filter { !spokenWordIDs.contains($0.id) }
        cachedSongIDs = cachedSongs.map(\.id)
        cachedAlbums = library.visibleAlbums.map { self.map($0) }
        cachedArtists = library.visibleArtists.map { self.map($0) }
        visibleSongCountsBySource = Dictionary(grouping: visibleSongs, by: \.sourceID)
            .mapValues(\.count)
        songByID = Dictionary(allMapped.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        albumByID = Dictionary(cachedAlbums.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        cachedAlbumIndexByID = Dictionary(
            cachedAlbums.indices.map { (cachedAlbums[$0].id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        libraryContentRevision &+= 1
        syncTrackNavigationCommands()
    }

    private func syncTrackNavigationCommands() {
        let availability = trackNavigationAvailability
        engine.setRemoteTrackCommandAvailability(
            previous: availability.canGoPrevious,
            next: availability.canGoNext
        )
    }

    /// The TV removal control is device-local; retain the source and its
    /// credential so restoring it does not require another pairing.
    func deleteSource(_ id: String) {
        guard canMutateLibrary else { return }
        cancelScan(sourceID: id)
        serverFeedback.cancel(sourceID: id)
        scanner.invalidateFnMusicClient(sourceID: id)
        locallyRemovedSourceIDs.insert(id)
        defaults.set(Array(locallyRemovedSourceIDs), forKey: "tv.removedSourceIDs")
        if currentSongID.flatMap({ library.song(id: $0)?.sourceID }) == id {
            pausePlayback()
        }
        refreshVisibility()
        sourcesRevision += 1
    }

    /// 在 Apple TV 上启用 / 停用音乐源。停用源的歌曲在资料库里是隐藏的,启用后即可
    /// 浏览 / 播放(快照含全量歌曲,显隐由各源的 enabled 状态决定)。
    func setSourceEnabled(_ id: String, _ enabled: Bool) {
        guard canMutateLibrary else { return }
        do {
            guard try sourcesStore.updateDurably(id, mutate: { $0.isEnabled = enabled }) else { return }
        } catch {
            playbackIssue = .failed(PMString("ext.tv.persistence.failed"))
            return
        }
        if !enabled {
            cancelScan(sourceID: id)
            serverFeedback.cancel(sourceID: id)
            if currentSongID.flatMap({ library.song(id: $0)?.sourceID }) == id { pausePlayback() }
        }
        refreshVisibility()
        sourcesRevision += 1
        let fromThis = library.songs.filter { $0.sourceID == id }.count
        let visibleFromThis = library.visibleSongs.filter { $0.sourceID == id }.count
        plog("🔀 TV setSourceEnabled \(id)→\(enabled); 该源歌曲 全量=\(fromThis) 可见=\(visibleFromThis); 总可见=\(library.visibleSongs.count)")
        enqueueSnapshotUpload()
    }

    // MARK: 源 CRUD(TV 本机新增 / 编辑 / 回收站;改后回传快照)

    /// 取底层 MusicSource(供编辑表单预填)。
    func source(id: String) -> MusicSource? { sourcesStore.source(id: id) }

    /// 「最近删除」的源(回收站),供恢复。
    var deletedSources: [TVSource] {
        _ = sourcesRevision
        return sourcesStore.allSources.filter { $0.isDeleted || locallyRemovedSourceIDs.contains($0.id) }
            .map { self.map($0) }
    }

    /// 只展示能由 Apple TV 自行建立曲库的来源。其余来源必须先在 iPhone / Mac
    /// 完成授权与扫描，再通过配对或同步传入完整曲库，不能保存成一个空来源冒充成功。
    /// 「在 Apple TV 上手动添加」能选的类型 —— 必须是电视端自己能建库的
    /// (`TVSourceLocalLibraryPolicy.directScanTypes`),否则加完只是个空壳。
    /// 网盘也在列:没有浏览器的设备改走提供方的扫码 / 设备码授权
    /// (`CloudDeviceAuthSupport`),或者像 123 云盘、Drime 那样直接填开发者密钥。
    static let addableTypes: [MusicSourceType] = [
        .smb, .synology, .qnap, .ugreen,
        .webdav, .ftp, .sftp, .nfs, .s3, .upnp,
        .jellyfin, .emby, .plex,
        .subsonic, .navidrome, .airsonic, .gonic,
        .fnMusic, .daoliyu, .songloft, .synologyAudioStation,
        .aliyunDrive, .baiduPan, .oneDrive, .dropbox,
        .googleDrive, .pan115, .pan123, .drime, .guangya,
    ]

    nonisolated static func canBuildLibraryOnTV(_ type: MusicSourceType) -> Bool {
        TVSourceLocalLibraryPolicy.capability(for: type) == .directScan
    }

    func prepareTransferSource() throws -> MusicSource {
        guard canMutateLibrary else { throw WiFiTransferError.unavailable }
        try FileManager.default.createDirectory(at: TVLocalTransferSource.root, withIntermediateDirectories: true)
        let localName = NSLocalizedString("root", tableName: "WiFiTransfer", bundle: .main,
                                          value: WiFiTransferPage.english["root"] ?? "Local music", comment: "")
        let source: MusicSource
        if let existing = sourcesStore.source(id: TVLocalTransferSource.sourceID), !existing.isDeleted {
            guard TVLocalTransferSource.isOwned(existing) else { throw WiFiTransferError.invalidPath }
            guard existing.isEnabled else { throw WiFiTransferError.unavailable }
            var current = existing
            current.basePath = TVLocalTransferSource.root.path
            if current.name == "local_import_source_name" { current.name = localName }
            if current.basePath != existing.basePath || current.name != existing.name {
                try sourcesStore.updateDurably(current.id) { $0.basePath = current.basePath; $0.name = current.name }
            }
            source = sourcesStore.source(id: existing.id) ?? current
        } else {
            var created = MusicSource(id: TVLocalTransferSource.sourceID,
                name: localName, type: .local,
                basePath: TVLocalTransferSource.root.path,
                extraConfig: MusicSource.encodeScannedDirectories(["/"], into: nil, type: .local))
            created.authType = .none
            try sourcesStore.addDurably(created)
            source = created
        }
        locallyRemovedSourceIDs.remove(source.id)
        locallyScannedSourceIDs.insert(source.id)
        defaults.set(Array(locallyRemovedSourceIDs), forKey: "tv.removedSourceIDs")
        defaults.set(Array(locallyScannedSourceIDs), forKey: "tv.scannedSourceIDs")
        afterSourceMutation()
        return source
    }

    func queueTransferScan(source: MusicSource, path: String, deleted: Bool) {
        if deleted {
            let ids = Set(library.songs.filter { $0.sourceID == source.id && $0.filePath == "/" + path }.map(\.id))
            removeTransferredSongsFromQueue(ids)
        }
        let url = URL(fileURLWithPath: "/" + path)
        if PrimuseConstants.readableLyricsExtensions.contains(url.pathExtension.lowercased()) {
            transferLyricsStems.insert(url.deletingPathExtension().path)
        }
        TVLocalTransferSource.markPendingScan(in: defaults)
        transferNeedsScan = true
        startTransferScan(sourceID: source.id)
    }

    func recoverReceivedMusicIfNeeded() {
        guard defaults.bool(forKey: "tv.transfer.pendingScan"),
              let source = sourcesStore.allSources.first(where: TVLocalTransferSource.isOwned),
              !source.isDeleted, source.isEnabled, !locallyRemovedSourceIDs.contains(source.id) else { return }
        transferNeedsScan = true
        // Interrupted sidecar updates may have lost their in-memory path list.
        transferLyricsStems.formUnion(library.songs.filter { $0.sourceID == source.id }.map {
            URL(fileURLWithPath: $0.filePath).deletingPathExtension().path
        })
        startTransferScan(sourceID: source.id)
    }

    private func startTransferScan(sourceID: String) {
        guard transferScanTask == nil else { return }
        transferScanError = nil
        transferIsIndexing = true
        transferScanTask = Task { @MainActor in
            defer { transferScanTask = nil; transferIsIndexing = false }
            while transferNeedsScan && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                _ = await syncTask?.value
                guard await retryPendingSnapshotImport(), canMutateLibrary else { return }
                while activeScanSourceID != nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !Task.isCancelled, let source = sourcesStore.source(id: sourceID),
                      TVLocalTransferSource.isOwned(source), source.isEnabled, !source.isDeleted,
                      !locallyRemovedSourceIDs.contains(sourceID) else { return }
                transferNeedsScan = false
                let scanRevision = TVLocalTransferSource.scanRevision(in: defaults)
                let stems = transferLyricsStems
                transferLyricsStems.removeAll()
                let changed = library.songs.filter {
                    $0.sourceID == sourceID && stems.contains(URL(fileURLWithPath: $0.filePath).deletingPathExtension().path)
                }
                for song in changed {
                    _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id)
                    applyLyrics([], forSongID: song.id)
                }
                guard await runScan(source: source, lister: TVLocalDirectoryLister(), dirs: ["/"]) else {
                    transferScanError = "unavailable"
                    return
                }
                guard case .done = scanner.phase else { transferScanError = "unavailable"; return }
                if let id = currentSongID, changed.contains(where: { $0.id == id }),
                   let song = library.song(id: id), let requestID = activePlaybackRequestID {
                    coordinator.refreshTransferredLyrics(song: song, source: source, requestID: requestID)
                }
                if !transferNeedsScan {
                    TVLocalTransferSource.clearPendingScan(ifRevisionMatches: scanRevision, in: defaults)
                }
            }
        }
    }

    private func removeTransferredSongsFromQueue(_ ids: Set<String>) {
        guard !isLiveRadio, !ids.isEmpty else { return }
        let plan = QueueBatchRemovalPolicy.plan(queueSongIDs: queue, currentIndex: queueIndex,
                                               currentSongID: currentSongID, removingSongIDs: ids)
        guard plan.action != .unchanged else { return }
        let removedCurrent = currentSongID.map(ids.contains) ?? false
        let wasPlaying = engine.isPlaying || engine.status == .loading
        if removedCurrent {
            playbackTask?.cancel(); playbackTask = nil
            activePlaybackRequestID = nil
            coordinator.cancelAuxiliaryTasks()
            finishListeningSession()
            engine.stop()
            lyrics = []
            playbackIssue = nil
        }
        let retainedCanonical = canonicalQueue.indices.filter { !ids.contains(canonicalQueue[$0]) }
        let newCanonicalIndex = Dictionary(uniqueKeysWithValues: retainedCanonical.enumerated().map { ($0.element, $0.offset) })
        let oldOrder = queueCanonicalIndices
        queue = plan.retainedIndices.map { queue[$0] }
        canonicalQueue = retainedCanonical.map { canonicalQueue[$0] }
        queueCanonicalIndices = plan.retainedIndices.compactMap {
            oldOrder.indices.contains($0) ? newCanonicalIndex[oldOrder[$0]] : nil
        }
        if queueCanonicalIndices.count != queue.count {
            canonicalQueue = queue
            queueCanonicalIndices = Array(queue.indices)
        }
        switch plan.action {
        case .unchanged: break
        case .replaceQueue(let index): queueIndex = index
        case .playReplacement(let index):
            queueIndex = index
            if queue.indices.contains(index), let next = song(queue[index]) { startPlaying(next, autoPlay: wasPlaying) }
        case .stopAndClearQueue:
            leaveSpokenWordItem()
            queueIndex = 0
            nowPlaying = .none
            hasNowPlaying = false
        }
        refreshUpNext()
        if currentSongID == nil {
            let previous = playbackSessionTask
            let storage = sessionStore
            playbackSessionTask = Task.detached {
                await previous?.value
                try? storage.clear()
            }
        } else { persistPlaybackSession() }
    }

    /// TV 上新增源:写入 sources + 存本地凭据 + 回传快照。
    @discardableResult
    func addSource(
        _ source: MusicSource,
        password: String?,
        fnConnectAccessCode: String? = nil
    ) -> Bool {
        guard canMutateLibrary, Self.canBuildLibraryOnTV(source.type) else { return false }
        let previousCredential = TVCredentialStore.loadLocalCredential(sourceID: source.id)
        guard saveLocalCred(source, password, fnConnectAccessCode) else { return false }
        do {
            try sourcesStore.addDurably(source)
        } catch {
            _ = restoreLocalCredential(previousCredential, sourceID: source.id)
            return false
        }
        scanner.invalidateFnMusicClient(sourceID: source.id)
        afterSourceMutation()
        return true
    }

    /// TV 上编辑源连接参数:更新 + 失效旧会话 + 回传快照。
    @discardableResult
    func updateSource(
        _ source: MusicSource,
        password: String?,
        fnConnectAccessCode: String? = nil
    ) -> Bool {
        guard canMutateLibrary else { return false }
        let originalSource = sourcesStore.source(id: source.id)
        var source = source
        if let originalSource,
           Self.connectionIdentity(originalSource) != Self.connectionIdentity(source) {
            cancelScan(sourceID: source.id)
            source.lastScannedAt = nil
            source.songCount = 0
            source.extraConfig = MusicSource.encodeScannedDirectories([], into: source.extraConfig, type: source.type)
            source.scannedDirectoryDisplayNames = [:]
        }
        let previousCredential = TVCredentialStore.loadLocalCredential(sourceID: source.id)
        guard saveLocalCred(source, password, fnConnectAccessCode) else { return false }
        do {
            guard try sourcesStore.updateDurably(source.id, mutate: { $0 = source }) else {
                _ = restoreLocalCredential(previousCredential, sourceID: source.id)
                return false
            }
        } catch {
            _ = restoreLocalCredential(previousCredential, sourceID: source.id)
            return false
        }
        scanner.invalidateFnMusicClient(sourceID: source.id)
        serverFeedback.cancel(sourceID: source.id)
        if let originalSource,
           originalSource.authType != source.authType || originalSource.username != source.username {
            cancelScan(sourceID: source.id)
        }
        if let originalSource,
           Self.connectionIdentity(originalSource) != Self.connectionIdentity(source) {
            library.addSongs([], affectedSourceIDs: [source.id])
            library.persistNow()
            locallyScannedSourceIDs.remove(source.id)
            defaults.set(Array(locallyScannedSourceIDs), forKey: "tv.scannedSourceIDs")
        }
        if source.authType == .none {
            credentialBundle?.entries.removeValue(forKey: source.id)
            if var paired = TVCredentialStore.loadPairedBundle() {
                paired.entries.removeValue(forKey: source.id)
                _ = TVCredentialStore.savePairedBundle(paired)
            }
        }
        if let s = sourcesStore.source(id: source.id) {
            Task { await StreamResolverRegistry.shared.invalidateSession(for: s) }
        }
        afterSourceMutation()
        return true
    }

    /// 从回收站恢复软删除的源。
    func restoreSource(_ id: String) {
        guard canMutateLibrary else { return }
        scanner.invalidateFnMusicClient(sourceID: id)
        if locallyRemovedSourceIDs.remove(id) != nil {
            defaults.set(Array(locallyRemovedSourceIDs), forKey: "tv.removedSourceIDs")
            refreshVisibility()
            sourcesRevision += 1
        } else {
            do {
                guard try sourcesStore.restoreDurably(id: id) else { return }
                afterSourceMutation()
            } catch { playbackIssue = .failed(PMString("ext.tv.persistence.failed")) }
        }
    }

    private static func connectionIdentity(_ source: MusicSource) -> String {
        [source.type.rawValue, source.host ?? "", String(source.port ?? 0),
         source.basePath ?? "", source.shareName ?? "", String(source.useSsl)].joined(separator: "\u{0}")
    }

    private func saveLocalCred(
        _ source: MusicSource,
        _ password: String?,
        _ fnConnectAccessCode: String?
    ) -> Bool {
        if source.authType == .none {
            return TVCredentialStore.clearLocalCredential(sourceID: source.id)
        }
        let existing = TVCredentialStore.loadLocalCredential(sourceID: source.id)
        let resolved = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        let newPassword = password?.isEmpty == false ? password : nil
        let newAccessCode = fnConnectAccessCode?.isEmpty == false ? fnConnectAccessCode : nil
        let storedUsername = source.username ?? ""
        let previousUsername = existing?.username
            ?? sourcesStore.allSources.first(where: { $0.id == source.id })?.username
            ?? credentialBundle?.entries[source.id]?.username
            ?? ""
        let usernameChanged = previousUsername != storedUsername
        let accessCodeChanged = newAccessCode != nil && newAccessCode != existing?.accessCode
        guard newPassword != nil || usernameChanged || accessCodeChanged else { return true }
        return TVCredentialStore.saveLocalCredential(
            sourceID: source.id,
            username: storedUsername,
            password: newPassword ?? existing?.password ?? resolved.password ?? "",
            accessCode: newAccessCode ?? existing?.accessCode
        )
    }

    @discardableResult
    private func restoreLocalCredential(
        _ credential: (username: String, password: String, accessCode: String?)?,
        sourceID: String
    ) -> Bool {
        guard let credential else {
            return TVCredentialStore.clearLocalCredential(sourceID: sourceID)
        }
        return TVCredentialStore.replaceLocalCredential(
            sourceID: sourceID,
            username: credential.username,
            password: credential.password,
            accessCode: credential.accessCode
        )
    }

    private func afterSourceMutation() {
        refreshVisibility()
        sourcesRevision += 1
        enqueueSnapshotUpload()
    }

    // MARK: TV 本机扫描(SMB / Dropbox / OneDrive 选目录，服务端音乐源整库)

    /// 该源能否在 TV 上扫描。飞牛音乐不浏览文件夹，直接读取服务端完整曲库。
    func canScanOnTV(_ source: MusicSource) -> Bool {
        Self.tvScannableTypes.contains(source.type) || TVLocalTransferSource.isOwned(source)
    }

    /// 构造目录列举器(供选目录页浏览)。
    func makeLister(for source: MusicSource) -> TVDirectoryLister? {
        let cred = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        return scanner.makeLister(source: source, credential: cred)
    }

    /// 封面和歌词加载复用连接测试/扫描已建立的飞牛音乐会话。
    func fnMusicClient(for sourceID: String) -> FnMusicServiceClient? {
        guard let source = sourcesStore.source(id: sourceID), source.type == .fnMusic else {
            return nil
        }
        if let active = scanner.cachedFnMusicClient(sourceID: sourceID) {
            return active
        }
        let credential = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        return scanner.fnMusicClient(source: source, credential: credential)
    }

    /// 走查选中目录扫描,落库(addSongs 按确定性 id 去重合并)+ 持久化 + 记录已扫目录 + 回传源。
    @discardableResult
    func runScan(
        source: MusicSource,
        lister: TVDirectoryLister,
        dirs: [String],
        rereadMetadata: Bool = false
    ) async -> Bool {
        guard await retryPendingSnapshotImport() else { return false }
        guard canMutateLibrary, !locallyRemovedSourceIDs.contains(source.id), TVScanAdmissionPolicy.canStart(
            activeSourceID: activeScanSourceID,
            requestedSourceID: source.id
        ) else {
            return false
        }
        activeScanSourceID = source.id
        let generation = UUID()
        scanGeneration = generation
        let task = Task {
            await self.performScan(source: source, lister: lister, dirs: dirs,
                                   rereadMetadata: rereadMetadata, generation: generation)
        }
        scanTask = task
        let committed = await task.value
        if scanGeneration == generation {
            scanTask = nil
            activeScanSourceID = nil
            if !committed, scanner.phase == .scanning { scanner.phase = .idle }
        }
        return true
    }

    func cancelScan(sourceID: String) {
        guard activeScanSourceID == sourceID else { return }
        scanTask?.cancel()
    }

    private func flushScanBatch(sourceID: String) async throws {
        guard !pendingScanSongs.isEmpty else { return }
        let batch = pendingScanSongs
        pendingScanSongs = []
        var replacements: [String: String] = [:]
        for song in batch {
            let key = Self.scanFileIdentity(song)
            if let old = scanExistingIDsByFile[key], old != song.id,
               library.song(id: old) != nil {
                replacements[old] = song.id
            }
            scanExistingIDsByFile[key] = song.id
        }
        applySongIDReplacements(replacements)
        library.addSongs(batch, affectedSourceIDs: nil, notifyRemovals: false, pruneMissingSongs: false)
        guard case .success = await library.persistIncrementalNowAndWait() else {
            throw CocoaError(.fileWriteUnknown)
        }
        locallyScannedSourceIDs.insert(sourceID)
        defaults.set(Array(locallyScannedSourceIDs), forKey: "tv.scannedSourceIDs")
        await library.waitForPendingIndex()
        refreshVisibility()
        lastScanFlush = Date()
    }

    private func acceptScanBatch(_ songs: [Song], sourceID: String, generation: UUID) async throws {
        guard scanGeneration == generation, !locallyRemovedSourceIDs.contains(sourceID),
              sourcesStore.source(id: sourceID)?.isDeleted == false else { throw CancellationError() }
        pendingScanSongs.append(contentsOf: songs)
        if pendingScanSongs.count >= 200 || Date().timeIntervalSince(lastScanFlush) >= 1.5 {
            try await flushScanBatch(sourceID: sourceID)
        }
    }

    private func performScan(source: MusicSource, lister: TVDirectoryLister, dirs: [String],
                             rereadMetadata: Bool, generation: UUID) async -> Bool {
        pendingScanSongs = []
        scanExistingIDsByFile = Dictionary(
            library.songs.filter { $0.sourceID == source.id }.map { (Self.scanFileIdentity($0), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        lastScanFlush = .distantPast
        let cred = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        let checkpointURL = sessionStore.url.deletingLastPathComponent()
            .appendingPathComponent("scan-checkpoints", isDirectory: true)
            .appendingPathComponent(TVScanPipelinePolicy.hash32(source.id) + ".json")
        let roots = TVScanPipelinePolicy.normalizedScanRoots(dirs)
        let connection = Self.connectionIdentity(source)
        let saved = (try? Data(contentsOf: checkpointURL)).flatMap {
            try? JSONDecoder().decode(ScanCheckpoint.self, from: $0)
        }
        let checkpointModifiedAt = try? checkpointURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let resumeState = saved.flatMap {
            $0.connectionIdentity == connection && $0.roots == roots && $0.state.isUsable
                && Self.canResumeScanCheckpoint(lastScannedAt: source.lastScannedAt,
                                                checkpointModifiedAt: checkpointModifiedAt)
                ? $0.state : nil
        }
        let saveCheckpoint: TVScanCheckpointHandler = { state in
            // Do not turn every 20-row scanner publication into a complete
            // library reindex. Only advance the checkpoint past durable rows.
            guard self.pendingScanSongs.isEmpty || state.pendingDirectories.isEmpty else { return }
            try await self.flushScanBatch(sourceID: source.id)
            try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let checkpoint = ScanCheckpoint(connectionIdentity: connection, roots: roots, state: state)
            try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
        }
        let result = await scanner.scan(
            source: source,
            lister: lister,
            dirs: dirs,
            credential: cred,
            existingSongs: library.songs.filter { $0.sourceID == source.id },
            rereadMetadata: rereadMetadata,
            resumeState: rereadMetadata ? nil : resumeState,
            onCheckpoint: rereadMetadata ? nil : saveCheckpoint,
            onSkeletonBatch: { songs in
                try await self.acceptScanBatch(songs, sourceID: source.id, generation: generation)
            },
            onMetadataBatch: { songs in
                try await self.acceptScanBatch(songs, sourceID: source.id, generation: generation)
            }
        )
        var pruningRecovery: MusicLibrary.ScanPruningRecovery?
        do {
            // A cancelled scan still commits the discovery batches already
            // accepted by the store, but never prunes or announces completion.
            try await Task { try await self.flushScanBatch(sourceID: source.id) }.value
            guard isCurrentScan(source: source, generation: generation), result.canCommit else { return false }
            // A walk that saw the catalogue move keeps what it read (the batches
            // above) but cannot vouch for songs it never listed.
            if result.canPrune {
                pruningRecovery = library.beginScanPruning(result.songs, sourceID: source.id)
            }
            let persistence = await scanPersistence(library)
            guard isCurrentScan(source: source, generation: generation) else { throw CancellationError() }
            guard case .success = persistence else { throw CocoaError(.fileWriteUnknown) }
            await library.waitForPendingIndex()
            guard isCurrentScan(source: source, generation: generation) else { throw CancellationError() }
            let count = library.songs.lazy.filter { $0.sourceID == source.id }.count
            if source.type != .fnMusic && source.type != .daoliyu && source.type != .songloft
                && source.type != .synologyAudioStation {
                try sourcesStore.updateDurably(source.id) {
                    $0.songCount = count
                    $0.lastScannedAt = Date()
                    $0.extraConfig = MusicSource.encodeScannedDirectories(dirs, into: $0.extraConfig, type: $0.type)
                }
            } else {
                try sourcesStore.updateLocalDurably(source.id) {
                    $0.songCount = count
                    $0.lastScannedAt = Date()
                }
            }
            if let pruningRecovery { library.finishScanPruning(pruningRecovery) }
            pruningRecovery = nil
            if source.type != .fnMusic && source.type != .daoliyu && source.type != .songloft
                && source.type != .synologyAudioStation {
                library.updateAutomaticArtistArtworkCatalog(
                    SourceArtistArtworkCatalog(sourceID: source.id, index: result.resumeState.index)
                )
            }
            refreshVisibility()
            library.sourceSyncDidComplete()
            sourcesRevision += 1
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                try? FileManager.default.removeItem(at: checkpointURL)
            }
            scanner.markPersistedScanComplete()
            if source.type == .fnMusic {
                await syncFnMusicLibrary(source: source, credential: cred, generation: generation)
                guard isCurrentScan(source: source, generation: generation) else { return false }
            } else if TVSourceScanner.serverPlaylistTypes.contains(source.type) {
                await syncServerLibrary(source: source, credential: cred, generation: generation)
                guard isCurrentScan(source: source, generation: generation) else { return false }
            }
            enqueueSnapshotUpload()
            return true
        } catch {
            if let pruningRecovery,
               let current = sourcesStore.source(id: source.id), !current.isDeleted,
               Self.connectionIdentity(current) == connection {
                library.rollbackScanPruning(pruningRecovery)
                let restored = await Task { await self.library.persistNowAndWait() }.value
                await library.waitForPendingIndex()
                refreshVisibility()
                guard case .success = restored else {
                    scanner.phase = .failed(PMString("ext.tv.persistence.failed"))
                    return false
                }
            }
            scanner.phase = error is CancellationError ? .idle : .failed(PMString("ext.tv.persistence.failed"))
            return false
        }
    }

    /// 把 Navidrome、Jellyfin 这类服务器上的自建歌单与「喜欢」标记同步下来。
    /// 与 iPhone、Mac 用同一份 `ServerPlaylistMirror`:歌单 ID 由 sourceID 派生,
    /// 每次扫描后以服务端内容为准覆盖,电视这边的改动不回写服务端。
    private func syncServerLibrary(
        source: MusicSource,
        credential: SourceCredential?,
        generation: UUID
    ) async {
        do {
            guard let snapshot = try await scanner.fetchServerPlaylists(
                source: source, credential: credential
            ) else { return }
            guard isCurrentScan(source: source, generation: generation) else { return }
            _ = ServerPlaylistMirror.apply(snapshot: snapshot, source: source, library: library)
        } catch {
            if OperationCancellationPolicy.isCancellation(error) { return }
            // 歌单镜像是扫描的附加步骤,失败不能把已经成功的扫描算作失败。
            plog("Server playlist sync failed for '\(source.name)': \(error.localizedDescription)")
        }

        guard isCurrentScan(source: source, generation: generation),
              let revision = serverFeedback.favoriteRefreshRevision(sourceID: source.id) else { return }
        do {
            guard let itemIDs = try await scanner.fetchServerFavorites(
                source: source, credential: credential
            ) else { return }
            guard isCurrentScan(source: source, generation: generation),
                  serverFeedback.favoriteRefreshRevision(sourceID: source.id) == revision else { return }
            let favorites = Set(itemIDs)
            let songIDs = library.songs.filter {
                $0.sourceID == source.id && ServerFavoriteWritebackPolicy.songID(
                    fromConnectorPath: $0.filePath, sourceType: source.type
                ).map(favorites.contains) == true
            }.map(\.id)
            library.replaceLikedSongs(fromSourceID: source.id, with: songIDs)
        } catch {
            if OperationCancellationPolicy.isCancellation(error) { return }
            plog("Server favorite sync failed for '\(source.name)': \(error.localizedDescription)")
        }
    }

    private func syncFnMusicLibrary(source: MusicSource, credential: SourceCredential?, generation: UUID) async {
        do {
            let snapshot = try await scanner.fetchFnMusicPlaylists(source: source, credential: credential)
            guard isCurrentScan(source: source, generation: generation) else { return }
            _ = ServerPlaylistMirror.apply(
                snapshot: ServerPlaylistSnapshot(
                    playlists: snapshot.playlists.map {
                        ServerPlaylist(id: $0.id, name: $0.name, coverArtReference: $0.coverReference,
                                       trackIDs: $0.trackIDs, reportedTrackCount: $0.trackIDs.count)
                    }, failedPlaylistIDs: snapshot.failedPlaylistIDs
                ), source: source, library: library
            )
        } catch {
            if OperationCancellationPolicy.isCancellation(error) { return }
            plog("Server playlist sync failed for '\(source.name)': \(error.localizedDescription)")
        }
        guard isCurrentScan(source: source, generation: generation),
              let revision = serverFeedback.favoriteRefreshRevision(sourceID: source.id) else { return }
        do {
            let itemIDs = try await scanner.fetchFnMusicFavorites(source: source, credential: credential)
            guard isCurrentScan(source: source, generation: generation),
                  serverFeedback.favoriteRefreshRevision(sourceID: source.id) == revision else { return }
            let favorites = Set(itemIDs)
            let songIDs = library.songs.filter {
                $0.sourceID == source.id && ServerFavoriteWritebackPolicy.songID(
                    fromConnectorPath: $0.filePath, sourceType: .fnMusic
                ).map(favorites.contains) == true
            }.map(\.id)
            library.replaceLikedSongs(fromSourceID: source.id, with: songIDs)
        } catch {
            if OperationCancellationPolicy.isCancellation(error) { return }
            plog("Server favorite sync failed for '\(source.name)': \(error.localizedDescription)")
        }
    }

    private func isCurrentScan(source: MusicSource, generation: UUID) -> Bool {
        guard scanGeneration == generation, !Task.isCancelled,
              !locallyRemovedSourceIDs.contains(source.id),
              let current = sourcesStore.source(id: source.id), current.isEnabled, !current.isDeleted else { return false }
        return Self.connectionIdentity(current) == Self.connectionIdentity(source)
            && current.authType == source.authType && current.username == source.username
    }

    nonisolated static func canResumeScanCheckpoint(lastScannedAt: Date?, checkpointModifiedAt: Date?) -> Bool {
        guard let checkpointModifiedAt else { return false }
        // Sources JSON loses subsecond precision. Treat an ambiguous same-
        // second checkpoint as stale: re-enumeration is safer than skipping
        // new files after cleanup of a completed checkpoint failed.
        return (lastScannedAt ?? .distantPast).timeIntervalSince1970.rounded(.down)
            < checkpointModifiedAt.timeIntervalSince1970.rounded(.down)
    }

    /// 飞牛音乐没有目录选择步骤，直接从服务端分页读取完整曲库。
    @discardableResult
/// 重新读取全部音乐源的标签:按顺序逐个源重扫已选目录(没选过目录的从根开始),
    /// 服务端型的源直接刷新服务端曲库。扫描器一次只允许一个源,所以这里串行等待。
    func rereadAllTags() {
        guard rereadAllTagsTask == nil else { return }
        let targets = sourcesStore.allSources.filter {
            !$0.isDeleted
                && $0.isEnabled
                && canScanOnTV($0)
                && !locallyRemovedSourceIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return }
        rereadAllTagsProgress = TVRereadAllTagsProgress(
            index: 0,
            total: targets.count,
            sourceName: targets[0].name
        )
        rereadAllTagsTask = Task { [weak self] in
            defer {
                self?.rereadAllTagsTask = nil
                self?.rereadAllTagsProgress = nil
            }
            for (offset, source) in targets.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.rereadAllTagsProgress = TVRereadAllTagsProgress(
                    index: offset + 1,
                    total: targets.count,
                    sourceName: source.name
                )
                if TVSourceScanner.serverCatalogTypes.contains(source.type) {
                    _ = await self.runServerCatalogScan(source: source, rereadMetadata: true)
                } else if let lister = self.makeLister(for: source) {
                    let dirs = source.scannedDirectories.isEmpty ? ["/"] : source.scannedDirectories
                    _ = await self.runScan(
                        source: source,
                        lister: lister,
                        dirs: dirs,
                        rereadMetadata: true
                    )
                }
            }
        }
    }

    func cancelRereadAllTags() {
        if let active = activeScanSourceID { cancelScan(sourceID: active) }
        rereadAllTagsTask?.cancel()
        rereadAllTagsTask = nil
        rereadAllTagsProgress = nil
    }

    /// 整库型来源(飞牛 / 刀里鱼 / Songloft / 媒体服务器 / Subsonic 系)的扫描:
    /// 没有目录可选,dirs 传空,由扫描器整体拉取服务端曲库。
    func runServerCatalogScan(source: MusicSource, rereadMetadata: Bool = false) async -> Bool {
        guard TVScanAdmissionPolicy.canStart(
            activeSourceID: activeScanSourceID,
            requestedSourceID: source.id
        ) else {
            return false
        }
        guard TVSourceScanner.serverCatalogTypes.contains(source.type),
              let lister = makeLister(for: source) else {
            scanner.phase = .failed(PMString("ext.tv.scan.connectFailed"))
            return true
        }
        return await runScan(source: source, lister: lister, dirs: [], rereadMetadata: rereadMetadata)
    }

    /// 串行化 sources 上传:快速连续改源时,前一个上传跑完再发下一个,
    /// 避免两个 detached 任务交错改写同一条 CloudKit 记录。
    /// 只走 `uploadSourcesOnly()` —— 仅覆盖服务器记录的 sources 字段,绝不回传 tvOS 本机
    /// 那份启动时下载的旧 library 副本(否则会回退手机端新扫描的曲库)。
    private func enqueueSnapshotUpload(removingCredentialFor sourceID: String? = nil) {
        defaults.set(UUID().uuidString, forKey: "tv.pendingSourceUpload")
        resumePendingSourceUpload()
    }

    private func resumePendingSourceUpload() {
        guard !hasPendingSnapshotRecovery, sourcesStore.hasCompleteSnapshot else { return }
        // 总开关关掉时不往云端回传。`tv.pendingSourceUpload` 标记原样留着,用户
        // 重新打开同步后的下一次引导会把它补发出去。
        guard CloudSyncChannel.isMasterEnabled(defaults: defaults) else { return }
        guard pendingUpload == nil, defaults.string(forKey: "tv.pendingSourceUpload") != nil else { return }
        pendingUpload = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingUpload = nil }
            for attempt in 0..<6 {
                guard !Task.isCancelled,
                      let generation = self.defaults.string(forKey: "tv.pendingSourceUpload") else { return }
                if await LibrarySnapshotSync.shared.uploadSourcesOnly() {
                    if self.defaults.string(forKey: "tv.pendingSourceUpload") == generation {
                        self.defaults.removeObject(forKey: "tv.pendingSourceUpload")
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(min(120, pow(2, Double(attempt)) * 2))) }
                catch { return }
            }
        }
    }

    // MARK: 歌词

    var lyricsFollowPlayback: Bool {
        LyricPlaybackPositionPolicy.shouldFollowPlayback(
            in: lyrics,
            isSynchronized: \.isSynchronized
        )
    }

    /// 当前播放时间所在的歌词行索引。纯文本歌词没有时间轴，不参与自动跟随。
    var currentLyricIndex: Int? {
        guard lyricsFollowPlayback else { return nil }
        // 与逐字扫光取同一个时钟。扫光已经按帧外推,行号若仍吃 0.25 秒一跳的原始值,
        // 会出现「这一行的字都填满了、高亮行还没换」的错位。
        return LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: interpolatedTime(),
            lookahead: 0.25,
            timestamp: \.time
        )
    }
    // MARK: 播放控制(AVPlayer 流式播放,真实流 URL 由 TVPlaybackCoordinator 解析)

    func togglePlayPause() {
        if isLiveRadio {
            if engine.status == .playing || engine.status == .loading {
                pausePlayback()
            } else {
                resumePlayback()
            }
            return
        }
        if engine.isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    private func pausePlayback() {
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        if isLiveRadio {
            playbackTask?.cancel()
            playbackTask = nil
            activePlaybackRequestID = nil
            if engine.status == .loading {
                engine.stop()
            } else {
                engine.pause()
            }
            return
        }
        engine.pause()
    }

    private func resumePlayback() {
        guard !hasPendingSnapshotRecovery else { return }
        if isLiveRadio {
            radioReconnectTask?.cancel()
            radioReconnectTask = nil
            guard let station = currentRadioStation else { return }
            playbackTask?.cancel()
            let requestID = UUID()
            activePlaybackRequestID = requestID
            playbackIssue = nil
            engine.prepareForSelection(startAt: 0)
            beginRadioResolution(station, requestID: requestID, forceRefresh: false)
            return
        }

        guard engine.status != .loading else { return }
        guard let id = currentSongID, let currentSong = song(id) else {
            engine.play()
            return
        }
        let isAtTrackEnd = duration > 0 && currentTime >= max(0, duration - 0.5)
        let needsRecovery: Bool
        if case .failed = engine.status {
            needsRecovery = true
        } else {
            needsRecovery = false
        }
        let action = LocalPlaybackResumePolicy.action(
            isAtTrackEnd: isAtTrackEnd,
            needsRecovery: needsRecovery,
            hasPreparedAudio: engine.hasPreparedAudio
        )
        switch action {
        case .resumePreparedAudio:
            if !engine.play() {
                startPlaying(currentSong, resumeTime: currentTime)
            }
        case .recoverFromInterruption:
            startPlaying(currentSong, resumeTime: currentTime)
        case .restartCurrentSong:
            startPlaying(currentSong, resumeTime: isAtTrackEnd ? 0 : currentTime)
        }
    }
    func seek(toFraction f: Double) {
        guard !isLiveRadio else { return }
        engine.seekToFraction(f)
    }
    func skipForward() {
        guard !isLiveRadio else { return }
        engine.skip(by: 10)
    }
    func skipBackward() {
        guard !isLiveRadio else { return }
        engine.skip(by: -10)
    }

    /// 把一本有声书按章节顺序作为队列播放,从 `itemID`(缺省为续听的那一章)开始。
    /// 听完的一章被重新点播时从头开始。队列不随机:章节必须按顺序听。
    @discardableResult
    func playSpokenWordBook(songIDs: [String], startingAt itemID: String?) -> Bool {
        guard let first = songIDs.first else { return false }
        let startID = itemID.flatMap { songIDs.contains($0) ? $0 : nil } ?? first
        if SpokenWordStore.shared.isFinished(songID: startID) {
            SpokenWordStore.shared.markFinished(false, songIDs: [startID])
        }
        return playResolvedQueue(songIDs: songIDs, shuffled: false, startingAt: startID)
    }

    /// 正在播放页的「上一个」键:有声内容后退 15 秒,其余照旧上一首 / 上一台。
    func transportBackward(restartCurrentIfNeeded: Bool = true) {
        if currentItemIsSpokenWord, !isLiveRadio {
            skipSpokenWord(by: -SpokenWordSkipPolicy.backwardInterval)
        } else {
            previous(restartCurrentIfNeeded: restartCurrentIfNeeded)
        }
    }

    /// 正在播放页的「下一个」键:有声内容前进 30 秒,其余照旧下一首 / 下一台。
    func transportForward() {
        if currentItemIsSpokenWord, !isLiveRadio {
            skipSpokenWord(by: SpokenWordSkipPolicy.forwardInterval)
        } else {
            next()
        }
    }

    private func skipSpokenWord(by offset: Double) {
        guard hasNowPlaying, !isLiveRadio else { return }
        let target = SpokenWordSkipPolicy.position(
            from: currentTime,
            offset: offset,
            duration: duration
        )
        // 手动跳过就是这一条的新位置,不必再等续播定位。
        pendingSpokenWordResume = nil
        engine.seek(to: target)
        rememberSpokenWordPosition(force: true)
    }

    /// 有声内容开播的起点:请求里没指定(不是断点恢复 / 切画面)时,用这一条记住的位置。
    private func spokenWordStartTime(for song: TVSong, requested: Double, isRecovery: Bool) -> Double {
        let isSpokenWord = library.spokenWordSongIDs.contains(song.id)
        currentItemIsSpokenWord = isSpokenWord
        spokenWordPositionArmed = false
        pendingSpokenWordResume = nil
        lastSpokenWordPositionSave = 0
        guard isSpokenWord else { return requested }
        guard requested <= 0, !isRecovery,
              let raw = library.song(id: song.id),
              let stored = SpokenWordStore.shared.resumePosition(for: raw) else {
            return requested
        }
        plog("🎧 TV spoken word: resuming '\(song.title)' at \(Int(stored))s")
        pendingSpokenWordResume = (song.id, stored)
        return stored
    }

    /// 离开有声内容去播电台 / 目录歌曲 / 清空队列:先记下位置,再撤掉有声状态。
    private func leaveSpokenWordItem() {
        rememberSpokenWordPosition(force: true)
        currentItemIsSpokenWord = false
        spokenWordPositionArmed = false
        pendingSpokenWordResume = nil
    }

    /// 真正出声后才允许写位置;引擎若没按起点开播(时钟还在开头),这时补一次定位。
    private func armSpokenWordPositionIfNeeded() {
        guard currentItemIsSpokenWord, !spokenWordPositionArmed else { return }
        if let pending = pendingSpokenWordResume {
            pendingSpokenWordResume = nil
            if pending.songID == nowPlaying.songID,
               engine.currentTime < 2, pending.position > 2 {
                engine.seek(to: pending.position)
            }
        }
        spokenWordPositionArmed = true
        lastSpokenWordPositionSave = engine.currentTime
    }

    /// 记下有声内容听到哪里。`force` 用于暂停、停止、换条、跳过和退到后台;
    /// 其余时候按 15 秒间隔写。
    private func rememberSpokenWordPosition(force: Bool = false) {
        guard currentItemIsSpokenWord, spokenWordPositionArmed, hasNowPlaying, !isLiveRadio else { return }
        let songID = nowPlaying.songID
        guard !songID.isEmpty else { return }
        let position = engine.currentTime
        guard position.isFinite else { return }
        if !force {
            guard abs(position - lastSpokenWordPositionSave) >= SpokenWordProgressPolicy.autosaveInterval else {
                return
            }
        }
        lastSpokenWordPositionSave = position
        SpokenWordStore.shared.rememberPosition(
            position,
            duration: duration > 0 ? duration : nowPlaying.duration,
            forSongID: songID
        )
    }

    /// 用户选台(卡片、Top Shelf 深链)。上一台 / 下一台走 `switchRadioStation`。
    func play(_ station: RadioStation) {
        // 用户自己开始播放了,还挂着的深链就作废,免得它之后补执行把这次播放顶掉。
        pendingDeepLink = nil
        startRadioSelection(station, recordsNavigationOrder: true, resolutionCompletion: nil)
    }

    func playRadioFromIntent(_ station: RadioStation) async -> Bool {
        pendingDeepLink = nil
        return await withCheckedContinuation { continuation in
            startRadioSelection(station, recordsNavigationOrder: true) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }

    /// 上一台 / 下一台(`step` 为 1 / -1,首尾相接):沿用用户选台时记下的顺序,
    /// 找不到可用的相邻台就不动。
    private func switchRadioStation(by step: Int) {
        guard let currentRadioStationID else { return }
        let byID = Dictionary(
            radioStations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // 快照里已经不在列表里的台(被删、源被停用)跳过;快照用不上时退回实时列表。
        var order = radioNavigationOrder.filter { byID[$0] != nil }
        if order.count < 2 || !order.contains(currentRadioStationID) {
            order = radioStations.map(\.id)
        }
        guard order.count > 1,
              let index = order.firstIndex(of: currentRadioStationID),
              let station = byID[order[(index + step + order.count) % order.count]] else { return }
        startRadioSelection(station, recordsNavigationOrder: false, resolutionCompletion: nil)
    }

    private func startRadioSelection(
        _ station: RadioStation,
        recordsNavigationOrder: Bool,
        resolutionCompletion: ((Bool) -> Void)?
    ) {
        guard !hasPendingSnapshotRecovery,
              RadioStationValidation.hasConsistentServerIdentity(station),
              RadioStationValidation.hasValidPlaybackReference(station) else {
            resolutionCompletion?(false)
            return
        }
        // 必须在 `markRadioPlayed` 之前记:它会把这个台按最近播放排到最前。
        if recordsNavigationOrder {
            radioNavigationOrder = radioStations.map(\.id)
        }
        leaveSpokenWordItem()
        finishListeningSession()
        persistPlaybackSession()
        playbackRestoreAttempted = true
        coordinator.cancelAuxiliaryTasks()
        playbackTask?.cancel()
        let requestID = UUID()
        activePlaybackRequestID = requestID
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        radioReconnectAttempt = 0
        playbackIssue = nil
        queue = []
        canonicalQueue = []
        queueCanonicalIndices = []
        queueIndex = 0
        queueUpNextIDs = []
        lyrics = []
        isMusicVideoModeEnabled = false
        isLiveRadio = true
        currentRadioStationID = station.id
        radioMetadataTitle = ""
        engine.prepareForSelection(startAt: 0)

        let fallback = nowPlayingPresentationColors
        nowPlaying = TVNowPlaying(
            songID: "radio:\(station.id)",
            coverRef: nil,
            title: station.name,
            artist: station.tvPlaybackSubtitle,
            album: "",
            albumID: "",
            tint: fallback.primary,
            tint2: fallback.secondary,
            glyph: "radio",
            duration: 0,
            currentTime: 0,
            format: station.streamFormat.displayName,
            bitrate: (station.bitRate ?? 0) / 1_000,
            sampleRate: 0,
            sourcePath: station.sourcePlaybackPath ?? station.streamURL
        )
        updateAutomaticThemePalette(nil)
        hasNowPlaying = true
        markRadioPlayed(station.id)
        beginRadioResolution(
            station,
            requestID: requestID,
            forceRefresh: false,
            resolutionCompletion: resolutionCompletion
        )
    }

    private func beginRadioResolution(
        _ station: RadioStation,
        requestID: UUID,
        forceRefresh: Bool,
        resolutionCompletion: ((Bool) -> Void)? = nil
    ) {
        playbackTask = Task { @MainActor [weak self] in
            guard let self else {
                resolutionCompletion?(false)
                return
            }
            do {
                let url = try await self.coordinator.resolveRadioStream(
                    for: station,
                    requestID: requestID,
                    forceRefresh: forceRefresh
                )
                guard self.isCurrentPlaybackRequest(
                    requestID,
                    isCancelled: Task.isCancelled
                ), self.currentRadioStationID == station.id else {
                    resolutionCompletion?(false)
                    return
                }
                self.playbackTask = nil
                self.engine.loadLiveRadio(
                    url: url.url,
                    headers: url.headers,
                    // 解析期间台可能被改了名,用列表里现在的名字。
                    title: self.currentRadioStation?.name ?? station.name,
                    subtitle: self.radioMetadataTitle.isEmpty
                        ? station.tvPlaybackSubtitle
                        : self.radioMetadataTitle,
                    format: station.streamFormat.displayName,
                    streamFormat: station.streamFormat,
                    isSourceBacked: station.requiresSourceStreamResolution
                )
                resolutionCompletion?(true)
            } catch is CancellationError {
                resolutionCompletion?(false)
                return
            } catch {
                guard self.isCurrentPlaybackRequest(
                    requestID,
                    isCancelled: Task.isCancelled
                ), self.currentRadioStationID == station.id else {
                    resolutionCompletion?(false)
                    return
                }
                self.playbackTask = nil
                self.engine.stop()
                self.playbackIssue = self.coordinator.radioPlaybackIssue(
                    for: error,
                    station: station
                )
                resolutionCompletion?(false)
            }
        }
    }

    /// 通用单曲入口(整库列表 / 搜索结果 / 首页歌曲卡片 / 推荐行):
    /// 队列取当前可见曲库顺序,从该曲开始续播,而不是切换到该曲所属专辑。
    func play(_ song: TVSong) {
        pendingDeepLink = nil
        guard !hasPendingSnapshotRecovery else { return }
        setQueueAround(song)
        startPlaying(song)
    }

    /// 明确列表内的单曲点击(艺人 / 专辑 / 文件夹 / 歌单 / 接收列表):
    /// 队列就是该列表本身与它的顺序,从点选曲开始,并沿用当前随机开关
    /// (点选一首歌不应该把随机播放悄悄关掉)。
    @discardableResult
    func play(_ song: TVSong, in songIDs: [String]) -> Bool {
        playResolvedQueue(songIDs: songIDs, shuffled: shuffleEnabled, startingAt: song.id)
    }

    /// Siri 等系统入口已经解析出确定的歌曲顺序时直接采用该队列，避免再按
    /// 单曲所属专辑重建随机队列而丢失语音请求的范围与顺序。
    @discardableResult
    func playResolvedQueue(songIDs: [String], shuffled: Bool, startingAt songID: String? = nil) -> Bool {
        // 专辑 / 歌单 / 全部播放 / Siri 都从这里进:用户自己开始播放,挂着的深链作废。
        pendingDeepLink = nil
        guard !hasPendingSnapshotRecovery else { return false }
        let resolved = songIDs.filter { song($0) != nil }
        guard !resolved.isEmpty else { return false }
        // 按 id 定位首个匹配项(与既有行为一致);随机时由 plan 把选中曲目放在队首。
        let plan = TVPlaybackQueuePolicy.plan(
            count: resolved.count,
            selectedIndex: songID.flatMap { resolved.firstIndex(of: $0) },
            shuffled: shuffled
        )
        canonicalQueue = resolved
        queueCanonicalIndices = plan.canonicalIndices
        queue = plan.canonicalIndices.map { resolved[$0] }
        queueIndex = plan.queueIndex
        guard let first = song(queue[queueIndex]) else { return false }
        shuffleEnabled = shuffled
        startPlaying(first)
        return true
    }

    func play(album: TVAlbum) {
        playResolvedQueue(songIDs: songs(forAlbum: album.id).map(\.id), shuffled: shuffleEnabled)
    }

    /// 播放歌单**自身**的曲目:用歌单全部歌曲建队列、从首曲开始,续播留在歌单内
    /// (而非退化为封面所属专辑或整库)。智能歌单使用与其他端相同的规则引擎。
    @discardableResult
    func play(playlist: TVPlaylist) -> Bool {
        let ids: [String]
        if playlist.kind == .smart {
            _ = smartPlaylists
            ids = smartPlaylistSongIDs[playlist.id] ?? []
        } else {
            ids = library.songs(forPlaylist: playlist.id).map(\.id)
        }
        return playResolvedQueue(songIDs: ids, shuffled: shuffleEnabled)
    }

    /// 全部播放 / 随机播放整个可见曲库(库多为散曲、没有真正专辑,所以播放范围用整库)。
    @discardableResult
    func playAll(shuffle: Bool) -> Bool {
        playResolvedQueue(songIDs: cachedSongIDs, shuffled: shuffle)
    }

    func next() {
        if isLiveRadio {
            switchRadioStation(by: 1)
            return
        }
        // 手动下一首:忽略「单曲循环」;到队尾时「列表循环」则回到队首。
        guard let nextIndex = QueueTraversalPolicy.nextAvailableIndex(
            queueCount: queue.count,
            after: queueIndex,
            wraps: repeatMode == .all,
            isAvailable: { song(queue[$0]) != nil }
        ), let nextSong = song(queue[nextIndex]) else { return }
        queueIndex = nextIndex
        startPlaying(nextSong)
    }

    /// 一曲自然播完后的推进:单曲循环重播本曲,否则等同手动下一首。
    private func advanceAfterEnd() {
        guard !isLiveRadio else {
            scheduleRadioReconnect()
            return
        }
        plog("🎬 TV advanceAfterEnd: queueIndex=\(queueIndex)/\(queue.count) repeat=\(repeatMode)")
        // 有声内容听到了结尾:记成听完,下次从这本书的下一章接着听。
        if currentItemIsSpokenWord, hasNowPlaying {
            SpokenWordStore.shared.markFinished(true, songIDs: [nowPlaying.songID])
            spokenWordPositionArmed = false
        }
        if repeatMode == .one, queue.indices.contains(queueIndex), let s = song(queue[queueIndex]) {
            startPlaying(s)
        } else {
            next()
        }
    }

    /// 点击「下一首」队列里的某首,直接跳到它播放。
    func playQueueItem(at upNextIndex: Int) {
        guard !isLiveRadio else { return }
        let abs = queueIndex + 1 + upNextIndex
        guard queue.indices.contains(abs), let s = song(queue[abs]) else { return }
        queueIndex = abs
        startPlaying(s)
    }

    func toggleShuffle() {
        guard !isLiveRadio else { return }
        shuffleEnabled.toggle()
        guard queueCanonicalIndices.indices.contains(queueIndex) else { return }
        if shuffleEnabled {
            let tailStart = queueIndex + 1
            if tailStart < queueCanonicalIndices.count {
                queueCanonicalIndices.replaceSubrange(tailStart..., with: queueCanonicalIndices[tailStart...].shuffled())
            }
        } else {
            // Store occurrence indices, not just IDs: playlists may contain the
            // same track more than once and must restore the selected occurrence.
            queueIndex = queueCanonicalIndices[queueIndex]
            queueCanonicalIndices = Array(canonicalQueue.indices)
        }
        queue = queueCanonicalIndices.map { canonicalQueue[$0] }
        refreshUpNext()
        persistPlaybackSession()
    }

    func cycleRepeatMode() {
        guard !isLiveRadio else { return }
        repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
        persistPlaybackSession()
    }

    func toggleMusicVideoMode() {
        guard canPlayMusicVideo else { return }
        let resumeTime = currentTime
        let shouldPlay = isPlaying
        isMusicVideoModeEnabled.toggle()
        guard let id = currentSongID, let song = song(id) else { return }
        startPlaying(song, resumeTime: resumeTime, autoPlay: shouldPlay)
    }

    /// 睡眠定时:关→15→30→60→关 分钟。到点停止播放。
    func cycleSleepTimer() {
        let presets = [0, 15, 30, 60]
        let cur = presets.firstIndex(of: sleepTimerMinutes) ?? 0
        sleepTimerMinutes = presets[(cur + 1) % presets.count]
        sleepWorkItem?.cancel()
        guard sleepTimerMinutes > 0 else { return }
        // 走 pausePlayback 而不是 engine.pause():电台要先断掉重连任务和
        // 解析任务,并在 .loading 阶段用 stop(),否则到点后又被拉起来接着播。
        let work = DispatchWorkItem { [weak self] in
            self?.pausePlayback()
            self?.sleepTimerMinutes = 0
        }
        sleepWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(sleepTimerMinutes) * 60, execute: work)
    }

    private func refreshUpNext() {
        guard queue.indices.contains(queueIndex),
              queueIndex + 1 < queue.count else {
            queueUpNextIDs = []
            return
        }
        queueUpNextIDs = Array(queue[(queueIndex + 1)...])
    }

    func previous(restartCurrentIfNeeded: Bool = true) {
        if isLiveRadio {
            switchRadioStation(by: -1)
            return
        }
        // 播过 3 秒先回到开头,否则切上一首。
        if restartCurrentIfNeeded, currentTime > 3 { engine.seek(to: 0); return }
        guard let previousIndex = QueueTraversalPolicy.previousAvailableIndex(
            before: queueIndex,
            isAvailable: { song(queue[$0]) != nil }
        ), let s = song(queue[previousIndex]) else { engine.seek(to: 0); return }
        queueIndex = previousIndex
        startPlaying(s)
    }

    /// 通用单曲入口的队列范围:当前可见曲库顺序(专辑范围只留给显式的专辑播放),
    /// 曲库里找不到这首(例如刚接收、尚未可见)时退化为单曲队列,避免队列与实际播放不一致。
    private func setQueueAround(_ song: TVSong) {
        let selected = cachedSongIDs.firstIndex(of: song.id)
        let scope = selected == nil ? [song.id] : cachedSongIDs
        let plan = TVPlaybackQueuePolicy.plan(
            count: scope.count,
            selectedIndex: selected,
            shuffled: shuffleEnabled
        )
        canonicalQueue = scope
        queueCanonicalIndices = plan.canonicalIndices
        queue = plan.canonicalIndices.map { scope[$0] }
        queueIndex = plan.queueIndex
    }

    /// 设置展示元数据 + 触发真实解析播放。
    private func startPlaying(_ song: TVSong, resumeTime: Double = 0, autoPlay: Bool = true,
                              isRecovery: Bool = false) {
        // 换条之前先记下上一条有声内容听到哪了,时钟马上就要归零。
        rememberSpokenWordPosition(force: true)
        let startTime = spokenWordStartTime(for: song, requested: resumeTime, isRecovery: isRecovery)
        finishListeningSession()
        playbackRestoreAttempted = true
        if !isRecovery { playbackRecoveryAttempt = 0 }
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        radioReconnectAttempt = 0
        isLiveRadio = false
        currentRadioStationID = nil
        radioMetadataTitle = ""
        playbackTask?.cancel()
        let requestID = UUID()
        activePlaybackRequestID = requestID
        playbackIssue = nil
        engine.prepareForSelection(startAt: startTime)

        let a = albumOf(song)
        let rawSong = library.song(id: song.id)
        let fallback = Self.tint(song.id)
        let albumPalette = artworkPalettes[song.albumID]
        let songPalette = artworkPalettes[Self.songArtworkPaletteKey(song.id)]
        nowPlaying = TVNowPlaying(
            songID: song.id,
            coverRef: rawSong?.coverArtFileName,
            title: song.title, artist: song.artist, album: a?.title ?? "",
            albumID: song.albumID,
            tint: albumPalette?.primary.color ?? songPalette?.primary.color
                ?? a?.tint ?? fallback.0,
            tint2: albumPalette?.secondary.color ?? songPalette?.secondary.color
                ?? a?.tint2 ?? fallback.1,
            glyph: a?.glyph ?? "♪", duration: song.duration, currentTime: startTime,
            format: song.format, bitrate: song.bitrate, sampleRate: song.sampleRate, sourcePath: "")
        updateAutomaticThemePalette(albumPalette ?? songPalette)
        hasNowPlaying = true
        lyrics = []
        refreshUpNext()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.coordinator.play(
                songID: song.id,
                requestID: requestID,
                preferMusicVideo: self.isMusicVideoModeEnabled,
                startAt: startTime,
                autoPlay: autoPlay
            )
            guard self.isCurrentPlaybackRequest(
                requestID,
                isCancelled: Task.isCancelled
            ) else { return }
            self.playbackTask = nil
        }
    }

    /// 播放一条 Apple Music 目录搜索结果。这首歌不在本机曲库里,所以像电台那样
    /// 直接构造「正在播放」:`songID` 带前缀,避免与曲库歌曲的 ID 撞上。
    func playAppleMusicCatalogHit(_ hit: AppleMusicCatalogHit) {
        leaveSpokenWordItem()
        finishListeningSession()
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        isLiveRadio = false
        currentRadioStationID = nil
        radioMetadataTitle = ""
        playbackTask?.cancel()
        let requestID = UUID()
        activePlaybackRequestID = requestID
        playbackIssue = nil
        queue = []
        queueIndex = 0
        queueUpNextIDs = []
        lyrics = []
        isMusicVideoModeEnabled = false
        engine.prepareForSelection(startAt: 0)

        let fallback = Self.tint(hit.id)
        nowPlaying = TVNowPlaying(
            songID: Self.appleMusicCatalogSongID(hit.id),
            coverRef: nil,
            title: hit.title,
            artist: hit.artistName,
            album: hit.albumTitle,
            albumID: "",
            tint: fallback.0,
            tint2: fallback.1,
            glyph: "♪",
            duration: hit.duration,
            currentTime: 0,
            format: "AAC",
            bitrate: 0,
            sampleRate: 0,
            sourcePath: hit.id
        )
        updateAutomaticThemePalette(nil)
        hasNowPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.coordinator.playAppleMusicCatalogItem(
                itemID: hit.id,
                duration: hit.duration,
                requestID: requestID
            )
            guard self.isCurrentPlaybackRequest(
                requestID,
                isCancelled: Task.isCancelled
            ) else { return }
            self.playbackTask = nil
        }
    }

    /// 目录结果的「正在播放」标识。加前缀是为了不和曲库歌曲的 ID 混淆 ——
    /// 队列推进、收藏、播放记录都按曲库 ID 查表,目录结果不该被误命中。
    nonisolated static func appleMusicCatalogSongID(_ itemID: String) -> String {
        "appleMusic:\(itemID)"
    }

    /// 播放一张 Apple Music 专辑。
    func playAppleMusicAlbum(_ album: AppleMusicCatalogAlbumHit) {
        startAppleMusicCollection(
            .album(id: album.id),
            songID: Self.appleMusicCatalogSongID("album." + album.id),
            title: album.title,
            artist: album.artistName,
            album: album.title,
            glyph: "opticaldisc"
        )
    }

    /// 播放某位艺术家的热门曲目。
    func playAppleMusicArtist(_ artist: AppleMusicCatalogArtistHit) {
        startAppleMusicCollection(
            .artistTopSongs(id: artist.id),
            songID: Self.appleMusicCatalogSongID("artist." + artist.id),
            title: artist.name,
            artist: artist.name,
            album: "",
            glyph: "person.fill"
        )
    }

    /// 播放用户自己的 Apple Music 歌单。
    func playAppleMusicPlaylist(_ playlist: AppleMusicPlaylistHit) {
        startAppleMusicCollection(
            .libraryPlaylist(id: playlist.id),
            songID: Self.appleMusicCatalogSongID("playlist." + playlist.id),
            title: playlist.name,
            artist: playlist.curatorName,
            album: "",
            glyph: "music.note.list"
        )
    }

    /// 集合类播放共用的「正在播放」构造。首曲信息由系统播放器回灌后再精化,
    /// 这里先用集合本身的名字占位,免得按下去之后界面空着。
    private func startAppleMusicCollection(
        _ collection: TVPlaybackCoordinator.AppleMusicCollection,
        songID: String,
        title: String,
        artist: String,
        album: String,
        glyph: String
    ) {
        finishListeningSession()
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        isLiveRadio = false
        currentRadioStationID = nil
        radioMetadataTitle = ""
        playbackTask?.cancel()
        let requestID = UUID()
        activePlaybackRequestID = requestID
        playbackIssue = nil
        queue = []
        queueIndex = 0
        queueUpNextIDs = []
        lyrics = []
        isMusicVideoModeEnabled = false
        engine.prepareForSelection(startAt: 0)

        let fallback = Self.tint(songID)
        nowPlaying = TVNowPlaying(
            songID: songID,
            coverRef: nil,
            title: title,
            artist: artist,
            album: album,
            albumID: "",
            tint: fallback.0,
            tint2: fallback.1,
            glyph: glyph,
            duration: 0,
            currentTime: 0,
            format: "AAC",
            bitrate: 0,
            sampleRate: 0,
            sourcePath: ""
        )
        updateAutomaticThemePalette(nil)
        hasNowPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.coordinator.playAppleMusicCollection(
                collection,
                fallbackDuration: 0,
                requestID: requestID
            )
            guard self.isCurrentPlaybackRequest(
                requestID,
                isCancelled: Task.isCancelled
            ) else { return }
            self.playbackTask = nil
        }
    }

    private func handlePlaybackEnded() {
        finishListeningSession()
        persistPlaybackSession()
        if isLiveRadio {
            scheduleRadioReconnect()
        } else {
            advanceAfterEnd()
        }
    }

    private func handlePlaybackFailure(_ message: String) {
        playbackIssue = .failed(message)
        if isLiveRadio {
            scheduleRadioReconnect()
            return
        }
        finishListeningSession()
        persistPlaybackSession()
        guard playbackRecoveryAttempt == 0,
              let id = currentSongID, let selected = song(id),
              let raw = library.song(id: id),
              let source = sourcesStore.allSources.first(where: { $0.id == raw.sourceID }) else { return }
        playbackRecoveryAttempt = 1
        let position = currentTime
        let requestID = activePlaybackRequestID
        playbackTask = Task { [weak self] in
            await StreamResolverRegistry.shared.invalidateSession(for: source)
            guard !Task.isCancelled, let self,
                  self.activePlaybackRequestID == requestID else { return }
            self.startPlaying(selected, resumeTime: position, isRecovery: true)
        }
    }

    private func observePlaybackChanges() {
        withObservationTracking {
            _ = engine.isPlaying
            _ = engine.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePlaybackChanges()
                self.scanner.readingConfigurationChanged()
                self.updateListeningMonitor()
            }
        }
    }

    private func updateListeningMonitor() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        persistPlaybackSession()
        // 暂停 / 停止 / 出错都会走到这里:有声内容立刻记下位置。
        if !engine.isPlaying { rememberSpokenWordPosition(force: true) }
        guard !isLiveRadio, engine.isPlaying, engine.status == .playing,
              let requestID = activePlaybackRequestID, let id = currentSongID,
              let raw = library.song(id: id) else { return }
        armSpokenWordPositionIfNeeded()
        if historyRequestID != requestID {
            historyRequestID = requestID
            library.recordPlayback(of: id)
            PlayHistoryStore.shared.beginSession(song: raw)
            ScrobbleService.shared.serverScrobbleHandler = { [weak self] song, submission in
                if submission { self?.serverFeedback.reportScrobble(song: song) }
                else { self?.serverFeedback.reportNowPlaying(song: song) }
            }
            ScrobbleService.shared.handlePlaybackStarted(song: raw)
            publishTopShelf()
        }
        ScrobbleService.shared.handlePlaybackDurationResolved(songID: id, duration: duration)
        playbackMonitorTask = Task { [weak self] in
            var lastTick = ProcessInfo.processInfo.systemUptime
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.activePlaybackRequestID == requestID,
                      self.engine.isPlaying, self.engine.status == .playing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = min(2, max(0, now - lastTick))
                lastTick = now
                PlayHistoryStore.shared.tick(playedDelta: delta)
                ScrobbleService.shared.handleProgressTick(playedDelta: delta)
                self.rememberSpokenWordPosition()
                ticks += 1
                if ticks % 5 == 0 { self.persistPlaybackSession() }
            }
        }
    }

    private func finishListeningSession() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        guard historyRequestID != nil else { return }
        PlayHistoryStore.shared.endSession()
        PlayHistoryStore.shared.flush()
        ScrobbleService.shared.handlePlaybackStopped()
        historyRequestID = nil
    }

    private func persistPlaybackSession() {
        guard !isLiveRadio, let id = currentSongID,
              queueCanonicalIndices.indices.contains(queueIndex) else { return }
        let mode: PrimuseKit.RepeatMode = repeatMode == .off ? .off : (repeatMode == .all ? .all : .one)
        let snapshot = PlaybackSessionSnapshot(
            queueSongIDs: canonicalQueue, currentSongID: id,
            currentIndex: queueCanonicalIndices[queueIndex], currentTime: currentTime,
            duration: duration, wasPlaying: isPlaying, shuffleEnabled: shuffleEnabled,
            shuffledIndices: shuffleEnabled ? queueCanonicalIndices : [],
            shufflePosition: shuffleEnabled ? queueIndex : 0, repeatMode: mode,
            isAtTrackEnd: duration > 0 && currentTime >= duration - 0.5
        )
        let previous = playbackSessionTask
        let storage = sessionStore
        playbackSessionTask = Task.detached {
            await previous?.value
            do { try storage.save(snapshot) }
            catch { plog("TV playback session save failed: \(error.localizedDescription)") }
        }
    }

    private func restorePlaybackSessionIfNeeded() {
        guard !playbackRestoreAttempted, !hasNowPlaying, !songByID.isEmpty else { return }
        playbackRestoreAttempted = true
        do {
            guard let snapshot = try sessionStore.load(),
                  let plan = PlaybackSessionRestorationPolicy.plan(
                    snapshot: snapshot, availableSongIDs: Set(songByID.keys)
                  ) else { return }
            canonicalQueue = plan.queueSongIDs
            shuffleEnabled = plan.shuffleEnabled
            queueCanonicalIndices = plan.shuffleEnabled ? plan.shuffledIndices : Array(canonicalQueue.indices)
            queue = queueCanonicalIndices.map { canonicalQueue[$0] }
            queueIndex = plan.shuffleEnabled ? plan.shufflePosition : plan.currentIndex
            repeatMode = plan.repeatMode == .off ? .off : (plan.repeatMode == .all ? .all : .one)
            if let selected = song(queue[queueIndex]) {
                startPlaying(selected, resumeTime: plan.currentTime, autoPlay: false)
            }
        } catch { plog("TV playback session restore failed: \(error.localizedDescription)") }
    }

    private func migrateLegacySongIDs() {
        var replacements: [String: String] = [:]
        for raw in library.songs where raw.id.count == 64 {
            let digest = SHA256.hash(data: Data("\(raw.sourceID):\(raw.filePath)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let type = sourcesStore.source(id: raw.sourceID)?.type
            guard raw.id == digest || type == .fnMusic || type == .daoliyu || type == .songloft
                    || type == .synologyAudioStation else { continue }
            let canonical = TVScanPipelinePolicy.canonicalSongID(raw.id)
            guard canonical != raw.id else { continue }
            replacements[raw.id] = canonical
            locallyScannedSourceIDs.insert(raw.sourceID)
        }
        applySongIDReplacements(replacements)
        defaults.set(Array(locallyScannedSourceIDs), forKey: "tv.scannedSourceIDs")
    }

    private static func scanFileIdentity(_ song: Song) -> String {
        [song.sourceID, song.filePath, song.cueSheetPath ?? "",
         song.cueStartTime.map { String($0) } ?? ""].joined(separator: "\u{0}")
    }

    private func applySongIDReplacements(_ replacements: [String: String]) {
        guard !replacements.isEmpty else { return }
        library.remapSongIDs(replacements)
        PlayHistoryStore.shared.remapSongIDs(replacements)
        queue = queue.map { replacements[$0] ?? $0 }
        canonicalQueue = canonicalQueue.map { replacements[$0] ?? $0 }
        nowPlaying.songID = replacements[nowPlaying.songID] ?? nowPlaying.songID
        refreshUpNext()
        Task {
            for (old, canonical) in replacements {
                await MetadataAssetStore.shared.preserveLyricsAlias(fromSongID: old, toSongID: canonical)
            }
        }
        if var snapshot = try? sessionStore.load() {
            snapshot.queueSongIDs = snapshot.queueSongIDs.map { replacements[$0] ?? $0 }
            snapshot.currentSongID = replacements[snapshot.currentSongID] ?? snapshot.currentSongID
            do { try sessionStore.save(snapshot) }
            catch { plog("TV migrated playback session save failed: \(error.localizedDescription)") }
        }
    }

    func applicationDidBecomeActive() {
        resumePendingSourceUpload()
        ScrobbleService.shared.retryPendingNow()
        recoverReceivedMusicIfNeeded()
    }

    func persistForLifecycle() async {
        guard !hasPendingSnapshotRecovery else { return }
        // 切台时攒着没写的最近收听时间（和批末才写的远端电台）现在写掉。
        radioStore.flushPendingPersist()
        rememberSpokenWordPosition(force: true)
        SpokenWordStore.shared.flush()
        persistPlaybackSession()
        if !isPlaying { finishListeningSession() }
        PlayHistoryStore.shared.flush()
        await playbackSessionTask?.value
        _ = await library.persistNowAndWait()
    }

    private func scheduleRadioReconnect() {
        guard isLiveRadio,
              radioReconnectTask == nil,
              let station = currentRadioStation,
              let requestID = activePlaybackRequestID else { return }
        radioReconnectAttempt += 1
        let attempt = radioReconnectAttempt
        guard attempt <= 6 else { return }
        let delay = min(15.0, pow(2.0, Double(min(attempt - 1, 4))))
        radioReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.isLiveRadio,
                  self.currentRadioStationID == station.id else { return }
            self.radioReconnectTask = nil
            do {
                let url = try await self.coordinator.resolveRadioStream(
                    for: station,
                    requestID: requestID,
                    forceRefresh: station.requiresSourceStreamResolution
                )
                guard self.isCurrentPlaybackRequest(
                    requestID,
                    isCancelled: Task.isCancelled
                ), self.currentRadioStationID == station.id else { return }
                self.playbackIssue = nil
                self.engine.loadLiveRadio(
                    url: url.url,
                    headers: url.headers,
                    title: self.currentRadioStation?.name ?? station.name,
                    subtitle: self.radioMetadataTitle.isEmpty
                        ? station.tvPlaybackSubtitle
                        : self.radioMetadataTitle,
                    format: station.streamFormat.displayName,
                    streamFormat: station.streamFormat,
                    isSourceBacked: station.requiresSourceStreamResolution
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentPlaybackRequest(
                    requestID,
                    isCancelled: Task.isCancelled
                ), self.currentRadioStationID == station.id else { return }
                self.playbackIssue = self.coordinator.radioPlaybackIssue(
                    for: error,
                    station: station
                )
                self.scheduleRadioReconnect()
            }
        }
    }

    func isCurrentPlaybackRequest(_ requestID: UUID, isCancelled: Bool) -> Bool {
        PlaybackRequestGenerationPolicy.shouldApplyResult(
            requestID: requestID,
            activeRequestID: activePlaybackRequestID,
            isCancelled: isCancelled
        )
    }

    /// 协调器加载完歌词后回填(本地缓存 / 从源读 .lrc)。仅当仍是这首歌时生效。
    func applyLyrics(_ lines: [TVLyricLine], forSongID songID: String) {
        guard currentSongID == songID else { return }
        lyrics = lines
    }
}

extension TVNowPlaying {
    /// 占位「无正在播放」。
    @MainActor
    static var none: TVNowPlaying {
        TVNowPlaying(songID: "", coverRef: nil,
                     title: "", artist: "", album: "", albumID: "",
                     tint: TVColor.brand, tint2: .black, glyph: "♪",
                     duration: 0, currentTime: 0, format: "", bitrate: 0,
                     sampleRate: 0, sourcePath: "")
    }
}
#endif
