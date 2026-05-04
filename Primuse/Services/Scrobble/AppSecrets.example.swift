// 模板文件 — 不参与编译 (没在 xcodeproj 里), 只给克隆仓库的人看的样例。
//
// 用法: 复制本文件为 `AppSecrets.swift` (同目录, gitignored), 把下面的
// 占位串换成自己注册的 Last.fm application credentials。如果留空, app
// 会 fallback 到「让用户自己在 Settings 里粘 key」模式, 不影响其他功能。
//
// Last.fm application 在 https://www.last.fm/api/account/create 注册,
// Callback URL 字段填一个 https URL (随便, 移动 app 不会真用到), app
// 实际用 `primuse://lastfm-auth` 走 ASWebAuthenticationSession 回调。
import Foundation

enum AppSecrets {
    static let lastFmAPIKey = "YOUR_LASTFM_API_KEY"
    static let lastFmAPISecret = "YOUR_LASTFM_SHARED_SECRET"

    /// 部分自定义 scraper 源的字级歌词需要二进制 payload 解密 (XOR + zlib),
    /// 这里按 scraper id 配 4 个 secret 字段 (URL 模板 / contentField /
    /// magicHex / xorKeyHex)。详见 `Primuse/Services/Scrobble/AppSecrets.swift`
    /// (gitignored 不入仓库)。
    static let scraperSecrets: [String: [String: String]] = [:]
}
