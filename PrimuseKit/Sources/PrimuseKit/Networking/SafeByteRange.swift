import Foundation

public enum SafeByteRange {
    /// Returns the exclusive end for a non-negative byte range, or `nil`
    /// when the range is empty, negative, or would overflow `Int64`.
    public static func exclusiveEnd(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end > offset else { return nil }
        return end
    }

    /// RFC 7233 Range header. Negative offsets use suffix-range syntax.
    public static func httpHeader(offset: Int64, length: Int64) -> String? {
        guard length > 0 else { return nil }
        if offset < 0 { return "bytes=\(offset)" }
        guard let end = exclusiveEnd(offset: offset, length: length) else { return nil }
        return "bytes=\(offset)-\(end - 1)"
    }
}
