import Foundation

/// 把「最后一个键是大数组」的对象分批编码成 JSON。
///
/// `JSONEncoder.encode` 会先把整棵值树建好再输出字节 —— 二十多万首歌的曲库快照
/// 编一次要额外占用近 1GB, 大曲库在手机上会因此被系统按内存超限杀掉。这里先编码
/// 数组为空的外层对象, 再按批编码数组元素拼进去, 瞬时占用只剩输出字节加一批的
/// 值树。紧凑输出下拼出来的字节与整份编码逐字节相同。
///
/// 只有外层对象的编码以 `"<key>":[]}` 结尾(数组键排在最后)时才能拼接; 否则返回
/// nil, 由调用方退回整份编码。
public enum TrailingArrayJSONEncoding {
    public static func encode<Element: Encodable>(
        emptyArrayObject: Data,
        trailingKey: String,
        elements: [Element],
        encoder: JSONEncoder,
        chunkSize: Int = 1000
    ) throws -> Data? {
        guard !encoder.outputFormatting.contains(.prettyPrinted) else { return nil }
        let suffix = Data("\"\(trailingKey)\":[]}".utf8)
        guard emptyArrayObject.count > suffix.count,
              emptyArrayObject.suffix(suffix.count).elementsEqual(suffix) else {
            return nil
        }
        // 键前面必须是对象开头或成员分隔符, 才说明它是外层对象的最后一个成员,
        // 而不是某个字符串值的一部分。
        let keyStart = emptyArrayObject.endIndex - suffix.count
        let preceding = emptyArrayObject[keyStart - 1]
        guard preceding == UInt8(ascii: "{") || preceding == UInt8(ascii: ",") else { return nil }

        // 保留 `"<key>":[`, 去掉末尾的 `]}`。
        var output = Data(emptyArrayObject[..<(emptyArrayObject.endIndex - 2)])
        let batchSize = max(1, chunkSize)
        var start = elements.startIndex
        var isFirstBatch = true
        while start < elements.endIndex {
            let end = min(start + batchSize, elements.endIndex)
            let batch = try encoder.encode(Array(elements[start..<end]))
            // 每批编码结果是 `[a,b,…]`, 只取中间部分。
            guard batch.count >= 2 else { return nil }
            if !isFirstBatch { output.append(UInt8(ascii: ",")) }
            output.append(batch[(batch.startIndex + 1)..<(batch.endIndex - 1)])
            if isFirstBatch {
                // 按第一批的平均大小预留, 免得几百 MB 的缓冲区反复倍增搬运。
                let estimate = output.count + (batch.count * (elements.count - end)) / max(1, end - start) + 16
                output.reserveCapacity(estimate)
            }
            isFirstBatch = false
            start = end
        }
        output.append(contentsOf: Array("]}".utf8))
        return output
    }
}
