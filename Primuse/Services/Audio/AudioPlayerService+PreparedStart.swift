import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

/// The song after the current one, opened while the current one plays: its
/// URL resolved, its range stream attached to the prefetched seed and its
/// decoder already holding the first seconds of audio. Pressing Next or
/// reaching the end hands that stream to the output instead of starting the
/// song from nothing.
final class PreparedPlaybackStart {
    let queueEntryID: UUID
    let song: Song
    let url: URL
    let decoderKind: AudioPlayerService.DecoderKind
    /// The output format the audio was decoded for. A song whose output
    /// pipeline comes up in another format is opened again.
    let outputFormat: AVAudioFormat
    let sourceStreamEpoch: UInt64
    let networkGeneration: UInt64
    let preparedWithAudioCache: Bool
    let preparedAt: TimeInterval
    /// Replays the first decoded buffer, then carries on with the decoder.
    let stream: AudioBufferStream
    private let feed: Task<Void, Never>

    init(
        queueEntryID: UUID,
        song: Song,
        url: URL,
        decoderKind: AudioPlayerService.DecoderKind,
        outputFormat: AVAudioFormat,
        sourceStreamEpoch: UInt64,
        networkGeneration: UInt64,
        preparedWithAudioCache: Bool,
        stream: AudioBufferStream,
        feed: Task<Void, Never>
    ) {
        self.queueEntryID = queueEntryID
        self.song = song
        self.url = url
        self.decoderKind = decoderKind
        self.outputFormat = outputFormat
        self.sourceStreamEpoch = sourceStreamEpoch
        self.networkGeneration = networkGeneration
        self.preparedWithAudioCache = preparedWithAudioCache
        self.preparedAt = ProcessInfo.processInfo.systemUptime
        self.stream = stream
        self.feed = feed
    }

    var age: TimeInterval { ProcessInfo.processInfo.systemUptime - preparedAt }

    /// Stops the decoder behind the stream when nobody will play it.
    func cancelFeed() {
        feed.cancel()
    }

    /// Ends a decoder's stream that nobody is reading: a read from a
    /// cancelled task terminates it, and the decoder then closes its source.
    static func endDecoding(_ iterator: BufferIteratorBox) {
        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            _ = try? await iterator.next()
        }
        task.cancel()
    }

    /// A stream that yields `first`, then everything else `rest` produces.
    /// Ending it early, from either side, also ends the decoder's own stream:
    /// a read from the cancelled feed task terminates it, so the decoder
    /// closes its source instead of waiting for a reader that never comes.
    static func replaying(
        first: AVAudioPCMBuffer,
        then rest: BufferIteratorBox
    ) -> (stream: AudioBufferStream, feed: Task<Void, Never>) {
        var captured: AudioBufferStream.Continuation?
        let stream = AudioBufferStreamFactory.make { captured = $0 }
        guard let continuation = captured else {
            return (stream, Task {})
        }
        let feed = Task {
            do {
                try await continuation.send(first)
                while let buffer = try await rest.next() {
                    try await continuation.send(buffer)
                }
                continuation.finish()
            } catch {
                if Task.isCancelled {
                    _ = try? await rest.next()
                }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in feed.cancel() }
        return (stream, feed)
    }
}

extension AudioPlayerService {
    /// Opens the song after the current one, once its prefetched seed is in
    /// place. Runs while the current song plays; nothing here is on the path
    /// of the song the listener hears.
    func schedulePreparedStart() {
        guard let entry = nextQueueEntryInQueue() else {
            discardPreparedStart(reason: "no successor")
            return
        }
        if let prepared = preparedStart {
            if prepared.queueEntryID == entry.id, prepared.song.id == entry.song.id { return }
            discardPreparedStart(reason: "successor changed")
        }
        if preparingStartEntryID == entry.id, preparedStartTask != nil { return }
        preparedStartTask?.cancel()
        preparingStartEntryID = entry.id
        preparingStartSongID = entry.song.id
        let ownerID = playID
        preparedStartTask = Task { [weak self] in
            await self?.prepareStart(for: entry, ownerID: ownerID)
        }
    }

