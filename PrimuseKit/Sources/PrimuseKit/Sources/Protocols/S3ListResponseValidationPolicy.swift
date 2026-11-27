import Foundation

/// ListObjectsV2 may legitimately contain no objects, but it must still be a
/// complete, well-formed ListBucketResult. A truncated page without a token is
/// never authoritative because accepting it can turn missing pages into song
/// deletions during reconciliation.
public enum S3ListResponseValidationPolicy {
    public static func isValid(
        xmlParsed: Bool,
        sawListBucketResult: Bool,
        hasValidIsTruncatedMarker: Bool,
        isTruncated: Bool,
        hasContinuationToken: Bool
    ) -> Bool {
        guard xmlParsed, sawListBucketResult, hasValidIsTruncatedMarker else {
            return false
        }
        return !isTruncated || hasContinuationToken
    }
}
