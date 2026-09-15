import Foundation

/// 把清单文件的字节变成文本。
///
/// 电台清单是「谁导出的谁说了算」的格式：机器生成的多半是 UTF-8，手写的
/// txt 在中文系统上常常是 GBK/GB18030，偶尔还有带 BOM 的 UTF-16。
/// 一律按 UTF-8 读会得到一屏乱码台名，而乱码是存进库里之后才被发现的 ——
/// 所以解码要在入库前一次做对。
public enum RadioPlaylistText {
    /// 清单再大也就是几百 KB 的文本。超过这个数多半是地址填错了，
    /// 与其把几十 MB 读进内存，不如当成失败。
    public static let maximumBytes = 4 * 1_024 * 1_024

    public static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        // BOM 是明示的，优先级高于任何猜测。
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
                .map(strippingBOM)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
                .map(strippingBOM)
        }

        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }

        #if canImport(Darwin)
        // 合法的 UTF-8 已经在上面命中了，走到这里的中文清单基本就是 GBK 系。
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if gb18030 != kCFStringEncodingInvalidId,
           let decoded = String(data: data, encoding: String.Encoding(rawValue: gb18030)) {
            return decoded
        }
        #endif

        // Latin-1 对任意字节都成立，只能垫底 —— 它至少能把 URL 那部分读出来。
        return String(data: data, encoding: .isoLatin1)
    }

    private static func strippingBOM(_ value: String) -> String {
        value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
    }
}
