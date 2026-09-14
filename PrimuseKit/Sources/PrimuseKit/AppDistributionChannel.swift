import Foundation

/// 当前这份包是从哪条渠道装上来的。
///
/// 判定只看 App Store 收据的文件名, 不做收据校验 —— 它只用来决定诊断入口露不
/// 露, 不参与解锁任何能力, 所以不需要(也不该)为此引入一次联网校验。
public enum AppDistributionChannel: String, Sendable, CaseIterable {
    /// 本机构建(Xcode 直接跑, 或任何 Debug 配置的包)。
    case development
    /// TestFlight 测试包。
    case testFlight
    /// App Store 正式版。
    case appStore

    /// TestFlight 装的包, 收据文件名固定是 `sandboxReceipt`; App Store 下载的
    /// 是 `receipt`。iOS 与 macOS 同一规则。
    public static let sandboxReceiptFileName = "sandboxReceipt"

    /// `receiptFileName` 传 `Bundle.main.appStoreReceiptURL?.lastPathComponent`。
    /// Release 配置下拿不到收据(例如直接签名装到设备上的包)时按最保守的
    /// `appStore` 处理:宁可少露一个入口,也不在正式渠道里多露一个。
    public static func resolve(
        isDebugBuild: Bool,
        receiptFileName: String?
    ) -> AppDistributionChannel {
        if isDebugBuild { return .development }
        return receiptFileName == sandboxReceiptFileName ? .testFlight : .appStore
    }
}

/// 「导出日志」入口对哪些渠道开放。
///
/// `FileLogger` 在所有构建里都照常写盘, 但导出入口此前只挂在 `#if DEBUG` 里,
/// 于是 TestFlight 用户报障时交不出日志, 只能靠口述复现。测试渠道的人本来就是
/// 来帮着找问题的, 对他们开放; App Store 正式版仍然不显示 —— 日志里凭据虽已由
/// `LogRedactionPolicy` 脱敏, 仍带着音乐源主机名与本地路径这类使用痕迹, 不该在
/// 正式版里摆一个随手就能外发的按钮。
public enum DiagnosticLogExportPolicy {
    public static func exposesExportEntry(channel: AppDistributionChannel) -> Bool {
        channel != .appStore
    }
}
