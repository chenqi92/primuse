import Foundation

/// Publishes playback ownership to decode pumps that no longer run on the main
/// actor.
///
/// A pump used to read `currentPlayID` / crossfade state directly off main-actor
/// storage on every decoded buffer. Once the loop moves off the main actor it
/// still has to answer "am I still the owner?" synchronously — hopping back to
/// the main actor per buffer would reintroduce the hop this change removes. The
/// lease keeps the same three inputs behind a lock and answers from
/// `CrossfadePumpContinuationPolicy`, so the decision rule stays in one place.
public final class PlaybackOwnershipLease<ID: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPlayID: ID?
    private var isCrossfading: Bool
    private var outgoingPlayID: ID?

    public init(
        currentPlayID: ID? = nil,
        isCrossfading: Bool = false,
        outgoingPlayID: ID? = nil
    ) {
        self.currentPlayID = currentPlayID
        self.isCrossfading = isCrossfading
        self.outgoingPlayID = outgoingPlayID
    }

    /// Publishes the authoritative state. Callers own it on the main actor and
    /// must push every change here, otherwise a retired pump keeps scheduling.
    public func update(currentPlayID: ID?, isCrossfading: Bool, outgoingPlayID: ID?) {
        lock.lock()
        self.currentPlayID = currentPlayID
        self.isCrossfading = isCrossfading
        self.outgoingPlayID = outgoingPlayID
        lock.unlock()
    }

    public func mayContinue(_ playID: ID) -> Bool {
        lock.lock()
        let current = currentPlayID
        let crossfading = isCrossfading
        let outgoing = outgoingPlayID
        lock.unlock()
        return CrossfadePumpContinuationPolicy.mayContinue(
            playID: playID,
            currentPlayID: current,
            isCrossfading: crossfading,
            outgoingPlayID: outgoing
        )
    }

    /// Snapshot for diagnostics and for callers that need the same three values
    /// to feed another policy (for example the final-buffer disposition).
    public func snapshot() -> (currentPlayID: ID?, isCrossfading: Bool, outgoingPlayID: ID?) {
        lock.lock()
        defer { lock.unlock() }
        return (currentPlayID, isCrossfading, outgoingPlayID)
    }
}
