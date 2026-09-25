import Foundation

/// 边播边取时，前台读取的一个分块遇到网络错误后要不要原地再取一次。
///
/// 以前一个 1MB 分块只请求一次：外网 IPv6、蜂窝切基站、反代偶发断开一条
/// keep-alive 连接（-1005 / ECONNRESET），解码器立刻拿到错误，整首歌要么从头
/// 重下、要么直接跳到下一首。同一条线路上 Infuse 之类的播放器只是悄悄重连，
/// 用户根本感觉不到。
///
/// 只管前台读取：后台预取失败本来就会停掉预取、交给前台读取兜底，
/// 预取风暴式重试正是网盘风控最敏感的形态。
public enum PlaybackChunkRetryPolicy {

    /// 一个分块最多尝试几次（含第一次）。
    public static let maximumAttempts = 3

    /// 前台读取有 30 秒硬截止。重试只在前 20 秒内发起，给最后一次请求留出
    /// 完整的往返时间；等满请求超时才失败的连接也就不会再被重试。
    public static let retryWindow: TimeInterval = 20

    /// 第 `failedAttempts` 次失败之后等多久再取；`nil` 表示把错误交给上层。
    ///
    /// `isTransportFailure` 由调用方判定：只有连接层的失败（断开、重置、超时、
    /// 连不上）值得重试。登录过期、服务端拒绝、内容不对重试没有意义。
    public static func delay(
        isTransportFailure: Bool,
        failedAttempts: Int,
        elapsed: TimeInterval
    ) -> TimeInterval? {
        guard isTransportFailure,
              failedAttempts >= 1,
              failedAttempts < maximumAttempts else { return nil }
        let delay: TimeInterval = failedAttempts == 1 ? 0.5 : 1.5
        guard elapsed.isFinite, elapsed >= 0, elapsed + delay < retryWindow else { return nil }
        return delay
    }
}
