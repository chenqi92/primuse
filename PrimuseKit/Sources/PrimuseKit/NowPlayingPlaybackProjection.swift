import Foundation

public struct NowPlayingPlaybackProjection: Equatable, Sendable {
    public var playbackRate: Double
    public var playCommandEnabled: Bool
    public var pauseCommandEnabled: Bool

    public init(
        playbackRate: Double,
        playCommandEnabled: Bool,
        pauseCommandEnabled: Bool
    ) {
        self.playbackRate = playbackRate
        self.playCommandEnabled = playCommandEnabled
        self.pauseCommandEnabled = pauseCommandEnabled
    }
}

public struct PlaybackAdvanceTicket: Equatable, Sendable {
    public let generation: UInt64
    public let id: UUID
    public let itemID: String

    public init(generation: UInt64, id: UUID = UUID(), itemID: String) {
        self.generation = generation
        self.id = id
        self.itemID = itemID
    }
}

public enum PlaybackAdvanceDecision: String, Equatable, Sendable {
    case accepted
    case noActiveTicket
    case staleGeneration
    case staleTicket
    case wrongItem
    case playbackNotIntended
    case transportNotActive
}

public enum PlaybackSeekEndAction: Equatable, Sendable {
    case preserveCurrentItem
    case advance
}

public enum PlaybackSeekEndPolicy {
    public static func action(isRecovery: Bool) -> PlaybackSeekEndAction {
        isRecovery ? .preserveCurrentItem : .advance
    }
}

/// Owns the one-shot right for a local transport completion to advance the
/// queue. A ticket invalidated by pause, interruption, route loss, or graph
/// replacement can never become valid again. Gapless playback prepares a
/// successor ticket and atomically hands ownership to it at the boundary.
public struct PlaybackAdvanceEligibilityPolicy: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var activeTicket: PlaybackAdvanceTicket?

    public init(generation: UInt64 = 0) {
        self.generation = generation
        activeTicket = nil
    }

    @discardableResult
    public mutating func beginTransport(itemID: String) -> PlaybackAdvanceTicket {
        generation &+= 1
        let ticket = PlaybackAdvanceTicket(generation: generation, itemID: itemID)
        activeTicket = ticket
        return ticket
    }

    public func prepareSuccessor(itemID: String) -> PlaybackAdvanceTicket? {
        guard activeTicket != nil else { return nil }
        return PlaybackAdvanceTicket(generation: generation, itemID: itemID)
    }

    public mutating func invalidate() {
        generation &+= 1
        activeTicket = nil
    }

    /// Remains true after a ticket is consumed, but becomes false as soon as
    /// pause, interruption, route loss, or another transport invalidates the
    /// generation. Async completion handlers use this after suspension points.
    public func isGenerationCurrent(for ticket: PlaybackAdvanceTicket) -> Bool {
        ticket.generation == generation
    }

    public func decision(
        for ticket: PlaybackAdvanceTicket,
        currentItemID: String?,
        playbackIsIntended: Bool,
        transportIsActive: Bool
    ) -> PlaybackAdvanceDecision {
        guard let activeTicket else { return .noActiveTicket }
        guard ticket.generation == generation else { return .staleGeneration }
        guard ticket.id == activeTicket.id else { return .staleTicket }
        guard ticket.itemID == activeTicket.itemID,
              ticket.itemID == currentItemID else { return .wrongItem }
        guard playbackIsIntended else { return .playbackNotIntended }
        guard transportIsActive else { return .transportNotActive }
        return .accepted
    }

    @discardableResult
    public mutating func consume(
        _ ticket: PlaybackAdvanceTicket,
        currentItemID: String?,
        playbackIsIntended: Bool,
        transportIsActive: Bool
    ) -> PlaybackAdvanceDecision {
        let result = decision(
            for: ticket,
            currentItemID: currentItemID,
            playbackIsIntended: playbackIsIntended,
            transportIsActive: transportIsActive
        )
        if result == .accepted {
            activeTicket = nil
        }
        return result
    }

    @discardableResult
    public mutating func handoff(
        from currentTicket: PlaybackAdvanceTicket,
        to successorTicket: PlaybackAdvanceTicket,
        currentItemID: String?,
        playbackIsIntended: Bool,
        transportIsActive: Bool
    ) -> PlaybackAdvanceDecision {
        let result = decision(
            for: currentTicket,
            currentItemID: currentItemID,
            playbackIsIntended: playbackIsIntended,
            transportIsActive: transportIsActive
        )
        guard result == .accepted,
              successorTicket.generation == generation,
              successorTicket.id != currentTicket.id,
              !successorTicket.itemID.isEmpty else {
            return result == .accepted ? .staleTicket : result
        }
        activeTicket = successorTicket
        return .accepted
    }
}