    /// The successor moved (queue edit, shuffle, a source went away): drop
    /// what was opened for the old one.
    func discardPreparedStartIfSuccessorChanged() {
        let nextID = nextQueueEntryInQueue()?.id
        if let prepared = preparedStart, prepared.queueEntryID != nextID {
            discardPreparedStart(reason: "successor changed")
        }
        if let preparing = preparingStartEntryID, preparing != nextID {
            preparedStartTask?.cancel()
            preparedStartTask = nil
            preparingStartEntryID = nil
            preparingStartSongID = nil
        }
    }

    func discardPreparedStart(reason: String) {
        preparedStartTask?.cancel()
        preparedStartTask = nil
        preparingStartEntryID = nil
        preparingStartSongID = nil
        guard let prepared = preparedStart else { return }
        preparedStart = nil
        releasePreparedStart(prepared, reason: reason)
    }

    func releasePreparedStart(_ prepared: PreparedPlaybackStart, reason: String) {
        plog("🔥 Prepared start dropped for '\(prepared.song.title)': \(reason)")
        prepared.cancelFeed()
        sourceManager?.releaseStandbyStreamingSession(for: prepared.song)
    }

    /// Takes the prepared start for `song` when playback is about to start
    /// it, or drops a prepared start that no longer fits.
    func takePreparedStart(for song: Song) -> PreparedPlaybackStart? {
        preparedStartTask?.cancel()
        preparedStartTask = nil
        preparingStartEntryID = nil
        preparingStartSongID = nil
        guard let prepared = preparedStart else { return nil }
        preparedStart = nil
        let verdict = PreparedPlaybackStartPolicy.verdict(
            prepared: PreparedPlaybackStartPolicy.Identity(prepared.song),
            requested: PreparedPlaybackStartPolicy.Identity(song),
            preparedNetworkGeneration: prepared.networkGeneration,
            currentNetworkGeneration: NetworkMonitor.shared.pathGeneration,
            streamEpochIsCurrent: CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: prepared.song.sourceID,
                ticket: prepared.sourceStreamEpoch
            ),
            preparedWithAudioCache: prepared.preparedWithAudioCache,
            audioCacheEnabled: playbackSettings.audioCacheEnabled,
            age: prepared.age
        )
        switch verdict {
        case .adopt:
            return prepared
        case .discard(let reason):
            releasePreparedStart(prepared, reason: reason)
            return nil
        }
    }

    private func prepareStart(for entry: QueueEntry, ownerID: UUID?) async {
        defer {
            if preparingStartEntryID == entry.id {
                preparingStartEntryID = nil
                preparingStartSongID = nil
                preparedStartTask = nil
            }
        }
        let song = songApplyingPlaybackRange(entry.song)
        guard let manager = sourceManager, isStillPreparing(entry, ownerID: ownerID) else { return }
        let hasMusicVideo = song.isStandaloneMusicVideo
            || (song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && isMusicVideoModeEnabled)
        let startsMidFile = song.appliedPlaybackRange != nil
            || song.cueStartTime != nil
            || spokenWordOpeningPosition(for: song) != nil
            || medleyDecoderStartTime(for: song) > 0
        guard castingController == nil,
              !isLiveRadio,
              !isAppleMusicMode,
              !isMedleyActive,
              song.id != currentSong?.id,
              song.sourceID != AppleMusicLibraryService.systemSourceID,
              isSourceEnabledForPlayback(song.sourceID),
              manager.cachedPlaybackURL(for: song) == nil,
              PreparedPlaybackStartPolicy.allowsPreparation(
                  streamsByRange: true,
                  startsMidFile: startsMidFile,
                  format: song.fileFormat,
                  requiresCompleteLocalFile: FileFormatRouter.requiresCompleteLocalFile(song.fileFormat),
                  isEpisodeOrStreamDescriptor: PodcastPlaybackSong.isEpisode(song)
                      || song.isStreamDescriptor
                      || isExternalURLItem(song),
                  hasMusicVideo: hasMusicVideo,
                  queuePrefetchEnabled: playbackSettings.prewarmQueueCount > 0,
                  audioCacheEnabled: playbackSettings.audioCacheEnabled
              ) else { return }

        guard await manager.queuePrefetchSeedsNextSong(song),
              isStillPreparing(entry, ownerID: ownerID) else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let networkGeneration = NetworkMonitor.shared.pathGeneration
        // The reachability check runs here, while the current song plays,
        // instead of in front of this song's first sound.
        guard await manager.playbackSourceIsUnavailable(for: song) == false,
              isStillPreparing(entry, ownerID: ownerID) else { return }
        let sourceStreamEpoch = CloudPlaybackSource.streamEpochTicket(sourceID: song.sourceID)
        let url: URL
        do {
            url = try await resolvedURL(for: song)
        } catch {
            plog("🔥 Prepared start skipped for '\(song.title)': \(error.localizedDescription)")
            return
        }
        guard isStillPreparing(entry, ownerID: ownerID) else { return }
        let kind = await decoderKind(for: song, url: url)
        guard kind == .cloudStream || kind == .httpStream else { return }
        // A multichannel M4A plays through the system player, which opens its
        // own stream; read its profile now, while the seed is still a seed.
        let prefersSystemPlayer = await preferredSystemAudioProfile(for: song, url: url) != nil
        guard !prefersSystemPlayer,
              isStillPreparing(entry, ownerID: ownerID),
              let outputFormat = audioEngine.outputFormat else { return }

        let inputSource: InputSource?
        if kind == .cloudStream {
            inputSource = try? await manager.makeStreamingInputSource(
                for: song,
                cacheEnabled: true,
                expectedStreamEpoch: sourceStreamEpoch,
                readAheadSuspended: true
            )
        } else {
            inputSource = await makeHTTPStreamingInputSource(
                for: song,
                url: url,
                sourceStreamEpoch: sourceStreamEpoch,
                readAheadSuspended: true
            )
        }
        guard let inputSource else { return }
        guard isStillPreparing(entry, ownerID: ownerID) else {
            manager.releaseStandbyStreamingSession(for: song)
            return
        }

        let decoded = nativeDecoder.decode(
            from: inputSource,
            outputFormat: outputFormat,
            onResolveSourceLength: makeResolveLengthCallback(for: song),
            lengthCanWait: song.duration > 0
        )
        let iterator = BufferIteratorBox(decoded.makeAsyncIterator())
        let first: AVAudioPCMBuffer?
        do {
            first = try await awaitFirstBuffer(
                from: iterator,
                timeoutSeconds: Self.firstBufferTimeoutSeconds
            )
        } catch {
            first = nil
            plog("🔥 Prepared start for '\(song.title)' could not decode: \(error.localizedDescription)")
        }
        guard let first, isStillPreparing(entry, ownerID: ownerID) else {
            PreparedPlaybackStart.endDecoding(iterator)
            manager.releaseStandbyStreamingSession(for: song)
            return
        }
        let replay = PreparedPlaybackStart.replaying(first: first, then: iterator)
        let prepared = PreparedPlaybackStart(
            queueEntryID: entry.id,
            song: song,
            url: url,
            decoderKind: kind,
            outputFormat: outputFormat,
            sourceStreamEpoch: sourceStreamEpoch,
            networkGeneration: networkGeneration,
            preparedWithAudioCache: playbackSettings.audioCacheEnabled,
            stream: replay.stream,
            feed: replay.feed
        )
        if let previous = preparedStart {
            preparedStart = nil
            releasePreparedStart(previous, reason: "replaced")
        }
        preparedStart = prepared
        let elapsed = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
        plog("🔥 Prepared start ready for '\(song.title)' kind=\(kind) in \(elapsed)ms")
    }

    /// The preparation still serves the song that will play next.
    private func isStillPreparing(_ entry: QueueEntry, ownerID: UUID?) -> Bool {
        !Task.isCancelled
            && playID == ownerID
            && preparingStartEntryID == entry.id
            && nextQueueEntryInQueue()?.id == entry.id
    }
}
