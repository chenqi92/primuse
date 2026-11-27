import Foundation
import CryptoKit

/// Builds deterministic, collision-resistant filenames for remote-file caches.
/// The remote path is hashed instead of replacing separators, because paths such
/// as `/A/B.mp3` and `/A_B.mp3` must never address the same cached bytes.
public enum CacheFileNamePolicy {
    public static func make(
        path: String,
        preferredExtension: String? = nil
    ) -> String {
        let normalizedPath = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let pathExtension = (path as NSString).pathExtension
        let ext = normalizedExtension(preferredExtension) ?? normalizedExtension(pathExtension)
        return ext.map { "\(hash).\($0)" } ?? hash
    }

    /// The pre-hash filename remains useful only for deleting stale cache files
    /// written by older builds. It must never be used as a current cache key.
    public static func legacySanitized(path: String) -> String {
        path.replacingOccurrences(of: "/", with: "_")
    }

    private static func normalizedExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return normalized
    }
}
