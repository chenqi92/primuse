#if os(tvOS)
import AMSMB2
import CryptoKit
import Foundation
import PrimuseKit

/// 目录项(浏览/扫描用)。
struct TVDirEntry: Sendable, Identifiable, Hashable {
    let name: String
    let isDir: Bool
    let size: Int64
    let path: String      // share 内相对路径(与 SMBByteReader.resolve 一致,供播放复用)
    let providerID: String?
    let parentPath: String?
    let modifiedDate: Date?
    let revision: String?

    init(
        name: String,
        isDir: Bool,
        size: Int64,
        path: String,
        providerID: String? = nil,
        parentPath: String? = nil,
        modifiedDate: Date? = nil,
        revision: String? = nil
    ) {
        self.name = name
        self.isDir = isDir
        self.size = size
        self.path = path
        self.providerID = providerID
        self.parentPath = parentPath
        self.modifiedDate = modifiedDate
        self.revision = revision
    }

    var id: String { path }
}

extension TVDirEntry: SidecarDirectoryItem {
    var sidecarName: String { name }
    var sidecarPath: String { path }
    var sidecarIsDirectory: Bool { isDir }
    var sidecarSize: Int64 { size }
    var sidecarModifiedDate: Date? { modifiedDate }
    var sidecarRevision: String? { revision }
    var sidecarProviderID: String? { providerID }
}

/// 目录列举器(浏览源的文件夹树)。先实现 SMB,其它协议后续补。
protocol TVDirectoryLister: Sendable {
    var usesStableProviderSongIdentity: Bool { get }
    func list(_ path: String) async throws -> [TVDirEntry]
}

extension TVDirectoryLister {
    var usesStableProviderSongIdentity: Bool { false }
}

private struct TVRoutedDirectoryListerCandidate: Sendable {
    let kind: SourceConnectionCandidateKind
    let lister: any TVDirectoryLister
}

/// Directory browsing is read-only, so a failed list operation can safely be
/// replayed against the next saved route without duplicating a mutation.
private actor TVRoutedDirectoryLister: TVDirectoryLister {
    private let sourceID: String
    private let candidates: [TVRoutedDirectoryListerCandidate]
    private var activeIndex: Int?
    private var routeGeneration: UInt64?

    init(sourceID: String, candidates: [TVRoutedDirectoryListerCandidate]) {
        self.sourceID = sourceID
        self.candidates = candidates
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        guard candidates.isEmpty == false else { throw TVScanError.connectFailed }
        let currentGeneration = await SourceConnectionRuntime.shared.routeGeneration()
        if routeGeneration != currentGeneration {
            activeIndex = nil
            routeGeneration = currentGeneration
        }
        var lastError: Error = TVScanError.connectFailed
        let activeKind = await SourceConnectionRuntime.shared.activeKind(for: sourceID)
        let orderedIndices = candidates.indices.sorted { lhs, rhs in
            if candidates[lhs].kind == activeKind { return true }
            if candidates[rhs].kind == activeKind { return false }
            if lhs == activeIndex { return true }
            if rhs == activeIndex { return false }
            return lhs < rhs
        }

        for index in orderedIndices {
            do {
                let entries = try await candidates[index].lister.list(path)
                activeIndex = index
                await SourceConnectionRuntime.shared.record(
                    candidates[index].kind,
                    for: sourceID
                )
                return entries
            } catch {
                lastError = error
                guard TVSourceConnectionFailoverPolicy.allowsRetry(after: error) else {
                    throw error
                }
                activeIndex = nil
                await SourceConnectionRuntime.shared.invalidate(sourceID: sourceID)
            }
        }
        throw lastError
    }
}

/// 飞牛音乐是服务端整库，不提供文件夹树。扫描流程仍需要一个 lister 来完成
/// 进入页面时的真实连接校验；返回空目录后 UI 会以当前根目录启动整库扫描。
actor TVFnMusicLister: TVDirectoryLister {
    private let client: FnMusicServiceClient

    init(client: FnMusicServiceClient) {
        self.client = client
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        guard path == "/" else { return [] }
        _ = try await client.validateConnection()
        return []
    }
}

/// 道理鱼同样是整库源；根目录浏览只执行真实登录和曲库探测。
actor TVDaoLiYuLister: TVDirectoryLister {
    private let client: DaoLiYuServiceClient

    init(client: DaoLiYuServiceClient) {
        self.client = client
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        guard path == "/" else { return [] }
        _ = try await client.validateConnection()
        return []
    }
}

/// Dropbox / OneDrive 直接通过 PrimuseKit 的 OAuth resolver 浏览目录。
/// lister 与播放共用同一 resolver，因此 401 触发的 token 刷新只发生一次，
/// 刷新结果也会走 TVStore 配置的持久化回调写回钥匙串和 CloudKit。
actor TVCloudDriveLister: TVDirectoryLister {
    private let source: MusicSource
    private let credential: SourceCredential?

    nonisolated var usesStableProviderSongIdentity: Bool { true }

    init(source: MusicSource, credential: SourceCredential?) {
        self.source = source
        self.credential = credential
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        let entries = try await StreamResolverRegistry.shared.listCloudDirectory(
            source: source,
            credential: credential,
            path: path
        )
        return entries.map {
            TVDirEntry(
                name: $0.name,
                isDir: $0.isDirectory,
                size: $0.size,
                path: $0.path,
                providerID: $0.providerID,
                parentPath: $0.parentPath ?? path,
                modifiedDate: $0.modifiedDate,
                revision: $0.revision
            )
        }
    }
}

// MARK: - SMB 目录列举(AMSMB2)

