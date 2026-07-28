import Foundation
import UserNotifications

/// Cross-platform local user notifications. Wraps `UNUserNotificationCenter`
/// so call sites don't have to think about authorization, the global
/// "long-task notifications" toggle, or per-category dedup.
///
/// - Long-task completions (scrape finished, full library rescrape done) are
///   gated by `notifyLongTasksEnabled`. Errors always go through — they need
///   attention even when the user opted out of progress notifications.
/// - Authorization is requested **lazily** on the first post, never at
///   launch. The system prompt is benign and won't fire if the user already
///   answered (allow or deny).
@MainActor
final class UserNotificationService {
    static let shared = UserNotificationService()

    /// `UserDefaults` key for the user-facing toggle. Read directly via
    /// `@AppStorage` from settings, mirrored here so service callers can
    /// short-circuit before touching UNUserNotificationCenter.
    static let notifyLongTasksKey = "primuse.notifyLongTasks"

    /// User-facing toggle. Long-task completion notifications honour it;
    /// error notifications ignore it. Default on.
    var notifyLongTasksEnabled: Bool {
        // `object(forKey:)` returns nil before the user has interacted with
        // the setting → treat that as "on" so first-run users actually see
        // the notifications we're advertising.
        UserDefaults.standard.object(forKey: Self.notifyLongTasksKey) as? Bool ?? true
    }

    private var permissionRequested = false
    private var permissionGranted = false
    /// Re-adding a request with the same identifier replaces the Notification
    /// Center entry, but iOS still presents a fresh banner and sound every time.
    /// Suppress identical content posted repeatedly by scan/backfill lifecycle
    /// callbacks while preserving distinct errors from other sources.
    private var lastPostAtBySignature: [String: Date] = [:]
    private static let duplicatePostCooldown: TimeInterval = 5 * 60

    private init() {}

    // MARK: - Public posting API

    enum Category: String {
        case scrapeMissingDone
        case rescrapeLibraryDone
        case scanFailed
        case cloudSyncFailed
    }

    /// Post a long-task completion notification (B1 / B2). No-op when the
    /// toggle is off or the user denied authorization.
    func postLongTaskCompletion(category: Category, title: String, body: String) async {
        guard notifyLongTasksEnabled else { return }
        await post(category: category, title: title, body: body)
    }

    /// Post an error notification. Always shown when authorization granted —
    /// errors bypass the long-task toggle so users don't miss real failures.
    func postError(category: Category, title: String, body: String) async {
        await post(category: category, title: title, body: body)
    }

    // MARK: - Internals

    private func post(category: Category, title: String, body: String) async {
        let signature = "\(category.rawValue)\u{0}\(title)\u{0}\(body)"
        let now = Date()
        lastPostAtBySignature = lastPostAtBySignature.filter {
            now.timeIntervalSince($0.value) < Self.duplicatePostCooldown
        }
        if let lastPostAt = lastPostAtBySignature[signature],
           now.timeIntervalSince(lastPostAt) < Self.duplicatePostCooldown {
            return
        }
        // Reserve before the authorization/add awaits. MainActor methods are
        // re-entrant, so another identical post could otherwise pass this check
        // while the first one is suspended in UserNotifications.
        lastPostAtBySignature[signature] = now

        guard await ensureAuthorized() else {
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
        // stacking up after repeat scrape runs.
        let request = UNNotificationRequest(
            identifier: category.rawValue,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
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
