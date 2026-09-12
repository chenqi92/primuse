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
    // MARK: - Decoded Buffer Health

    func resetDecodedBufferHealth(resetRecoveryAttempts: Bool) {
        activeDecodedBufferGate = nil
        activeDecodedBufferGatePlayID = nil
        decodedBufferUnhealthySampleCount = 0
        decodedBufferHealthySampleCount = 0
        decodedBufferRecoveryInProgress = false
        lastDecodedBufferSampleUptime = nil
        decodedBufferDiagnosticUnderflowStartedAt = nil
        if resetRecoveryAttempts {
            decodedBufferRecoveryAttempts = 0
            lastDecodedBufferRecoveryAt = nil
            decodedBufferDiagnosticEpisodeCount = 0
        }
    }

    func installDecodedBufferGate(_ gate: DecodedBufferGate, playID id: UUID) {
        guard playID == id else { return }
        activeDecodedBufferGate = gate
        activeDecodedBufferGatePlayID = id
        decodedBufferUnhealthySampleCount = 0
        decodedBufferHealthySampleCount = 0
        decodedBufferRecoveryInProgress = false
    }

    func sampleDecodedBufferHealth(clockTicket: UInt64) async {
        guard let gate = activeDecodedBufferGate,
              let gatePlayID = activeDecodedBufferGatePlayID,
              playID == gatePlayID,
              !isLiveRadio,
              !isAppleMusicMode,
              !isCastingMode,
              !isSystemMediaPlaybackActive else {
            decodedBufferUnhealthySampleCount = 0
            return
        }

        let snapshot = await gate.snapshot()
        guard playbackClockTickGate.isCurrent(clockTicket),
              playID == gatePlayID,
              activeDecodedBufferGate === gate else { return }

        let queueIsEmpty = snapshot.bufferCount == 0
            && snapshot.bufferedDuration <= Self.decodedBufferEmptyThreshold
        let isUnhealthy = !snapshot.decodingFinished
            && (!audioEngine.isActuallyPlaying || queueIsEmpty)
        recordDecodedBufferDiagnostic(snapshot: snapshot, isUnhealthy: isUnhealthy, playID: gatePlayID)
        if isUnhealthy {
            decodedBufferUnhealthySampleCount += 1
            decodedBufferHealthySampleCount = 0
        } else {
            decodedBufferUnhealthySampleCount = 0
            if isPlaying, !snapshot.decodingFinished {
                decodedBufferHealthySampleCount += 1
                // A full minute of healthy output starts a fresh recovery
                // budget for long-running queues without letting a tight
                // failure loop rebuild the same pipeline forever.
                if decodedBufferHealthySampleCount >= 120 {
                    decodedBufferHealthySampleCount = 0
                    decodedBufferRecoveryAttempts = 0
                    lastDecodedBufferRecoveryAt = nil
                }
            }
        }

        let cooldownElapsed = lastDecodedBufferRecoveryAt.map {
            Date().timeIntervalSince($0)
        } ?? .greatestFiniteMagnitude
        let action = DecodedBufferHealthPolicy.action(
            isPlaying: isPlaying,
            hasPreparedAudio: hasPreparedLocalPlayback,
            isLoading: isLoading,
            isTransitioning: isCrossfading,
            engineIsPlaying: audioEngine.isActuallyPlaying,
            decoderFinished: snapshot.decodingFinished,
            bufferedDuration: snapshot.bufferedDuration,
            bufferCount: snapshot.bufferCount,
            emptyDurationThreshold: Self.decodedBufferEmptyThreshold,
            consecutiveUnhealthySamples: decodedBufferUnhealthySampleCount,
            requiredUnhealthySamples: Self.requiredDecodedBufferUnhealthySamples,
            recoveryInProgress: decodedBufferRecoveryInProgress,
            recoveryAttempts: decodedBufferRecoveryAttempts,
            maximumRecoveryAttempts: Self.maxDecodedBufferRecoveryAttempts,
            cooldownElapsed: cooldownElapsed,
            minimumCooldown: Self.decodedBufferRecoveryCooldown
        )

        switch action {
        case .none:
            return
        case .rebuildPipeline:
            recoverDecodedBufferUnderflow(snapshot: snapshot, playID: gatePlayID)
        case .stopPlayback:
            stopAfterRepeatedDecodedBufferUnderflow(snapshot: snapshot, playID: gatePlayID)
        }
    }

    private func recordDecodedBufferDiagnostic(
        snapshot: DecodedBufferGate.Snapshot,
        isUnhealthy: Bool,
        playID id: UUID
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let sampleGap = lastDecodedBufferSampleUptime.map { max(0, now - $0) } ?? 0
        lastDecodedBufferSampleUptime = now
        guard isPlaying, hasPreparedLocalPlayback, !isLoading, !isCrossfading,
              let song = currentSong else {
            decodedBufferDiagnosticUnderflowStartedAt = nil
            return
        }
        let event: String
        if isUnhealthy {
            guard decodedBufferDiagnosticUnderflowStartedAt == nil else { return }
            decodedBufferDiagnosticUnderflowStartedAt = now
            decodedBufferDiagnosticEpisodeCount += 1
            event = "underflow"
        } else if let startedAt = decodedBufferDiagnosticUnderflowStartedAt {
            decodedBufferDiagnosticUnderflowStartedAt = nil
            event = "recovered after=\(String(format: "%.3f", now - startedAt))s"
        } else {
            return
        }
        // Brief dropouts never reach the pipeline-rebuild threshold. Record
        // their onset and recovery too, without producing a per-tick log.
        guard decodedBufferDiagnosticEpisodeCount <= 8 else { return }
        let sourceType = playbackMetadataSourceType?(song.sourceID)?.rawValue ?? "unknown"
        let route = sourceManager?.activeConnectionRoutes[song.sourceID]?.rawValue ?? "unknown"
        let network = NetworkMonitor.shared
        plog("Playback buffer \(event) playID=\(id.uuidString.prefix(8)) source=\(song.sourceID.prefix(8)) song=\(song.id.prefix(8)) sourceType=\(sourceType) decoder=\(activeDecoderKind) format=\(song.fileFormat.rawValue) episode=\(decodedBufferDiagnosticEpisodeCount) position=\(String(format: "%.3f", currentTime)) queued=\(String(format: "%.3f", snapshot.bufferedDuration))s/\(snapshot.bufferedBytes)B/\(snapshot.bufferCount) sampleGap=\(String(format: "%.3f", sampleGap))s enginePlaying=\(audioEngine.isActuallyPlaying) route=\(route) networkGeneration=\(network.pathGeneration) reachable=\(network.isReachable) expensive=\(network.isExpensive) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    private func recoverDecodedBufferUnderflow(
        snapshot: DecodedBufferGate.Snapshot,
        playID id: UUID
    ) {
        guard playID == id,
              let song = currentSong,
              !decodedBufferRecoveryInProgress else { return }

        decodedBufferRecoveryInProgress = true
        decodedBufferRecoveryAttempts += 1
        decodedBufferUnhealthySampleCount = 0
        lastDecodedBufferRecoveryAt = Date()
        stopTimeUpdater()
        syncPlaybackProgressFromEngine()
        let resumeTime = max(0, currentTime - 0.25)
        plog(String(
            format: "⚠️ decoded-audio underflow: attempt=%d enginePlaying=%d queued=%.3fs/%dB/%d buffers at %.2fs; rebuilding",
            decodedBufferRecoveryAttempts,
            audioEngine.isActuallyPlaying ? 1 : 0,
            snapshot.bufferedDuration,
            snapshot.bufferedBytes,
            snapshot.bufferCount,
            resumeTime
        ))

        if playbackSettings.audioCacheEnabled,
           activeDecoderKind == .cloudStream || activeDecoderKind == .httpStream {
            beginRemoteMidStreamRecovery(
                song: song,
                playID: id,
                frozenResumeTime: resumeTime
            )
        } else {
            seek(to: resumeTime, startPlaying: true, isRecovery: true)
        }
    }

    private func stopAfterRepeatedDecodedBufferUnderflow(
        snapshot: DecodedBufferGate.Snapshot,
        playID id: UUID
    ) {
        guard playID == id else { return }
        plog(String(
            format: "🛑 decoded-audio underflow persisted after recovery: queued=%.3fs/%dB/%d buffers",
            snapshot.bufferedDuration,
            snapshot.bufferedBytes,
            snapshot.bufferCount
        ))
        decodingTask?.cancel()
        decodingTask = nil
        invalidateAutomaticAdvance(reason: "decoded-underflow-stop")
        stopTimeUpdater()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        isPlaying = false
        isLoading = false
        needsPlaybackRecovery = true
        pendingRecoveryTime = currentTime
        showPlaybackError(String(localized: "playback_error_connection"))
        updateNowPlayingInfo()
        updatePlaybackState()
    }
}
