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

    static let boundaryCharacters = MediaImportText.boundaryCharacters

    public static func normalizedSourceURLString(_ text: String) -> String? {
        MediaImportText.normalizedURL(text).map(MediaImportText.rawContentURL)?.absoluteString
    }

    public static func decode(_ data: Data) -> String? {
        MediaImportText.decode(data)
    }
}
