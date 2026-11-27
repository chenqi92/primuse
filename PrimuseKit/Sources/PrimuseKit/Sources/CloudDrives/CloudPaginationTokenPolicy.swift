import Foundation

/// Pagination must make globally monotonic progress within a request. This
/// rejects empty tokens and cycles such as A -> B -> A, not just a token that
/// repeats on two adjacent pages.
public enum CloudPaginationTokenPolicy {
    public static func canAdvance(
        to token: String,
        seenTokens: Set<String>
    ) -> Bool {
        !token.isEmpty && !seenTokens.contains(token)
    }
}
