import CryptoKit
import Foundation
import PrimuseKit

#if DEBUG
/// DL4 之前的 iCloud / Apple TV 传输整理:整份快照解码成每一首歌、在内存里过滤、收封面、再整份编码。只编进调试构建,
/// 给一页一页的整理(`MusicLibrary+PortableSnapshotPreparation.swift`)逐字节对照用,也给规模夹具量「以前」的内存。
/// 与 DL4 之前 `MusicLibrary.swift` 里的三个函数相同,只有三处不同:函数名加了 `Reference`;整理的两个大小上限
/// (60 MiB、64 MiB)改成参数 `limits`,默认值就是原来的数,好让小样例也能走到每一级退路;收封面改调这里的那一份。
extension MusicLibrary {
    /// The local snapshot stays metadata-only. Transport copies include bounded,
    /// content-deduplicated covers so tvOS can display artwork without the sender's cache.
    nonisolated static func preparePortableSnapshotDataIncludingArtworkAssetsReference(
        _ data: Data,
        cloudSources: [MusicSource]? = nil,
        excludedSourceIDs: Set<String> = [],
        assetStore: MetadataAssetStore = .shared,
        maximumArtworkBytes: Int = portableArtworkBudgetBytes,
        limits: PortableSnapshotSizeLimits = .standard
    ) async -> PortableSnapshotTransferData? {
        guard !Task.isCancelled else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var snapshot = try? decoder.decode(Snapshot.self, from: data) else { return nil }

        var eligibleLyricsFileNames: Set<String>?
        // Without a cloud source list nothing is filtered out, so the payload is
        // not the device-local-only case the automatic upload guard looks for.
        var hasCloudEligibleSources = true
        if let cloudSources {
            hasCloudEligibleSources = cloudSources.contains(
                where: MusicSourceCloudSyncPolicy.isEligible
            )
            snapshot.songs = MusicSourceCloudSyncPolicy.eligibleSongs(
                snapshot.songs,
                sources: cloudSources
            )
            // 这台设备单独关了 iCloud 同步的源:扫描结果也不出设备。
            if !excludedSourceIDs.isEmpty {
                snapshot.songs.removeAll { excludedSourceIDs.contains($0.sourceID) }
            }
            let retainedSourceIDs = Set(snapshot.songs.map(\.sourceID))
            snapshot.automaticArtistArtworkCatalogs?.removeAll {
                !retainedSourceIDs.contains($0.sourceID)
            }
            let retainedSongIDs = Set(snapshot.songs.map(\.id))
            if var playlistSongIDs = snapshot.playlistSongIDs {
                for playlistID in playlistSongIDs.keys {
                    playlistSongIDs[playlistID]?.removeAll {
                        !retainedSongIDs.contains($0) && !PlaylistPendingEntry.isPendingID($0)
                    }
                }
                snapshot.playlistSongIDs = playlistSongIDs
            }
            snapshot.recentPlaybackSongIDs?.removeAll {
                !retainedSongIDs.contains($0)
            }
            var names = Set<String>()
            names.reserveCapacity(snapshot.songs.count * 2)
            for song in snapshot.songs {
                names.insert(
                    MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
                )
                if let legacyName = song.lyricsFileName,
                   LyricsSnapshotEncoder.isValidFileName(legacyName) {
                    names.insert(legacyName)
                }
            }
            eligibleLyricsFileNames = names
        }

        let maximumEncodedSnapshotBytes = limits.encodedBytes
        let availableEncodedBytes = max(0, maximumEncodedSnapshotBytes - data.count - 512)
        let maximumRawArtworkBytes = min(max(0, maximumArtworkBytes), availableEncodedBytes * 3 / 4)
        guard let artwork = await collectPortableArtworkReference(
            songs: snapshot.songs,
            artworkOverrides: snapshot.artworkOverrides,
            assetStore: assetStore,
            maximumRawBytes: maximumRawArtworkBytes,
            maximumEncodedBytes: availableEncodedBytes
        ) else { return nil }
        snapshot.artworkAssets = artwork.customAssets.isEmpty ? nil : artwork.customAssets
        snapshot.cachedArtworkAssets = artwork.cachedAssets.isEmpty ? nil : artwork.cachedAssets
        snapshot.artworkCacheReferences = artwork.references.isEmpty ? nil : artwork.references
        snapshot.coverContentSongIDs = artwork.coverContentSongIDs.isEmpty ? nil : artwork.coverContentSongIDs

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(snapshot),
           encoded.count <= maximumEncodedSnapshotBytes {
            return PortableSnapshotTransferData(
                data: LibraryCatalogExportOutput.fileBacked(encoded),
                eligibleLyricsFileNames: eligibleLyricsFileNames,
                eligibleSongCount: snapshot.songs.count,
                artworkBytes: artwork.rawBytes,
                hasCloudEligibleSources: hasCloudEligibleSources
            )
        }

        // 放不下时先丢封面内容表:它只是让别的设备少读几次文件,Apple TV 看得见的
        // 封面更要紧。
        let coverContentSongIDs = snapshot.coverContentSongIDs
        if coverContentSongIDs != nil {
            snapshot.coverContentSongIDs = nil
            if let encoded = try? encoder.encode(snapshot),
               encoded.count <= maximumEncodedSnapshotBytes {
                return PortableSnapshotTransferData(
                    data: LibraryCatalogExportOutput.fileBacked(encoded),
                    eligibleLyricsFileNames: eligibleLyricsFileNames,
                    eligibleSongCount: snapshot.songs.count,
                    artworkBytes: artwork.rawBytes,
                    hasCloudEligibleSources: hasCloudEligibleSources
                )
            }
        }

        // Artwork is optional. Never fall back to the unfiltered raw snapshot
        // for CloudKit, because that would reintroduce device-local songs.
        snapshot.artworkAssets = nil
        snapshot.cachedArtworkAssets = nil
        snapshot.artworkCacheReferences = nil
        if let coverContentSongIDs {
            snapshot.coverContentSongIDs = coverContentSongIDs
            if let encoded = try? encoder.encode(snapshot),
               encoded.count <= maximumEncodedSnapshotBytes {
                return PortableSnapshotTransferData(
                    data: LibraryCatalogExportOutput.fileBacked(encoded),
                    eligibleLyricsFileNames: eligibleLyricsFileNames,
                    eligibleSongCount: snapshot.songs.count,
                    artworkBytes: 0,
                    hasCloudEligibleSources: hasCloudEligibleSources
                )
            }
            snapshot.coverContentSongIDs = nil
        }
        guard let encoded = try? encoder.encode(snapshot),
              encoded.count <= limits.withoutArtworkBytes else { return nil }
        return PortableSnapshotTransferData(
            data: LibraryCatalogExportOutput.fileBacked(encoded),
            eligibleLyricsFileNames: eligibleLyricsFileNames,
            eligibleSongCount: snapshot.songs.count,
            artworkBytes: 0,
            hasCloudEligibleSources: hasCloudEligibleSources
        )
    }