public enum PlaybackAppActivationAction: Equatable, Sendable {
    case preservePendingRecovery
    case synchronizeVisibleState
}

public enum PlaybackAppActivationPolicy {
    public static func action(needsPlaybackRecovery: Bool) -> PlaybackAppActivationAction {
        needsPlaybackRecovery ? .preservePendingRecovery : .synchronizeVisibleState
    }
}

public enum WatchQueuedCommandPolicy {
    public static func acceptsQueuedDelivery(command: String) -> Bool {
        command == "requestState"
    }
}

/// Keeps the system play/pause affordance derived from the same state as the
/// in-app controls. A zero playback rate is the portable paused signal used by
/// iOS, while command availability represents transport capabilities.
public enum NowPlayingPlaybackProjectionPolicy {
    public static func projection(
        hasCurrentItem: Bool,
        isPlaying: Bool,
        isLoading: Bool = false,
        preferredPlaybackRate: Double
    ) -> NowPlayingPlaybackProjection {
        guard hasCurrentItem else {
            return NowPlayingPlaybackProjection(
                playbackRate: 0,
                playCommandEnabled: false,
                pauseCommandEnabled: false
            )
        }

        let safeRate = preferredPlaybackRate.isFinite && preferredPlaybackRate > 0
            ? preferredPlaybackRate
            : 1
        return NowPlayingPlaybackProjection(
            playbackRate: isPlaying ? safeRate : 0,
            playCommandEnabled: true,
            pauseCommandEnabled: true
        )
    }
}

/// Keeps user playback intent separate from transient engine/UI state. System
/// interruption recovery may only resume the exact item/generation that was
/// actively playing when the interruption began. Any later user action
/// invalidates the pending ticket, so delayed callbacks cannot revive stale
/// playback.
public struct PlaybackInterruptionResumePolicy: Equatable, Sendable {
    private struct Ticket: Equatable, Sendable {
        var intentGeneration: UInt64
        var itemID: String
    }

    public private(set) var playbackIsIntended: Bool
    private var intentGeneration: UInt64
    private var pendingTicket: Ticket?

    public init(playbackIsIntended: Bool = false) {
        self.playbackIsIntended = playbackIsIntended
        intentGeneration = 0
        pendingTicket = nil
    }

    public var isAwaitingInterruptionEnd: Bool {
        pendingTicket != nil
    }

    public mutating func registerPlayIntent() {
        advanceGeneration()
        playbackIsIntended = true
        pendingTicket = nil
    }

    public mutating func registerPauseOrStopIntent() {
        advanceGeneration()
        playbackIsIntended = false
        pendingTicket = nil
    }

    /// Queue/item/route replacement is a new generation even if playback is
    /// expected to continue. It must invalidate an older interruption ticket.
    public mutating func invalidatePendingResumePreservingIntent() {
        advanceGeneration()
        pendingTicket = nil
    }

