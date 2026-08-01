import Testing
@testable import PrimuseKit

@Suite("Network credential policy")
struct NetworkCredentialPolicyTests {
    @Test("Passwords preserve surrounding whitespace and symbols")
    func passwordPreservesOriginalBytes() {
        let passwords = [
            " leading",
            "trailing ",
            " both ",
            "\tline\n",
            " 中文@.长密码 ",
        ]

        for password in passwords {
            #expect(NetworkCredentialPolicy.password(password) == password)
            #expect(Array(NetworkCredentialPolicy.password(password).utf8) == Array(password.utf8))
        }
    }

    @Test("Usernames retain normalized form")
    func usernameTrimsAccidentalWhitespace() {
        #expect(NetworkCredentialPolicy.username("  test-user\n") == "test-user")
    }

    @Test("Lookup failures remain distinct from missing credentials")
    func lookupFailuresRemainDistinct() {
        #expect(
            NetworkCredentialPolicy.resolveForConnector(.temporarilyUnavailable(-25308))
                == .temporarilyUnavailable(-25308)
        )
        #expect(NetworkCredentialPolicy.resolveForConnector(.failed(-34018)) == .failed(-34018))
        #expect(NetworkCredentialPolicy.resolveForConnector(.notFound) == .ready(""))
        #expect(NetworkCredentialPolicy.resolveForConnector(.found(" saved ")) == .ready(" saved "))
    }

    @Test("Replacement waits for successful login and authenticated browsing")
    func replacementRequiresCompleteValidation() {
        let candidate = " new password "

        #expect(NetworkCredentialPolicy.validatedReplacement(
            candidate: candidate,
            loginSucceeded: false,
            browserReady: false
        ) == nil)
        #expect(NetworkCredentialPolicy.validatedReplacement(
            candidate: candidate,
            loginSucceeded: true,
            browserReady: false
        ) == nil)
        #expect(NetworkCredentialPolicy.validatedReplacement(
            candidate: nil,
            loginSucceeded: true,
            browserReady: true
        ) == nil)
        #expect(NetworkCredentialPolicy.validatedReplacement(
            candidate: candidate,
            loginSucceeded: true,
            browserReady: true
        ) == candidate)
    }
}
