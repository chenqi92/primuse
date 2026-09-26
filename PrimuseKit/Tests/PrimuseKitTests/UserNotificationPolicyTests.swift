import Foundation
import Testing
@testable import PrimuseKit

@Suite("System notifications")
struct UserNotificationPolicyTests {
    private func decide(
        _ kind: UserNotificationPolicy.Kind,
        title: String = "Scan failed",
        body: String = "NAS: the server did not respond",
        active: Bool = false,
        userInitiated: Bool = true,
        completionsOn: Bool = true,
        items: Int? = nil
    ) -> UserNotificationPolicy.Decision {
        UserNotificationPolicy.decision(
            kind: kind,
            title: title,
            body: body,
            isApplicationActive: active,
            isUserInitiated: userInitiated,
            completionNotificationsEnabled: completionsOn,
            itemCount: items
        )
    }

    @Test("Blank text never reaches the system", arguments: [("", "body"), ("title", " \n"), ("  ", "")])
    func blank(title: String, body: String) {
        for kind in [UserNotificationPolicy.Kind.completion, .failure, .actionRequired] {
            #expect(decide(kind, title: title, body: body) == .skip(.blankContent))
        }
    }

    @Test("Nothing is posted while the app is in front")
    func foreground() {
        #expect(decide(.failure, active: true) == .skip(.applicationActive))
        #expect(decide(.actionRequired, active: true) == .skip(.applicationActive))
    }

    @Test("Completions follow the switch, which is off until turned on")
    func completionSwitch() {
        #expect(UserNotificationPolicy.completionNotificationsDefault == false)
        #expect(decide(.completion, completionsOn: false) == .skip(.completionNotificationsOff))
        #expect(decide(.completion, items: 40) == .post)
    }

    @Test("Background upkeep the listener did not start stays quiet")
    func automaticWork() {
        #expect(decide(.completion, userInitiated: false) == .skip(.notRequestedByUser))
        #expect(decide(.failure, userInitiated: false) == .skip(.notRequestedByUser))
        #expect(decide(.actionRequired, userInitiated: false) == .post)
    }

    @Test("A handful of items is not a long task")
    func smallRuns() {
        #expect(decide(.completion, items: 1) == .skip(.tooFewItems))
        #expect(decide(.completion, items: UserNotificationPolicy.minimumCompletionItems) == .post)
    }

    @Test("Problems that need the listener repeat daily, not per attempt")
    func repeatInterval() {
        #expect(UserNotificationPolicy.repeatInterval(for: .actionRequired) == 24 * 3600)
        #expect(UserNotificationPolicy.repeatInterval(for: .failure) == 5 * 60)
    }
}
