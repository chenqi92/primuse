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
/// interruptions may only resume the exact item/generation that was actively
/// playing when the interruption began. Any later user action invalidates the
/// pending ticket, so delayed callbacks cannot revive stale playback.
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
        guard playbackIsIntended,
              wasActuallyPlaying,
              let currentItemID,
              !currentItemID.isEmpty else {
            pendingTicket = nil
            return
        }
        pendingTicket = Ticket(
            intentGeneration: intentGeneration,
            itemID: currentItemID
        )
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

/// Keeps a Bluetooth microphone preemption separate from a physical route loss.
/// A2DP/HFP profile switches can report `.oldDeviceUnavailable`, but playback
/// should pause only when the resulting route really falls back to the device.
/// Deferred resume stays one-shot and cannot cross an item or user-intent change.
public enum BluetoothPlaybackRecoveryPolicy {
    public static func shouldPauseForRouteLoss(
        reasonIsOldDeviceUnavailable: Bool,
        previousRouteWasBluetooth: Bool,
        currentRouteIsBluetooth: Bool
    ) -> Bool {
        reasonIsOldDeviceUnavailable
            && !(previousRouteWasBluetooth && currentRouteIsBluetooth)
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
