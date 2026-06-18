import Foundation
import PrimuseKit

/// iOS 本地音乐导入 —— 把用户经系统「文件」选中的音频拷进 app 沙箱固定目录,
/// 再复用 `.local` 源 + LibraryScanner 把元数据/时长/封面/歌词读出来入库。
/// macOS 走「选文件夹 + 安全域书签」的 LocalFileSource 流程, 不经过这里。
enum LocalImportService {
    /// 本地导入源 ID 在 UserDefaults 里的持久化 key。
    private static let sourceIDKey = "local_import_source_id"

    /// 本设备的「本地音乐」源 ID。每台设备独立(UUID 存 UserDefaults):
    /// 同一设备多次导入复用同一个源往里追加; 不同设备各自独立, 即便源记录
    /// 随 CloudKit 同步过去也不会因固定 ID 互相覆盖(basePath 是各自的沙箱
    /// 路径, 在别的设备上本就无效, 会优雅降级为扫不到)。
    static var sourceID: String {
        if let existing = UserDefaults.standard.string(forKey: sourceIDKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: sourceIDKey)
        return new
    }

    /// 只读当前持久化的本地导入源 ID, 不存在返回 nil —— 不像 `sourceID` 那样
    /// 懒创建并写 UserDefaults。判断"某源是不是本地导入源"这类只读场景(算占用、
    /// 删源回收校验)用它, 避免仅仅查看源列表就在从未导入的设备上凭空写入 ID。
    static var existingSourceID: String? {
        UserDefaults.standard.string(forKey: sourceIDKey)
    }

    /// 沙箱内存放导入音频的目录(Documents/LocalMusic)。放 Documents 而非
    /// Caches —— 这些是用户自己的歌, 不能在低存储时被系统回收。
    static var musicDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("LocalMusic", isDirectory: true)
    }

    /// 确保目录存在并返回。首次创建时排除 iCloud 备份: 导入的音频可能很大,
    /// 真正需要备份的是曲库 DB, 音频本身可重新导入。
    @discardableResult
    static func ensureMusicDirectory() -> URL {
        var dir = musicDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    /// 构造/复用「本地音乐」源。basePath 指向沙箱目录, scannedDirectories=["/"]
    /// 覆盖整个目录 —— ScanService 对 `.local` 源要求 scannedDirectories 非空
    /// 才会真正扫描。
    static func makeSource(name: String) -> MusicSource {
        let dir = ensureMusicDirectory()
        return MusicSource(
            id: sourceID,
            name: name,
            type: .local,
            basePath: dir.path,
            extraConfig: MusicSource.encodeScannedDirectories(["/"], into: nil, type: .local)
        )
    }

    struct CopyResult {
        var copied = 0
        var skipped = 0
    }

    /// 把「文件」选择器返回的 URL 拷进音乐目录。选择器给的是 security-scoped
    /// URL, 必须 startAccessing 才能读。选中项可以是文件或**文件夹**——文件夹
    /// 会递归(含子目录)枚举出所有受支持音频一并导入。非受支持格式跳过; 重名
    /// 追加序号避免覆盖已导入的歌。
    static func copy(_ pickedURLs: [URL]) -> CopyResult {
        let dir = ensureMusicDirectory()
        let fm = FileManager.default
        var result = CopyResult()
        for url in pickedURLs {
            // 文件夹 URL 的 security-scoped 访问覆盖整个子树, 在此 startAccessing
            // 一次即可枚举/拷贝里面的文件; 单个文件同理。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                result.skipped += 1
                continue
            }
            if isDir.boolValue {
                for audioURL in audioFiles(under: url, fm: fm) {
                    copyOne(audioURL, into: dir, fm: fm, result: &result)
                }
            } else {
                copyOne(url, into: dir, fm: fm, result: &result)
            }
        }
        return result
    }

    /// 拷一个音频文件进目标目录(非受支持格式跳过, 重名追加序号)。
    private static func copyOne(_ url: URL, into dir: URL, fm: FileManager, result: inout CopyResult) {
        guard PrimuseConstants.supportedAudioExtensions.contains(url.pathExtension.lowercased()) else {
            result.skipped += 1
            return
        }
        let dest = uniqueDestination(for: url.lastPathComponent, in: dir, fm: fm)
        do {
            try fm.copyItem(at: url, to: dest)
            result.copied += 1
        } catch {
            result.skipped += 1
        }
    }

    /// 递归枚举文件夹(含子目录)里所有受支持的音频文件, 跳过隐藏文件。
    private static func audioFiles(under folder: URL, fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let fileURL as URL in enumerator {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular,
                  PrimuseConstants.supportedAudioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            out.append(fileURL)
        }
        return out
    }

    /// 目标目录已存在同名文件时追加 " 2"/" 3"…, 不覆盖。
    private static func uniqueDestination(for fileName: String, in dir: URL, fm: FileManager) -> URL {
        let first = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: first.path) else { return first }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
