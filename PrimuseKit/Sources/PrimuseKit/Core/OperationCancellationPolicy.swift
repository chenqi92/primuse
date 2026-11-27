import Foundation

/// Normalizes cancellation errors emitted by Swift concurrency and Foundation.
/// URLSession commonly reports a cancelled task as `URLError.cancelled` rather
/// than `CancellationError`, and callers should not turn either form into a
/// user-facing failure.
public enum OperationCancellationPolicy {
    public static func isCancellation(
        _ error: any Error,
        operationIsCancelled: Bool = Task.isCancelled
    ) -> Bool {
        if error is CancellationError { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            // Foundation also uses -999 when an authentication challenge is
            // rejected. Only normalize that ambiguous code when the enclosing
            // Swift task was actually cancelled; otherwise callers must handle
            // it as a route/transport failure.
            return operationIsCancelled
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error,
           (underlying as NSError) !== nsError {
            return isCancellation(
                underlying,
                operationIsCancelled: operationIsCancelled
            )
        }
        return false
    }
}
