import Foundation

/// 写回预检失败时，「这个源不能写」和「这次没连上」是两回事。
///
/// 预检要连一次音乐源，而全库扫描正在跑的时候，NAS 的连接与速率预算已经被
/// 占住，一次十秒的预检很容易排队超时。把超时当成不可写，用户看到的就是
/// 「无法写回音乐源」，而他明明有写入权限 —— 这种情况该说的是稍后重试。
public enum SourceWriteProbeFailure {
    /// 是否属于「这次没成功，但源本身可能是可写的」。
    public static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return nsError.domain == NSPOSIXErrorDomain
                && [ETIMEDOUT, ECONNRESET, ECONNABORTED, EHOSTUNREACH, ENETUNREACH]
                    .contains(Int32(nsError.code))
        }
        return [
            URLError.timedOut,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed,
            .cannotFindHost,
            .resourceUnavailable,
            .cancelled,
        ].map(\.rawValue).contains(nsError.code)
    }
}
