import Foundation
import Testing
@testable import PrimuseKit

@Suite("Objective-C exception unwind policy")
struct ObjCExceptionUnwindPolicyTests {
    // 用假地址搭栈：0x5xxx 是并发运行时里的帧，其余是 App / 系统框架的帧。
    private static let start: UInt = 0x1001
    private static let main: UInt = 0x1002
    private static let runApp: UInt = 0x1003
    private static let appKitRunTry: UInt = 0x2001
    private static let appKitRunCatch: UInt = 0x2002
    private static let runLoopDrain: UInt = 0x3001
    private static let dispatchDrain: UInt = 0x3002
    private static let jobRun: UInt = 0x5001
    private static let innerJobRun: UInt = 0x5002
    private static let asyncBody: UInt = 0x6001
    private static let innerAsyncBody: UInt = 0x6002
    private static let modalRun: UInt = 0x7001
    private static let modalTry: UInt = 0x7002
    private static let modalCatch: UInt = 0x7003
    private static let eventHandler: UInt = 0x8001
    private static let throwSite: UInt = 0x9001
    private static let preprocess: UInt = 0x9002
    private static let hook: UInt = 0xA001
    private static let reportException: UInt = 0xA002

    private static func isRuntimeFrame(_ address: UInt) -> Bool {
        address & 0xF000 == 0x5000
    }

    @Test("A job that threw up to the run loop left the runtime behind")
    func exceptionEscapingJobIsDetected() {
        let thrown = [
            Self.preprocess, Self.throwSite, Self.asyncBody, Self.jobRun,
            Self.dispatchDrain, Self.runLoopDrain, Self.appKitRunTry,
            Self.runApp, Self.main, Self.start,
        ]
        let reporting = [
            Self.hook, Self.reportException, Self.appKitRunCatch,
            Self.runApp, Self.main, Self.start,
        ]

        let unwound = ObjCExceptionUnwindPolicy.unwoundFrames(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting
        )
        #expect(Array(unwound) == Array(thrown.prefix(7)))
        let escaped = ObjCExceptionUnwindPolicy.unwoundThroughConcurrencyRuntime(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting,
            isConcurrencyRuntimeFrame: Self.isRuntimeFrame
        )
        #expect(escaped)
    }

    @Test("An event handler outside any job keeps AppKit's logging behaviour")
    func exceptionOutsideJobIsIgnored() {
        let thrown = [
            Self.preprocess, Self.throwSite, Self.eventHandler, Self.appKitRunTry,
            Self.runApp, Self.main, Self.start,
        ]
        let reporting = [
            Self.hook, Self.reportException, Self.appKitRunCatch,
            Self.runApp, Self.main, Self.start,
        ]

        let escaped = ObjCExceptionUnwindPolicy.unwoundThroughConcurrencyRuntime(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting,
            isConcurrencyRuntimeFrame: Self.isRuntimeFrame
        )
        #expect(!escaped)
    }

    @Test("A job still on the stack below the catch point is not treated as abandoned")
    func exceptionCaughtInsideSameJobIsIgnored() {
        let jobBase = [
            Self.modalRun, Self.asyncBody, Self.jobRun, Self.dispatchDrain,
            Self.runLoopDrain, Self.appKitRunTry, Self.runApp, Self.main, Self.start,
        ]
        let thrown = [Self.preprocess, Self.throwSite, Self.eventHandler, Self.modalTry] + jobBase
        let reporting = [Self.hook, Self.reportException, Self.modalCatch] + jobBase

        let unwound = ObjCExceptionUnwindPolicy.unwoundFrames(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting
        )
        #expect(Array(unwound) == [Self.preprocess, Self.throwSite, Self.eventHandler, Self.modalTry])
        let escaped = ObjCExceptionUnwindPolicy.unwoundThroughConcurrencyRuntime(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting,
            isConcurrencyRuntimeFrame: Self.isRuntimeFrame
        )
        #expect(!escaped)
    }

    @Test("An inner job abandoned inside a modal loop is detected even though the outer job survives")
    func nestedJobEscapeIsDetected() {
        let jobBase = [
            Self.modalRun, Self.asyncBody, Self.jobRun, Self.dispatchDrain,
            Self.runLoopDrain, Self.appKitRunTry, Self.runApp, Self.main, Self.start,
        ]
        let thrown = [
            Self.preprocess, Self.throwSite, Self.innerAsyncBody, Self.innerJobRun,
            Self.dispatchDrain, Self.runLoopDrain, Self.modalTry,
        ] + jobBase
        let reporting = [Self.hook, Self.reportException, Self.modalCatch] + jobBase

        let escaped = ObjCExceptionUnwindPolicy.unwoundThroughConcurrencyRuntime(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting,
            isConcurrencyRuntimeFrame: Self.isRuntimeFrame
        )
        #expect(escaped)
    }

    @Test("An exception that was never raised has no unwound frames")
    func missingBacktraceIsIgnored() {
        let reporting = [Self.hook, Self.reportException, Self.runApp, Self.main, Self.start]
        let unwound = ObjCExceptionUnwindPolicy.unwoundFrames(
            thrownReturnAddresses: [],
            reportingReturnAddresses: reporting
        )
        #expect(unwound.isEmpty)
        let escaped = ObjCExceptionUnwindPolicy.unwoundThroughConcurrencyRuntime(
            thrownReturnAddresses: [],
            reportingReturnAddresses: reporting,
            isConcurrencyRuntimeFrame: { _ in true }
        )
        #expect(!escaped)
    }

    @Test("Stacks that share nothing are treated as fully unwound")
    func unrelatedStacksReturnWholeThrownStack() {
        let thrown = [Self.throwSite, Self.jobRun, 0xB001]
        let unwound = ObjCExceptionUnwindPolicy.unwoundFrames(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: [Self.hook, 0xB002]
        )
        #expect(Array(unwound) == thrown)
    }
}
