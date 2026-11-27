import Foundation

public enum BaiduAPIErrorDisposition: Equatable, Sendable {
    case success
    case refreshAuthentication
    case retryAfterBackoff
    case missingPath
    case fail
}

/// Baidu returns application errors in an HTTP-200 JSON body. Keep the
/// provider-specific values out of generic HTTP classification: notably,
/// `-9` is a missing path, while only `31034` is the documented rate limit.
public enum BaiduAPIErrorPolicy {
    public static func disposition(errno: Int) -> BaiduAPIErrorDisposition {
        switch errno {
        case 0:
            return .success
        case -6, 111:
            return .refreshAuthentication
        case 31034:
            return .retryAfterBackoff
        case -9:
            return .missingPath
        default:
            return .fail
        }
    }
}

/// Baidu's successful `create` acknowledgement is not a stable metadata
/// representation across API versions, and the directory API can expose a
/// provider-specific digest rather than the uploaded bytes' standard MD5.
/// The connector therefore confirms the committed size and opaque revision;
/// its callers then perform a byte-for-byte source readback.
public enum BaiduMetadataReplacementVerificationPolicy {
    public static func matchesCommittedFile(
        remoteSize: Int64,
        remoteRevision: String?,
        expectedSize: Int64
    ) -> Bool {
        guard remoteSize == expectedSize,
              let remoteRevision,
              !remoteRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}
