import Foundation
import Testing
@testable import PrimuseKit

@Suite("App distribution channel")
struct AppDistributionChannelTests {
    @Test("TestFlight is told apart from App Store by the sandbox receipt")
    func resolvesReleaseChannelsFromReceiptName() {
        #expect(AppDistributionChannel.resolve(
            isDebugBuild: false,
            receiptFileName: AppDistributionChannel.sandboxReceiptFileName
        ) == .testFlight)
        #expect(AppDistributionChannel.resolve(
            isDebugBuild: false,
            receiptFileName: "receipt"
        ) == .appStore)
    }

    @Test("A Release build without a receipt stays on the conservative side")
    func missingReceiptIsTreatedAsAppStore() {
        // 直接签名装到设备上的 Release 包没有收据。按 appStore 处理, 免得
        // 正式渠道里因为读不到收据反而多露一个诊断入口。
        #expect(AppDistributionChannel.resolve(
            isDebugBuild: false,
            receiptFileName: nil
        ) == .appStore)
        #expect(AppDistributionChannel.resolve(
            isDebugBuild: false,
            receiptFileName: ""
        ) == .appStore)
    }

    @Test("Debug wins over whatever receipt the bundle happens to carry")
    func debugBuildIsAlwaysDevelopment() {
        for receipt in [nil, "receipt", AppDistributionChannel.sandboxReceiptFileName] {
            #expect(AppDistributionChannel.resolve(
                isDebugBuild: true,
                receiptFileName: receipt
            ) == .development)
        }
    }

    @Test("Log export reaches testers but never the App Store build")
    func logExportEntryIsHiddenOnlyOnTheAppStore() {
        #expect(DiagnosticLogExportPolicy.exposesExportEntry(channel: .development))
        #expect(DiagnosticLogExportPolicy.exposesExportEntry(channel: .testFlight))
        #expect(!DiagnosticLogExportPolicy.exposesExportEntry(channel: .appStore))
    }
}
