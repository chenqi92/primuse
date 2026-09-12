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
    @discardableResult
    func play(station: RadioStation, within stations: [RadioStation] = []) async -> Bool {
        let resolutionID = UUID()
        let resolutionGeneration = playbackAdvancePolicy.generation
        pendingRadioResolutionID = resolutionID
        let url: URL
        do {
            url = try await resolveRadioStreamURL(for: station, forceRefresh: false)
        } catch {
            guard pendingRadioResolutionID == resolutionID,
                  playbackAdvancePolicy.generation == resolutionGeneration else { return false }
            pendingRadioResolutionID = nil
            plog(
                "⚠️ Radio URL resolution failed sourceBacked="
                    + "\(station.requiresSourceStreamResolution) errorType=\(String(reflecting: type(of: error)))"
            )
            showPlaybackError(String(localized: station.requiresSourceStreamResolution
                ? "playback_error_connection"
                : "radio_invalid_url"))
            return false
        }
        guard pendingRadioResolutionID == resolutionID,
              playbackAdvancePolicy.generation == resolutionGeneration else { return false }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            pendingRadioResolutionID = nil
            showPlaybackError(String(localized: "radio_invalid_url"))
            return false
        }
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingRadioResolutionID = nil
            showPlaybackError(String(format: String(localized: "insecure_http_permission_required %@"), trustTarget))
            return false
        }
        registerPlayIntent()
        pendingRadioResolutionID = resolutionID
        let transportGeneration = playbackAdvancePolicy.generation

        let id = UUID()
        playID = id
        // 拖动进度触发的整文件物化会一直下到底, 切到电台同样要取消, 否则被
        // 放弃的传输继续占用带宽和缓存配额 (它只在下载完成后才检查 playID)。
        // 重入说明同 play(song:): 唯一能从 seek 任务走到这里的是
        // handleTrackEnd → next()/previous() 的电台分支, 那里已先摘掉句柄。
        seekTask?.cancel()
        seekTask = nil
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        beginPlaybackErrorScope()
        clearPendingPlaybackRecovery()
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        radioReconnectAttempt = 0
        radioResolvedStreamURL = url
        let inferredFormat = RadioStreamFormat.inferred(from: url)
        radioPrefersDecodedTransport = station.streamFormat == .flac || inferredFormat == .flac
        radioDidAttemptDecodedFallback = radioPrefersDecodedTransport
        radioDecodedFallbackNeedsValidation = false

        if let controller = castingController {
            castingPositionTask?.cancel()
            castingPositionTask = nil
            try? await controller.stop()
            castingRenderer = nil
            castingController = nil
        }
        guard playbackAdvancePolicy.generation == transportGeneration,
              pendingRadioResolutionID == resolutionID,
              playID == id,
              interruptionResumePolicy.playbackIsIntended else {
            plog("🛡️ Radio start cancelled during renderer handoff")
            return false
        }
        pendingRadioResolutionID = nil
        appleMusicPlaybackTask?.cancel()
        appleMusicPlaybackTask = nil
        appleMusicTimeoutTask?.cancel()
        appleMusicTimeoutTask = nil
        activeAppleMusicRequestID = nil
        stopAppleMusicMirror()
        AppServices.shared.appleMusic.stopAppleMusic()
        isPrimuseManagingAppleMusicQueue = false

        let deferredStreamingDownloadSongID = retireStreamingDownloadPreparation()
        if !isLiveRadio,
           StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
            previousSongID: currentSong?.id,
            newSongID: nil,
            retiredSongID: deferredStreamingDownloadSongID
           ),
           let previous = currentSong {
            sourceManager?.finalizeStreamingSession(for: previous)
            ScrobbleService.shared.handlePlaybackStopped()
            PlayHistoryStore.shared.endSession()
        }
        decodingTask?.cancel()
        decodingTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        sourceManager?.cancelBackgroundAudioCaching(keeping: [])
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopMusicVideoPlayback(clearPlayer: true)
        stopTimeUpdater()
        radioPlaybackController.stop()

        playbackKind = .liveRadio
        currentRadioStation = station
        clearRadioMetadataState()
        radioStreamFormat = station.streamFormat
        radioBitRate = station.bitRate
        radioStationOrder = RadioStationOrdering.sorted(
            stations.isEmpty ? [station] : stations.filter { !$0.isDeleted }
        )
        if !radioStationOrder.contains(where: { $0.id == station.id }) {
            radioStationOrder.append(station)
        }
        currentSong = station.playbackSong
        currentTime = 0
        duration = 0
        isAtTrackEnd = false
        isPlaying = false
        isLoading = true
        radioPlaybackStartedAt = nil
        queueEntries = []
        currentIndex = 0
        invalidateQueueTransitions()
        AppServices.shared.radioStationsStore.markPlayed(station.id)

        _ = AudioSessionManager.shared.activatePlaybackSession()
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
        startRadioTransport(station: station, playID: id)
        // 正在听的这个台最值得有一张图。发现全程在后台，起播不等它。
        RadioLogoDiscoveryService.shared.discoverIfNeeded(for: [station])
        return true
    }

    func testRadioStream(url: URL) async -> Result<Void, Error> {
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            return .failure(TrustedHTTPTransportError.permissionRequired(host: trustTarget))
        }
        let inferredFormat = RadioStreamFormat.inferred(from: url)
        if inferredFormat == .flac {
            return await testDecodedRadioStream(url: url)
        }
        let nativeResult = await RadioPlaybackController.probe(url: url)
        guard case .failure = nativeResult, inferredFormat == .automatic else {
            return nativeResult
        }
        let decodedResult = await testDecodedRadioStream(url: url)
        if case .success = decodedResult { return decodedResult }
        return nativeResult
    }

    private func testDecodedRadioStream(url: URL) async -> Result<Void, Error> {
        let source = RadioLiveStreamSource(url: url)
        defer { source.cancel() }
        do {
            let prepared = try await source.prepare()
            guard let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: 44_100,
                channels: 2
            ) else {
                return .failure(AudioDecoderError.converterCreationFailed)
            }
            let stream = radioFLACDecoder.decode(
                from: source,
                prepared: prepared,
                outputFormat: outputFormat
            )
            let iterator = BufferIteratorBox(stream.makeAsyncIterator())
            let firstBuffer = try await awaitFirstBuffer(from: iterator, timeoutSeconds: 15)
            return firstBuffer?.frameLength ?? 0 > 0
                ? .success(())
                : .failure(AudioDecoderError.decodingFailed("No live audio frames"))
        } catch {
            return .failure(error)
        }
    }

    private func startRadioTransport(station: RadioStation, playID id: UUID) {
        guard let url = radioResolvedStreamURL,
              playID == id,
              currentRadioStation?.id == station.id,
              interruptionResumePolicy.playbackIsIntended,
              !interruptionResumePolicy.isAwaitingInterruptionEnd else { return }
        radioPlaybackController.stop()
        radioLiveStreamSource?.cancel()
        radioLiveStreamSource = nil
        decodingTask?.cancel()
        decodingTask = nil
        audioEngine.stopPlayback()

        if radioPrefersDecodedTransport {
            startDecodedRadioTransport(station: station, url: url, playID: id)
            return
        }
        radioUsesDecodedTransport = false
        radioPlaybackController.start(url: url, volume: audioEngine.userVolume) { [weak self] event in
            guard let self, self.playID == id, self.currentRadioStation?.id == station.id else { return }
            self.handleRadioEvent(event, station: station, playID: id)
        }
    }

    private func startDecodedRadioTransport(
        station: RadioStation,
        url: URL,
        playID id: UUID
    ) {
        radioUsesDecodedTransport = true
        let source = RadioLiveStreamSource(url: url) { [weak self] metadata in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playID == id,
                      self.currentRadioStation?.id == station.id else { return }
                self.handleRadioEvent(.metadata(metadata), station: station, playID: id)
            }
        }
        radioLiveStreamSource = source
        handleRadioEvent(.loading, station: station, playID: id)

        decodingTask = Task { [weak self, source] in
            guard let self else { return }
            do {
                let prepared = try await source.prepare()
                guard !Task.isCancelled,
                      self.playID == id,
                      self.currentRadioStation?.id == station.id,
                      self.radioLiveStreamSource === source,
                      self.interruptionResumePolicy.playbackIsIntended,
                      !self.interruptionResumePolicy.isAwaitingInterruptionEnd else { return }

                let settings = self.playbackSettings.snapshot()
                _ = AudioSessionManager.shared.activatePlaybackSession()
                try self.audioEngine.configure(
                    outputMode: settings.outputMode,
                    directSourceFormat: nil
                )
                self.audioEngine.applyPlaybackRate(1)
                self.applySpatialAudioSettings()
                self.audioEffectsService.applySettings()
                self.equalizerService.applySettings()
                guard let outputFormat = self.audioEngine.outputFormat else {
                    throw AudioDecoderError.decodingFailed("Audio engine not ready")
                }
                try self.audioEngine.start()
                self.audioEngine.resetPlayerVolume()

                let stream = self.radioFLACDecoder.decode(
                    from: source,
                    prepared: prepared,
                    outputFormat: outputFormat
                )
                let iterator = BufferIteratorBox(stream.makeAsyncIterator())
                guard let firstBuffer = try await self.awaitFirstBuffer(
                    from: iterator,
                    timeoutSeconds: 15
                ) else {
                    throw AudioDecoderError.decodingFailed("No live audio frames")
                }
                guard !Task.isCancelled,
                      self.playID == id,
                      self.currentRadioStation?.id == station.id,
                      self.radioLiveStreamSource === source,
                      self.interruptionResumePolicy.playbackIsIntended,
                      !self.interruptionResumePolicy.isAwaitingInterruptionEnd else { return }

                self.audioEngine.scheduleBuffer(firstBuffer)
                self.hasPreparedLocalPlayback = true
                guard self.audioEngine.play() else {
                    throw AudioDecoderError.decodingFailed("Audio engine failed to start")
                }
                self.handleRadioEvent(
                    .ready(format: prepared.format, bitRate: prepared.bitRate),
                    station: station,
                    playID: id
                )
                self.handleRadioEvent(.playing, station: station, playID: id)
                self.consumeDecodedRadioStream(
                    iterator,
                    source: source,
                    station: station,
                    playID: id
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.playID == id,
                      self.currentRadioStation?.id == station.id,
                      self.radioLiveStreamSource === source else { return }
                self.finishDecodedRadioTransport(
                    source: source,
                    station: station,
                    playID: id,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func consumeDecodedRadioStream(
        _ iterator: BufferIteratorBox,
        source: RadioLiveStreamSource,
        station: RadioStation,
        playID id: UUID
    ) {
        let gate = DecodedBufferGate(
            maxBufferedDuration: Self.decodedAudioLookahead,
            maxBufferedBytes: Self.maxInFlightDecodedBytes,
            maxBufferCount: Self.maxInFlightDecodedBufferCount
        )
        decodingTask = Task { [weak self, iterator, source, gate] in
            guard let self else { return }
            var lastBuffer: AVAudioPCMBuffer?
            var terminalMessage = String(localized: "radio_stream_ended")
            defer { Task { await gate.drain() } }

            do {
                while let buffer = try await iterator.next() {
                    guard !Task.isCancelled,
                          self.playID == id,
                          self.currentRadioStation?.id == station.id,
                          self.radioLiveStreamSource === source else { return }
                    if let previous = lastBuffer {
                        let bufferedDuration = Self.decodedBufferDuration(previous)
                        let bufferedByteCount = Self.decodedBufferByteCount(previous)
                        await gate.acquire(
                            duration: bufferedDuration,
                            byteCount: bufferedByteCount
                        )
                        guard !Task.isCancelled,
                              self.playID == id,
                              self.currentRadioStation?.id == station.id else { return }
                        self.audioEngine.scheduleBuffer(
                            previous,
                            completionCallbackType: .dataPlayedBack
                        ) { _ in
                            gate.release(
                                duration: bufferedDuration,
                                byteCount: bufferedByteCount
                            )
                        }
                    }
                    lastBuffer = buffer
                }
            } catch is CancellationError {
                return
            } catch {
                terminalMessage = error.localizedDescription
            }

            guard !Task.isCancelled,
                  self.playID == id,
                  self.currentRadioStation?.id == station.id,
                  self.radioLiveStreamSource === source else { return }
            if let lastBuffer {
                let message = terminalMessage
                self.audioEngine.scheduleBuffer(
                    lastBuffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self, source] _ in
                    Task { @MainActor [weak self] in
                        self?.finishDecodedRadioTransport(
                            source: source,
                            station: station,
                            playID: id,
                            message: message
                        )
                    }
                }
            } else {
                finishDecodedRadioTransport(
                    source: source,
                    station: station,
                    playID: id,
                    message: terminalMessage
                )
            }
        }
    }

    private func finishDecodedRadioTransport(
        source: RadioLiveStreamSource,
        station: RadioStation,
        playID id: UUID,
        message: String
    ) {
        guard playID == id,
              currentRadioStation?.id == station.id,
              radioLiveStreamSource === source else { return }
        source.cancel()
        radioLiveStreamSource = nil
        decodingTask = nil
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        if radioDecodedFallbackNeedsValidation {
            radioPrefersDecodedTransport = false
            radioDecodedFallbackNeedsValidation = false
        }
        handleRadioEvent(
            .failed(message: message, shouldReconnect: true),
            station: station,
            playID: id
        )
    }

    private func handleRadioEvent(
        _ event: RadioPlaybackController.Event,
        station: RadioStation,
        playID id: UUID
    ) {
        guard playID == id, currentRadioStation?.id == station.id else { return }
        switch event {
        case .loading:
            isLoading = true
            isPlaying = false
        case .ready(let format, let bitRate):
            if format != .automatic { radioStreamFormat = format }
            if let bitRate { radioBitRate = bitRate }
            updateRadioPresentation()
        case .playing:
            guard interruptionResumePolicy.playbackIsIntended,
                  !interruptionResumePolicy.isAwaitingInterruptionEnd else {
                radioPlaybackController.stop()
                isLoading = false
                isPlaying = false
                break
            }
            isLoading = false
            isPlaying = true
            if radioUsesDecodedTransport {
                radioDecodedFallbackNeedsValidation = false
            }
            radioReconnectAttempt = 0
            if radioPlaybackStartedAt == nil { radioPlaybackStartedAt = Date() }
            startTimeUpdater()
        case .buffering:
            isLoading = true
            isPlaying = false
        case .metadata(let metadata):
            applyRadioMetadata(metadata, station: station)

        case .subtitleTracks(let tracks):
            radioSubtitleTracks = tracks
            // 字幕不参与锁屏信息，直接返回，别为它重算一遍 now playing。
            return

        case .subtitle(let text):
            // 字幕一秒可能来好几条，绝不能每条都去刷锁屏和播放状态。
            radioSubtitleText = text
            return
        case .failed(let message, let shouldReconnect):
            if !radioUsesDecodedTransport,
               !radioDidAttemptDecodedFallback,
               station.streamFormat == .automatic,
               radioResolvedStreamURL.map({ RadioStreamFormat.inferred(from: $0) == .automatic }) == true {
                radioDidAttemptDecodedFallback = true
                radioPrefersDecodedTransport = true
                radioDecodedFallbackNeedsValidation = true
                startRadioTransport(station: station, playID: id)
                return
            }
            isLoading = false
            isPlaying = false
            stopTimeUpdater()
            showPlaybackError(message)
            if shouldReconnect {
                scheduleRadioReconnect(station: station, playID: id)
            }
        }
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    /// 把电台推来的一条元数据落到界面状态上。
    ///
    /// 电台每隔几秒就会重复推送同一条，所以这里对「没有变化」的情况直接返回：
    /// 一次无谓的 `currentSong` 赋值会连带刷新锁屏信息和一整屏 SwiftUI。
    private func applyRadioMetadata(_ metadata: RadioLiveMetadata, station: RadioStation) {
        let isSameTitle = RadioStreamTitleParser.isSameTrack(
            radioNowPlaying?.title,
            metadata.title
        )
        let artwork = metadata.artworkURL ?? radioNowPlayingArtworkURL
        guard !isSameTitle || artwork != radioNowPlayingArtworkURL else { return }

        radioTitleHistory = RadioTitleHistoryPolicy.appending(metadata, to: radioTitleHistory)
        radioNowPlaying = metadata
        radioMetadataTitle = metadata.displayText ?? radioMetadataTitle
        radioNowPlayingArtworkURL = artwork
        updateRadioPresentation()
    }

    private func clearRadioMetadataState() {
        radioMetadataTitle = nil
        radioNowPlaying = nil
        radioNowPlayingArtworkURL = nil
        radioTitleHistory = []
        radioSubtitleTracks = []
        radioSelectedSubtitleTrackID = nil
        radioSubtitleText = nil
    }

    /// 播放页切字幕轨。没有字幕轨的流上调用是安全的空操作。
    func selectRadioSubtitleTrack(id: String?) {
        guard isLiveRadio else { return }
        radioSelectedSubtitleTrackID = id
        if id == nil { radioSubtitleText = nil }
        radioPlaybackController.selectSubtitleTrack(id: id)
    }

    private func updateRadioPresentation() {
        guard var station = currentRadioStation else { return }
        station.streamFormat = radioStreamFormat
        station.bitRate = radioBitRate
        currentRadioStation = station
        var song = station.playbackSong
        song.artistName = radioMetadataTitle ?? station.playbackSubtitle
        // 电台给了当前曲目的配图就用它 —— 比一张一成不变的台标更贴合此刻在放的内容。
        if let artwork = radioNowPlayingArtworkURL {
            song.coverArtFileName = artwork
        }
        currentSong = song
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
    }

    private func scheduleRadioReconnect(station: RadioStation, playID id: UUID) {
        radioReconnectTask?.cancel()
        radioReconnectAttempt += 1
        let delay = min(pow(2, Double(max(0, radioReconnectAttempt - 1))), 15)
        isLoading = true
        radioReconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.playID == id,
                  self.currentRadioStation?.id == station.id,
                  self.interruptionResumePolicy.playbackIsIntended,
                  !self.interruptionResumePolicy.isAwaitingInterruptionEnd else { return }
            if station.requiresSourceStreamResolution {
                do {
                    self.radioResolvedStreamURL = try await self.resolveRadioStreamURL(
                        for: station,
                        forceRefresh: true
                    )
                } catch {
                    guard self.playID == id,
                          self.currentRadioStation?.id == station.id else { return }
                    self.isLoading = false
                    self.isPlaying = false
                    self.showPlaybackError(String(localized: "playback_error_connection"))
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                    self.scheduleRadioReconnect(station: station, playID: id)
                    return
                }
            }
            self.radioPlaybackStartedAt = nil
            self.startRadioTransport(station: station, playID: id)
        }
    }

    func stopRadioTransport(clearSelection: Bool) {
        radioReconnectTask?.cancel()
        radioReconnectTask = nil
        radioPlaybackController.stop()
        radioLiveStreamSource?.cancel()
        radioLiveStreamSource = nil
        if radioUsesDecodedTransport {
            decodingTask?.cancel()
            decodingTask = nil
            audioEngine.stopPlayback()
            hasPreparedLocalPlayback = false
        }
        radioUsesDecodedTransport = false
        radioPrefersDecodedTransport = false
        radioDidAttemptDecodedFallback = false
        radioDecodedFallbackNeedsValidation = false
        radioResolvedStreamURL = nil
        pendingRadioResolutionID = nil
        stopTimeUpdater()
        isPlaying = false
        isLoading = false
        currentTime = 0
        radioPlaybackStartedAt = nil
        if clearSelection {
            currentRadioStation = nil
            clearRadioMetadataState()
            radioStreamFormat = .automatic
            radioBitRate = nil
            radioStationOrder = []
            playbackKind = .track
            currentSong = nil
        }
    }

    private func resolveRadioStreamURL(
        for station: RadioStation,
        forceRefresh: Bool
    ) async throws -> URL {
        if station.requiresSourceStreamResolution {
            guard let sourceID = station.sourceID,
                  let serverStationID = station.serverStationID,
                  let sourceManager else {
                throw SourceError.fileNotFound("Radio source is unavailable")
            }
            return try await sourceManager.resolveServerRadioStream(
                sourceID: sourceID,
                stationID: serverStationID,
                forceRefresh: forceRefresh
            )
        }
        guard let url = station.url else {
            throw SourceError.fileNotFound(station.streamURL)
        }
        return url
    }

    func refreshRadioStationOrder() {
        guard isLiveRadio, let current = currentRadioStation else { return }
        let stations = AppServices.shared.radioStationsStore.stations
        radioStationOrder = stations

        guard var updated = stations.first(where: { $0.id == current.id }) else {
            stopRadioTransport(clearSelection: true)
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }

        updated.streamFormat = radioStreamFormat
        updated.bitRate = radioBitRate
        currentRadioStation = updated
        var song = updated.playbackSong
        song.artistName = radioMetadataTitle ?? updated.playbackSubtitle
        if let artwork = radioNowPlayingArtworkURL {
            song.coverArtFileName = artwork
        }
        currentSong = song
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
    }
}
