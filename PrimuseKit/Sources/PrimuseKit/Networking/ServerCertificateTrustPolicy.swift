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

/// Accepts the routine renewal of a manually pinned certificate without a new
/// prompt. A LAN endpoint that serves a public-domain certificate (for example
/// a NAS reached by its private address while its certificate names its DDNS
/// hostname) fails ordinary validation only on the hostname, so it is pinned by
/// fingerprint, and every renewal would otherwise interrupt playback with a
/// confirmation. The replacement is accepted silently when it carries the same
/// DNS subject as the pinned certificate; the caller must additionally verify
/// that the new chain is trusted by the platform for that exact subject name,
/// which an interceptor cannot obtain for a domain it does not control.
public enum ServerCertificateRenewalPolicy {
    /// The DNS name to validate the replacement chain against, or nil when the
    /// certificates do not share a usable DNS subject.
    public static func renewalValidationHostname(
        pinnedSubject: String?,
        currentSubject: String?
    ) -> String? {
        guard let pinned = dnsSubject(pinnedSubject),
              let current = dnsSubject(currentSubject),
              pinned == current else { return nil }
        return current
    }

    /// Normalizes a certificate subject summary into a DNS host name. Wildcard,
    /// IP-literal, single-label, empty and free-text subjects are rejected.
    public static func dnsSubject(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let candidate = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty,
              candidate.contains("."),
              !candidate.hasPrefix("."),
              !candidate.hasSuffix("."),
              candidate.allSatisfy({ character in
                  character == "." || character == "-"
                      || (character.isASCII && (character.isLetter || character.isNumber))
              }) else { return nil }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return candidate
    }
}
