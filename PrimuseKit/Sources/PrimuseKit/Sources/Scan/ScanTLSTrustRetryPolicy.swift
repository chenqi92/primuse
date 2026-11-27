import Foundation

/// 扫描遇到 TLS 失败并且证书已被信任时可以自动重来一次。域名早就在信任库里
/// 的话, 信任处理会立刻返回 true, 于是一个持续握手失败的主机会让扫描无限
/// 自我重启; 这里给这类自动重试封顶, 超出后走正常的失败上报与退避。
public enum ScanTLSTrustRetryPolicy {
    /// 同一次扫描里允许的自动重试次数。
    public static let maximumAutomaticRetries = 1

    public static func shouldRetry(afterTrustedRetries count: Int) -> Bool {
        count < maximumAutomaticRetries
    }
}
