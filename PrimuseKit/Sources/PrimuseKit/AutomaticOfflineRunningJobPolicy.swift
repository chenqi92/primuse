import Foundation

/// 重新核对「要保持离线的歌」时，正在下的那一首要不要停。
///
/// 以前每次核对一进来就先停掉正在下的任务，核完再从断点续上。下载自己写文件、
/// 书架分组变化、扫描结束都会触发核对，一首歌下着下着被打断好几次（SYQ 实测
/// 一首 7.8MB 的歌中途停了三次，每次丢掉在途的那一块）。只有这首歌的身份变了，
/// 才有理由停：不再要它、内容换了、要写到别处、来源账号或线路换了、来历判断变了。
public enum AutomaticOfflineRunningJobPolicy {

    /// 决定一首歌下成什么、写到哪里的那几样。
    public struct Identity: Sendable, Equatable {
        public let contentSignature: String
        public let artifactPath: String
        public let artifactSignature: String
        public let sourceIdentitySignature: String
        public let sourceEndpointSignature: String

        public init(
            contentSignature: String,
            artifactPath: String,
            artifactSignature: String,
            sourceIdentitySignature: String,
            sourceEndpointSignature: String
        ) {
            self.contentSignature = contentSignature
            self.artifactPath = artifactPath
            self.artifactSignature = artifactSignature
            self.sourceIdentitySignature = sourceIdentitySignature
            self.sourceEndpointSignature = sourceEndpointSignature
        }
    }

    public enum Decision: Sendable, Equatable {
        case keep
        /// 停下的原因，写进日志。
        case cancel(String)
    }

    /// - Parameters:
    ///   - running: 正在下的这一首开始时的身份。
    ///   - desired: 新一轮核对里它的身份；不再要它时为 nil。
    public static func decide(running: Identity, desired: Identity?) -> Decision {
        guard let desired else { return .cancel("no-longer-wanted") }
        if desired.contentSignature != running.contentSignature { return .cancel("content-changed") }
        if desired.artifactPath != running.artifactPath { return .cancel("target-path-changed") }
        if desired.artifactSignature != running.artifactSignature { return .cancel("artifact-changed") }
        if desired.sourceIdentitySignature != running.sourceIdentitySignature { return .cancel("source-account-changed") }
        if desired.sourceEndpointSignature != running.sourceEndpointSignature { return .cancel("source-route-changed") }
        return .keep
    }

    /// 来历判断（要不要先删旧文件、保留旧文件下完再换）和开始时不一样，也要停：
    /// 这一轮核对可能会隔离它要写的那个路径。判断以原始值比较，nil 表示这一轮
    /// 没有给它算来历。
    public static func decide(
        runningDisposition: String,
        currentDisposition: String?
    ) -> Decision {
        guard let currentDisposition, currentDisposition != runningDisposition else { return .keep }
        return .cancel("refresh-disposition-changed")
    }
}
