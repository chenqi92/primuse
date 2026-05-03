import Compression
import Foundation

/// 通用「magic + xor + zlib」二进制歌词解码器：
/// 二进制布局 = `magic 字节 + xor(repeating-key 异或) + zlib stream`
/// 解开后是带行偏移 + 字相对偏移的文本格式：
/// `[lineStartMs,lineDurMs]<wordOffsetRelMs,wordDurMs,0>字...`
/// 转 A2 扩展 LRC（绝对时间）输出。
///
/// magic 字节、异或 key 由调用方（scraper config 的 secrets）注入——
/// 解码器本身**不携带任何平台特定的常量**，是纯算法工具。
enum XorZlibLyricsDecoder {

    /// 解密二进制 → 解压后的文本。
    /// - Parameters:
    ///   - data: 完整二进制
    ///   - magicPrefix: 文件开头需要匹配的 magic 字节（匹配后裁掉）
    ///   - xorKey: 重复异或的 key 字节
    static func decrypt(_ data: Data, magicPrefix: Data, xorKey: [UInt8]) -> String? {
        guard !xorKey.isEmpty,
              data.count > magicPrefix.count,
              data.prefix(magicPrefix.count) == magicPrefix else { return nil }
        let body = data.subdata(in: magicPrefix.count..<data.count)
        var xored = Data(count: body.count)
        for i in 0..<body.count {
            xored[i] = body[i] ^ xorKey[i % xorKey.count]
        }
        guard let inflated = inflateZlib(xored) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    /// 把行偏移 + 字相对偏移的文本转换成 (行级 LRC, 字级 A2 LRC) 双字段，
    /// 让老版本看到的也是合法行级 LRC。
    static func relativeOffsetToA2(_ text: String) -> (lineLevel: String, wordLevel: String) {
        var lineOut: [String] = []
        var wordOut: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let head = line.range(of: #"^\[(\d+),(\d+)\]"#, options: .regularExpression) else { continue }

            let headText = String(line[head])
            let nums = headText
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .split(separator: ",")
            guard nums.count == 2,
                  let lineStart = Int(nums[0]), let lineDur = Int(nums[1]) else { continue }

            let body = String(line[head.upperBound...])
            let pieces = parseWordPieces(body)
            guard !pieces.isEmpty else { continue }

            let plain = pieces.map(\.text).joined()
            guard !plain.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            lineOut.append("[\(fmt(lineStart))]\(plain)")

            var wordLine = "[\(fmt(lineStart))]"
            for p in pieces {
                wordLine += "<\(fmt(lineStart + p.offsetRel))>\(p.text)"
            }
            wordLine += "<\(fmt(lineStart + lineDur))>"
            wordOut.append(wordLine)
        }

        return (lineOut.joined(separator: "\n"), wordOut.joined(separator: "\n"))
    }

    // MARK: - Private

    private struct Piece {
        let offsetRel: Int
        let dur: Int
        let text: String
    }

    private static func parseWordPieces(_ body: String) -> [Piece] {
        let regex = try? NSRegularExpression(pattern: #"<(\d+),(\d+),\d+>([^<]*)"#)
        guard let regex else { return [] }
        let nsBody = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
        return matches.compactMap { m in
            guard m.numberOfRanges >= 4 else { return nil }
            let off = Int(nsBody.substring(with: m.range(at: 1))) ?? 0
            let dur = Int(nsBody.substring(with: m.range(at: 2))) ?? 0
            let text = nsBody.substring(with: m.range(at: 3))
            return Piece(offsetRel: off, dur: dur, text: text)
        }
    }

    private static func fmt(_ ms: Int) -> String {
        let totalCs = (ms + 5) / 10
        let cs = totalCs % 100
        let totalSec = totalCs / 100
        let s = totalSec % 60
        let m = totalSec / 60
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let raw = data.subdata(in: 2..<(data.count - 4))
        let dstCapacity = max(raw.count * 16, 64 * 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }
        let written = raw.withUnsafeBytes { src -> Int in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(dst, dstCapacity, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }
}

// MARK: - Hex helpers

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2)
            guard let byte = UInt8(cleaned[i..<next], radix: 16) else { return nil }
            bytes.append(byte)
            i = next
        }
        self.init(bytes)
    }
}

extension Array where Element == UInt8 {
    init?(hexString: String) {
        guard let data = Data(hexString: hexString) else { return nil }
        self = Array(data)
    }
}
