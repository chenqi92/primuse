import Foundation

public struct AppleMusicLibraryAccess: Equatable, Sendable {
    public var storefrontCountryCode: String?
    public var canPlayCatalogContent: Bool
    public var canBecomeSubscriber: Bool

    public init(storefrontCountryCode: String?, canPlayCatalogContent: Bool, canBecomeSubscriber: Bool) {
        self.storefrontCountryCode = storefrontCountryCode?.uppercased()
        self.canPlayCatalogContent = canPlayCatalogContent
        self.canBecomeSubscriber = canBecomeSubscriber
    }

    public var syncMode: AppleMusicLibrarySyncMode {
        canPlayCatalogContent ? .authoritative : .partialFallback
    }

    public func canCommit(comparedTo latest: Self) -> Bool {
        self == latest
    }

    public func storefrontChanged(since previousCountryCode: String?) -> Bool {
        guard let previousCountryCode, let storefrontCountryCode else { return false }
        return previousCountryCode.uppercased() != storefrontCountryCode
    }
}

public enum AppleMusicPlaybackFailure: Equatable, Sendable {
    case authenticationRequired
    case systemPlayerFailedAfterAccessCheck
    case systemPlayerFailed
    case other

    public var stopsSource: Bool { self == .authenticationRequired }
}

public enum AppleMusicPlaybackFailurePolicy {
    public static func classify(
        _ error: any Error,
        catalogPlaybackWasVerified: Bool,
        authenticationRequired: Bool = false
    ) -> AppleMusicPlaybackFailure {
        let errors = errorChain(error as NSError)
        if authenticationRequired || errors.contains(where: isAuthenticationFailure) {
            return .authenticationRequired
        }
        if errors.contains(where: { $0.domain == AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain }) {
            // MP error 6 only reports a failed preparation. It does not identify
            // an expired subscription, revoked authorization, or account failure.
            return catalogPlaybackWasVerified ? .systemPlayerFailedAfterAccessCheck : .systemPlayerFailed
        }
        return .other
    }

    private static func isAuthenticationFailure(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorUserAuthenticationRequired {
            return true
        }
        // These may be supplied as underlying errors by Apple's playback service.
        // An opaque MP error must never be promoted to either of these diagnoses.
        return (error.domain == "AMSErrorDomain" && error.code == 100)
            || (error.domain == "ICError" && error.code == -7403)
    }

    private static func errorChain(_ root: NSError) -> [NSError] {
        var pending: [(NSError, Int)] = [(root, 0)]
        var visited: Set<ObjectIdentifier> = []
        var result: [NSError] = []
        while let (error, depth) = pending.popLast(), result.count < 32 {
            guard depth < 8, visited.insert(ObjectIdentifier(error)).inserted else { continue }
            result.append(error)
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
                pending.append((underlying as NSError, depth + 1))
            }
            if let underlying = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
                pending.append(contentsOf: underlying.prefix(32).map { ($0 as NSError, depth + 1) })
            }
        }
        return result
    }
}
