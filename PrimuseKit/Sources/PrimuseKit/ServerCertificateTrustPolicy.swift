import Foundation

/// Selects the only trust path that may handle a server certificate challenge.
///
/// A manually pinned certificate is an exception for certificates that do not
/// pass ordinary platform validation. It must never override a later successful
/// system evaluation: publicly trusted certificates can renew normally without
/// being blocked by a stale exception pin.
public enum ServerCertificateTrustAction: Equatable, Sendable {
    case useSystemTrust
    case usePinnedCertificate
    case requestInitialTrust
    case requestChangedCertificateTrust
}

public enum ServerCertificateTrustPolicy {
    public static func action(
        systemTrustSucceeded: Bool,
        endpointWasTrusted: Bool,
        currentFingerprint: String?,
        pinnedFingerprint: String?
    ) -> ServerCertificateTrustAction {
        if systemTrustSucceeded {
            return .useSystemTrust
        }
        guard endpointWasTrusted else {
            return .requestInitialTrust
        }
        guard let pinnedFingerprint, !pinnedFingerprint.isEmpty else {
            return .requestInitialTrust
        }
        guard let currentFingerprint,
              currentFingerprint.caseInsensitiveCompare(pinnedFingerprint) == .orderedSame else {
            return .requestChangedCertificateTrust
        }
        return .usePinnedCertificate
    }
}

public enum ServerCertificateFingerprint {
    public static func formatted(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let compact = rawValue.filter { $0.isHexDigit }.uppercased()
        guard !compact.isEmpty, compact.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: compact.count, by: 2).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return String(compact[start..<end])
        }.joined(separator: ":")
    }
}
