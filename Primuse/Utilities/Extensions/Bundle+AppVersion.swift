import Foundation
import PrimuseKit

extension Bundle {
    /// 应用版本号 (跟 xcconfig 的 MARKETING_VERSION 一致, 来自 Info.plist
    /// 的 CFBundleShortVersionString)。
    var appVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Build 号 (跟 xcconfig 的 CURRENT_PROJECT_VERSION 一致, 来自 Info.plist
    /// 的 CFBundleVersion)。
    var appBuildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    /// 这份包是 Xcode 构建、TestFlight 测试包, 还是 App Store 正式版。
    /// 只读收据文件名, 不做收据校验 —— 判定规则与理由见 `AppDistributionChannel`。
    var distributionChannel: AppDistributionChannel {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return AppDistributionChannel.resolve(
            isDebugBuild: isDebugBuild,
            receiptFileName: appStoreReceiptURL?.lastPathComponent
        )
    }
}
