import Foundation

/// 响应头里报的、这次真要收下的正文字节数，用来在正文到达前判超限、预留缓冲。
/// HEAD 没有正文：它的 Content-Length 报的是同一地址 GET 会给的整份大小（Songloft 的
/// `/songs/{id}/play` 就是整首歌），拿它比内存上限只会把大文件误判成超限。
enum HTTPDeclaredBodyLengthPolicy {
    static func declaredBodyLength(method: String?, expectedContentLength: Int64) -> Int64? {
        guard method?.uppercased() != "HEAD", expectedContentLength > 0 else { return nil }
        return expectedContentLength
    }
}
