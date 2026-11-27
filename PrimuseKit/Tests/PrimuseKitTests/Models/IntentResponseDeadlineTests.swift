import Testing
@testable import PrimuseKit

@MainActor
@Suite("Intent response deadline")
struct IntentResponseDeadlineTests {
    @Test("A quick answer is returned as it is")
    func quickAnswer() async {
        let value = await IntentResponseDeadline.race(within: .seconds(5)) {
            1
        } onTimeout: {
            0
        }
        #expect(value == 1)
    }

    @Test("A slow operation is answered at the deadline and still runs to the end")
    func slowOperation() async throws {
        let log = CompletionLog()
        let value = await IntentResponseDeadline.race(within: .milliseconds(50)) {
            try? await Task.sleep(for: .milliseconds(300))
            log.finished = true
            return 1
        } onTimeout: {
            0
        }
        #expect(value == 0)
        #expect(!log.finished)
        try await Task.sleep(for: .milliseconds(800))
        #expect(log.finished)
    }
}

@MainActor
private final class CompletionLog {
    var finished = false
}
