import Foundation

/// ListenBrainz 上报发往哪台服务器(#464)。默认官方 api.listenbrainz.org;Maloja、Koito、
/// multi-scrobbler 这类自建服务也实现了 ListenBrainz 的接口,填它们的接口根地址即可。
///
/// 令牌只对发它的那台服务器有效,所以地址和令牌一样放在钥匙串里(`keychainAccount`):
/// iCloud 钥匙串、扫码直传都会把两者一起带走,别的设备不会拿自建服务器的令牌去请求官方服务器。
public enum ListenBrainzServerAddress {
    public static let officialURL = URL(string: "https://api.listenbrainz.org")!
    public static let keychainAccount = "scrobble.listenBrainz.serverURL"

    public enum ParseResult: Equatable, Sendable {
        /// 留空,或填的就是官方地址。
        case official
        case custom(URL)
        case invalid
    }

    private static let officialHosts: Set<String> = [
        "api.listenbrainz.org", "listenbrainz.org", "www.listenbrainz.org",
    ]

    /// 接口路径接在根地址后面,用户常把整条接口地址贴进来,只留根地址。
    private static let endpointSuffixes = ["/1/submit-listens", "/1/validate-token", "/1"]

    /// 用户填的文字 → 接口根地址。没写协议的按 https 补上;查询串与锚点不要。
    public static func parse(_ input: String) -> ParseResult {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .official }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              !host.contains(" ") else {
            return .invalid
        }
        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in endpointSuffixes where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        if path.isEmpty, officialHosts.contains(host), scheme == "https",
           components.port == nil || components.port == 443,
           components.user == nil, components.password == nil {
            return .official
        }
        guard let url = components.url else { return .invalid }
        return .custom(url)
    }

    /// 钥匙串里存的文字 → 实际请求的根地址。存进去的都是 `parse` 归一过的,这里只防损坏的值。
    public static func resolvedURL(stored: String) -> URL? {
        switch parse(stored) {
        case .official: return officialURL
        case .custom(let url): return url
        case .invalid: return nil
        }
    }
}