    public mutating func interruptionBegan(
        wasActuallyPlaying: Bool,
        currentItemID: String?
    ) {
        guard let currentItemID, !currentItemID.isEmpty else {
            pendingTicket = nil
            return
        }

        // After a long background suspension, iOS may deliver another begin
        // notification after the engine and visible state are already paused.
        // Preserve only the exact live ticket; a genuinely paused item still
        // has no right to start automatically.
        if !wasActuallyPlaying {
            guard playbackIsIntended,
                  let ticket = pendingTicket,
                  ticket.intentGeneration == intentGeneration,
                  ticket.itemID == currentItemID else {
                pendingTicket = nil
                return
            }
            return
        }

        guard playbackIsIntended else {
            pendingTicket = nil
            return
        }
        pendingTicket = Ticket(
            intentGeneration: intentGeneration,
            itemID: currentItemID
        )
    }

    /// Reconciles a live interruption ticket when the app returns after being
    /// suspended and iOS did not deliver a usable interruption-end event. Other
    /// audio keeps the ticket pending so foreground activation never steals its
    /// session; cold launch and ordinary paused state have no ticket to consume.
    public mutating func resumeAfterAppActivationIfSafe(
        otherAudioIsPlaying: Bool,
        currentItemID: String?
    ) -> Bool {
        guard let ticket = pendingTicket else { return false }
        guard playbackIsIntended,
              ticket.intentGeneration == intentGeneration,
              ticket.itemID == currentItemID else {
            pendingTicket = nil
            return false
        }
        guard !otherAudioIsPlaying else { return false }

        pendingTicket = nil
        return true
    }

    /// Returns `true` exactly once when system permission, user intent, item
    /// identity and playback generation all still match the interruption.
    public mutating func interruptionEnded(
        systemShouldResume: Bool,
        currentItemID: String?
    ) -> Bool {
        guard let ticket = pendingTicket else { return false }
        pendingTicket = nil

        guard systemShouldResume,
              playbackIsIntended,
              ticket.intentGeneration == intentGeneration,
              ticket.itemID == currentItemID else {
            if ticket.intentGeneration == intentGeneration {
                advanceGeneration()
                playbackIsIntended = false
            }
            return false
        }
        return true
    }

    private mutating func advanceGeneration() {
        intentGeneration &+= 1
    }
}

public enum BluetoothDeferredResumeDecision: Equatable, Sendable {
    case wait
    case discard
    case resume
}

public enum QueueSelectionPlaybackDecision: Equatable, Sendable {
    case startSelectedItem
    case preserveCurrentTransport
}

/// Replacing a queue around the item that is already playing should update the
/// traversal context without restarting its decoder. This also coalesces
/// repeated taps while the same item is still starting.
public enum QueueSelectionPlaybackPolicy {
    public static func decision(
        selectedItemID: String,
        currentItemID: String?,
        transportIsActive: Bool,
        isLoading: Bool,
        transportCanBePreserved: Bool = true
    ) -> QueueSelectionPlaybackDecision {
        guard transportCanBePreserved,
              selectedItemID == currentItemID,
              transportIsActive || isLoading else {
            return .startSelectedItem
        }
        return .preserveCurrentTransport
    }
}

/// Distinguishes a real external-output loss from the noisy
/// `.oldDeviceUnavailable` notifications iOS can emit while the phone remains
/// on its built-in speaker. Pausing is only needed when an external route was
/// actually present and the replacement route has no external output.
public enum AudioOutputRouteLossPolicy {
    public static func shouldPause(
        reasonIsOldDeviceUnavailable: Bool,
        previousRouteHadExternalOutput: Bool,
        currentRouteHasExternalOutput: Bool
    ) -> Bool {
        reasonIsOldDeviceUnavailable
            && previousRouteHadExternalOutput
            && !currentRouteHasExternalOutput
    }
}

