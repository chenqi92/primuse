import Foundation

/// Decides whether a system notification is worth posting at all.
///
/// A notification interrupts from outside the app, so it has to be about
/// something the listener asked for and would otherwise miss. Background
/// upkeep (tag reading nobody started, automatic rescans, sync retries) is
/// visible inside the app and never earns a banner; neither does anything
/// while the app is in front, where the same outcome is already on screen.
public enum UserNotificationPolicy {
    public enum Kind: Sendable, Equatable {
        /// A long task the listener started has finished.
        case completion
        /// A task the listener started has failed.
        case failure
        /// Something only the listener can fix (iCloud storage full), whoever
        /// started the work that ran into it.
        case actionRequired
    }

    public enum SkipReason: String, Sendable, Equatable {
        case blankContent
        case applicationActive
        case completionNotificationsOff
        case notRequestedByUser
        case tooFewItems
    }

    public enum Decision: Sendable, Equatable {
        case post
        case skip(SkipReason)
    }

    /// Completion notifications are opt-in. This matches the switch in
    /// settings, which has always shown "off" until turned on.
    public static let completionNotificationsDefault = false

    /// A task over fewer items is over before the listener has left the app.
    public static let minimumCompletionItems = 5

    public static func decision(
        kind: Kind,
        title: String,
        body: String,
        isApplicationActive: Bool,
        isUserInitiated: Bool,
        completionNotificationsEnabled: Bool,
        itemCount: Int? = nil
    ) -> Decision {
        if isBlank(title) || isBlank(body) { return .skip(.blankContent) }
        if isApplicationActive { return .skip(.applicationActive) }
        switch kind {
        case .completion:
            guard completionNotificationsEnabled else { return .skip(.completionNotificationsOff) }
            guard isUserInitiated else { return .skip(.notRequestedByUser) }
            if let itemCount, itemCount < minimumCompletionItems { return .skip(.tooFewItems) }
        case .failure:
            guard isUserInitiated else { return .skip(.notRequestedByUser) }
        case .actionRequired:
            break
        }
        return .post
    }

    /// How long the same notification stays quiet after it was posted.
    /// Something that needs the listener's hand keeps failing until it is
    /// fixed; once a day is a reminder, every sync attempt is nagging.
    public static func repeatInterval(for kind: Kind) -> TimeInterval {
        switch kind {
        case .completion, .failure: 5 * 60
        case .actionRequired: 24 * 3600
        }
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
