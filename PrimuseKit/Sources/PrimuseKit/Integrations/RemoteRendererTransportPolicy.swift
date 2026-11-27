import Foundation

/// UPnP AVTransport 回报的传输状态。
///
/// 固件之间的字符串并不统一 —— 大小写、首尾空白都见过, 还有回 "PAUSED"
/// 这种规范里没有的简写。把它归一成枚举, 上层就不用再拿字符串做判断。
public enum RemoteRendererTransportState: Sendable, Equatable {
    case stopped
    case playing
    case paused
    case transitioning
    case noMediaPresent
    /// 设备没回状态, 或者回了个规范外的值。
    case unknown

    public init(reported: String?) {
        let normalized = (reported ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch normalized {
        case "PLAYING": self = .playing
        case "STOPPED": self = .stopped
        case "PAUSED_PLAYBACK", "PAUSED_RECORDING", "PAUSED": self = .paused
        case "TRANSITIONING": self = .transitioning
        case "NO_MEDIA_PRESENT", "NO MEDIA PRESENT": self = .noMediaPresent
        default: self = .unknown
        }
    }
}

/// 投放时"下一步该给渲染器发什么命令"的判断。
///
/// 这里不发网络请求, 只根据渲染器回报的状态做决定 —— 换歌、曲末接下一首
/// 这些路径因此可以脱离真实音箱验证。
public enum RemoteRendererTransportPolicy {
    /// 装载新曲目之前是否必须先发 Stop。
    ///
    /// UPnP 规范允许在播放中直接 SetAVTransportURI, 但大量音箱固件做不到:
    /// transport 不在 STOPPED 时, 要么回 705 (Transport is locked), 要么收下
    /// 新 URI 却继续把当前这首放完。两种表现对用户是同一件事 —— app 里已经
    /// 翻到下一首, 音箱还在放上一首。先 Stop 把 transport 打回 STOPPED 再设
    /// URI 是控制点的通用做法。
    ///
    /// 状态不明时按最坏情况处理: 多发一条 Stop 只多一次局域网往返, 漏发一条
    /// 就是切不了歌。
    public static func requiresStopBeforeLoading(_ state: RemoteRendererTransportState) -> Bool {
        switch state {
        case .stopped, .noMediaPresent: false
        case .playing, .paused, .transitioning, .unknown: true
        }
    }

    /// Stop 之后等渲染器把 transport 真正落到 STOPPED 的时间。
    public static let stopSettleMilliseconds = 180

    /// 装载一条 URI 最多试几次。第一次不成立刻再来一遍, 第二遍不再相信设备
    /// 回报的状态, 无条件先 Stop。
    public static let maximumLoadAttempts = 2

    /// 回读 CurrentURI 对不上时, 隔多久再读一次才下结论。少数固件的状态变量
    /// 要慢一拍才更新。
    public static let uriReadbackRetryMilliseconds = 250

    /// 渲染器是不是正在出声。
    ///
    /// TRANSITIONING 是"正在缓冲 / 正在切换", 算在播 —— 否则每次换歌界面都要
    /// 闪一下暂停。回 nil 表示状态不认识, 界面保持原样: 不能凭一个读不懂的
    /// 字符串去翻转播放状态。
    public static func isRenderingAudio(_ state: RemoteRendererTransportState) -> Bool? {
        switch state {
        case .playing, .transitioning: true
        case .stopped, .paused, .noMediaPresent: false
        case .unknown: nil
        }
    }

    /// 曲末容差。1Hz 轮询常常要到最后一两秒才看见停止, 设备自报的 RelTime
    /// 也可能比实际结束早几秒。
    public static let trackEndTolerance: TimeInterval = 6

    /// 渲染器停下来了, 这是不是"这一首播完了"、该接下一首。
    ///
    /// 本机播放有解码器回调告诉我们曲终, 投放模式只有轮询能看见, 所以判断
    /// 必须保守: 先看到过它真的在播, 并且停下的位置贴着曲末, 才算播完。
    /// 用户在音箱面板上按停止、或者流断了停在中间, 都不该被当成切歌。
    public static func shouldAdvanceAfterTrackEnd(
        state: RemoteRendererTransportState,
        hasObservedPlayback: Bool,
        lastKnownTime: TimeInterval,
        knownDuration: TimeInterval
    ) -> Bool {
        guard hasObservedPlayback else { return false }
        switch state {
        case .stopped, .noMediaPresent: break
        case .playing, .paused, .transitioning, .unknown: return false
        }
        guard knownDuration.isFinite, knownDuration > 0,
              lastKnownTime.isFinite, lastKnownTime >= 0 else { return false }
        return lastKnownTime >= knownDuration - trackEndTolerance
    }

    /// 渲染器回读的 CurrentURI 是不是我们刚装进去的那一条。
    ///
    /// SetAVTransportURI 回 200 不代表固件真的换了曲目, 所以装完要回读一次。
    /// 回读本身也不可靠: 有的设备不实现 GetMediaInfo, 有的在切换途中回空,
    /// 有的把保留字符重新转义一遍。只有"明确回了另一条 URI"才判定没装上 ——
    /// 拿不准就放过, 误判会让一首本来能播的歌白白重发一遍。
    public static func didLoadRequestedURI(reported: String?, requested: String) -> Bool {
        guard let reported else { return true }
        let loaded = normalizedURI(reported)
        guard !loaded.isEmpty else { return true }
        return loaded == normalizedURI(requested)
    }

    private static func normalizedURI(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.removingPercentEncoding ?? value
        while value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }
}
