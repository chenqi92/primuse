import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
import PrimuseKit
import SFBAudioEngine
#if os(iOS)
import CarPlay
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
import WidgetKit
#endif

extension AudioPlayerService {
    // MARK: - Helpers

    /// Run after a non-recoverable playback failure (unsupported format,
    /// empty stream, decode error, URL resolve fail, fallback
    /// exhausted, mid-stream decode crash). Centralises the "what
    /// happens after failure" rule so every error path stays
    /// consistent:
    /// - Under `repeatMode == .one`, `nextSongInQueue()` returns the
    ///   current song. Calling `next()` from there would either loop the
    ///   broken file forever (single-song queue) or jump to a different
    ///   track and silently violate repeat-one (multi-song queue). So
    ///   we suspend the transport and let the user see the error toast that
    ///   the caller already raised, while preserving the selected item.
    /// - Otherwise advance if there's a real successor; if not (last
    ///   track failed, repeat-off), suspend the broken transport while keeping
    ///   the current item and queue available for an explicit retry.
    func autoAdvanceAfterFailure(
        skippingSourceID failedSourceID: String? = nil,
        trigger: String = #function
    ) async {
        guard let advanceTicket = localPipelineAdvanceTicket else {
            plog("🛡️ dropped failure advance trigger=\(trigger) reason=noActiveTicket")
            return
        }
        let transportIsActive = isPlaying
            ? audioEngine.isActuallyPlaying
            : interruptionResumePolicy.playbackIsIntended
        await autoAdvanceAfterFailure(
            advanceTicket: advanceTicket,
            trigger: trigger,
            skippingSourceID: failedSourceID,
            transportIsActive: transportIsActive
        )
    }

    func autoAdvanceAfterFailure(
        advanceTicket: PlaybackAdvanceTicket,
        trigger: String,
        skippingSourceID failedSourceID: String? = nil,
        transportIsActive: Bool? = nil
    ) async {
        guard automaticAdvanceDecision(
            for: advanceTicket,
            trigger: trigger,
            consume: true,
            transportIsActive: transportIsActive
        ) == .accepted else { return }
        if let song = currentSong,
           playbackMetadataSourceType?(song.sourceID) == .appleMusicLibrary {
            suspendPlaybackAfterFailure(
                reason: "apple-music-local-playback-failure",
                message: lastPlaybackError ?? String(localized: "playback_error_local_audio")
            )
            return
        }
        if isDLNACast(currentSong) {
            stop()
            return
        }
        if repeatMode == .one {
            suspendPlaybackAfterFailure(
                reason: "repeat-one-playback-failure",
                message: lastPlaybackError ?? String(localized: "playback_error_decode")
            )
            return
        }

        let startsChain = !isFailureAdvanceChainActive
        if startsChain {
            isFailureAdvanceChainActive = true
            consecutiveFailureAdvanceCount = 0
        }
        defer {
            if startsChain {
                isFailureAdvanceChainActive = false
                consecutiveFailureAdvanceCount = 0
            }
        }

        consecutiveFailureAdvanceCount += 1
        guard consecutiveFailureAdvanceCount <= Self.maxConsecutiveFailureAdvances else {
            plog("⏸️ Suspended after \(Self.maxConsecutiveFailureAdvances) consecutive playback failures")
            suspendPlaybackAfterFailure(
                reason: "consecutive-playback-failures",
                message: lastPlaybackError ?? String(localized: "playback_error_decode")
            )
            return
        }

        if let failedSourceID {
            var skippedCount = 0
            while let candidate = nextSongInQueue(),
                  SourceFailureAdvancePolicy.shouldSkipCandidate(
                    failedSourceID: failedSourceID,
                    candidateSourceID: candidate.sourceID
                  ),
                  sourceManager?.hasUsableCachedAudioForPlayback(candidate) != true {
                guard skippedCount < queueEntries.count else {
                    plog("⏸️ No playable provider remains after source-wide failure")
                    suspendPlaybackPreservingSelection(reason: "source-wide-playback-failure")
                    return
                }
                advanceToNextIndex()
                skippedCount += 1
            }
            if skippedCount > 0 {
                plog("⏭️ Skipped \(skippedCount) queued entr\(skippedCount == 1 ? "y" : "ies") from unavailable source")
            }
        }

        if nextSongInQueue() != nil {
            await Task.yield()
            guard interruptionResumePolicy.playbackIsIntended,
                  currentSong?.id == advanceTicket.itemID,
                  playbackAdvancePolicy.isGenerationCurrent(for: advanceTicket),
                  playbackAdvancePolicy.activeTicket == nil else {
                plog("🛡️ cancelled failure advance after yield trigger=\(trigger)")
                return
            }
            await next(
                context: failedSourceID == nil ? .userInitiated : .sourceFailureRecovery,
                caller: "auto-failure:\(trigger)",
                callerLine: 0
            )
        } else {
            suspendPlaybackAfterFailure(
                reason: "queue-tail-playback-failure",
                message: lastPlaybackError ?? String(localized: "playback_error_decode")
            )
        }
    }

