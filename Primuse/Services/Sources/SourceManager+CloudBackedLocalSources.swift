import Foundation
import PrimuseKit

/// 放在 iCloud 云盘或别的文件提供方里的本机文件夹(系统随时可能把文件移回云端):认出这类源、
/// 下载离线时先从 iCloud 取回、播过的歌复制进播放缓存。
extension SourceManager {
    func isCloudBackedLocalSource(_ source: MusicSource) -> Bool {
        LocalCloudStoragePathPolicy.isCloudBackedLocalSource(
            source,
            registeredCloudLocalSourceIDs: cloudBackedLocalSourceIDs
        )
    }

    func isCloudBackedLocalSourceID(_ sourceID: String) -> Bool {
        cloudBackedLocalSourceIDs.contains(sourceID)
    }

    /// 起播时解析出的文件在 iCloud 云盘或文件提供方里:把它的源记成云盘托管的本机源。
    /// 只给 `.local` 源调(调用方先看源的类型),登记表里因此只有本机源。
    func noteCloudBackedLocalSourceIfNeeded(_ sourceID: String, url: URL) async {
        guard url.isFileURL, await UbiquitousPlaybackFile.isCloudBacked(url) else { return }
        CloudBackedLocalSourceRegistry.shared.register(sourceID: sourceID)
        cloudBackedLocalSourceIDs = CloudBackedLocalSourceRegistry.shared.sourceIDs
        _ = await ensureAudioCacheScopeValidated(for: sourceID)
    }

