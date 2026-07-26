import CloudKit
import Foundation

#if os(macOS)
import Security
#endif

/// Safely constructs the shared CloudKit container for every app platform.
///
/// `CKContainer(identifier:)` raises an Objective-C exception when the running
/// binary does not carry the requested iCloud entitlement. Swift cannot catch
/// that exception, so simulator and ad-hoc builds must be rejected before
/// construction.
enum CloudKitRuntime {
    static let containerID = "iCloud.com.welape.yuanyin"

    static var canCreateContainer: Bool {
        #if targetEnvironment(simulator)
        // Simulator ad-hoc builds have no usable CloudKit container and the
        // initializer traps even when an environment override is supplied.
        false
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ),
              let identifiers = value as? [String] else {
            return false
        }
        return identifiers.contains(containerID)
        #else
        // Installable iOS/tvOS/watchOS builds are signed against the target's
        // entitlement file; an invalid profile is rejected at install/signing.
        true
        #endif
    }

    static func makeContainer() -> CKContainer? {
        guard canCreateContainer else { return nil }
        return CKContainer(identifier: containerID)
    }
}