/// Keeps a Bluetooth microphone preemption separate from a physical route loss.
/// A2DP/HFP profile switches can report `.oldDeviceUnavailable`, but playback
/// should pause only when the resulting route really falls back to the device.
/// Deferred resume stays one-shot and cannot cross an item or user-intent change.
public enum BluetoothPlaybackRecoveryPolicy {
    /// Retained for callers that only model Bluetooth routes. Unrelated
    /// built-in route churn is never a Bluetooth disconnect.
    public static func shouldPauseForRouteLoss(
        reasonIsOldDeviceUnavailable: Bool,
        previousRouteWasBluetooth: Bool,
        currentRouteIsBluetooth: Bool
    ) -> Bool {
        reasonIsOldDeviceUnavailable
            && previousRouteWasBluetooth
            && !currentRouteIsBluetooth
    }

    public static func deferredResumeDecision(
        hasTicket: Bool,
        currentRouteIsBluetoothHFP: Bool,
        currentRouteIsBluetooth: Bool,
        playbackIsIntended: Bool,
        isAwaitingInterruptionEnd: Bool,
        isPlaybackActuallyActive: Bool,
        suspendedItemMatchesCurrent: Bool,
        supportsAutomaticRecovery: Bool
    ) -> BluetoothDeferredResumeDecision {
        guard hasTicket else { return .discard }
        guard !currentRouteIsBluetoothHFP,
              currentRouteIsBluetooth,
              !isAwaitingInterruptionEnd else {
            return .wait
        }
        guard playbackIsIntended,
              !isPlaybackActuallyActive,
              suspendedItemMatchesCurrent,
              supportsAutomaticRecovery else {
            return .discard
        }
        return .resume
    }
}

/// Reacquires the phone's non-mixable playback focus only for an intentional
/// AirPlay-to-built-in route transition. A physical route loss keeps the
/// existing pause-on-disconnect behavior, and inactive or system-owned
/// transports must never be started by a route notification.
public enum AirPlayReturnFocusRecoveryPolicy {
    public static func shouldReacquire(
        previousRouteWasAirPlay: Bool,
        currentRouteIsBuiltIn: Bool,
        reasonIsOldDeviceUnavailable: Bool,
        playbackWasActive: Bool,
        playbackIsIntended: Bool,
        isAwaitingInterruptionEnd: Bool,
        supportsLocalPipelineRecovery: Bool
    ) -> Bool {
        previousRouteWasAirPlay
            && currentRouteIsBuiltIn
            && !reasonIsOldDeviceUnavailable
            && playbackWasActive
            && playbackIsIntended
            && !isAwaitingInterruptionEnd
            && supportsLocalPipelineRecovery
    }
}

public enum RemotePlayCommandAction: Equatable, Sendable {
    case noActionableItem
    case alreadyPlaying
    case awaitInFlightRequest
    case retryLoadingPlayback
    case resume
}

public enum RemotePlayCommandPolicy {
    public static func action(
        hasCurrentItem: Bool,
        isPlaybackActuallyActive: Bool,
        isLoading: Bool,
        playbackIsIntended: Bool
    ) -> RemotePlayCommandAction {
        guard hasCurrentItem else { return .noActionableItem }
        if isPlaybackActuallyActive { return .alreadyPlaying }
        if isLoading {
            return playbackIsIntended ? .awaitInFlightRequest : .retryLoadingPlayback
        }
        return .resume
    }
}

/// 锁屏、控制中心两侧的按钮：「上一首 / 下一首」和「快退 / 快进」系统只给同两个位置，只能放一对。
/// 播客固定快退快进；有声书和音乐按各自的设置；直播电台没法快进快退。
public enum NowPlayingSkipControlsPolicy {
    public enum Content: Sendable, Equatable {
        case music, podcast, audiobook, liveRadio, other
    }

    public static func offersSkipIntervals(
        content: Content,
        audiobookUsesChapters: Bool,
        musicUsesSkip: Bool
    ) -> Bool {
        switch content {
        case .podcast: return true
        case .audiobook: return !audiobookUsesChapters
        case .music: return musicUsesSkip
        case .liveRadio, .other: return false
        }
    }

    /// 锁屏上的收藏按钮：这一首能收藏、而且设置里没关掉才出现。
    public static func showsLike(canLike: Bool, likeVisible: Bool) -> Bool {
        canLike && likeVisible
    }
}