    /// A single file request or decoder timeout cannot establish a source
    /// outage. Only account failures or independently unreachable endpoints
    /// justify skipping other uncached songs from that provider.
    func isSourceWideResolutionFailure(_ error: Error, sourceID: String) async -> Bool {
        if sourceManager?.isSourceKnownUnavailableForPlayback(sourceID) == true { return true }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable:
                return true
            case .connectionFailed, .timeout:
                return await sourceManager?.playbackSourceEndpointsAreUnavailable(
                    sourceID: sourceID, refresh: true
                ) == true
            case .pathNotFound, .fileNotFound:
                return false
            }
        }
        if SourceNetworkFailurePolicy.isNetworkFailure(error) {
            return await sourceManager?.playbackSourceEndpointsAreUnavailable(
                sourceID: sourceID, refresh: true
            ) == true
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return await isSourceWideResolutionFailure(underlying, sourceID: sourceID)
        }
        return false
    }

    func isDLNACast(_ song: Song?) -> Bool {
        song?.sourceID == Self.dlnaSourceID
    }

    /// Shuffle is a library-discovery mode, not a request to repeat the only
    /// item in a one-song queue. Once the current shuffle round is exhausted,
    /// append currently visible playable songs that are not already present
    /// and make only those new entries the next shuffle segment.
    @discardableResult
    func extendExhaustedShuffleFromLibrary() -> Bool {
        guard shuffleEnabled,
              repeatMode != .one,
              nextSongInQueue() == nil,
              let library,
              queueEntries.indices.contains(currentIndex) else { return false }

        let playable = library.visibleSongs.filteredPlayable()
        let candidateIDs = ShuffleContinuationPolicy.candidateIDs(
            queueIDs: queueEntries.map(\.song.id),
            libraryIDs: playable.map(\.id),
            currentID: currentSong?.id
        )
        guard !candidateIDs.isEmpty else { return false }

        let songsByID = Dictionary(
            playable.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let additions = candidateIDs.compactMap { songsByID[$0] }
        guard !additions.isEmpty else { return false }

        let firstNewIndex = queueEntries.count
        invalidatePreparedQueueSuccessor()
        queueEntries.append(contentsOf: additions.map { QueueEntry(song: $0) })
        pendingNextShuffleIndices = nil
        shuffledIndices = [currentIndex]
            + Array(firstNewIndex..<queueEntries.count).shuffled()
        shufflePosition = 0
        plog("🔀 Extended exhausted shuffle queue by \(additions.count) library songs")
        return true
    }

    private struct QueueTraversalTarget {
        let queueIndex: Int
        let shufflePosition: Int?
        let pendingShuffleRound: [Int]?
    }

    func isSourceEnabledForPlayback(_ sourceID: String) -> Bool {
        library?.disabledSourceIDs.contains(sourceID) != true
    }

    /// Keep durable queue order intact during an outage. Complete local audio
    /// stays eligible and a changed network path immediately expires old
    /// reachability evidence, including when moving between two Wi-Fi networks.
    func isSongAvailableForNewPlayback(_ song: Song) -> Bool {
        let isUnreachable = sourceManager?.isSourceKnownUnavailableForPlayback(song.sourceID) == true
        return PlaybackSourceAvailabilityPolicy.allowsPlayback(
            isSourceEnabled: isSourceEnabledForPlayback(song.sourceID),
            isSourceUnreachable: isUnreachable,
            hasUsableLocalAudio: isUnreachable
                && sourceManager?.hasUsableCachedAudioForPlayback(song) == true
        )
    }

    func nextQueueEntryInQueue(
        respectsRepeatOne: Bool = true
    ) -> QueueEntry? {
        guard let target = nextQueueTraversalTarget(
            respectsRepeatOne: respectsRepeatOne
        ) else { return nil }
        return queueEntries[target.queueIndex]
    }

    func nextSongInQueue() -> Song? {
        nextQueueEntryInQueue()?.song
    }

    func nextQueueTraversalTarget(
        respectsRepeatOne: Bool = true,
        wrapsAtEnd: Bool? = nil
    ) -> QueueTraversalTarget? {
        upcomingQueueTraversalTargets(
            maximumCount: 1,
            respectsRepeatOne: respectsRepeatOne,
            wrapsAtEnd: wrapsAtEnd
        ).first
    }

    /// Returns enabled successors in exactly the order that advance will
    /// adopt. Disabled entries are only filtered from traversal, never from
    /// `queueEntries`, so CloudKit re-enablement restores them in place.
    func upcomingQueueTraversalTargets(
        maximumCount: Int,
        respectsRepeatOne: Bool = true,
        wrapsAtEnd: Bool? = nil
    ) -> [QueueTraversalTarget] {
        guard !queueEntries.isEmpty, maximumCount > 0 else { return [] }
        let shouldWrapAtEnd = wrapsAtEnd ?? (repeatMode == .all)

        let isAvailable: (Int) -> Bool = { [self] index in
            queueEntries.indices.contains(index)
                && isSongAvailableForNewPlayback(queueEntries[index].song)
        }

        if respectsRepeatOne, repeatMode == .one {
            guard isAvailable(currentIndex) else { return [] }
            let position = shuffleEnabled
                ? shuffledIndices.firstIndex(of: currentIndex)
                : nil
            return [QueueTraversalTarget(
                queueIndex: currentIndex,
                shufflePosition: position,
                pendingShuffleRound: nil
            )]
        }

        var result: [QueueTraversalTarget] = []
        result.reserveCapacity(maximumCount)

        if shuffleEnabled {
            let anchorPosition = shuffledIndices.firstIndex(of: currentIndex)
                ?? min(max(shufflePosition, -1), shuffledIndices.count - 1)
            var cursor = anchorPosition
            while result.count < maximumCount,
                  let position = QueueTraversalPolicy.nextAvailableTraversalPosition(
                    in: shuffledIndices,
                    queueCount: queueEntries.count,
                    after: cursor,
                    isAvailable: isAvailable
                  ) {
                result.append(QueueTraversalTarget(
                    queueIndex: shuffledIndices[position],
                    shufflePosition: position,
                    pendingShuffleRound: nil
                ))
                cursor = position
            }

            if result.count < maximumCount, shouldWrapAtEnd {
                let pending = preparedNextShuffleRound()
                var pendingCursor = -1
                while result.count < maximumCount,
                      let position = QueueTraversalPolicy.nextAvailableTraversalPosition(
                        in: pending,
                        queueCount: queueEntries.count,
                        after: pendingCursor,
                        isAvailable: isAvailable
                      ) {
                    result.append(QueueTraversalTarget(
                        queueIndex: pending[position],
                        shufflePosition: position,
                        pendingShuffleRound: pending
                    ))
                    pendingCursor = position
                }
            }
            return result
        }

        var cursor = currentIndex
        while result.count < maximumCount,
              let index = QueueTraversalPolicy.nextAvailableIndex(
                queueCount: queueEntries.count,
                after: cursor,
                wraps: false,
                isAvailable: isAvailable
              ) {
            result.append(QueueTraversalTarget(
                queueIndex: index,
                shufflePosition: nil,
                pendingShuffleRound: nil
            ))
            cursor = index
        }

        if result.count < maximumCount, shouldWrapAtEnd, currentIndex >= 0 {
            let wrapEnd = min(currentIndex, queueEntries.count - 1)
            if wrapEnd >= 0 {
                for index in 0...wrapEnd where isAvailable(index) {
                    result.append(QueueTraversalTarget(
                        queueIndex: index,
                        shufflePosition: nil,
                        pendingShuffleRound: nil
                    ))
                    if result.count == maximumCount { break }
                }
            }
        }
        return result
    }

    func previousQueueTraversalTarget() -> QueueTraversalTarget? {
        guard !queueEntries.isEmpty else { return nil }
        let isAvailable: (Int) -> Bool = { [self] index in
            queueEntries.indices.contains(index)
                && isSongAvailableForNewPlayback(queueEntries[index].song)
        }

        if shuffleEnabled {
            let anchorPosition = shuffledIndices.firstIndex(of: currentIndex)
                ?? min(max(shufflePosition, 0), max(0, shuffledIndices.count - 1))
            if let position = QueueTraversalPolicy.previousAvailableTraversalPosition(
                in: shuffledIndices,
                queueCount: queueEntries.count,
                before: anchorPosition,
                isAvailable: isAvailable
            ) {
                return QueueTraversalTarget(
                    queueIndex: shuffledIndices[position],
                    shufflePosition: position,
                    pendingShuffleRound: nil
                )
            }
            guard isAvailable(currentIndex) else { return nil }
            return QueueTraversalTarget(
                queueIndex: currentIndex,
                shufflePosition: shuffledIndices.firstIndex(of: currentIndex),
                pendingShuffleRound: nil
            )
        }

        if let index = QueueTraversalPolicy.previousAvailableIndex(
            before: currentIndex,
            isAvailable: isAvailable
        ) {
            return QueueTraversalTarget(
                queueIndex: index,
                shufflePosition: nil,
                pendingShuffleRound: nil
            )
        }

        if currentIndex + 1 < queueEntries.count {
            for index in stride(
                from: queueEntries.count - 1,
                through: currentIndex + 1,
                by: -1
            ) where isAvailable(index) {
                return QueueTraversalTarget(
                    queueIndex: index,
                    shufflePosition: nil,
                    pendingShuffleRound: nil
                )
            }
        }

        guard isAvailable(currentIndex) else { return nil }
        return QueueTraversalTarget(
            queueIndex: currentIndex,
            shufflePosition: nil,
            pendingShuffleRound: nil
        )
    }

    func applyQueueTraversalTarget(_ target: QueueTraversalTarget) {
        guard queueEntries.indices.contains(target.queueIndex) else { return }
        if let pending = target.pendingShuffleRound,
           let position = target.shufflePosition,
           pending.indices.contains(position),
           pending[position] == target.queueIndex {
            pendingNextShuffleIndices = nil
            shuffledIndices = pending
            shufflePosition = position
        } else if shuffleEnabled,
                  let position = target.shufflePosition,
                  shuffledIndices.indices.contains(position),
                  shuffledIndices[position] == target.queueIndex {
            shufflePosition = position
        }
        currentIndex = target.queueIndex
    }

    @discardableResult
    func advanceToNextIndex(
        respectsRepeatOne: Bool = true
    ) -> Bool {
        guard let target = nextQueueTraversalTarget(
            respectsRepeatOne: respectsRepeatOne
        ) else { return false }
        applyQueueTraversalTarget(target)
        return true
    }

    func rebuildShuffleOrder() {
        guard !queue.isEmpty else { shuffledIndices = []; pendingNextShuffleIndices = nil; return }
        shuffledIndices = Array(0..<queue.count).shuffled()
        shufflePosition = 0
        pendingNextShuffleIndices = nil
        // Place current index at position 0 so current song stays first
        // when shuffle is toggled mid-playback (we don't want to jump
        // off the current track). Wrap-around uses a different builder.
        if let pos = shuffledIndices.firstIndex(of: currentIndex) {
            shuffledIndices.swapAt(0, pos)
        }
    }

    /// Cache the first generated repeat-all round. `pendingNextShuffleIndices`
    /// is observation-ignored because SwiftUI may call this from a computed
    /// presentation getter; preparing hidden playback state must not invalidate
    /// that getter and start another observation pass.
    func preparedNextShuffleRound() -> [Int] {
        let prepared = ShuffleRoundPreparationPolicy.preparedRound(
            pending: pendingNextShuffleIndices,
            generate: buildPendingNextRound
        )
        if pendingNextShuffleIndices == nil {
            pendingNextShuffleIndices = prepared
        }
        return prepared
    }

    /// Build (but don't install) the next round's shuffle order. Preview,
    /// prefetch and the actual wrap share the cached result. Avoid placing the
    /// eventual boundary track at position 0 so repeat-all doesn't feel like
    /// repeat-one even when the UI prepares the round early.
    private func buildPendingNextRound() -> [Int] {
        guard !queue.isEmpty else { return [] }
        var order = Array(0..<queue.count).shuffled()
        // The UI may prepare this round well before the current song reaches
        // the boundary. Compare against the eventual last slot of this round,
        // not the song that happened to be current when the preview opened.
        let boundaryIndex = shuffledIndices.last ?? currentIndex
        if queue.count > 1, order.first == boundaryIndex {
            let otherPos = Int.random(in: 1..<order.count)
            order.swapAt(0, otherPos)
        }
        return order
    }

    // MARK: - URL Resolution

    /// 用于日志的脱敏 URL —— 只保留 scheme+host(:port)+path, 剥掉 query 和
    /// user-info。多个源把可重放凭据放在 query 里 (Subsonic t=md5(pwd+salt)&s=salt,
    /// Synology _sid=会话令牌, 各类 api_sig/token), 而日志会被写进 caches 明文
    /// 文件并通过设置页分享出去, 原样记录等于把账号泄露给收到日志的人。query
    /// 非空时用 "?…" 占位, 既不丢失"带参数"这条诊断信息也不暴露内容。
    nonisolated func redactedURL(_ url: URL) -> String {
        guard !url.isFileURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.isFileURL ? url.path : url.absoluteString
        }
        let hadQuery = !(components.query?.isEmpty ?? true)
        components.query = nil
        components.user = nil
        components.password = nil
        components.fragment = nil
        let base = components.string ?? url.absoluteString
        return hadQuery ? base + "?…" : base
    }

    func resolvedURL(
        for song: Song,
        forContinuousPreparation: Bool = false
    ) async throws -> URL {
        // DLNA renderer items are ephemeral and intentionally never registered
        // with SourceManager. Their filePath is the controller-provided HTTP(S)
        // URI, so seeking must reuse it directly instead of asking the library
        // source resolver for a non-existent "dlna" source.
        if song.sourceID == "dlna",
           let remoteURL = URL(string: song.filePath),
           let scheme = remoteURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            plog("🔗 resolvedURL for '\(song.title)': DLNA remote → \(redactedURL(remoteURL))")
            return remoteURL
        }
        if let sourceManager {
            do {
                let url = try await sourceManager.resolveURL(
                    for: song,
                    acquirePlaybackCacheLease: !forContinuousPreparation
                )
                plog("🔗 resolvedURL for '\(song.title)': \(url.isFileURL ? "LOCAL" : url.scheme?.uppercased() ?? "?") → \(redactedURL(url))")
                return url
            } catch {
                plog("🔗 resolveURL failed for '\(song.title)': \(error), filePath=\(song.filePath.prefix(80))")
                if let localURL = PrimuseSandboxPathResolver.existingURL(
                    forStoredAbsolutePath: song.filePath
                ) {
                    if localURL.path != song.filePath {
                        plog("🔗 rebased stale sandbox path for '\(song.title)' → \(localURL.path)")
                    }
                    return localURL
                }
                throw error
            }
        }
        if let remoteURL = URL(string: song.filePath), remoteURL.scheme != nil {
            plog("🔗 resolvedURL for '\(song.title)': direct remote → \(redactedURL(remoteURL))")
            return remoteURL
        }
        if let localURL = PrimuseSandboxPathResolver.existingURL(
            forStoredAbsolutePath: song.filePath
        ) {
            plog("🔗 resolvedURL for '\(song.title)': file path → \(localURL.path.prefix(80))")
            return localURL
        }
        throw SourceError.fileNotFound(song.filePath)
    }
}
