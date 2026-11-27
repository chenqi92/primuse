import Foundation

/// Extracts a metadata-only byte window when a WebDAV proxy ignores `Range`
/// and returns the complete resource with HTTP 200.
///
/// This must not be used by sparse playback caches: a whole-resource response
/// cannot prove that later random-access reads are safe. Metadata readers are
/// different — they only need a bounded head or tail slice and never place the
/// result at an arbitrary offset in the playback cache.
public enum WholeResourceMetadataRangePolicy {
    public enum ResponseDisposition: Sendable, Equatable {
        case consumeBoundedPrefix
        case rejectSuffixWithoutConsuming
        case useCompleteFileFallback
    }

    /// 服务器不认 Range、回 200 整个文件时, 一次元数据读取最多从响应开头吃这么多字节。
    /// 首段和按声明补读(ID3、FLAC 块、fast-start moov)都落在 16 MB 以内; 更远的读取
    /// (几 GB 的 mdat 之后的 moov、DSF 文件尾的 ID3) 得先流过整段前缀, 直到超时才停 ——
    /// 这种读取和尾部读取一样当作「不支持」, 响应体一个字节都不读。
    public static let maximumConsumedPrefixByteCount: Int64 = 16 * 1024 * 1024

    /// 回 200 时能不能从整文件响应的开头切出这段。
    public static func consumesWholeResponsePrefix(
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Bool {
        guard requestedOffset >= 0 else { return false }
        let (end, overflow) = requestedOffset.addingReportingOverflow(max(requestedLength, 0))
        return !overflow && end <= maximumConsumedPrefixByteCount
    }

    /// `rejectSuffixWithoutConsuming` 也用于离开头太远的读取(见
    /// `maximumConsumedPrefixByteCount`), 调用方照样抛 `suffixRangeUnsupported`。
    public static func responseDisposition(
        requestedOffset: Int64,
        requestedLength: Int64 = 0,
        intent: MetadataRangeReadIntent
    ) -> ResponseDisposition {
        if consumesWholeResponsePrefix(
            requestedOffset: requestedOffset,
            requestedLength: requestedLength
        ) {
            return .consumeBoundedPrefix
        }
        switch intent {
        case .bulkBounded:
            return .rejectSuffixWithoutConsuming
        case .explicitSingleFileCompleteFallback:
            return .useCompleteFileFallback
        }
    }

    /// Limits the initial Range probe when an endpoint responds with HTTP 200.
    /// Suffix probes intentionally accept zero body bytes: callers can reject
    /// bulk work immediately or start one separately cached complete download.
    /// 离开头太远的读取同样只收 0 字节。
    public static func wholeResponsePrefixLimit(
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Int? {
        guard requestedOffset >= 0,
              let end = SafeByteRange.exclusiveEnd(
                  offset: requestedOffset,
                  length: requestedLength
              ) else {
            return requestedOffset < 0 ? 0 : nil
        }
        guard end <= maximumConsumedPrefixByteCount else { return 0 }
        return Int(clamping: end)
    }

    public static func sliceRange(
        bodyLength: Int,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Range<Int>? {
        guard bodyLength > 0,
              requestedLength > 0,
              requestedOffset != Int64.min else {
            return nil
        }

        let totalLength = Int64(bodyLength)
        let start = requestedOffset < 0
            ? max(0, totalLength + requestedOffset)
            : requestedOffset
        guard start >= 0,
              start < totalLength,
              let requestedEnd = SafeByteRange.exclusiveEnd(
                offset: start,
                length: requestedLength
              ) else {
            return nil
        }

        let end = min(requestedEnd, totalLength)
        return Int(start)..<Int(end)
    }
}
