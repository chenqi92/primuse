import Foundation

/// 判断一次被 AppKit 顶层接住的 Objective-C 异常，展开时有没有越过 Swift 并发运行时。
///
/// 运行时执行一个 job 时把「当前执行器」登记进线程局部变量，job 返回后再手动撤销，
/// 中间没有展开清理。异常若从 job 里一路抛到运行循环边界，这条登记就留在了已经销毁的
/// 栈帧上。判断只需要两条栈：异常抛出时的返回地址，和汇报异常那一刻（捕获点）的返回地址。
public enum ObjCExceptionUnwindPolicy {
    /// 抛出栈里已经被展开掉的那一段。
    ///
    /// 两条栈从线程底部往上共享的帧仍在栈上；抛出栈剩下的前缀，就是从抛出点到捕获点之间
    /// 被越过的帧。捕获点所在的那一帧，两边返回地址不同，也算在这一段里。
    public static func unwoundFrames(
        thrownReturnAddresses thrown: [UInt],
        reportingReturnAddresses reporting: [UInt]
    ) -> ArraySlice<UInt> {
        var sharedCount = 0
        while sharedCount < thrown.count,
              sharedCount < reporting.count,
              thrown[thrown.count - 1 - sharedCount] == reporting[reporting.count - 1 - sharedCount] {
            sharedCount += 1
        }
        return thrown[..<(thrown.count - sharedCount)]
    }

    /// 被越过的帧里有没有落在并发运行时里的。
    ///
    /// 在捕获点之下仍在栈上的 job 不算：异常在同一个 job 里被接住时，它的登记依然有效。
    public static func unwoundThroughConcurrencyRuntime(
        thrownReturnAddresses: [UInt],
        reportingReturnAddresses: [UInt],
        isConcurrencyRuntimeFrame: (UInt) -> Bool
    ) -> Bool {
        unwoundFrames(
            thrownReturnAddresses: thrownReturnAddresses,
            reportingReturnAddresses: reportingReturnAddresses
        ).contains(where: isConcurrencyRuntimeFrame)
    }
}