    /// LAN pairing sends the library first and its covers afterwards in
    /// batches, so the covers are gathered on their own here with only a raw
    /// byte budget. Returns nil when the snapshot is unreadable or the task is
    /// cancelled.
    nonisolated static func collectPortableArtworkReference(
        fromSnapshotData data: Data,
        assetStore: MetadataAssetStore = .shared,
        maximumRawBytes: Int = portableArtworkBudgetBytes
    ) async -> PortableArtworkCollection? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return nil }
        return await collectPortableArtworkReference(
            songs: snapshot.songs,
            artworkOverrides: snapshot.artworkOverrides,
            assetStore: assetStore,
            maximumRawBytes: maximumRawBytes,
            maximumEncodedBytes: Int.max / 4
        )
    }

    /// Bounded, content-deduplicated covers for a transport copy. The encoded
    /// budget counts the base64 text the covers become inside snapshot JSON.
    nonisolated static func collectPortableArtworkReference(
        songs: [Song],
        artworkOverrides: [LibraryArtworkOverride]?,
        assetStore: MetadataAssetStore,
        maximumRawBytes: Int,
        maximumEncodedBytes: Int
    ) async -> PortableArtworkCollection? {
        var usedBytes = 0
        var usedEncodedBytes = 0
        var assets: [String: Data] = [:]
        let uploaded = (artworkOverrides ?? [])
            .filter { $0.mode == .uploaded }
            .sorted { $0.updatedAt > $1.updatedAt }
        let selectedSongContentIDs = songs.compactMap { song -> String? in
            guard let reference = song.coverArtFileName, StoredArtworkOrigin.resolve(reference) == .selected else { return nil }
            return StoredArtworkOrigin.contentID(reference)
        }
        for contentID in uploaded.compactMap(\.uploadedContentID) + selectedSongContentIDs {
            guard assets[contentID] == nil,
                  let artworkData = assetStore.customArtworkData(
                    contentID: contentID
                  ),
                  usedBytes <= maximumRawBytes - artworkData.count else {
                continue
            }
            let encodedBytes = ((artworkData.count + 2) / 3) * 4 + contentID.utf8.count + 6
            guard encodedBytes <= maximumEncodedBytes - usedEncodedBytes else { continue }
            assets[contentID] = artworkData
            usedBytes += artworkData.count
            usedEncodedBytes += encodedBytes
        }

        var cachedAssets: [String: Data] = [:]
        var references: [String: String] = [:]
        var coverContentSongIDs: [String: [String]] = [:]
        var preparedContent: [String: String] = [:]
        var attemptedContent = Set<String>()
        var visitedFiles = Set<String>()
        var artworkBudgetExhausted = false
        func includeCachedCover(named sourceName: String, as destinationName: String) async {
            guard references[destinationName] == nil,
                  visitedFiles.insert(destinationName).inserted,
                  let cacheIdentity = assetStore.coverContentIdentifier(named: sourceName) else { return }
            let sourceID = cacheIdentity.hasPrefix("sha256:") ? cacheIdentity : sourceName + ":" + cacheIdentity
            let referenceBytes = destinationName.utf8.count + 64 + 6
            guard referenceBytes <= maximumEncodedBytes - usedEncodedBytes else { return }
            if let contentID = preparedContent[sourceID] {
                references[destinationName] = contentID
                usedEncodedBytes += referenceBytes
                return
            }
            // A cover that cannot fit the remaining budget must not be
            // decoded again for every track on the same album.
            guard !artworkBudgetExhausted,
                  usedBytes < maximumRawBytes,
                  attemptedContent.insert(sourceID).inserted else { return }
            let startedAt = ContinuousClock.now
            guard let cover = assetStore.preparePortableCover(
                named: sourceName, contentIdentifier: sourceID
            ) else { return }
            if cover.requiredProcessing {
                // Cold exports can encounter thousands of distinct covers.
                // Yield between conversions and leave CPU time for playback.
                do {
                    try await Task.sleep(for: max(.milliseconds(20), startedAt.duration(to: .now)))
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            let image = cover.data
            let contentID = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            if cachedAssets[contentID] == nil {
                let encodedBytes = ((image.count + 2) / 3) * 4 + contentID.utf8.count + 6
                guard image.count <= maximumRawBytes - usedBytes,
                      encodedBytes + referenceBytes <= maximumEncodedBytes - usedEncodedBytes else {
                    artworkBudgetExhausted = true
                    return
                }
                cachedAssets[contentID] = image
                usedBytes += image.count
                usedEncodedBytes += encodedBytes
            }
            preparedContent[sourceID] = contentID
            references[destinationName] = contentID
            usedEncodedBytes += referenceBytes
        }
        // Iterate only retained songs: CloudKit excludes device-local media and
        // must also exclude the ordinary covers belonging solely to that media.
        for song in songs {
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return nil }
            if let albumID = song.albumID, !albumID.isEmpty {
                let name = "album/" + assetStore.expectedCoverFileName(for: "album_\(albumID)")
                await includeCachedCover(named: name, as: name)
            }
            if let reference = song.coverArtFileName, StoredArtworkOrigin.resolve(reference) == .selected,
               let contentID = StoredArtworkOrigin.contentID(reference), assets[contentID] != nil {
                continue
            }
            let name = assetStore.expectedCoverFileName(for: song.id)
            let sourceName: String
            if StoredArtworkOrigin.resolve(song.coverArtFileName) == .selected,
               let reference = song.coverArtFileName {
                sourceName = reference
            } else if let identity = assetStore.coverContentIdentifier(named: name) {
                if identity.hasPrefix(Self.coverContentIdentityPrefix) {
                    let key = String(identity.dropFirst(Self.coverContentIdentityPrefix.count))
                    if PeerScanSeedPolicy.isContentKey(key) {
                        coverContentSongIDs[key, default: []].append(song.id)
                    }
                }
                sourceName = name
            } else if let legacy = song.coverArtFileName, assetStore.isLegacyLocalRef(legacy) {
                sourceName = legacy
            } else {
                continue
            }
            await includeCachedCover(named: sourceName, as: name)
        }
        for name in portableArtistCacheNames(songs: songs, assetStore: assetStore).sorted() {
            guard !Task.isCancelled else { return nil }
            await includeCachedCover(named: name, as: name)
        }
        guard !Task.isCancelled else { return nil }
        return PortableArtworkCollection(
            customAssets: assets,
            cachedAssets: cachedAssets,
            references: references,
            rawBytes: usedBytes,
            coverContentSongIDs: coverContentSongIDs
        )
    }
}
#endif
