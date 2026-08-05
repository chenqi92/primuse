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
