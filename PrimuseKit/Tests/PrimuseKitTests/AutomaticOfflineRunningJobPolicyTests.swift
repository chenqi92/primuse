import Foundation
import Testing
@testable import PrimuseKit

@Suite("Automatic offline running job")
struct AutomaticOfflineRunningJobPolicyTests {
    private func identity(
        content: String = "c", path: String = "p", artifact: String = "a",
        account: String = "s", route: String = "r"
    ) -> AutomaticOfflineRunningJobPolicy.Identity {
        .init(contentSignature: content, artifactPath: path, artifactSignature: artifact,
              sourceIdentitySignature: account, sourceEndpointSignature: route)
    }

    @Test("身份没变的核对不打断正在下的歌")
    func unchangedKeepsRunning() {
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: identity(), desired: identity()) == .keep)
    }

    @Test("不再要、内容或目标变了才停，并说明原因")
    func changesCancelWithReason() {
        let running = identity()
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: running, desired: nil) == .cancel("no-longer-wanted"))
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: running, desired: identity(content: "x")) == .cancel("content-changed"))
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: running, desired: identity(path: "x")) == .cancel("target-path-changed"))
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: running, desired: identity(artifact: "x")) == .cancel("artifact-changed"))
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: running, desired: identity(account: "x")) == .cancel("source-account-changed"))
        #expect(AutomaticOfflineRunningJobPolicy.decide(running: running, desired: identity(route: "x")) == .cancel("source-route-changed"))
    }

    @Test("来历判断变了要停，没算或没变不停")
    func dispositionChange() {
        #expect(AutomaticOfflineRunningJobPolicy.decide(runningDisposition: "none", currentDisposition: nil) == .keep)
        #expect(AutomaticOfflineRunningJobPolicy.decide(runningDisposition: "none", currentDisposition: "none") == .keep)
        #expect(AutomaticOfflineRunningJobPolicy.decide(runningDisposition: "none", currentDisposition: "discardUntrusted") == .cancel("refresh-disposition-changed"))
    }
}
