import Foundation

/// 设置 › 界面里的「屏幕方向」(只在 iPhone 上出现):跟着手机转,或者整个 App 固定竖屏、固定横屏。
/// 系统的方向锁定只能锁竖屏,手机横放在车载支架、床头上听电台时靠这一项把 App 停在横屏。只存在本机,不同步。
public enum InterfaceOrientationPreference: String, CaseIterable, Codable, Sendable {
    case automatic
    case portrait
    case landscape

    public static let storageKey = "primuse.interface.orientation"

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

/// 主窗口某一刻能停在哪些方向。只分竖、横、不限,朝哪一边由 App 层换成系统的方向掩码。
public enum InterfaceOrientationAllowance: Sendable, Equatable {
    case any
    case portrait
    case landscape
}

/// 几处会限定方向的东西叠在一起时听谁的。
public enum InterfaceOrientationLockPolicy {
    /// 内容自己要的方向(MV 全屏横着看)最先,其次是播放页按住的方向(横竖屏切换键、关了「跟随手机方向转屏」),
    /// 最后才是设置里的「屏幕方向」。前两样都只管这一会儿,退出、收起就交还。
    public static func allowance(
        content: InterfaceOrientationAllowance?,
        player: InterfaceOrientationAllowance?,
        preference: InterfaceOrientationPreference
    ) -> InterfaceOrientationAllowance {
        if let content { return content }
        if let player { return player }
        switch preference {
        case .automatic: return .any
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }

    /// 「跟随手机方向转屏」此刻算不算数。屏幕方向固定时手机怎么转界面都不转:播放页用切换键转过去以后,
    /// 也不能因为手机转到了同一个方向就交还 —— 交还给固定的方向,界面马上又被转回去。
    public static func followsDevice(
        _ followsDevice: Bool,
        preference: InterfaceOrientationPreference
    ) -> Bool {
        followsDevice && preference == .automatic
    }
}
