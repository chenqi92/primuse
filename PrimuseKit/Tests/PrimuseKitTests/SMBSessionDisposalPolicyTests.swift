import Foundation
import Testing
@testable import PrimuseKit

@Suite("SMB session disposal")
struct SMBSessionDisposalPolicyTests {
    @Test("A request that stopped being awaited keeps its session alive")
    func retainsSessionForAbandonedRequests() {
        let codes: [POSIXErrorCode] = [
            .ETIMEDOUT, .ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .EPIPE,
            .ENOTCONN, .ESHUTDOWN, .EBADF, .ENOTSOCK, .ENETRESET, .ENETDOWN,
            .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .EIO,
        ]

        for code in codes {
            #expect(SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue)
            ))
        }
    }

    /// A delivered reply leaves nothing queued inside libsmb2, so the session
    /// can still be closed and released the normal way.
    @Test("Failures carried by a delivered reply still close their session")
    func closesSessionForDeliveredFailures() {
        let codes: [POSIXErrorCode] = [
            .EACCES, .EPERM, .ENOENT, .EEXIST, .ENOTDIR, .EISDIR, .ENOSPC,
            // AMSMB2 reports a callback that fired without its payload as
            // ENODATA: the reply arrived, so nothing is left queued.
            .ENODATA,
        ]

        for code in codes {
            #expect(!SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue)
            ))
        }
    }

    @Test("Errors from other domains never retire a session")
    func ignoresUnrelatedDomains() {
        #expect(!SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut
        ))
        #expect(!SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: NSCocoaErrorDomain,
            errorCode: Int(POSIXErrorCode.ETIMEDOUT.rawValue)
        ))
    }

    @Test("A retired session is held for the rest of the process")
    func retiredSessionsStayAlive() {
        final class Session {}

        let store = SMBRetiredSessions()
        weak var observed: Session?

        do {
            let session = Session()
            observed = session
            #expect(store.retire(session) == 1)
        }

        #expect(observed != nil)
        #expect(store.count == 1)
    }
}

/// AMSMB2 4.0.3 abandons a request when its own timeout fires and then keeps
/// servicing the same socket inside the same call (a file read closes its
/// handle in `deinit`), so a late reply lands on a dead stack frame. These
/// cases pin the replacement: AMSMB2 never gives up first, Primuse's deadline
/// only stops waiting, and the request itself always runs to its real end.
@Suite("SMB request deadline")
struct SMBRequestDeadlineTests {
    @Test("AMSMB2's own timeout stays far beyond the deadline Primuse applies")
    func libraryTimeoutOutlastsDeadline() {
        let ratio = SMBRequestDeadline.libraryTimeout / SMBRequestDeadline.standardStallTimeout
        #expect(SMBRequestDeadline.libraryTimeout > 0)
        #expect(ratio >= 5)
    }

    @Test("A request that answers in time returns its value")
    func returnsValue() async throws {
        let value = try await SMBRequestDeadline.run(stallTimeout: 5) { _ in 42 }
        #expect(value == 42)
    }

    @Test("A failure reported by the request is passed through unchanged")
    func passesFailuresThrough() async {
        do {
            _ = try await SMBRequestDeadline.run(stallTimeout: 5) { _ -> Int in
                throw POSIXError(.ENOENT)
            }
            Issue.record("expected the request's own error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSPOSIXErrorDomain)
            #expect(nsError.code == Int(POSIXErrorCode.ENOENT.rawValue))
        }
    }

    /// The expired deadline must look exactly like AMSMB2's old timeout, so
    /// the busy session is retired instead of closed and a fresh one is tried.
    @Test("A request without progress is let go with ETIMEDOUT")
    func stalledRequestIsLetGo() async {
        let outcome = RequestOutcome()
        do {
            _ = try await SMBRequestDeadline.run(stallTimeout: 0.2) { _ -> Int in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                outcome.finish(cancelled: Task.isCancelled)
                return 0
            }
            Issue.record("expected the deadline to expire")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSPOSIXErrorDomain)
            #expect(nsError.code == Int(POSIXErrorCode.ETIMEDOUT.rawValue))
            #expect(SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: nsError.domain,
                errorCode: nsError.code
            ))
            #expect(SMBConnectionRecoveryPolicy.shouldReconnect(
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                completedReconnectAttempts: 0
            ))
        }
        #expect(!outcome.isFinished)
    }

    @Test("Letting go does not cancel the request; it still runs to its end")
    func requestOutlivesDeadline() async throws {
        let outcome = RequestOutcome()
        _ = try? await SMBRequestDeadline.run(stallTimeout: 0.1) { _ -> Int in
            try? await Task.sleep(nanoseconds: 400_000_000)
            outcome.finish(cancelled: Task.isCancelled)
            return 0
        }
        for _ in 0..<60 where !outcome.isFinished {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(outcome.isFinished)
        #expect(!outcome.wasCancelled)
    }

    @Test("Reported progress keeps a slow transfer alive past the stall limit")
    func progressRestartsDeadline() async throws {
        let value = try await SMBRequestDeadline.run(stallTimeout: 0.5) { activity in
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 100_000_000)
                activity.noteProgress()
            }
            return 7
        }
        #expect(value == 7)
    }

    /// AMSMB2 ignores Swift cancellation; returning early would hand the
    /// caller a session that is still in the middle of a request.
    @Test("Cancelling the caller does not abandon a pending request")
    func callerCancellationKeepsWaiting() async throws {
        let task = Task {
            try await SMBRequestDeadline.run(stallTimeout: 5) { _ -> Int in
                try? await Task.sleep(nanoseconds: 300_000_000)
                return 9
            }
        }
        task.cancel()
        let value = try await task.value
        #expect(value == 9)
    }
}

private final class RequestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancelled = false

    func finish(cancelled: Bool) {
        lock.lock()
        finished = true
        self.cancelled = cancelled
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
