import Foundation

/// CloudKit keeps two independent schemas. `Development` infers a record type
/// (and its fields) the first time a client saves one; `Production` refuses,
/// until the type is deployed from CloudKit Console. A distribution-signed build
/// therefore fails *every* snapshot upload with `CKError.invalidArguments` while
/// the same code succeeds over a development profile.
///
/// The raw CloudKit message is unreadable for users and hides that no retry can
/// ever help, so uploads classify it and surface the deploy requirement instead.
public enum CloudSchemaDeploymentPolicy {
    /// `CKError.invalidArguments`. Matched numerically so the policy stays free
    /// of CloudKit and remains testable on every platform.
    public static let invalidArgumentsCode = 12
    public static let errorDomain = "CKErrorDomain"

    /// What the production schema is missing.
    public enum Gap: Sendable, Equatable {
        case recordType(String)
        case field(String)

        public var name: String {
            switch self {
            case .recordType(let name), .field(let name): return name
            }
        }
    }

    /// Returns the missing schema element when `error` is CloudKit rejecting an
    /// implicit production-schema creation, otherwise nil.
    public static func gap(domain: String, code: Int, message: String) -> Gap? {
        guard domain == errorDomain, code == invalidArgumentsCode else { return nil }
        guard message.localizedCaseInsensitiveContains("production schema") else { return nil }
        if let name = token(after: "Cannot create new type", in: message) {
            return .recordType(name)
        }
        if let name = token(after: "Cannot create new field", in: message) {
            return .field(name)
        }
        return nil
    }

    /// First whitespace-delimited token following `marker`, stripped of the
    /// quoting CloudKit puts around field names.
    private static func token(after marker: String, in message: String) -> String? {
        guard let range = message.range(
            of: marker,
            options: [.caseInsensitive]
        ) else { return nil }
        let remainder = message[range.upperBound...].drop { $0.isWhitespace }
        let raw = remainder.prefix { !$0.isWhitespace }
        let trimmed = raw.trimmingCharacters(
            in: CharacterSet(charactersIn: "'\"`“”‘’")
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
