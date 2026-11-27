import Foundation

/// Keeps remote sessions alive that their library can no longer close.
///
/// AMSMB2 leaves a request queued in libsmb2, with a callback pointing into
/// memory that is already gone, when it stops waiting for it. Closing or
/// releasing such a session fires that callback through a freed directory
/// handle. Retaining the session is what stops that teardown from ever
/// running, so a broken session is parked here for the rest of the process
/// instead of being closed.
///
/// `SMBSessionDisposalPolicy` decides which failures land here; ordinary
/// protocol errors still close their session normally.
public final class RemoteRetiredSessions: @unchecked Sendable {
    public static let shared = RemoteRetiredSessions()

    private let lock = NSLock()
    private var sessions: [AnyObject] = []

    public init() {}

    /// Retains `session` and reports how many sessions are now being held.
    @discardableResult
    public func retire(_ session: AnyObject) -> Int {
        lock.lock()
        defer { lock.unlock() }
        sessions.append(session)
        return sessions.count
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }
}

/// Bounds how long Primuse waits on one call into a callback-based remote
/// client (AMSMB2) without letting that client give up on the request itself.
///
/// AMSMB2 stops waiting once its `timeout` passes without socket activity,
/// but the request stays queued in libsmb2 with a callback pointer into the
/// stack frame that was waiting. Its multi-step calls keep servicing the same
/// socket right after that: the file transfers close their handle in
/// `deinit`, `connectShare` releases the old context after a failed echo,
/// `listShares` disconnects its temporary session. A reply or teardown at
/// that point is delivered through the stale pointer, sometimes before the
/// error ever reaches Primuse, so retiring the session afterwards can be too
/// late. (NFS uses libnfs' synchronous calls instead, see `LibNFSSession`.)
///
/// Clients therefore run with `libraryTimeout`, which switches the client's
/// own timeout off, and the deadline is enforced here from the outside. When
/// it expires the caller stops waiting, while the request itself stays
/// awaited with a valid callback until its reply or a transport error ends
/// it. The thrown error is `ETIMEDOUT`, so callers retire that still busy
/// session (`SMBSessionDisposalPolicy`) and reconnect on a fresh one.
public enum RemoteRequestDeadline {
    /// Value for the client's own `timeout`: 0 turns AMSMB2's timeout off.
    ///
    /// AMSMB2 measures it with `Date()`, so time the device spends asleep
    /// counts as silence. A request still in flight when an Apple TV or Mac
    /// went to sleep was given up on the first poll after waking — any finite
    /// value is shorter than a night — and the late reply then landed on the
    /// dead stack frame described above. The deadline here runs on uptime
    /// instead. A request whose server never answers keeps one thread of its
    /// retired session waiting until the transport reports an error.
    public static let libraryTimeout: TimeInterval = 0

    /// The deadline AMSMB2 and the former NFSKit client used to apply by
    /// themselves (their default timeout); NFSv3 requests time out after it.
    public static let standardStallTimeout: TimeInterval = 60

    /// Directory listings report no progress, so their deadline covers the
    /// whole listing. The libraries' own timeouts only counted silence, and a
    /// large folder over a slow link can keep replies coming for well over a
    /// minute.
    public static let listingStallTimeout: TimeInterval = 180

    /// Progress of one request. Transfers report every completed chunk, which
    /// restarts the deadline, so a slow but moving download is not cut off.
    public final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastProgress: UInt64

        fileprivate init() {
            lastProgress = RemoteRequestDeadline.now()
        }

        /// Restarts the deadline. Returns `true` so it can directly answer
        /// the libraries' "keep going?" progress callbacks.
        @discardableResult
        public func noteProgress() -> Bool {
            let now = RemoteRequestDeadline.now()
            lock.lock()
            lastProgress = now
            lock.unlock()
            return true
        }

        fileprivate func idleNanoseconds(at now: UInt64) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return now > lastProgress ? now - lastProgress : 0
        }
    }

    /// Runs `operation` and stops waiting for it once `stallTimeout` seconds
    /// pass without it finishing or reporting progress.
    ///
    /// Caller cancellation is deliberately not a reason to stop waiting:
    /// the libraries ignore it, and while the request is pending its session
    /// can be neither reused nor closed. Only the deadline lets go early, and
    /// the request keeps running after that.
    public static func run<Value: Sendable>(
        stallTimeout: TimeInterval,
        operation: @escaping @Sendable (_ activity: Activity) async throws -> Value
    ) async throws -> Value {
        let limit = (max(0.05, stallTimeout) * 1_000_000_000)
            .finiteUInt64(or: 60_000_000_000)
        let activity = Activity()
        let race = CancellableResultRace<Value>()
        Task<Void, Never> {
            do {
                race.resolve(.success(try await operation(activity)))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let watchdog = Task<Void, Never> {
            var wait = limit
            while true {
                do {
                    try await Task.sleep(nanoseconds: wait)
                } catch {
                    return
                }
                let idle = activity.idleNanoseconds(at: now())
                if idle >= limit {
                    race.resolve(.failure(POSIXError(.ETIMEDOUT)))
                    return
                }
                wait = limit - idle
            }
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
        }
    }

    /// Uptime, so time the app spends suspended does not count as a stall.
    fileprivate static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
