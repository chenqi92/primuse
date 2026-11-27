import Foundation
import Testing
@testable import PrimuseKit

@Test func contentLengthResponseCompletesBeforeConnectionClose() {
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello".utf8)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: response) == response.count)

    let incomplete = Data(response.dropLast())
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: incomplete) == nil)
}

@Test func chunkedResponseCompletesBeforeConnectionClose() {
    let response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: response) == response.count)

    let incomplete = Data(response.dropLast(2))
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: incomplete) == nil)
}

@Test func framingLengthExcludesTrailingBytes() {
    let framed = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
    var buffered = framed
    buffered.append(Data("ignored".utf8))
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: buffered) == framed.count)
}

private func httpMessage(_ head: String, _ body: Data = Data()) -> Data {
    Data(head.utf8) + body
}

private func chunkedBody(_ chunks: [Data], sizeLine: (Int) -> String = { String($0, radix: 16) }) -> Data {
    var body = Data()
    for chunk in chunks {
        body += Data((sizeLine(chunk.count) + "\r\n").utf8) + chunk + Data("\r\n".utf8)
    }
    return body + Data("0\r\n\r\n".utf8)
}

@Test func chunkSizesInEitherCaseWithExtensionsAndTrailersFrameTheWholeMessage() {
    let first = Data(repeating: 0x41, count: 0x1A)
    let second = Data(repeating: 0x42, count: 0xAB)
    var body = Data("1A;name=value\r\n".utf8) + first + Data("\r\n".utf8)
    body += Data("ab\r\n".utf8) + second + Data("\r\n".utf8)
    body += Data("0\r\nX-Checksum: 1\r\nX-Other: 2\r\n\r\n".utf8)
    let message = httpMessage("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", body)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: message) == message.count)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: message) == .complete(messageLength: message.count))
}

@Test func lastChunkLookalikeInsideBinaryDataDoesNotEndTheBody() {
    // Image bytes may contain "0\r\n\r\n"; only the declared sizes decide where chunks end.
    let tricky = Data("0\r\n\r\n".utf8) + Data([0xFF, 0xD8]) + Data("\r\n0\r\n\r\n".utf8)
    let message = httpMessage(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        chunkedBody([tricky, Data(repeating: 7, count: 300)])
    )
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: message) == message.count)
    for cut in 1..<message.count {
        let prefix = Data(message.prefix(cut))
        #expect(HTTPResponseFramingPolicy.completeMessageLength(in: prefix) == nil)
    }
}

@Test func everyPrefixOfAFramedMessageWaitsForMoreBytes() {
    let messages = [
        httpMessage("HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\n", Data(repeating: 1, count: 64)),
        httpMessage("HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\n\r\n",
                 chunkedBody([Data(repeating: 2, count: 17), Data(repeating: 3, count: 1)])),
    ]
    for message in messages {
        #expect(HTTPResponseFramingPolicy.completeMessageLength(in: message) == message.count)
        for cut in 0..<message.count {
            #expect(HTTPResponseFramingPolicy.completeMessageLength(in: Data(message.prefix(cut))) == nil)
        }
    }
}

@Test func connectionClosedBeforeTheHeadersEndIsNotAResponse() {
    #expect(HTTPResponseFramingPolicy.endOfStream(in: Data()) == .closedBeforeResponse)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: Data("HTTP/1.1 200 OK\r\nContent-Le".utf8)) == .closedBeforeResponse)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) == .closedBeforeResponse)
}

@Test func closeBeforeTheDeclaredBodyEndsIsTruncated() {
    let short = httpMessage("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n", Data("12345".utf8))
    #expect(HTTPResponseFramingPolicy.endOfStream(in: short) == .truncatedBody)

    var chunked = chunkedBody([Data("hello".utf8), Data(" world".utf8)])
    chunked.removeLast(5) // stops right after a complete chunk, before the last one
    let atBoundary = httpMessage("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", chunked)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: atBoundary) == .truncatedBody)

    let midChunk = httpMessage("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", Data("a\r\n01234".utf8))
    #expect(HTTPResponseFramingPolicy.endOfStream(in: midChunk) == .truncatedBody)
}

@Test func responseWithoutLengthEndsWhenTheConnectionCloses() {
    let message = httpMessage("HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\n\r\n", Data(repeating: 9, count: 500))
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: message) == nil)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: message) == .complete(messageLength: message.count))
}

@Test func headAndBodylessStatusesCompleteAtTheHeaders() {
    let head = httpMessage("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n")
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: head, requestMethod: "HEAD") == head.count)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: head, requestMethod: "GET") == nil)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: head, requestMethod: "head") == .complete(messageLength: head.count))
    #expect(HTTPResponseFramingPolicy.endOfStream(in: head, requestMethod: "GET") == .truncatedBody)

    for status in ["204 No Content", "304 Not Modified"] {
        let message = httpMessage("HTTP/1.1 \(status)\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(HTTPResponseFramingPolicy.completeMessageLength(in: message) == message.count)
    }
}

@Test func interimResponsesAreSkippedBeforeTheFinalOne() {
    let interim = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\n"
    let message = httpMessage(interim + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n", Data("ok".utf8))
    #expect(HTTPResponseFramingPolicy.finalResponseOffset(in: message) == interim.utf8.count)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: message) == message.count)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: Data(message.dropLast())) == nil)
    #expect(HTTPResponseFramingPolicy.finalResponseOffset(in: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)) == 0)
}

@Test func invalidFramingIsMalformedNotTruncated() {
    let badLength = httpMessage("HTTP/1.1 200 OK\r\nContent-Length: -3\r\n\r\n", Data("abc".utf8))
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: badLength) == nil)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: badLength) == .malformed)

    let badChunk = httpMessage("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", Data("zz\r\nabc\r\n0\r\n\r\n".utf8))
    #expect(HTTPResponseFramingPolicy.endOfStream(in: badChunk) == .malformed)

    let missingTerminator = httpMessage("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", Data("3\r\nabcXY0\r\n\r\n".utf8))
    #expect(HTTPResponseFramingPolicy.endOfStream(in: missingTerminator) == .malformed)
}

@Test func framingReadsSlicedInputByItsOwnIndices() {
    let message = httpMessage("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n", Data("abc".utf8))
    let padded = Data("junk".utf8) + message
    let slice = padded.dropFirst(4)
    #expect(HTTPResponseFramingPolicy.completeMessageLength(in: slice) == message.count)
    #expect(HTTPResponseFramingPolicy.endOfStream(in: slice) == .complete(messageLength: message.count))
}
