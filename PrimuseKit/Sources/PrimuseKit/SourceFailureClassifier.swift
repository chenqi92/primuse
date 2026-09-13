import Foundation

/// 音乐源操作失败的归类。
///
/// 出现的原因:同一件事(浏览目录 / 扫描 / 测试连接 / 两步验证登录)在不同的源
/// 类型里由不同的库抛错 —— `StreamResolveError`、`URLError`、连接器自定义错误。
/// 界面层此前各自 `catch`,漏掉的分支就直接把 `error.localizedDescription` 抛给
/// 用户,于是电视上出现过「未能完成操作。(PrimuseKit.StreamResolveError 错误 3。)」
/// 这种既看不懂、也没法据此做下一步动作的文案。
///
/// 归类之后界面只需要认这几种,并且可以据此**自动**进入下一步:
/// `needsTwoFactor` 直接弹验证码页,`certificateRejected` 提示去确认证书。
public enum SourceFailureKind: Sendable, Equatable {
    /// 服务端要求一次性验证码。
    case needsTwoFactor
    /// 账号、密码或会话无效。
    case authFailed
    /// 本机没有该源的凭据。
    case missingCredential
    /// TLS 证书没有通过验证,或用户拒绝了信任。
    case certificateRejected
    /// 连不上:超时、拒绝连接、DNS 解析失败、断网。
    case unreachable
    /// 连上了,但服务端返回错误状态。
    case serverError(status: Int?)
    /// 该源类型不支持当前操作。
    case unsupported
    /// 调用方自己取消的,不该当作错误提示给用户。
    case cancelled
    /// 归不进上面任何一类,界面回落到系统错误描述。
    case unknown

    /// 稳定的短标识,只用于日志与测试断言,不进界面。
    public var identifier: String {
        switch self {
        case .needsTwoFactor: return "needsTwoFactor"
        case .authFailed: return "authFailed"
        case .missingCredential: return "missingCredential"
        case .certificateRejected: return "certificateRejected"
        case .unreachable: return "unreachable"
        case .serverError: return "serverError"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }
}

public enum SourceFailureClassifier {
    /// TLS 相关的 URL 错误码。证书不受信任与「安全连接失败」都归到证书一类:
    /// 自签证书的 NAS 在拒绝信任后报的正是后者,用户要做的动作是一样的。
    public static let certificateErrorCodes: Set<Int> = [
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
        NSURLErrorSecureConnectionFailed,
    ]

    public static let unreachableErrorCodes: Set<Int> = [
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
        NSURLErrorResourceUnavailable,
    ]

    public static func kind(for error: Error) -> SourceFailureKind {
        if error is CancellationError { return .cancelled }
        if let resolveError = error as? StreamResolveError {
            switch resolveError {
            case .needs2FA: return .needsTwoFactor
            case .authFailed: return .authFailed
            case .missingCredential: return .missingCredential
            case .unsupportedSourceType: return .unsupported
            case .badServerResponse(let status): return .serverError(status: status)
            case .cannotBuildURL: return .unknown
            case .relayUnavailable: return .unreachable
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .unknown }
        if nsError.code == NSURLErrorCancelled { return .cancelled }
        if certificateErrorCodes.contains(nsError.code) { return .certificateRejected }
        if unreachableErrorCodes.contains(nsError.code) { return .unreachable }
        if nsError.code == NSURLErrorUserAuthenticationRequired { return .authFailed }
        return .unknown
    }

    /// 是否应当直接把用户送进验证码输入页,而不是先显示一条错误再让他自己去长按菜单找。
    public static func requiresTwoFactor(_ error: Error) -> Bool {
        kind(for: error) == .needsTwoFactor
    }

    /// 该错误是不是「用户可以当场处理」的:界面据此决定给按钮还是只给文案。
    public static func isActionable(_ error: Error) -> Bool {
        switch kind(for: error) {
        case .needsTwoFactor, .authFailed, .missingCredential, .certificateRejected:
            return true
        default:
            return false
        }
    }
}
