import Foundation

/// Keeps FTP callback quirks from turning an incomplete transfer into a
/// durable cache entry: a completion can arrive more than once while the
/// final control reply is validated.
public enum FTPTransferPolicy {
    public enum CallbackDecision: Equatable, Sendable {
        case accept
        case retry
        case awaitRetry
        case fail
    }

    public enum PromotionDecision: Equatable, Sendable {
        case rejectTemporary
        case useExistingTarget
        case promoteTemporary
        case replaceIncompleteTarget
    }

    public struct RangePlan: Equatable, Sendable {
        public let offset: Int64
        public let expectedLength: Int

        public init(offset: Int64, expectedLength: Int) {
            self.offset = offset
            self.expectedLength = expectedLength
        }
    }

    /// A full-file callback is valid only when the transport itself succeeded
    /// and the staged file has the exact advertised byte count. This matters
    /// for zero-byte files because a failed transfer may still leave an empty
    /// destination behind.
    public static func downloadPayloadIsValid(
        expectedSize: Int64,
        actualSize: Int64?,
        errorOccurred: Bool
    ) -> Bool {
        !errorOccurred && expectedSize >= 0 && actualSize == expectedSize
    }

    /// Converts regular and suffix requests into a nonnegative, EOF-clipped
    /// range whose expected byte count fits in an `Int`.
    public static func rangePlan(
        fileSize: Int64,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> RangePlan {
        let safeFileSize = max(0, fileSize)
        let actualOffset = requestedOffset < 0
            ? max(0, safeFileSize + requestedOffset)
            : requestedOffset
        let available = actualOffset < safeFileSize
            ? safeFileSize - actualOffset
            : 0
        let boundedLength = min(
            max(0, requestedLength),
            min(available, Int64(Int.max))
        )
        return RangePlan(offset: actualOffset, expectedLength: Int(boundedLength))
    }

    /// A positive range is complete only when its callback contains every
    /// EOF-clipped byte and no transport error accompanied the buffer.
    public static func rangePayloadIsValid(
        expectedLength: Int,
        actualLength: Int?,
        errorOccurred: Bool
    ) -> Bool {
        !errorOccurred && expectedLength >= 0 && actualLength == expectedLength
    }

    /// A valid payload from either attempt wins. The first failed callback
    /// starts one retry; duplicate callbacks from that first attempt are
    /// ignored while the retry is active.
    public static func callbackDecision(
        attempt: Int,
        payloadIsValid: Bool,
        retryAlreadyStarted: Bool
    ) -> CallbackDecision {
        if payloadIsValid { return .accept }
        if attempt == 0 {
            return retryAlreadyStarted ? .awaitRetry : .retry
        }
        return .fail
    }

    /// FTP is byte-preserving in binary mode, so only an exact byte count may
    /// be promoted. If another concurrent request already installed an exact
    /// target, that target wins and the redundant temporary file is discarded.
    public static func promotionDecision(
        expectedSize: Int64,
        temporarySize: Int64?,
        existingTargetSize: Int64?
    ) -> PromotionDecision {
        guard expectedSize >= 0, temporarySize == expectedSize else {
            return .rejectTemporary
        }
        if existingTargetSize == expectedSize {
            return .useExistingTarget
        }
        if existingTargetSize != nil {
            return .replaceIncompleteTarget
        }
        return .promoteTemporary
    }
}
