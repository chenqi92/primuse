import Foundation

/// A two-byte probe avoids a MiniDLNA 1.3.3 edge case where `bytes=0-0`
/// is treated as an open-ended request and the whole file is streamed. The
/// response must also describe exactly the requested (or EOF-clipped) range;
/// a bare 206 is not sufficient proof that later random access is safe.
public enum HTTPRangeProbePolicy {
    public static let requestHeaderValue = "bytes=0-1"

    public static func validatedTotalLength(
        contentRange header: String?,
        contentLength: Int64?
    ) -> Int64? {
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
              start == 0,
              end == min(1, total - 1) else { return nil }

        let expectedLength = min(Int64(2), total)
        if let contentLength, contentLength != expectedLength {
            return nil
        }
        return total
    }
}
