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
    var id: String { path }
}

/// 目录列举器(浏览源的文件夹树)。先实现 SMB,其它协议后续补。
protocol TVDirectoryLister: Sendable {
    func list(_ path: String) async throws -> [TVDirEntry]
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
            return TVDirEntry(name: name, isDir: isDir, size: size, path: Self.append(path, name))
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name) < ($1.isDir ? 0 : 1, $1.name) }
    }

    private static func append(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

enum TVScanError: Error { case connectFailed, unsupported, maximumDepthExceeded }

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
        case .smb: return TVSMBLister(source: source, credential: credential)
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

    /// 走查选中目录建库:先路径骨架(快),再逐文件读真实 tag/时长/封面/歌词(慢)。
    /// 返回 nil 表示失败(phase 已置 .failed)。`credential` 用于读文件头补元数据。
    func scan(source: MusicSource, lister: TVDirectoryLister, dirs: [String],
              credential: SourceCredential?) async -> [Song]? {
        phase = .scanning
        indexed = 0
        currentFile = ""
        // (骨架 Song, 同级文件列表) —— 同级文件给 enrich 找同名 .lrc / cover.jpg。
        var collected: [(song: Song, siblings: [TVDirEntry])] = []
        var seen = Set<String>()
        do {
            if source.type == .fnMusic {
                let songs = try await withRoutedSource(source) { routedSource in
                    try await self.scanFnMusic(
                        source: routedSource,
                        credential: credential
                    )
                }
                try Task.checkCancellation()
                indexed = songs.count
                currentFile = ""
                phase = .done
                return songs
            }
            if source.type == .daoliyu {
                let songs = try await withRoutedSource(source) { routedSource in
                    try await self.scanDaoLiYu(
                        source: routedSource,
                        credential: credential
                    )
                }
                try Task.checkCancellation()
                indexed = songs.count
                currentFile = ""
                phase = .done
                return songs
            }
            for dir in dirs {
                try Task.checkCancellation()
                try await collect(
                    lister: lister,
                    path: dir,
                    source: source,
                    depth: 0,
                    into: &collected,
                    seen: &seen
                )
            }
            let songs = try await enrichAll(collected, source: source, credential: credential)
            try Task.checkCancellation()
            indexed = songs.count
            phase = .done
            return songs
        } catch is CancellationError {
            phase = .idle
            currentFile = ""
            return nil
        } catch {
            let message: String
            switch error as? TVScanError {
            case .connectFailed:
                message = PMString("ext.tv.scan.connectFailed")
            case .maximumDepthExceeded:
                message = PMString("ext.tv.scan.depthExceeded", Self.maximumScanDepth)
            default:
                message = error.localizedDescription
            }
            phase = .failed(message)
            return nil
        }
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
        credential: SourceCredential?
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
        credential: SourceCredential?
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

    /// 递归遍历:收集每首歌的路径骨架 + 其所在目录的同级文件(供找歌词/封面)。
    private func collect(lister: TVDirectoryLister, path: String, source: MusicSource,
                         depth: Int,
                         into collected: inout [(song: Song, siblings: [TVDirEntry])],
                         seen: inout Set<String>) async throws {
        try Task.checkCancellation()
        guard depth <= Self.maximumScanDepth else {
            throw TVScanError.maximumDepthExceeded
        }
        let entries = try await lister.list(path)
        try Task.checkCancellation()
        let files = entries.filter { !$0.isDir }
        for e in entries {
            try Task.checkCancellation()
            if e.isDir {
                try await collect(
                    lister: lister,
                    path: e.path,
                    source: source,
                    depth: depth + 1,
                    into: &collected,
                    seen: &seen
                )
            } else {
                let ext = (e.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext)
                    || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
                    guard seen.insert(e.path).inserted else { continue }
                    collected.append((Self.makeSong(entry: e, source: source), files))
                } else if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
                    // 独立 MV: 同目录无同名音频的视频独立成曲, mvPath 指向自身;
                    // 有同名音频时它是那首歌的 sidecar(enrich 阶段挂上), 不成曲。
                    let stem = (e.name as NSString).deletingPathExtension.lowercased()
                    let hasSameNameAudio = files.contains {
                        let fExt = ($0.name as NSString).pathExtension.lowercased()
                        return (PrimuseConstants.supportedAudioExtensions.contains(fExt)
                            || PrimuseConstants.supportedStreamDescriptorExtensions.contains(fExt))
                            && ($0.name as NSString).deletingPathExtension.lowercased() == stem
                    }
                    guard hasSameNameAudio == false else { continue }
                    guard seen.insert(e.path).inserted else { continue }
                    var song = Self.makeSong(entry: e, source: source)
                    song.mvPath = e.path
                    collected.append((song, files))
                } else {
                    continue
                }
                indexed = collected.count
                currentFile = e.path
            }
        }
    }

    /// 逐文件补真实元数据(有限并发,默认 4)。失败的文件保留路径骨架,不阻断。
    private func enrichAll(_ items: [(song: Song, siblings: [TVDirEntry])],
                           source: MusicSource, credential: SourceCredential?) async throws -> [Song] {
        var result: [Song] = []
        result.reserveCapacity(items.count)
        let chunk = 4
        var i = 0
        while i < items.count {
            try Task.checkCancellation()
            let slice = Array(items[i..<min(i + chunk, items.count)])
            let enriched: [Song] = await withTaskGroup(of: (Int, Song).self) { group in
                for (j, it) in slice.enumerated() {
                    group.addTask {
                        guard !Task.isCancelled else { return (j, it.song) }
                        return (j, await TVMetadataEnricher.enrich(song: it.song, source: source,
                                                                   credential: credential, siblings: it.siblings))
                    }
                }
                var acc = [Song?](repeating: nil, count: slice.count)
                for await (j, s) in group { acc[j] = s }
                return acc.compactMap { $0 }
            }
            try Task.checkCancellation()
            result.append(contentsOf: enriched)
            i += chunk
            currentFile = enriched.last?.filePath ?? currentFile
        }
        return result
    }

    /// 路径式建 Song(Phase A):标题=文件名,专辑=父文件夹,艺术家=祖父文件夹。
    /// id / albumID / artistID 用与手机端 LibraryScanner 完全一致的 SHA256 派生,保证可合并去重。
    static func makeSong(entry e: TVDirEntry, source: MusicSource) -> Song {
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
        let artistID = artist.map { sha256($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
        let albumID: String? = (album != nil && artist != nil)
            ? sha256("\(artist!.lowercased()):\(album!.lowercased())") : nil
        return Song(
            id: sha256("\(source.id):\(e.path)"),
            title: title.isEmpty ? e.name : title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: album,
            artistName: artist,
            albumArtistName: artist,
            fileFormat: format,
            filePath: e.path,
            sourceID: source.id,
            fileSize: e.size
        )
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
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
