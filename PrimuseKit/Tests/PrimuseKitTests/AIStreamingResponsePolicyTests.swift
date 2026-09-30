import Foundation
import Testing
@testable import PrimuseKit

struct AIStreamingResponsePolicyTests {
    @Test func reassemblesEventsSplitAnywhere() {
        let body = ": keep-alive\r\nevent: content_block_delta\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\n"
            + "data: 你好\n\ndata: [DONE]"
        var parser = AIServerSentEventParser()
        var events: [AIServerSentEventParser.Event] = []
        // Feed byte by byte so every line and every UTF-8 sequence is split.
        for byte in Array(body.utf8) {
            if let event = parser.consume(byte) { events.append(event) }
        }
        if let last = parser.finish() { events.append(last) }

        #expect(events == [
            .init(name: "content_block_delta", data: "{\"a\":\n1}"),
            .init(data: "你好"),
            .init(data: "[DONE]"),
        ])
    }

    @Test func readsTextDeltasForEveryStyle() {
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"choices":[{"delta":{"content":"Hel"}}]}"#),
            style: .chatCompletions
        ) == .text("Hel"))
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#),
            style: .chatCompletions
        ) == .ignored)
        #expect(AIStreamingTextDelta.from(.init(data: "[DONE]"), style: .chatCompletions) == .done)

        #expect(AIStreamingTextDelta.from(
            .init(name: "response.output_text.delta",
                  data: #"{"type":"response.output_text.delta","delta":"lo"}"#),
            style: .responses
        ) == .text("lo"))
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"type":"response.completed","response":{}}"#),
            style: .responses
        ) == .done)
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"type":"response.failed"}"#),
            style: .responses
        ) == .failed)

        #expect(AIStreamingTextDelta.from(
            .init(name: "content_block_delta",
                  data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" wor"}}"#),
            style: .anthropicMessages
        ) == .text(" wor"))
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"x"}}"#),
            style: .anthropicMessages
        ) == .ignored)
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"type":"message_stop"}"#),
            style: .anthropicMessages
        ) == .done)

        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"candidates":[{"content":{"parts":[{"text":"skip","thought":true},{"text":"ld"}]}}]}"#),
            style: .geminiGenerateContent
        ) == .text("ld"))
        #expect(AIStreamingTextDelta.from(
            .init(data: #"{"error":{"code":429}}"#),
            style: .geminiGenerateContent
        ) == .failed)
    }

    @Test func extractsEachObjectAsSoonAsItCloses() {
        let document = """
        ```json
        {"translations": [
          {"id": "a", "text": "he said \\"}]\\" twice"},
          {"id": "b", "text": "[bracket] {brace}", "extra": [1, {"x": 2}]},
          {"id": "c", "text": "最后"}
        ]}
        ```
        """
        var extractor = AIStreamingJSONArrayExtractor(keys: ["translations"])
        var ids: [String] = []
        var completedAt: [Int] = []
        let characters = Array(document)
        var index = 0
        // Uneven pieces, as a provider's text deltas arrive.
        while index < characters.count {
            let end = min(characters.count, index + 1 + index % 7)
            let piece = String(characters[index..<end])
            index = end
            for object in extractor.append(piece) {
                ids.append(object["id"] as? String ?? "?")
                completedAt.append(index)
            }
        }

        #expect(ids == ["a", "b", "c"])
        #expect(completedAt == completedAt.sorted())
    }

    @Test func extractorAcceptsAlternateKeysAndIgnoresLookalikes() {
        var extractor = AIStreamingJSONArrayExtractor(keys: ["recommendations", "items"])
        let first = extractor.append(#"{"summary":"items: ["#)
        let second = extractor.append(#"not this","items":[{"id":"c1","reason":"r"},"#)
        let third = extractor.append(#"{"id":"c2","reason":"s"}]}"#)
        let afterClose = extractor.append(#"{"items":[{"id":"c3"}]}"#)

        #expect(first.isEmpty)
        #expect(second.map { $0["id"] as? String } == ["c1"])
        #expect(third.map { $0["id"] as? String } == ["c2"])
        #expect(afterClose.isEmpty)
    }

    @Test func geminiStreamsFromItsOwnMethod() throws {
        let gemini = AIRemoteProviderConfiguration(
            baseURL: "https://generativelanguage.googleapis.com",
            apiStyle: .geminiGenerateContent,
            generationModel: "models/gemini-flash-lite"
        )
        let regular = try AIRemoteEndpointPolicy.generationEndpoint(configuration: gemini).absoluteString
        #expect(regular.hasSuffix("/models/gemini-flash-lite:generateContent"))
        #expect(try AIRemoteEndpointPolicy.streamingGenerationEndpoint(
            configuration: gemini
        ).absoluteString == regular.replacingOccurrences(
            of: ":generateContent",
            with: ":streamGenerateContent"
        ) + "?alt=sse")

        let chat = AIRemoteProviderConfiguration(
            baseURL: "https://api.example.com/v1",
            apiStyle: .chatCompletions,
            generationModel: "model"
        )
        #expect(try AIRemoteEndpointPolicy.streamingGenerationEndpoint(configuration: chat)
            == AIRemoteEndpointPolicy.generationEndpoint(configuration: chat))
    }
}
