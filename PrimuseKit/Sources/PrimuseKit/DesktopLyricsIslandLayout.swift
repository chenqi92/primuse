import Foundation

/// 一块屏幕上跟「歌词岛」有关的几何量 —— 从 NSScreen 抄出来的纯数据，
/// 这样尺寸推导能脱离 AppKit 单独测。
public struct DesktopLyricsIslandScreen: Equatable, Sendable {
    /// 整块屏幕（含菜单栏）的 frame，AppKit 坐标：左下原点、y 向上。
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`：带刘海的内建屏上等于刘海高度，其余屏为 0。
    public var safeAreaTop: CGFloat
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 的宽度，只有刘海屏才有。
    public var auxiliaryLeftWidth: CGFloat?
    public var auxiliaryRightWidth: CGFloat?
    /// 菜单栏设成自动隐藏时 visibleFrame 顶到屏幕边，拿系统状态栏厚度兜底。
    public var statusBarThickness: CGFloat

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat = 0,
        auxiliaryLeftWidth: CGFloat? = nil,
        auxiliaryRightWidth: CGFloat? = nil,
        statusBarThickness: CGFloat = 24
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
        self.statusBarThickness = statusBarThickness
    }
}

/// 指针相对歌词岛落在哪一块。
public enum DesktopLyricsIslandZone: Equatable, Sendable {
    case outside
    /// 刘海 / 顶部那条：停一下就展开。
    case trigger
    /// 刘海下面垂着的那行歌词：只让它变淡、点击照样落到后面的窗口，
    /// 不展开 —— 那里正好是全屏窗口工具栏和地址栏的位置，路过就弹开会很烦。
    case peek
    /// 已展开的卡片里。
    case inside
}

/// 歌词岛的全部尺寸。
///
/// 两种屏幕两种排法：
/// - 刘海屏：顶部那条跟刘海一样高，左右各长出一片「翼」（左封面、右声线），
///   当前这句歌词从刘海正下方垂下来一行，宽度跟着这句歌词走。
/// - 普通屏：没有刘海可借，整块只是一枚挂在屏幕顶边正中的胶囊，比菜单栏高一点，
///   封面、歌词、声线排成一行。
/// 展开后两种屏幕都是同一张卡片，只是刘海屏的内容要让出刘海那一截。
public struct DesktopLyricsIslandMetrics: Equatable, Sendable {
    public var hasNotch: Bool
    /// 硬件刘海宽度；普通屏为 0。
    public var notchWidth: CGFloat
    /// 顶部那条的高度：刘海高度，或者菜单栏高度。
    public var topBand: CGFloat
    /// 刘海两侧各长出的翼宽。普通屏为 0。
    public var wingWidth: CGFloat
    public var artworkSide: CGFloat
    /// 右翼那道声线的宽度。
    public var glyphWidth: CGFloat
    /// 刘海屏上垂下来那行歌词的高度。普通屏为 0。
    public var stripHeight: CGFloat
    public var horizontalPadding: CGFloat
    /// 普通屏胶囊里封面、文字、声线之间的间距。
    public var innerSpacing: CGFloat
    public var compactMinWidth: CGFloat
    public var compactMaxWidth: CGFloat
    public var compactHeight: CGFloat
    public var expandedWidth: CGFloat
    public var expandedHeight: CGFloat
    /// 展开卡片里内容从多高开始排 —— 刘海屏要让出刘海那一截。
    public var expandedContentTop: CGFloat
    /// 岛下方光晕要占的余量，面板比岛大出这么多。
    public var glowMargin: CGFloat
    /// 顶部两肩向外翻出的最大半径。
    public var maxShoulder: CGFloat

    public static let expandedBodyHeight: CGFloat = 150

    public static func resolve(for screen: DesktopLyricsIslandScreen) -> DesktopLyricsIslandMetrics {
        let frame = screen.frame
        var notchWidth: CGFloat = 0
        if screen.safeAreaTop > 0,
           let left = screen.auxiliaryLeftWidth,
           let right = screen.auxiliaryRightWidth {
            notchWidth = max(0, frame.width - left - right)
        }
        // 窄于 40pt 的「刘海」多半是 auxiliary 区域量歪了，按普通屏处理更稳。
        let hasNotch = notchWidth >= 40

        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let rawBand = hasNotch
            ? screen.safeAreaTop
            : (menuBar > 0 ? menuBar : screen.statusBarThickness)
        let topBand = min(max(rawBand, 18), 60)

        let artworkSide = min(max(topBand - 12, 16), 24).rounded()
        let glyphWidth: CGFloat = 22
        let wingWidth: CGFloat = hasNotch ? artworkSide + 18 : 0
        let stripHeight: CGFloat = hasNotch ? 30 : 0
        let horizontalPadding: CGFloat = hasNotch ? 18 : 12
        let compactHeight = hasNotch ? topBand + stripHeight : topBand + 8
        let compactMinWidth = hasNotch ? notchWidth + wingWidth * 2 : 170
        let compactMaxWidth = max(compactMinWidth, min(560, frame.width * 0.42))

        let expandedContentTop = hasNotch ? topBand : 10
        var expandedWidth = min(max(frame.width * 0.3, 420), 520)
        expandedWidth = max(expandedWidth, notchWidth + 240)
        expandedWidth = min(expandedWidth, max(frame.width - 40, compactMinWidth)).rounded()

        return DesktopLyricsIslandMetrics(
            hasNotch: hasNotch,
            notchWidth: notchWidth,
            topBand: topBand,
            wingWidth: wingWidth,
            artworkSide: artworkSide,
            glyphWidth: glyphWidth,
            stripHeight: stripHeight,
            horizontalPadding: horizontalPadding,
            innerSpacing: 10,
            compactMinWidth: compactMinWidth,
            compactMaxWidth: compactMaxWidth,
            compactHeight: compactHeight,
            expandedWidth: expandedWidth,
            expandedHeight: expandedContentTop + expandedBodyHeight,
            expandedContentTop: expandedContentTop,
            glowMargin: 30,
            maxShoulder: 12
        )
    }

    /// 面板要多大才装得下展开的卡片、最宽的歌词行和底下的光晕。面板本身永远
    /// 是透明的，不吃鼠标的地方由控制器按指针位置放行。
    public var panelSize: CGSize {
        let side = glowMargin + maxShoulder
        return CGSize(
            width: (max(expandedWidth, compactMaxWidth) + side * 2).rounded(.up),
            height: (max(expandedHeight, compactHeight) + glowMargin + 8).rounded(.up)
        )
    }

    /// 面板贴着屏幕顶边、水平居中。刘海总在内建屏正中，所以按屏幕中线摆就对得上。
    public func panelFrame(on screenFrame: CGRect) -> CGRect {
        let size = panelSize
        return CGRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 岛本体（不含两肩）在屏幕坐标里的位置。
    public func islandFrame(size: CGSize, on screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 收起时的宽度，由这一行文字的宽度推出来，夹在最窄和最宽之间。
    public func compactWidth(textWidth: CGFloat) -> CGFloat {
        let text = max(0, textWidth)
        let content: CGFloat
        if hasNotch {
            content = text + horizontalPadding * 2
        } else {
            content = horizontalPadding * 2 + artworkSide + glyphWidth + innerSpacing * 2 + text
        }
        return min(max(content.rounded(.up), compactMinWidth), compactMaxWidth)
    }

    /// 收起、有内容可显示时的尺寸。
    public func compactSize(textWidth: CGFloat) -> CGSize {
        CGSize(width: compactWidth(textWidth: textWidth), height: compactHeight)
    }

    /// 没东西可显示时（没在播）。刘海屏上整块缩进刘海背后，看上去就是没有；
    /// 普通屏留一枚小胶囊，告诉用户岛还在、指针移过去能展开。
    public var restingSize: CGSize {
        hasNotch ? tuckedSize : CGSize(width: 96, height: compactHeight)
    }

    /// 上岛 / 下岛动画的起止形态：刘海屏缩进刘海背后，普通屏收回屏幕顶边。
    public var tuckedSize: CGSize {
        hasNotch
            ? CGSize(width: max(notchWidth - 24, 40), height: max(topBand - 8, 10))
            : CGSize(width: 96, height: 0)
    }

    public var expandedSize: CGSize {
        CGSize(width: expandedWidth, height: expandedHeight)
    }

    /// 硬件刘海在屏幕坐标里的矩形；普通屏返回 `.null`。
    public func notchFrame(on screenFrame: CGRect) -> CGRect {
        guard hasNotch else { return .null }
        return CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - topBand,
            width: notchWidth,
            height: topBand
        )
    }

    /// 指针落在哪一块。所有矩形都是屏幕坐标（y 向上）。
    ///
    /// 收起时只有顶部那条算「要展开」，刘海下面垂着的那行歌词只让它变淡；
    /// 刘海本身永远算在触发区里 —— 没在播时岛整块缩在刘海背后，刘海是唯一能
    /// 摸到它的地方。
    public func zone(
        of point: CGPoint,
        islandFrame: CGRect,
        screenFrame: CGRect,
        expanded: Bool
    ) -> DesktopLyricsIslandZone {
        if expanded {
            return islandFrame.insetBy(dx: -8, dy: -8).contains(point) ? .inside : .outside
        }
        // 往上多放 3pt：指针顶到屏幕最上沿时读数可能正好落在边上。
        var reach = islandFrame.insetBy(dx: 0, dy: -3)
        let notch = notchFrame(on: screenFrame)
        if !notch.isNull { reach = reach.union(notch.insetBy(dx: 0, dy: -3)) }
        guard reach.contains(point) else { return .outside }
        guard hasNotch else { return .trigger }
        return point.y >= screenFrame.maxY - topBand ? .trigger : .peek
    }
}

/// 岛上临时浮现的系统状态（耳机、音量、电源）要用的纯规则。
public enum DesktopLyricsIslandOutputKind: Equatable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case airPlay
    case display
    case other
}

public enum DesktopLyricsIslandActivityPolicy {
    /// 音量一路按着会连续来事件，每来一次都从头计时。
    public static let volumeDuration: TimeInterval = 1.6
    /// 换输出设备、插拔电源这类一次性的状态。
    public static let statusDuration: TimeInterval = 3.2
    /// 换了输出设备后新设备的音量会跟着报一次变化，这段时间里的音量事件不算用户调的。
    public static let volumeQuietAfterOutputChange: TimeInterval = 1.2

    public static func outputSymbol(
        kind: DesktopLyricsIslandOutputKind,
        name: String,
        isHeadphoneJack: Bool
    ) -> String {
        let lowered = name.lowercased()
        switch kind {
        case .airPlay:
            return "airplayaudio"
        case .bluetooth:
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            if lowered.contains("beats") { return "beats.headphones" }
            if lowered.contains("homepod") { return "homepod.fill" }
            if lowered.contains("speaker") || lowered.contains("soundbar") { return "hifispeaker.fill" }
            return "headphones"
        case .builtIn:
            if isHeadphoneJack || lowered.contains("headphone") { return "headphones" }
            if lowered.contains("macbook") { return "laptopcomputer" }
            if lowered.contains("imac") { return "desktopcomputer" }
            return "speaker.wave.2.fill"
        case .usb:
            if lowered.contains("headphone") || lowered.contains("headset") { return "headphones" }
            return "hifispeaker.fill"
        case .display:
            return lowered.contains("tv") ? "tv" : "display"
        case .other:
            return "speaker.wave.2.fill"
        }
    }

    public static func volumeSymbol(level: Double, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    public static func batterySymbol(level: Double, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        if level <= 0.1 { return "battery.0percent" }
        if level <= 0.37 { return "battery.25percent" }
        if level <= 0.62 { return "battery.50percent" }
        if level <= 0.87 { return "battery.75percent" }
        return "battery.100percent"
    }

    /// 电量低于这一档时电量条改用警示色。
    public static let lowBatteryLevel: Double = 0.2
}