    func probeCloudBackedLocalSources(_ sources: [MusicSource]) {
        // 只动这份源列表里认得的源:删掉的、不是本机文件夹的去掉登记。不按这份列表整表裁剪 ——
        // 测试里另建的管理器只认得自己那一个源,那样会把 App 自己登记的源全清掉。
        for source in sources where source.isDeleted || source.type != .local {
            CloudBackedLocalSourceRegistry.shared.unregister(sourceID: source.id)
        }
        let localSources = sources.filter { !$0.isDeleted && $0.type == .local }

        var candidates: [(id: String, basePath: String?)] = []
        for source in localSources {
            if LocalCloudStoragePathPolicy.isCloudBackedPath(source.basePath) {
                CloudBackedLocalSourceRegistry.shared.register(sourceID: source.id)
            } else {
                candidates.append((id: source.id, basePath: source.basePath))
            }
        }
        cloudBackedLocalSourceIDs = CloudBackedLocalSourceRegistry.shared.sourceIDs

        cloudBackedLocalProbeTask?.cancel()
        guard !candidates.isEmpty else {
            cloudBackedLocalProbeTask = nil
            return
        }
        cloudBackedLocalProbeTask = Task.detached(priority: .utility) {
            for candidate in candidates {
                if Task.isCancelled { return }
                var urlsToCheck: [URL] = []
                var scopedURLs: [URL] = []
                if let refs = LocalBookmarkStore.resolveReferences(
                    sourceID: candidate.id,
                    refreshStaleBookmarks: false
                ), !refs.isEmpty {
                    for ref in refs {
                        if ref.url.startAccessingSecurityScopedResource() {
                            scopedURLs.append(ref.url)
                        }
                        urlsToCheck.append(ref.url)
                    }
                } else if let basePath = candidate.basePath, !basePath.isEmpty {
                    urlsToCheck.append(URL(fileURLWithPath: basePath))
                }
                defer {
                    for url in scopedURLs {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                guard !urlsToCheck.isEmpty else { continue }
                let hasExistingRoot = urlsToCheck.contains {
                    FileManager.default.fileExists(atPath: $0.path)
                        || UbiquitousPlaybackFile.isEvictedPlaceholder($0)
                }
                var isCloud = false
                for url in urlsToCheck where !isCloud {
                    isCloud = await UbiquitousPlaybackFile.isCloudBacked(url)
                }
                if isCloud {
                    CloudBackedLocalSourceRegistry.shared.register(sourceID: candidate.id)
                } else if hasExistingRoot {
                    CloudBackedLocalSourceRegistry.shared.unregister(sourceID: candidate.id)
                }
            }
        }
    }

    func ensureLocalURLDownloadedForOffline(_ localURL: URL, song: Song, source: MusicSource) async throws {
        guard localURL.isFileURL else { return }
        // 登记表里只记本机文件夹源(资料库源的文件也可能在 iCloud 里,但它不走本机源的缓存规则)。
        if source.type == .local, await UbiquitousPlaybackFile.isCloudBacked(localURL) {
            CloudBackedLocalSourceRegistry.shared.register(sourceID: song.sourceID)
            cloudBackedLocalSourceIDs = CloudBackedLocalSourceRegistry.shared.sourceIDs
        }
        guard await UbiquitousPlaybackFile.needsDownload(localURL) else { return }
        try await UbiquitousPlaybackFile.download(
            localURL,
            isOffline: { @MainActor in
                NetworkMonitor.shared.hasDeterminedPath && !NetworkMonitor.shared.isReachable
            },
            isCurrent: { !Task.isCancelled },
            onProgress: { [weak self] progress in
                guard let progress else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          let current = self.offlineAudioSnapshots[song.id],
                          current.state == .downloading else { return }
                    let clamped = min(max(progress, 0), 1)
                    if let existing = current.progress, abs(existing - clamped) < 0.01 { return }
                    self.setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                        state: .downloading,
                        progress: clamped,
                        byteCount: current.byteCount,
                        errorMessage: nil
                    ), for: song.id)
                }
            }
        )
    }

    func cacheCloudBackedLocalFile(
        song: Song,
        source: MusicSource,
        allowsICloudDownload: Bool,
        downloadIfNeeded: Bool,
        writesToPlaybackCache: Bool
    ) async throws {
        let conn = connector(for: source)
        try await conn.connect()
        try Task.checkCancellation()
        let localURL = try await conn.localURL(for: song.filePath)
        guard localURL.isFileURL else { return }
        if !isCloudBackedLocalSource(source) {
            guard await UbiquitousPlaybackFile.isCloudBacked(localURL) else { return }
        }
        CloudBackedLocalSourceRegistry.shared.register(sourceID: source.id)
        cloudBackedLocalSourceIDs = CloudBackedLocalSourceRegistry.shared.sourceIDs

        if await UbiquitousPlaybackFile.needsDownload(localURL) {
            guard downloadIfNeeded else {
                if allowsICloudDownload {
                    _ = try? await UbiquitousPlaybackFile.requestDownloadIfNeeded(localURL)
                }
                return
            }
            try await UbiquitousPlaybackFile.download(
                localURL,
                isOffline: { @MainActor in
                    NetworkMonitor.shared.hasDeterminedPath && !NetworkMonitor.shared.isReachable
                },
                isCurrent: { !Task.isCancelled }
            )
        }

        guard writesToPlaybackCache else { return }
        try Task.checkCancellation()
        guard automaticAudioCachingEnabled,
              audioCacheReadsAreAllowed(for: song.sourceID),
              cachedPlaybackURL(for: song) == nil else { return }

        let relativePath = audioCacheRelativePath(for: song)
        guard !hasOfflineDownloadTask(at: relativePath) else { return }

        let actualSize = byteSize(at: localURL)
        guard actualSize > 0 else { return }

        guard let lease = await AudioCacheManager.shared.acquirePathFamilyLease(
            path: relativePath,
            reserveBytes: 0
        ) else { return }
        defer {
            Task {
                await AudioCacheManager.shared.releasePathFamilyLease(lease)
            }
        }
        guard audioCacheReadsAreAllowed(for: song.sourceID),
              cachedPlaybackURL(for: song) == nil else { return }

        let maximumBytes = try await prepareOfflineTransferCapacity(
            expectedSize: actualSize,
            lease: lease,
            respectsConfiguredCacheLimit: true
        )
        let target = cacheURL(for: song)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expectedSize = song.fileSize > 0 ? song.fileSize : actualSize
        try await Task.detached(priority: .utility) {
            try Self.validateCompleteCacheFile(
                at: localURL,
                expectedSize: expectedSize,
                maximumBytes: maximumBytes
            )
            try Self.installCacheFile(from: localURL, to: target, move: false)
        }.value
        try Task.checkCancellation()

        await AudioCacheManager.shared.recordAccess(path: relativePath)
        _ = await AudioCacheManager.shared.evictIfNeeded(reserveBytes: 0)
        let cachedSize = fileSize(at: target) ?? actualSize
        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .cached,
            progress: nil,
            byteCount: cachedSize,
            errorMessage: nil
        ), for: song.id)
        plog("🗄️ Cache: stored cloud-backed local audio '\(song.title)' size=\(cachedSize / 1024)KB")
    }
}
