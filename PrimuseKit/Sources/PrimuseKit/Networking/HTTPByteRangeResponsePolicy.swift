import Foundation

/// Validates one HTTP 206 response before its bytes enter a sparse audio cache.
/// A status code alone is insufficient: proxies can return the wrong window,
/// expand a request to the full resource, or compress the body while keeping
/// byte-oriented headers from the origin.
public enum HTTPByteRangeResponsePolicy {
    public static func validatedTotalLength(
        contentRange header: String?,
        contentLength: Int64?,
        bodyLength: Int,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Int64? {
        guard requestedLength > 0, bodyLength >= 0, let parsed = parse(header) else {
            return nil
        }

        let expectedStart: Int64
        let expectedEnd: Int64
        if requestedOffset >= 0 {
            guard requestedOffset < parsed.total,
                  let exclusiveEnd = SafeByteRange.exclusiveEnd(
                      offset: requestedOffset,
                      length: requestedLength
                  ) else { return nil }
            expectedStart = requestedOffset
            expectedEnd = min(exclusiveEnd, parsed.total) - 1
        } else {
            guard requestedOffset != Int64.min else { return nil }
            let suffixLength = -requestedOffset
            expectedStart = max(0, parsed.total - suffixLength)
            expectedEnd = parsed.total - 1
        }

        let expectedLength = expectedEnd - expectedStart + 1
        guard parsed.start == expectedStart,
              parsed.end == expectedEnd,
              Int64(bodyLength) == expectedLength else { return nil }
        if let contentLength, contentLength != expectedLength { return nil }
        return parsed.total
    }

    /// A server that ignores Range may still safely satisfy a request when the
    /// entire resource is no larger than the requested head/suffix window.
    public static func acceptsWholeResourceResponse(
        bodyLength: Int,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Bool {
        guard bodyLength >= 0, requestedLength > 0 else { return false }
        if requestedOffset == 0 {
            return Int64(bodyLength) <= requestedLength
        }
        if requestedOffset < 0, requestedOffset != Int64.min {
            return Int64(bodyLength) <= -requestedOffset
        }
        return false
    }

    private static func parse(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header else { return nil }
        let unitAndValue = header.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard unitAndValue.count == 2,
              unitAndValue[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              rangeAndTotal[1] != "*",
              let total = Int64(rangeAndTotal[1]),
              total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total else { return nil }
        return (start, end, total)
    }
}
