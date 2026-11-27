import Foundation

/// iPhone、iPad 用线缆或隔空播放接上电视、显示器、投影时，外接屏上显示什么。
public enum ExternalDisplayContentMode: String, CaseIterable, Sendable {
    /// 封面、歌名和歌词（一直以来外接屏固定显示的那一页）。
    case nowPlaying
    /// 全屏效果，用哪一种效果另外选。
    case immersive
    /// 不接管外接屏，系统照本机画面镜像。
    case mirror

    public static let storageKey = "primuse.externalDisplay.contentMode"
    /// 外接屏用的全屏效果。空字符串是没单独选过，跟着播放页的全屏效果。
    public static let effectStorageKey = "primuse.externalDisplay.effect"
    public static let defaultValue = ExternalDisplayContentMode.nowPlaying

    /// 存储值读不出来(没设过、以后版本写的别的值)时退回默认。
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }

    /// 外接屏由 App 自己画；镜像时不建外接屏窗口，交给系统。
    public var drawsOwnContent: Bool { self != .mirror }

    public var titleKey: String {
        switch self {
        case .nowPlaying: "external_display_mode_now_playing"
        case .immersive: "external_display_mode_immersive"
        case .mirror: "external_display_mode_mirror"
        }
    }
}