actor TVSMBLister: TVDirectoryLister {
    private let serverURL: URL
    private let credential: URLCredential
    private let configuredShare: String
    private var manager: SMB2Manager?
    private var connectedShare: String?

    init?(source: MusicSource, credential cred: SourceCredential?) {
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let port = source.port ?? 445
        let hostPart = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        guard let url = URL(string: "smb://\(hostPart):\(port)") else { return nil }
        serverURL = url
        let user = (cred?.username ?? source.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = (cred?.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isGuest = user.isEmpty && pass.isEmpty
        credential = URLCredential(user: isGuest ? "guest" : user, password: pass, persistence: .forSession)
        configuredShare = (source.shareName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private func ensureManager() throws -> SMB2Manager {
        if let manager { return manager }
        guard let m = SMB2Manager(url: serverURL, credential: credential) else {
            throw TVScanError.connectFailed
        }
        manager = m
        return m
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        let (share, rel) = SMBByteReader.resolve(share: configuredShare, path: path)
        let m = try ensureManager()
        // 服务器根(未指定 share):列出可见共享当作一级目录。
        if share.isEmpty {
            let shares = try await m.listShares()
            return shares
                .filter { !$0.name.hasSuffix("$") && !$0.name.isEmpty }
                .map { TVDirEntry(name: $0.name, isDir: true, size: 0, path: "/\($0.name)") }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        if connectedShare != share {
            if connectedShare != nil { try? await m.disconnectShare() }
            try await m.connectShare(name: share)
            connectedShare = share
        }
        let items = try await m.contentsOfDirectory(atPath: rel)
        return items.compactMap { item -> TVDirEntry? in
            let name = item[.nameKey] as? String ?? ""
            guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = item[.fileSizeKey] as? Int64 ?? 0
            let modifiedDate = item[.contentModificationDateKey] as? Date
            let revision = modifiedDate.map {
                "smb:\(size):\(Int64($0.timeIntervalSince1970))"
            }
            return TVDirEntry(
                name: name,
                isDir: isDir,
                size: size,
                path: Self.append(path, name),
                parentPath: path,
                modifiedDate: modifiedDate,
                revision: revision
            )
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name) < ($1.isDir ? 0 : 1, $1.name) }
    }

    private static func append(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

enum TVScanError: Error { case connectFailed, unsupported, maximumDepthExceeded }

private enum TVScanPipelineError: Error {
    case skeletonDelivery(String)
    case metadataDelivery(String)

    var message: String {
        switch self {
        case .skeletonDelivery(let message), .metadataDelivery(let message):
            return message
        }
    }
}

private enum TVScanBatchKind {
    case skeleton
    case metadata
}

enum TVScanCompletion: Sendable, Equatable {
    case completed
    case completedWithMetadataFailures(Int)
    case enumerationFailed(String)
    case skeletonDeliveryFailed(String)
    case metadataDeliveryFailed(String)
    case cancelled
}

struct TVScanResult: Sendable {
    let songs: [Song]
    let discoveredSongIDs: Set<String>
    let enumerationCompleted: Bool
    let metadataCompleted: Bool
    let metadataFailureCount: Int
    let completion: TVScanCompletion
    let resumeState: SourceScanResumeState

    var canPrune: Bool {
        guard enumerationCompleted else { return false }
        switch completion {
        case .completed, .completedWithMetadataFailures:
            return true
        case .enumerationFailed, .skeletonDeliveryFailed,
             .metadataDeliveryFailed, .cancelled:
            return false
        }
    }
}

typealias TVScanBatchHandler = @MainActor @Sendable ([Song]) async throws -> Void
typealias TVScanCheckpointHandler = @MainActor @Sendable (
    SourceScanResumeState
) async throws -> Void

// MARK: - 扫描服务(走查选中目录 → 路径式建 Song)

@MainActor
@Observable
final class TVSourceScanner {
    enum Phase: Equatable { case idle, browsing, scanning, done, failed(String) }

    var phase: Phase = .idle
    var indexed: Int = 0
    var currentFile: String = ""
    private static let maximumScanDepth = 64
    private static let fnMusicPageSize = 50
    private static let daoLiYuPageSize = 100

    private struct DirectoryWork: Sendable {
        let path: String
        let depth: Int
    }

    private struct ScanItem: Sendable {
        var song: Song
        let candidate: Song
        let existing: Song?
        let sidecars: SidecarDirectoryIndex<TVDirEntry>
    }

    private struct CueTrackDescriptor: Sendable {
        let cuePath: String
        let albumTitle: String?
        let albumPerformer: String?
        let genre: String?
        let year: Int?
        let format: AudioFormat
        let track: CueTrack
    }

    private struct FnMusicClientConfiguration: Equatable {
        let host: String?
        let port: Int?
        let useSSL: Bool
        let basePath: String?
        let connectionMode: FnMusicConnectionMode
        let sourceUsername: String?
        let credential: SourceCredential?
    }

    private struct FnMusicClientCacheEntry {
        let configuration: FnMusicClientConfiguration
        let client: FnMusicServiceClient
    }

    private var fnMusicClients: [String: FnMusicClientCacheEntry] = [:]

    /// 构造源对应的目录列举器。飞牛音乐没有目录树，lister 只校验真实音乐服务。
    func makeLister(source: MusicSource, credential: SourceCredential?) -> TVDirectoryLister? {
        if source.connectionConfiguration != nil {
            let candidates = source.connectionCandidates.compactMap { candidate -> TVRoutedDirectoryListerCandidate? in
                let routedSource = source.applyingConnectionCandidate(candidate)
                guard let lister = makeSingleLister(source: routedSource, credential: credential) else {
                    return nil
                }
                return TVRoutedDirectoryListerCandidate(kind: candidate.kind, lister: lister)
            }
            guard candidates.isEmpty == false else { return nil }
            return TVRoutedDirectoryLister(sourceID: source.id, candidates: candidates)
        }
        return makeSingleLister(source: source, credential: credential)
    }

    private func makeSingleLister(
        source: MusicSource,
        credential: SourceCredential?
    ) -> TVDirectoryLister? {
        switch source.type {
        case .local where TVLocalTransferSource.isOwned(source): return TVLocalDirectoryLister()
        case .smb: return TVSMBLister(source: source, credential: credential)
        case .oneDrive, .dropbox:
            return TVCloudDriveLister(source: source, credential: credential)
        case .fnMusic:
            return TVFnMusicLister(client: fnMusicClient(source: source, credential: credential))
        case .daoliyu:
            return TVDaoLiYuLister(client: DaoLiYuServiceClient(source: source, credential: credential))
        default: return nil
        }
    }

    var supportsScanning: Bool { false }   // 占位,实例方法在 makeLister 判定

    /// 浏览一层目录(给选目录页用)。
    func browse(lister: TVDirectoryLister, path: String) async throws -> [TVDirEntry] {
        try Task.checkCancellation()
        let entries = try await lister.list(path)
        try Task.checkCancellation()
        return entries
    }

    /// 两阶段扫描：目录枚举每满 20 首立即发布可播放骨架，完整枚举后再以有限
    /// 并发读取标签并回填。只有 `enumerationCompleted` 的结果可用于删除未见歌曲；
    /// 扫描器不会自行进入 `.done`，必须等 Store 持久化成功后调用
    /// `markPersistedScanComplete()`。
    func scan(
        source: MusicSource,
        lister: TVDirectoryLister,
        dirs: [String],
        credential: SourceCredential?,
        existingSongs: [Song],
        resumeState: SourceScanResumeState? = nil,
        onCheckpoint: TVScanCheckpointHandler? = nil,
        onSkeletonBatch: @escaping TVScanBatchHandler,
        onMetadataBatch: @escaping TVScanBatchHandler
    ) async -> TVScanResult {
        phase = .scanning
        indexed = 0
        currentFile = ""
        if source.type == .fnMusic || source.type == .daoliyu {
            return await scanServerCatalog(
                source: source,
                credential: credential,
                existingSongs: existingSongs,
                onSkeletonBatch: onSkeletonBatch
            )
        }
        return await scanDirectories(
            source: source,
            lister: lister,
            dirs: dirs,
            credential: credential,
            existingSongs: existingSongs,
            resumeState: resumeState,
            onCheckpoint: onCheckpoint,
            onSkeletonBatch: onSkeletonBatch,
            onMetadataBatch: onMetadataBatch
        )
    }

    /// Temporary source-compatibility wrapper for callers migrating to the
    /// streaming contract. It intentionally does not mark the scan done.
    func scan(
        source: MusicSource,
        lister: TVDirectoryLister,
        dirs: [String],
        credential: SourceCredential?
    ) async -> [Song]? {
        let result = await scan(
            source: source,
            lister: lister,
            dirs: dirs,
            credential: credential,
            existingSongs: [],
            onSkeletonBatch: { _ in },
            onMetadataBatch: { _ in }
        )
        switch result.completion {
        case .completed, .completedWithMetadataFailures:
            return result.songs
        case .enumerationFailed, .skeletonDeliveryFailed,
             .metadataDeliveryFailed, .cancelled:
            return nil
        }
    }

    func markPersistedScanComplete() {
        phase = .done
        currentFile = ""
    }

    private func scanServerCatalog(
        source: MusicSource,
        credential: SourceCredential?,
        existingSongs: [Song],
        onSkeletonBatch: @escaping TVScanBatchHandler
    ) async -> TVScanResult {
        let existingByID = Self.existingSongsByCanonicalID(existingSongs)
        let existingByLocation = Self.existingSongsByLocation(existingSongs)
        var songsByID: [String: Song] = [:]
        var songOrder: [String] = []
        var discoveredIDs: Set<String> = []
        var pendingBatch: [Song] = []

        let accept: (Song) async throws -> Void = { rawSong in
            try Task.checkCancellation()
            var candidate = rawSong
            candidate.id = TVScanPipelinePolicy.canonicalSongID(candidate.id)
            let existing = existingByID[candidate.id]
                ?? existingByLocation[Self.locationKey(candidate)]
            let song = TVScanPipelinePolicy.reconciledSkeleton(
                existing: existing,
                candidate: candidate
            )
            if discoveredIDs.insert(song.id).inserted {
                songOrder.append(song.id)
            }
            songsByID[song.id] = song
            pendingBatch.append(song)
            self.indexed = discoveredIDs.count
            self.currentFile = song.title
            if pendingBatch.count >= TVScanPipelinePolicy.publicationBatchSize {
                let batch = Array(
                    pendingBatch.prefix(TVScanPipelinePolicy.publicationBatchSize)
                )
                do {
                    try await onSkeletonBatch(batch)
                    pendingBatch.removeFirst(batch.count)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw TVScanPipelineError.skeletonDelivery(
                        error.localizedDescription
                    )
                }
            }
        }

        do {
            if source.type == .fnMusic {
                _ = try await withRoutedSource(source) { routedSource in
                    try await self.scanFnMusic(
                        source: routedSource,
                        credential: credential,
                        onSong: accept
                    )
                }
            } else {
                _ = try await withRoutedSource(source) { routedSource in
                    try await self.scanDaoLiYu(
                        source: routedSource,
                        credential: credential,
                        onSong: accept
                    )
                }
            }
            try Task.checkCancellation()
            try await flush(
                &pendingBatch,
                to: onSkeletonBatch,
                ignoringCancellation: false
            )
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: true,
                metadataCompleted: true,
                metadataFailureCount: 0,
                completion: .completed,
                resumeState: SourceScanResumeState(pendingDirectories: [])
            )
        } catch is CancellationError {
            try? await flush(
                &pendingBatch,
                to: onSkeletonBatch,
                ignoringCancellation: true
            )
            phase = .idle
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: 0,
                completion: .cancelled,
                resumeState: SourceScanResumeState(pendingDirectories: [])
            )
        } catch let error as TVScanPipelineError {
            try? await flush(
                &pendingBatch,
                to: onSkeletonBatch,
                ignoringCancellation: true
            )
            let message = error.message
            phase = .failed(message)
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: 0,
                completion: .skeletonDeliveryFailed(message),
                resumeState: SourceScanResumeState(pendingDirectories: [])
            )
        } catch {
            try? await flush(
                &pendingBatch,
                to: onSkeletonBatch,
                ignoringCancellation: true
            )
            let message = scanErrorMessage(error)
            phase = .failed(message)
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: 0,
                completion: .enumerationFailed(message),
                resumeState: SourceScanResumeState(pendingDirectories: [])
            )
        }
    }

    private func scanDirectories(
        source: MusicSource,
        lister: TVDirectoryLister,
        dirs: [String],
        credential: SourceCredential?,
        existingSongs: [Song],
        resumeState suppliedResumeState: SourceScanResumeState?,
        onCheckpoint: TVScanCheckpointHandler?,
        onSkeletonBatch: @escaping TVScanBatchHandler,
        onMetadataBatch: @escaping TVScanBatchHandler
    ) async -> TVScanResult {
        let existingByID = Self.existingSongsByCanonicalID(existingSongs)
        let existingByLocation = Self.existingSongsByLocation(existingSongs)
        let existingCueSongsByPath = Dictionary(
            grouping: existingSongs.filter {
                $0.sourceID == source.id && $0.isCueTrack
            },
            by: \.filePath
        )
        var state: SourceScanResumeState
        let isResuming = suppliedResumeState?.isUsable == true
            && suppliedResumeState?.pendingDirectories.isEmpty == false
        if isResuming, let suppliedResumeState {
            state = suppliedResumeState
        } else {
            state = SourceScanResumeState(
                pendingDirectories: TVScanPipelinePolicy.normalizedScanRoots(dirs)
            )
        }

        var queue = state.pendingDirectories.map { DirectoryWork(path: $0, depth: 0) }
        var scheduledDirectories = Set(queue.map(\.path))
        let completedDirectories = Set(
            state.index.values.lazy.compactMap { item in
                item.isDirectory && item.seenEpoch > 0 ? item.path : nil
            }
        )
        queue.removeAll { completedDirectories.contains($0.path) }
        state.pendingDirectories = queue.map(\.path)
        var items: [ScanItem] = []
        var songsByID: [String: Song] = [:]
        var songOrder: [String] = []
        var discoveredIDs = state.encounteredSongIDs
        var pendingSkeletonBatch: [Song] = []
        var partialEnumerationMessage: String?
        var partialDirectories: [String] = []
        var songsSinceCheckpoint = 0
        var lastCheckpointAt = Date()
        let readerPool = TVMetadataReaderPool(source: source, credential: credential)

        // A resumed walk already published completed directories. Seed the
        // final authoritative result without emitting the same skeletons again.
        if isResuming {
            for id in discoveredIDs.sorted() {
                guard var song = existingByID[id] else { continue }
                song.id = TVScanPipelinePolicy.canonicalSongID(song.id)
                songsByID[song.id] = song
                songOrder.append(song.id)
                items.append(ScanItem(
                    song: song,
                    candidate: song,
                    existing: song,
                    sidecars: SidecarDirectoryIndex<TVDirEntry>([])
                ))
            }
        }

        do {
            while let work = queue.first {
                try Task.checkCancellation()
                guard work.depth <= Self.maximumScanDepth else {
                    throw TVScanError.maximumDepthExceeded
                }
                state.pendingDirectories = TVScanPipelinePolicy.normalizedScanRoots(
                    partialDirectories + queue.map(\.path)
                )
                currentFile = work.path
                let entries = try await lister.list(work.path)
                try Task.checkCancellation()
                let sidecars = SidecarDirectoryIndex(entries)
                let cueLoad = try await loadCueTracks(
                    from: entries,
                    using: readerPool
                )
                if let message = cueLoad.failureMessage {
                    partialEnumerationMessage = partialEnumerationMessage ?? message
                    if !partialDirectories.contains(work.path) {
                        partialDirectories.append(work.path)
                    }
                }

                for entry in entries where entry.isDir {
                    Self.recordIndexedItem(
                        entry,
                        parentPath: work.path,
                        songIDs: [],
                        sidecarFingerprint: nil,
                        seenEpoch: completedDirectories.contains(entry.path) ? 1 : 0,
                        in: &state.index
                    )
                    if !completedDirectories.contains(entry.path),
                       scheduledDirectories.insert(entry.path).inserted {
                        queue.append(
                            DirectoryWork(path: entry.path, depth: work.depth + 1)
                        )
                    }
                }

                let files = entries.filter { !$0.isDir }
                for entry in files {
                    try Task.checkCancellation()
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    var candidates: [Song] = []
                    if PrimuseConstants.supportedAudioExtensions.contains(ext)
                        || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
                        if let descriptors = cueLoad.tracksByAudioPath[entry.path],
                           !descriptors.isEmpty {
                            candidates = Self.makeCueSongs(
                                entry: entry,
                                descriptors: descriptors,
                                source: source,
                                usesStableProviderIdentity:
                                    lister.usesStableProviderSongIdentity,
                                sidecars: sidecars
                            )
                        } else if cueLoad.failureMessage != nil {
                            let priorCueSongs = existingCueSongsByPath[entry.path] ?? []
                            candidates = priorCueSongs.isEmpty
                                ? [Self.makeSong(
                                    entry: entry,
                                    source: source,
                                    usesStableProviderIdentity:
                                        lister.usesStableProviderSongIdentity,
                                    sidecars: sidecars
                                )]
                                : priorCueSongs.map { prior in
                                    var retained = prior
                                    retained.id = TVScanPipelinePolicy.canonicalSongID(prior.id)
                                    retained.fileSize = entry.size
                                    retained.lastModified = entry.modifiedDate
                                    retained.revision = entry.revision
                                    return retained
                                }
                        } else {
                            candidates = [Self.makeSong(
                                entry: entry,
                                source: source,
                                usesStableProviderIdentity:
                                    lister.usesStableProviderSongIdentity,
                                sidecars: sidecars
                            )]
                        }
                    } else if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
                        let stem = (entry.name as NSString)
                            .deletingPathExtension.lowercased()
                        guard !sidecars.containsAudioOrStream(basename: stem) else {
                            continue
                        }
                        var video = Self.makeSong(
                            entry: entry,
                            source: source,
                            usesStableProviderIdentity:
                                lister.usesStableProviderSongIdentity,
                            sidecars: sidecars
                        )
                        video.mvPath = entry.path
                        candidates = [video]
                    } else {
                        continue
                    }

                    var indexedSongIDs: [String] = []
                    for candidate in candidates {
                        guard discoveredIDs.insert(candidate.id).inserted else {
                            indexedSongIDs.append(candidate.id)
                            continue
                        }
                        let existing = existingByID[candidate.id]
                            ?? existingByLocation[Self.locationKey(candidate)]
                        let song = TVScanPipelinePolicy.reconciledSkeleton(
                            existing: existing,
                            candidate: candidate
                        )
                        items.append(ScanItem(
                            song: song,
                            candidate: candidate,
                            existing: existing,
                            sidecars: sidecars
                        ))
                        songsByID[song.id] = song
                        songOrder.append(song.id)
                        state.encounteredSongIDs.insert(song.id)
                        indexedSongIDs.append(song.id)
                        pendingSkeletonBatch.append(song)
                        indexed = discoveredIDs.count
                        currentFile = entry.path
                        if pendingSkeletonBatch.count
                            >= TVScanPipelinePolicy.publicationBatchSize {
                            let batch = Array(
                                pendingSkeletonBatch.prefix(
                                    TVScanPipelinePolicy.publicationBatchSize
                                )
                            )
                            do {
                                try await onSkeletonBatch(batch)
                                pendingSkeletonBatch.removeFirst(batch.count)
                                songsSinceCheckpoint += batch.count
                                if songsSinceCheckpoint >= 200
                                    || Date().timeIntervalSince(lastCheckpointAt) >= 1.5 {
                                    try await emitCheckpoint(
                                        state,
                                        to: onCheckpoint
                                    )
                                    songsSinceCheckpoint = 0
                                    lastCheckpointAt = Date()
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                throw TVScanPipelineError.skeletonDelivery(
                                    error.localizedDescription
                                )
                            }
                        }
                    }
                    let basename = (entry.name as NSString).deletingPathExtension
                    Self.recordIndexedItem(
                        entry,
                        parentPath: work.path,
                        songIDs: indexedSongIDs,
                        sidecarFingerprint: sidecars.snapshotFingerprint(
                            selectedPaths: [
                                sidecars.sameNameCover(basename: basename)?.path
                                    ?? sidecars.folderCover()?.path,
                                sidecars.sameNameLyrics(basename: basename)?.path,
                                sidecars.sameNameMusicVideo(basename: basename)?.path,
                            ]
                        ),
                        seenEpoch: 1,
                        in: &state.index
                    )
                }

                let directoryTailCount = pendingSkeletonBatch.count
                try await flush(
                    &pendingSkeletonBatch,
                    to: onSkeletonBatch,
                    ignoringCancellation: false
                )
                songsSinceCheckpoint += directoryTailCount
                if cueLoad.failureMessage == nil {
                    Self.recordCompletedDirectory(
                        path: work.path,
                        in: &state.index
                    )
                } else {
                    Self.recordPendingDirectory(
                        path: work.path,
                        in: &state.index
                    )
                }
                queue.removeFirst()
                state.pendingDirectories = TVScanPipelinePolicy.normalizedScanRoots(
                    partialDirectories + queue.map(\.path)
                )
                try await emitCheckpoint(state, to: onCheckpoint)
                songsSinceCheckpoint = 0
                lastCheckpointAt = Date()
            }
            try await flush(
                &pendingSkeletonBatch,
                to: onSkeletonBatch,
                ignoringCancellation: false
            )
            try await emitCheckpoint(state, to: onCheckpoint)
        } catch is CancellationError {
            try? await flush(
                &pendingSkeletonBatch,
                to: onSkeletonBatch,
                ignoringCancellation: true
            )
            await readerPool.closeAll()
            phase = .idle
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: 0,
                completion: .cancelled,
                resumeState: state
            )
        } catch let error as TVScanPipelineError {
            try? await flush(
                &pendingSkeletonBatch,
                to: onSkeletonBatch,
                ignoringCancellation: true
            )
            await readerPool.closeAll()
            phase = .failed(error.message)
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: 0,
                completion: .skeletonDeliveryFailed(error.message),
                resumeState: state
            )
        } catch {
            try? await flush(
                &pendingSkeletonBatch,
                to: onSkeletonBatch,
                ignoringCancellation: true
            )
            await readerPool.closeAll()
            let message = scanErrorMessage(error)
            phase = .failed(message)
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: 0,
                completion: .enumerationFailed(message),
                resumeState: state
            )
        }

        if !partialDirectories.isEmpty {
            state.pendingDirectories = partialDirectories
        }
        var pendingMetadataBatch: [Song] = []
        var metadataFailureCount = 0
        var itemOffset = 0
        do {
            while itemOffset < items.count {
                try Task.checkCancellation()
                let upperBound = min(
                    itemOffset + TVScanPipelinePolicy.metadataConcurrency,
                    items.count
                )
                let positions = Array(itemOffset..<upperBound)
                let results = await withTaskGroup(
                    of: (Int, TVMetadataEnrichmentResult).self,
                    returning: [(Int, TVMetadataEnrichmentResult)].self
                ) { group in
                    for position in positions {
                        let item = items[position]
                        if TVScanPipelinePolicy.canReuseMetadata(
                            existing: item.existing,
                            candidate: item.candidate
                        ) {
                            continue
                        }
                        group.addTask {
                            let result = await TVMetadataEnricher.enrich(
                                song: item.song,
                                sidecars: item.sidecars,
                                using: readerPool
                            )
                            return (position, result)
                        }
                    }
                    var values: [(Int, TVMetadataEnrichmentResult)] = []
                    for await value in group { values.append(value) }
                    return values.sorted { $0.0 < $1.0 }
                }

                for (position, result) in results {
                    switch result.status {
                    case .enriched:
                        items[position].song = result.song
                        songsByID[result.song.id] = result.song
                        pendingMetadataBatch.append(result.song)
                    case .failed, .timedOut:
                        metadataFailureCount += 1
                    case .cancelled:
                        throw CancellationError()
                    }
                    if pendingMetadataBatch.count
                        >= TVScanPipelinePolicy.publicationBatchSize {
                        let batch = Array(
                            pendingMetadataBatch.prefix(
                                TVScanPipelinePolicy.publicationBatchSize
                            )
                        )
                        do {
                            try await onMetadataBatch(batch)
                            pendingMetadataBatch.removeFirst(batch.count)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw TVScanPipelineError.metadataDelivery(
                                error.localizedDescription
                            )
                        }
                    }
                }
                itemOffset = upperBound
                currentFile = items[upperBound - 1].song.filePath
            }
            try Task.checkCancellation()
            try await flush(
                &pendingMetadataBatch,
                to: onMetadataBatch,
                ignoringCancellation: false,
                kind: .metadata
            )
        } catch is CancellationError {
            try? await flush(
                &pendingMetadataBatch,
                to: onMetadataBatch,
                ignoringCancellation: true,
                kind: .metadata
            )
            await readerPool.closeAll()
            phase = .idle
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: metadataFailureCount,
                completion: .cancelled,
                resumeState: state
            )
        } catch let error as TVScanPipelineError {
            try? await flush(
                &pendingMetadataBatch,
                to: onMetadataBatch,
                ignoringCancellation: true,
                kind: .metadata
            )
            await readerPool.closeAll()
            phase = .failed(error.message)
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: metadataFailureCount,
                completion: .metadataDeliveryFailed(error.message),
                resumeState: state
            )
        } catch {
            try? await flush(
                &pendingMetadataBatch,
                to: onMetadataBatch,
                ignoringCancellation: true,
                kind: .metadata
            )
            await readerPool.closeAll()
            let message = error.localizedDescription
            phase = .failed(message)
            currentFile = ""
            return TVScanResult(
                songs: songOrder.compactMap { songsByID[$0] },
                discoveredSongIDs: discoveredIDs,
                enumerationCompleted: false,
                metadataCompleted: false,
                metadataFailureCount: metadataFailureCount,
                completion: .metadataDeliveryFailed(message),
                resumeState: state
            )
        }

        await readerPool.closeAll()
        currentFile = ""
        let enumerationCompleted = partialEnumerationMessage == nil
        let completion: TVScanCompletion
        if let partialEnumerationMessage {
            completion = .enumerationFailed(partialEnumerationMessage)
            phase = .failed(partialEnumerationMessage)
        } else if metadataFailureCount > 0 {
            completion = .completedWithMetadataFailures(metadataFailureCount)
        } else {
            completion = .completed
        }
        return TVScanResult(
            songs: songOrder.compactMap { songsByID[$0] },
            discoveredSongIDs: discoveredIDs,
            enumerationCompleted: enumerationCompleted,
            metadataCompleted: metadataFailureCount == 0,
            metadataFailureCount: metadataFailureCount,
            completion: completion,
            resumeState: state
        )
    }

    /// 连接测试直接验证飞牛音乐曲库接口，不依赖本地是否已有该源歌曲。
    func validateFnMusicConnection(
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> Int? {
        guard source.type == .fnMusic else { throw TVScanError.unsupported }
        return try await withRoutedSource(source) { routedSource in
            try await self.fnMusicClient(
                source: routedSource,
                credential: credential
            ).validateConnection()
        }
    }

    func validateDaoLiYuConnection(
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> Int {
        guard source.type == .daoliyu else { throw TVScanError.unsupported }
        return try await withRoutedSource(source) { routedSource in
            try await DaoLiYuServiceClient(
                source: routedSource,
                credential: credential
            ).validateConnection()
        }
    }

    private func withRoutedSource<T: Sendable>(
        _ source: MusicSource,
        operation: (MusicSource) async throws -> T
    ) async throws -> T {
        guard source.connectionConfiguration != nil else {
            return try await operation(source)
        }
        let candidates = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
        guard candidates.isEmpty == false else { throw TVScanError.connectFailed }

        var lastError: Error = TVScanError.connectFailed
        for candidate in candidates {
            do {
                let value = try await operation(source.applyingConnectionCandidate(candidate))
                await SourceConnectionRuntime.shared.record(candidate.kind, for: source.id)
                return value
            } catch {
                lastError = error
                if error is TVScanPipelineError { throw error }
                guard TVSourceConnectionFailoverPolicy.allowsRetry(after: error) else {
                    throw error
                }
                invalidateFnMusicClient(sourceID: source.id)
                await SourceConnectionRuntime.shared.invalidate(sourceID: source.id)
            }
        }
        throw lastError
    }

    /// 源地址或凭据变化后丢弃已登录客户端，避免旧 token 被后续测试或扫描复用。
    func invalidateFnMusicClient(sourceID: String) {
        guard let entry = fnMusicClients.removeValue(forKey: sourceID) else { return }
        Task { await entry.client.invalidateSession() }
    }

    func invalidateFnMusicClients() {
        let entries = Array(fnMusicClients.values)
        fnMusicClients.removeAll()
        for entry in entries {
            Task { await entry.client.invalidateSession() }
        }
    }

    /// 严格分页读取整库。任何缺页、重复项、总数漂移或无法构造 Song 的项目都会
    /// 让整次扫描失败，调用方因此不会用不完整结果覆盖既有曲库。
    private func scanFnMusic(
        source: MusicSource,
        credential: SourceCredential?,
        onSong: (Song) async throws -> Void
    ) async throws -> [Song] {
        let client = fnMusicClient(source: source, credential: credential)
        var page = 1
        var received = 0
        var expectedTotal: Int?
        var seenTrackGUIDs: Set<String> = []
        var songs: [Song] = []

        while true {
            try Task.checkCancellation()
            let result = try await client.trackPage(page: page, size: Self.fnMusicPageSize)
            try Task.checkCancellation()

            guard let pageTotal = result.total else {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.missingTotal"))
            }
            if let expectedTotal, expectedTotal != pageTotal {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.totalChanged"))
            }
            expectedTotal = pageTotal

            guard result.rawCount == result.tracks.count,
                  result.rawCount <= Self.fnMusicPageSize else {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.invalidPageCount"))
            }
            if pageTotal == 0 {
                guard page == 1, result.rawCount == 0 else {
                    throw FnMusicServiceError.invalidResponse(PMString("error.catalog.pageTotalMismatch"))
                }
                break
            }
            guard result.rawCount > 0 else {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.pageEndedEarly"))
            }
            guard result.rawCount <= pageTotal,
                  received <= pageTotal - result.rawCount else {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.pageExceedsTotal"))
            }

            for track in result.tracks {
                try Task.checkCancellation()
                guard seenTrackGUIDs.insert(track.guid).inserted else {
                    throw FnMusicServiceError.invalidResponse(PMString("error.catalog.duplicateItem"))
                }
                guard let song = track.makeSong(sourceID: source.id) else {
                    throw FnMusicServiceError.invalidResponse(PMString("error.catalog.trackMissingFormat", track.title))
                }
                songs.append(song)
                try await onSong(song)
                indexed = songs.count
                currentFile = track.title
            }

            received += result.rawCount
            if received == pageTotal { break }
            guard result.rawCount == Self.fnMusicPageSize else {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.incompletePage"))
            }
            guard page < Int.max else {
                throw FnMusicServiceError.invalidResponse(PMString("error.catalog.pageOverflow"))
            }
            page += 1
        }

        return songs
    }

    private func scanDaoLiYu(
        source: MusicSource,
        credential: SourceCredential?,
        onSong: (Song) async throws -> Void
    ) async throws -> [Song] {
        let client = DaoLiYuServiceClient(source: source, credential: credential)
        guard let baseURL = DaoLiYuAPIProtocol.serverBaseURL(
            host: source.host ?? "",
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath
        ) else {
            throw DaoLiYuServiceError.invalidURL
        }
        var skip = 0
        var expectedTotal: Int?
        var seenIDs: Set<String> = []
        var songs: [Song] = []

        while true {
            try Task.checkCancellation()
            let page = try await client.trackPage(skip: skip, take: Self.daoLiYuPageSize)
            try Task.checkCancellation()
            if let expectedTotal, expectedTotal != page.total {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.totalChanged"))
            }
            expectedTotal = page.total
            guard page.skip == skip,
                  page.rawCount == page.tracks.count,
                  page.rawCount <= Self.daoLiYuPageSize else {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.invalidPagePositionOrCount"))
            }
            if page.total == 0 {
                guard skip == 0, page.rawCount == 0 else {
                    throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.pageTotalMismatch"))
                }
                break
            }
            guard page.rawCount > 0, skip <= page.total - page.rawCount else {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.pageEndedEarlyOrExceeded"))
            }
            for track in page.tracks {
                try Task.checkCancellation()
                guard seenIDs.insert(track.id).inserted else {
                    throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.duplicateItem"))
                }
                guard let song = track.makeSong(sourceID: source.id, serverBaseURL: baseURL) else {
                    throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.trackMissingFormat", track.title))
                }
                songs.append(song)
                try await onSong(song)
                indexed = songs.count
                currentFile = track.title
            }
            skip += page.rawCount
            if skip == page.total { break }
            guard page.rawCount == Self.daoLiYuPageSize else {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.incompletePage"))
            }
        }
        return songs
    }

    /// 返回与连接测试和扫描共用的客户端；配置未变化时复用登录会话。
    func fnMusicClient(
        source: MusicSource,
        credential: SourceCredential?
    ) -> FnMusicServiceClient {
        let configuration = FnMusicClientConfiguration(
            host: source.host,
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath,
            connectionMode: source.effectiveFnMusicConnectionMode,
            sourceUsername: source.username,
            credential: credential
        )
        if let cached = fnMusicClients[source.id], cached.configuration == configuration {
            return cached.client
        }
        if let stale = fnMusicClients.removeValue(forKey: source.id) {
            Task { await stale.client.invalidateSession() }
        }
        let client = FnMusicServiceClient(source: source, credential: credential)
        fnMusicClients[source.id] = FnMusicClientCacheEntry(
            configuration: configuration,
            client: client
        )
        return client
    }

    func cachedFnMusicClient(sourceID: String) -> FnMusicServiceClient? {
        fnMusicClients[sourceID]?.client
    }

    /// 路径式建 Song(Phase A):标题=文件名,专辑=父文件夹,艺术家=祖父文件夹。
    /// ID 使用共享 identity-material policy 和 16-byte SHA-256 前缀，与通用扫描器一致。
    static func makeSong(
        entry e: TVDirEntry,
        source: MusicSource,
        usesStableProviderIdentity: Bool = false,
        sidecars: SidecarDirectoryIndex<TVDirEntry>? = nil
    ) -> Song {
        let comps = e.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let rawName = (e.name as NSString).deletingPathExtension
        var title = Self.stripTrackNumber(rawName)
        let album = comps.count >= 2 ? comps[comps.count - 2] : nil
        var artist = comps.count >= 3 ? comps[comps.count - 3] : nil
        // 扁平文件夹(没有 艺术家/专辑 层级)时,尝试从文件名 "艺术家 - 标题" 解析。
        if artist == nil || artist == album, let dash = rawName.range(of: " - ") {
            let a = String(rawName[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let t = String(rawName[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !t.isEmpty { artist = a; title = Self.stripTrackNumber(t) }
        }
        let format = AudioFormat.from(fileExtension: (e.name as NSString).pathExtension) ?? .mp3
        let artistID = artist.map {
            TVScanPipelinePolicy.hash32(
                $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let albumID: String? = (album != nil && artist != nil)
            ? TVScanPipelinePolicy.hash32(
                "\(artist!.lowercased()):\(album!.lowercased())"
            ) : nil
        let cover = sidecars?.sameNameCover(basename: rawName)?.path
            ?? sidecars?.folderCover()?.path
        let lyrics = sidecars?.sameNameLyrics(basename: rawName)?.path
        let video = sidecars?.sameNameMusicVideo(basename: rawName)?.path
        return Song(
            id: TVScanPipelinePolicy.songID(
                sourceID: source.id,
                path: e.path,
                providerID: e.providerID,
                usesStableProviderIdentity: usesStableProviderIdentity
            ),
            title: title.isEmpty ? e.name : title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: album,
            artistName: artist,
            albumArtistName: artist,
            fileFormat: format,
            filePath: e.path,
            sourceID: source.id,
            fileSize: e.size,
            lastModified: e.modifiedDate,
            coverArtFileName: cover,
            lyricsFileName: lyrics,
            mvPath: video,
            revision: e.revision
        )
    }

    private static func makeCueSongs(
        entry: TVDirEntry,
        descriptors: [CueTrackDescriptor],
        source: MusicSource,
        usesStableProviderIdentity: Bool,
        sidecars: SidecarDirectoryIndex<TVDirEntry>
    ) -> [Song] {
        let basename = (entry.name as NSString).deletingPathExtension
        let cover = sidecars.sameNameCover(basename: basename)?.path
            ?? sidecars.folderCover()?.path
        let lyrics = sidecars.sameNameLyrics(basename: basename)?.path
        let video = sidecars.sameNameMusicVideo(basename: basename)?.path
        return descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let end = descriptor.track.endTime
            let artist = descriptor.track.performer ?? descriptor.albumPerformer
            let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: descriptor.albumPerformer,
                trackArtistName: artist
            )
            let artistID = artist.map {
                TVScanPipelinePolicy.hash32($0.lowercased())
            }
            let albumID: String? = if let albumArtist,
                                      let album = descriptor.albumTitle {
                TVScanPipelinePolicy.hash32(
                    "\(albumArtist.lowercased()):\(album.lowercased())"
                )
            } else {
                nil
            }
            return Song(
                id: TVScanPipelinePolicy.cueSongID(
                    sourceID: source.id,
                    path: entry.path,
                    providerID: entry.providerID,
                    usesStableProviderIdentity: usesStableProviderIdentity,
                    cuePath: descriptor.cuePath,
                    trackNumber: descriptor.track.number
                ),
                title: descriptor.track.title
                    ?? PMString("cue_track_title_format", descriptor.track.number),
                albumID: albumID,
                artistID: artistID,
                albumTitle: descriptor.albumTitle,
                artistName: artist,
                albumArtistName: albumArtist,
                trackNumber: descriptor.track.number,
                duration: end.map { max(0, $0 - start) } ?? 0,
                fileFormat: descriptor.format,
                filePath: entry.path,
                sourceID: source.id,
                fileSize: entry.size,
                genre: descriptor.genre,
                year: descriptor.year,
                lastModified: entry.modifiedDate,
                coverArtFileName: cover,
                lyricsFileName: lyrics,
                mvPath: video,
                cueSheetPath: descriptor.cuePath,
                cueStartTime: start,
                cueEndTime: end,
                revision: entry.revision
            )
        }
    }

    private func loadCueTracks(
        from siblings: [TVDirEntry],
        using readerPool: TVMetadataReaderPool
    ) async throws -> (
        tracksByAudioPath: [String: [CueTrackDescriptor]],
        failureMessage: String?
    ) {
        var result: [String: [CueTrackDescriptor]] = [:]
        var failureMessage: String?
        for cueItem in siblings where !cueItem.isDir
            && PrimuseConstants.supportedCueSheetExtensions.contains(
                (cueItem.name as NSString).pathExtension.lowercased()
            ) {
            do {
                try Task.checkCancellation()
                guard cueItem.size <= 0 || cueItem.size <= 1024 * 1024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let requestedLength = min(
                    max(cueItem.size, 64 * 1024),
                    Int64(1024 * 1024)
                )
                let data = try await readerPool.read(
                    path: cueItem.path,
                    size: cueItem.size,
                    offset: 0,
                    length: requestedLength
                )
                try Task.checkCancellation()
                guard let cue = CueSheetParser.parse(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                for cueFile in cue.files {
                    let referencedName = (
                        cueFile.name.replacingOccurrences(of: "\\", with: "/")
                            as NSString
                    ).lastPathComponent
                    guard let audioItem = siblings.first(where: {
                        !$0.isDir
                            && $0.name.caseInsensitiveCompare(referencedName)
                                == .orderedSame
                    }), let format = AudioFormat.from(
                        fileExtension: (audioItem.name as NSString)
                            .pathExtension.lowercased()
                    ) else {
                        continue
                    }
                    for track in cueFile.tracks
                        where track.type == "AUDIO" && track.startTime != nil {
                        result[audioItem.path, default: []].append(
                            CueTrackDescriptor(
                                cuePath: cueItem.path,
                                albumTitle: cue.title,
                                albumPerformer: cue.performer,
                                genre: cue.genre,
                                year: cue.year,
                                format: format,
                                track: track
                            )
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failureMessage = failureMessage
                    ?? "\(cueItem.name): \(error.localizedDescription)"
            }
        }
        return (result, failureMessage)
    }

    private func flush(
        _ buffer: inout [Song],
        to handler: @escaping TVScanBatchHandler,
        ignoringCancellation: Bool,
        kind: TVScanBatchKind = .skeleton
    ) async throws {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        do {
            if ignoringCancellation {
                try await Task { @MainActor in
                    try await handler(batch)
                }.value
            } else {
                try await handler(batch)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch kind {
            case .skeleton:
                throw TVScanPipelineError.skeletonDelivery(
                    error.localizedDescription
                )
            case .metadata:
                throw TVScanPipelineError.metadataDelivery(
                    error.localizedDescription
                )
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func emitCheckpoint(
        _ state: SourceScanResumeState,
        to handler: TVScanCheckpointHandler?
    ) async throws {
        guard let handler else { return }
        do {
            try await handler(state)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TVScanPipelineError.skeletonDelivery(
                error.localizedDescription
            )
        }
    }

    private func scanErrorMessage(_ error: Error) -> String {
        switch error as? TVScanError {
        case .connectFailed:
            return PMString("ext.tv.scan.connectFailed")
        case .maximumDepthExceeded:
            return PMString("ext.tv.scan.depthExceeded", Self.maximumScanDepth)
        default:
            return error.localizedDescription
        }
    }

    private static func existingSongsByCanonicalID(
        _ songs: [Song]
    ) -> [String: Song] {
        Dictionary(
            songs.map { (TVScanPipelinePolicy.canonicalSongID($0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func existingSongsByLocation(
        _ songs: [Song]
    ) -> [String: Song] {
        Dictionary(
            songs.map { (locationKey($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func locationKey(_ song: Song) -> String {
        [
            song.sourceID,
            song.filePath,
            song.cueSheetPath ?? "",
            song.isCueTrack ? song.trackNumber.map(String.init) ?? "" : "",
        ].joined(separator: "\u{1F}")
    }

    private static func recordIndexedItem(
        _ item: TVDirEntry,
        parentPath: String,
        songIDs: [String],
        sidecarFingerprint: String?,
        seenEpoch: Int64,
        in index: inout [String: SourceSyncIndexedItem]
    ) {
        let stableKey = item.providerID ?? "path:\(item.path.lowercased())"
        index[stableKey] = SourceSyncIndexedItem(
            stableKey: stableKey,
            path: item.path,
            displayName: item.name,
            parentPath: item.parentPath ?? parentPath,
            isDirectory: item.isDir,
            songIDs: songIDs,
            size: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision,
            sidecarFingerprint: sidecarFingerprint,
            seenEpoch: seenEpoch
        )
    }

    private static func recordCompletedDirectory(
        path: String,
        in index: inout [String: SourceSyncIndexedItem]
    ) {
        if let key = index.first(where: {
            $0.value.isDirectory && $0.value.path == path
        })?.key, var item = index[key] {
            item.seenEpoch = 1
            index[key] = item
            return
        }
        let stableKey = "path:\(path.lowercased())"
        index[stableKey] = SourceSyncIndexedItem(
            stableKey: stableKey,
            path: path,
            displayName: nil,
            parentPath: nil,
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil,
            seenEpoch: 1
        )
    }

    private static func recordPendingDirectory(
        path: String,
        in index: inout [String: SourceSyncIndexedItem]
    ) {
        if let key = index.first(where: {
            $0.value.isDirectory && $0.value.path == path
        })?.key, var item = index[key] {
            item.seenEpoch = 0
            index[key] = item
            return
        }
        let stableKey = "path:\(path.lowercased())"
        index[stableKey] = SourceSyncIndexedItem(
            stableKey: stableKey,
            path: path,
            displayName: nil,
            parentPath: nil,
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil,
            seenEpoch: 0
        )
    }

    /// 去掉文件名开头的音轨号(1-3 位数字 + 可选分隔符):"03 七里香" → "七里香"。
    /// 4 位以上数字(如年份 1989)不当音轨号。
    static func stripTrackNumber(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #"^\d{1,3}\s*[.\-_]?\s*"#, options: .regularExpression) {
            let rest = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }
}
#endif
