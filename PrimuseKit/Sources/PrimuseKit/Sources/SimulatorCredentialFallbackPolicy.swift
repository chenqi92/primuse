/// Keeps the simulator-only credential fallback consistent while app builds
/// move between Keychain entitlement states. A durable fallback may be the
/// only copy after an unsigned build, but it must never outrank a readable
/// Keychain item or survive an explicit replacement with stale bytes.
public enum SimulatorCredentialPrimaryRead: Equatable, Sendable {
    case found
    case itemNotFound
    case missingEntitlement
    case unavailable
}

public enum SimulatorCredentialReadSource: Equatable, Sendable {
    case primary
    case fallback
    case notFound
    case unavailable
}

public enum SimulatorCredentialWriteOutcome: Equatable, Sendable {
    case primarySucceeded
    case missingEntitlement
    case otherFailure
    case explicitDelete
}

public enum SimulatorCredentialFallbackMutation: Equatable, Sendable {
    case replace
    case preserve
    case remove
}

public enum SimulatorCredentialFallbackPolicy {
    public static func readSource(
        primary: SimulatorCredentialPrimaryRead,
        fallbackExists: Bool
    ) -> SimulatorCredentialReadSource {
        switch primary {
        case .found:
            return .primary
        case .itemNotFound:
            return fallbackExists ? .fallback : .notFound
        case .missingEntitlement:
            return fallbackExists ? .fallback : .unavailable
        case .unavailable:
            return .unavailable
        }
    }

    public static func mutation(
        after outcome: SimulatorCredentialWriteOutcome
    ) -> SimulatorCredentialFallbackMutation {
        switch outcome {
        case .primarySucceeded, .missingEntitlement:
            return .replace
        case .otherFailure:
            return .preserve
        case .explicitDelete:
            return .remove
        }
    }
}
