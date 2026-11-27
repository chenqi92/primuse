import Foundation

/// 播放界面上显示的歌名。标签空着或只是占位词时,路径末段真是文件名的源拿文件名顶上;别的时候照存的歌名显示。
/// 歌名「像是读错了编码」不在这里换:修编码归扫描与补全,界面上一换成文件名,曲库型服务器、ID 寻址的网盘、
/// Apple Music 的路径只是条目 ID,会把 ID 当歌名摆出来。
public enum PlayerDisplayTitlePolicy {
    /// - Parameter sourceType: 这首歌所在音乐源的类型;Apple Music、播客、电台这类不在音乐源列表里的传 nil。
    public static func title(stored: String, filePath: String?, sourceType: MusicSourceType?) -> String {
        let value = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServerCatalogMetadataInspectionPolicy.isPlaceholderTitle(value),
              sourceType?.itemPathsCarryFileNames == true,
              let fileTitle = MediaMetadataTextRepair.fileNameTitle(from: filePath) else { return value }
        return fileTitle
    }
}
