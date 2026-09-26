import Foundation
import PrimuseKit
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform local user notifications. Wraps `UNUserNotificationCenter`
/// so call sites don't have to think about authorization, the "long-task
/// notifications" switch, or repeats. Whether a notification is worth posting
/// at all is `UserNotificationPolicy`'s call: only work the listener started,
/// only while the app is not in front, never with blank text.
///
/// Authorization is requested **lazily** on the first post, never at launch.
@MainActor
final class UserNotificationService {
    static let shared = UserNotificationService()

    /// `UserDefaults` key for the user-facing switch, read directly via
    /// `@AppStorage` in settings.
    static let notifyLongTasksKey = "primuse.notifyLongTasks"

    /// Completion notifications are opt-in, with the same default the
    /// settings switch shows.
    var notifyLongTasksEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.notifyLongTasksKey) as? Bool
            ?? UserNotificationPolicy.completionNotificationsDefault
    }

    private var permissionRequested = false
    private var permissionGranted = false
    /// Re-adding a request with the same identifier replaces the Notification
    /// Center entry, but iOS still presents a fresh banner and sound every time.
    private var lastPostAtBySignature: [String: Date] = [:]

    private init() {}

    // MARK: - Public posting API

    enum Category: String {
        case scrapeMissingDone
        case rescrapeLibraryDone
        case scanFailed
        case cloudSyncFailed
    }

    /// A long task the listener started has finished.
    func postLongTaskCompletion(
        category: Category,
        title: String,
        body: String,
        isUserInitiated: Bool,
        itemCount: Int
    ) async {
        await post(
            kind: .completion,
            category: category,
            title: title,
            body: body,
            isUserInitiated: isUserInitiated,
            itemCount: itemCount
        )
    }

    /// A task the listener started has failed. Failures of automatic work
    /// show up in the app only.
    func postFailure(category: Category, title: String, body: String, isUserInitiated: Bool) async {
        await post(kind: .failure, category: category, title: title, body: body, isUserInitiated: isUserInitiated)
    }

    /// Something only the listener can fix, whoever started the work.
    func postActionRequired(category: Category, title: String, body: String) async {
        await post(kind: .actionRequired, category: category, title: title, body: body, isUserInitiated: false)
    }

    // MARK: - Settings

    /// Asks for permission when the listener turns notifications on. Returns
    /// false when notifications are (or were just) refused.
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            permissionRequested = true
            permissionGranted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return permissionGranted
        default:
            return false
        }
    }

    func isAuthorizationDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    // MARK: - Internals

    private var isApplicationActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        NSApp.isActive
        #else
        true
        #endif
    }

    private func post(
        kind: UserNotificationPolicy.Kind,
        category: Category,
        title: String,
        body: String,
        isUserInitiated: Bool,
        itemCount: Int? = nil
    ) async {
        let decision = UserNotificationPolicy.decision(
            kind: kind,
            title: title,
            body: body,
            isApplicationActive: isApplicationActive,
            isUserInitiated: isUserInitiated,
            completionNotificationsEnabled: notifyLongTasksEnabled,
            itemCount: itemCount
        )
        guard decision == .post else {
            if case .skip(let reason) = decision {
                plog("🔔 Notification skipped: \(category.rawValue) reason=\(reason.rawValue)")
            }
            return
        }

        let signature = "\(category.rawValue)\u{0}\(title)\u{0}\(body)"
        let now = Date()
        let repeatInterval = UserNotificationPolicy.repeatInterval(for: kind)
        lastPostAtBySignature = lastPostAtBySignature.filter {
            now.timeIntervalSince($0.value) < UserNotificationPolicy.repeatInterval(for: .actionRequired)
        }
        if let lastPostAt = lastPostAtBySignature[signature],
           now.timeIntervalSince(lastPostAt) < repeatInterval {
            return
        }
        // Reserve before the authorization/add awaits. MainActor methods are
        // re-entrant, so another identical post could otherwise pass this check
        // while the first one is suspended in UserNotifications.
        lastPostAtBySignature[signature] = now

        guard await ensureAuthorized(), !isApplicationActive else {
            if lastPostAtBySignature[signature] == now {
                lastPostAtBySignature[signature] = nil
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category.rawValue

        // Per-category identifier so a fresh notification of the same kind
        // replaces the previous one in Notification Center instead of
        // stacking up after repeat runs.
        let request = UNNotificationRequest(
            identifier: category.rawValue,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            plog("🔔 Notification posted: \(category.rawValue)")
        } catch {
            if lastPostAtBySignature[signature] == now {
                lastPostAtBySignature[signature] = nil
            }
        }
    }

    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Always re-check the live status — the user may have flipped the
        // OS toggle in System Settings since last launch.
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            #if DEBUG
            // Unattended simulator runs: the system prompt would sit over
            // every screenshot and cannot be answered from a script.
            if ProcessInfo.processInfo.environment["PRIMUSE_NO_NOTIFICATION_PROMPT"] == "1" {
                return false
            }
            #endif
            guard !permissionRequested else { return permissionGranted }
            permissionRequested = true
            do {
                permissionGranted = try await center.requestAuthorization(options: [.alert, .sound])
                return permissionGranted
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }
}
