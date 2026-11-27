import Foundation
import Testing
@testable import PrimuseKit

@Suite("响应头报的正文长度")
struct HTTPDeclaredBodyLengthPolicyTests {
    private static let fileOver32MiB: Int64 = 33_888_270

    @Test("HEAD 报的是 GET 会给的整份大小，不算这次的正文")
    func headIgnoresDeclaredLength() {
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: "HEAD", expectedContentLength: Self.fileOver32MiB
        ) == nil)
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: "head", expectedContentLength: 1_024
        ) == nil)
    }

    @Test("GET 照常按报的长度判超限")
    func getKeepsDeclaredLength() {
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: "GET", expectedContentLength: Self.fileOver32MiB
        ) == Self.fileOver32MiB)
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: nil, expectedContentLength: 2_048
        ) == 2_048)
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: "POST", expectedContentLength: 512
        ) == 512)
    }

    @Test("没报长度或报 0 时不预判")
    func unknownLengthIsNotDeclared() {
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: "GET", expectedContentLength: -1
        ) == nil)
        #expect(HTTPDeclaredBodyLengthPolicy.declaredBodyLength(
            method: "GET", expectedContentLength: 0
        ) == nil)
    }
}
