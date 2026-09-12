import Foundation

/// 台标可以从好几个地方冒出来：用户自己选的图、导入清单里的 `tvg-logo`、
/// 在线目录的 favicon、流响应头的 `icy-logo`、带内元数据里的图片地址，
/// 以及电台主页上的 og:image / apple-touch-icon。
///
/// 这个枚举给它们排了一个固定的可信度顺序 —— 数字越小越可信。发现流程
/// 只在「能拿到更可信的来源」时才覆盖已有台标，用户自己选的图永远不被自动覆盖。
public enum RadioLogoSource: String, Codable, CaseIterable, Sendable, Hashable {
    /// 用户在编辑页手选的图片，直接以字节形式存在电台里。
    case userProvided
    /// 用户导入的 m3u/pls 清单里显式写的 logo 地址。
    case importedManifest
    /// 在线目录(radio-browser)搜索结果自带的 favicon —— 用户在搜索列表里
    /// 已经看到过这张图，添加后应该保持一致。
    case directoryFavicon
    /// 流响应头 `icy-logo`(Icecast KH 分支)。
    case icyHeader
    /// 带内元数据里的图片地址(`StreamArtwork`，或指向图片的 `StreamUrl`)。
    case inbandMetadata
    /// 电台主页上抓到的 og:image / apple-touch-icon / favicon。
    case homepageIcon
    /// 拿流地址回查在线目录得到的 favicon。
    case directoryLookup

    public var rank: Int {
        switch self {
        case .userProvided: return 0
        case .importedManifest: return 1
        case .directoryFavicon: return 2
        case .icyHeader: return 3
        case .inbandMetadata: return 4
        case .homepageIcon: return 5
        case .directoryLookup: return 6
        }
    }

    /// 自动发现能够写入的来源。`userProvided` 只能由用户操作产生。
    public var isAutomatic: Bool { self != .userProvided }
}

/// 台标地址的清洗与判定。全是纯函数，发现流程和解析器共用一份实现，
/// 免得「哪些字符串算图片」这种判断在三四个地方各写一遍。
public enum RadioLogoURLPolicy {
    /// 超过这个长度的地址一律丢弃 —— 正常台标地址不会这么长，
    /// 过长的往往是被塞了 base64 或者跟踪参数的垃圾值。
    public static let maximumURLLength = 2_000

    /// 电台元数据里常见的占位垃圾值。Shoutcast 面板在没配置时会填这些。
    private static let placeholderValues: Set<String> = [
        "0", "1", "-", "--", "n/a", "na", "null", "nil", "none", "unknown",
        "about:blank", "http://", "https://", "example.com",
    ]

    /// ImageIO 能解码的位图扩展名。SVG 不在其中 —— 解码不了，拿来当封面
    /// 只会得到一个空白格子。
    private static let bitmapExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "tif", "tiff", "ico",
    ]

    /// 归一化并校验一个候选地址。要求 http(s)、有 host、不带内嵌凭据。
    ///
    /// 带凭据的地址会被拒掉：台标不该需要用户名密码，而一旦存下来，
    /// 这个凭据就会跟着电台进 CloudKit 同步和日志。
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumURLLength,
              !placeholderValues.contains(trimmed.lowercased()) else {
            return nil
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url.absoluteString
    }

    /// 相对地址(`/logo.png`、`img/logo.png`)按 base 补全后再校验。
    /// 协议相对地址(`//cdn/logo.png`)沿用 base 的 scheme。
    public static func normalized(_ raw: String?, relativeTo base: URL?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumURLLength,
              !placeholderValues.contains(trimmed.lowercased()) else {
            return nil
        }
        if let absolute = normalized(trimmed) { return absolute }
        guard let base else { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        return normalized(resolved.absoluteString)
    }

    /// 路径看起来是不是一张位图。用来区分「`StreamUrl` 给的是台标」还是
    /// 「`StreamUrl` 给的是电台主页」—— 两者走完全不同的后续处理。
    public static func looksLikeBitmap(_ urlString: String?) -> Bool {
        guard let urlString, let url = URL(string: urlString) else { return false }
        let ext = url.pathExtension.lowercased()
        if bitmapExtensions.contains(ext) { return true }
        // 有些 CDN 把格式放在查询参数里(`?format=png`)，路径本身没有扩展名。
        let query = url.query?.lowercased() ?? ""
        return bitmapExtensions.contains { query.contains("=\($0)") }
    }

    /// 候选是否值得覆盖当前已有的台标。同来源允许刷新(地址可能变了)，
    /// 更低可信度的来源不许把更可信的图顶掉。
    public static func shouldReplace(
        current: RadioLogoSource?,
        with candidate: RadioLogoSource
    ) -> Bool {
        guard let current else { return true }
        return candidate.rank <= current.rank
    }
}
