import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 群晖 Audio Station 的 WebAPI 协议层:接口发现与版本协商、请求构造、响应解码、
/// 曲目映射所需的纯规则。
///
/// Audio Station 没有公开文档。这里的请求形状取自 DSM 自报的 `SYNO.API.Info`、
/// 套件的接口定义文件,以及 PokaPlayer、音流等客户端的实际调用;响应形状取自真实
/// DSM 的响应样本。这些来源互相矛盾的地方都按「两边都能吃下」来写 —— 解码宽松、
/// 请求保守。
///
/// 只依赖 Foundation:iOS 连接器与 tvOS 解析器共用这一份,也能在 Linux 上真跑测试。
/// 带状态的部分(登录、会话续期、翻页)在 `SynologyAudioStationClient`。
public enum SynologyAudioStationAPI {
    /// DSM 用会话名区分套件的登录会话。与群晖直连的 `FileStation` 会话分开,
    /// 两边互不挤掉对方的 `_sid`。
    public static let sessionName = "AudioStation"
    public static let pageSize = 500
    /// `all` 同时覆盖共享曲库与个人曲库;个人曲库没开时它与 `shared` 等价。
    static let library = "all"
    static let songAdditional = "song_tag,song_audio,song_rating"
    static let playlistSongAdditional = "songs_song_tag,songs_song_audio,songs_song_rating"
    /// 每个账号都有一张存放「分享出去的歌」的内部歌单,不是用户建的。
    static let systemPlaylistName = "__SYNO_AUDIO_SHARED_SONGS__"
    static let songPathPrefix = "/songs/"
    /// 登录固定走 `auth.cgi`:这是群晖直连在生产环境里一直在用的入口,DSM 7 虽然在
    /// `SYNO.API.Info` 里把 Auth 报成 `entry.cgi`,旧入口仍然有效。
    static let authPath = "auth.cgi"
    static let discoveryPath = "query.cgi"
    static let discoveryQuery = "SYNO.API.Auth,SYNO.AudioStation."
    /// 真实样本里 `genre` 在 128 字节处被截断(重复拼接的 `Pop; Folk, W…`)。
    static let genreFieldCapacity = 128
    private static let formValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    // MARK: - 基址

    /// host 可能自带 scheme / 端口 / 反代前缀;basePath 接在它后面。返回不含 `/webapi` 的基址。
    public static func baseURL(host: String, port: Int?, useSSL: Bool, basePath: String?) -> URL? {
        let address = ProxyPrefixedBasePathPolicy.splitAddress(host)
        let split = NetworkHostAuthority.splitHostAndPort(address.authority)
        guard !split.host.isEmpty,
              let authority = NetworkHostAuthority.authority(host: split.host, port: split.port ?? port) else {
            return nil
        }
        let scheme = address.scheme ?? (useSSL ? "https" : "http")
        guard scheme == "http" || scheme == "https",
              let url = ProxyPrefixedBasePathPolicy.baseURL(
                scheme: scheme,
                authority: authority,
                hostPath: address.pathPrefix,
                basePath: basePath
              ),
              url.host?.isEmpty == false,
              // 凭据只走登录表单,不能跟着基址进每一条播放链接和日志。
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    // MARK: - 接口发现与版本协商

    /// `SYNO.API.Info` 不需要登录。按前缀一次查出 Auth 与全部 Audio Station 接口。
    public static func discoveryURL(baseURL: URL) -> URL? {
        let call = SynologyAudioStationCall(
            interface: nil, apiName: "SYNO.API.Info", method: "query",
            parameters: [SynologyAudioStationParameter("query", discoveryQuery)]
        )
        return url(for: call, baseURL: baseURL,
                   endpoint: SynologyAudioStationEndpoint(apiName: "SYNO.API.Info", path: discoveryPath, version: 1),
                   sid: nil)
    }

    /// 取 `min(首选, 服务端 max)`;它还得不低于服务端 min,也不低于我们依赖的请求形状最早出现的版本。
    public static func negotiatedVersion(preferred: Int, minimum: Int, serverMin: Int, serverMax: Int) -> Int? {
        guard serverMin <= serverMax, minimum <= preferred else { return nil }
        let version = min(preferred, serverMax)
        guard version >= serverMin, version >= minimum else { return nil }
        return version
    }

    public static func negotiate(
        _ descriptors: [String: SynologyAudioStationAPIDescriptor]
    ) throws -> SynologyAudioStationAPICatalog {
        guard descriptors.keys.contains(where: { $0.hasPrefix("SYNO.AudioStation.") }) else {
            // 套件没装或没启动时 DSM 根本不报这些接口。
            throw SynologyAudioStationError.audioStationUnavailable
        }
        var endpoints: [SynologyAudioStationInterface: SynologyAudioStationEndpoint] = [:]
        var rejected: Set<SynologyAudioStationInterface> = []
        for interface in SynologyAudioStationInterface.allCases {
            guard let descriptor = descriptors[interface.rawValue] else {
                if interface == .auth {
                    // 不报 Auth 的 DSM 不存在;真遇到了就退回生产环境验证过的 v7,
                    // 不在这里新造一种连不上的情形。
                    endpoints[.auth] = SynologyAudioStationEndpoint(
                        interface: .auth, path: authPath, version: interface.preferredVersion
                    )
                }
                continue
            }
            guard let version = negotiatedVersion(
                preferred: interface.preferredVersion,
                minimum: interface.minimumVersion,
                serverMin: descriptor.minVersion,
                serverMax: descriptor.maxVersion
            ) else {
                rejected.insert(interface)
                continue
            }
            let path = interface == .auth ? authPath : descriptor.path
            // 路径来自服务端:只接受 webapi 下的相对 CGI 路径,不让它把请求带去别处。
            guard isSafeAPIPath(path) else { continue }
            endpoints[interface] = SynologyAudioStationEndpoint(interface: interface, path: path, version: version)
        }
        let catalog = SynologyAudioStationAPICatalog(endpoints: endpoints, rejected: rejected)
        for interface in SynologyAudioStationInterface.allCases where interface.isEssential {
            _ = try catalog.endpoint(for: interface)
        }
        return catalog
    }

    static func isSafeAPIPath(_ path: String) -> Bool {
        guard path.hasSuffix(".cgi"), !path.hasPrefix("/") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.unicodeScalars.allSatisfy { scalar in
                    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
                }
        }
    }

    // MARK: - 请求构造

    /// 与 `SynologyStreamResolver.formEncode` 同一套:只保留 RFC 3986 的非保留字符,
    /// 其余一律转义。`+`、`&`、`/`、空格、中文都只编码这一次,DSM 按表单规则解一次就还原。
    public static func formEncoded(_ parameters: [SynologyAudioStationParameter]) -> String? {
        var pairs: [String] = []
        pairs.reserveCapacity(parameters.count)
        for parameter in parameters {
            guard let name = parameter.name.addingPercentEncoding(withAllowedCharacters: formValueAllowed),
                  let value = parameter.value.addingPercentEncoding(withAllowedCharacters: formValueAllowed) else {
                return nil
            }
            pairs.append("\(name)=\(value)")
        }
        return pairs.joined(separator: "&")
    }

    /// `api` / `version` / `method` 在前,调用参数居中,附加标记其后,`_sid` 永远最后。
    static func orderedParameters(
        for call: SynologyAudioStationCall,
        endpoint: SynologyAudioStationEndpoint,
        sid: String?,
        extraQueryItems: [URLQueryItem] = []
    ) -> [SynologyAudioStationParameter]? {
        var parameters = [
            SynologyAudioStationParameter("api", call.apiName),
            SynologyAudioStationParameter("version", String(endpoint.version)),
            SynologyAudioStationParameter("method", call.method),
        ]
        parameters += call.parameters
        let reserved = Set(parameters.map(\.name) + ["_sid"])
        for item in extraQueryItems {
            // 附加标记只能是播放层自己的键,不能改写协议参数。
            guard !reserved.contains(item.name), let value = item.value else { return nil }
            parameters.append(SynologyAudioStationParameter(item.name, value))
        }
        if let sid {
            guard !sid.isEmpty else { return nil }
            parameters.append(SynologyAudioStationParameter("_sid", sid))
        }
        return parameters
    }

    public static func url(
        for call: SynologyAudioStationCall,
        baseURL: URL,
        endpoint: SynologyAudioStationEndpoint,
        sid: String?,
        extraQueryItems: [URLQueryItem] = []
    ) -> URL? {
        guard endpoint.apiName == call.apiName,
              let parameters = orderedParameters(for: call, endpoint: endpoint, sid: sid, extraQueryItems: extraQueryItems),
              let query = formEncoded(parameters),
              var components = endpointComponents(call: call, baseURL: baseURL, endpoint: endpoint) else { return nil }
        // 查询串已经整段按表单规则编好,直接交给 percentEncodedQuery,避免 URLComponents
        // 在 Darwin 与 Linux 上对 `+`、`/` 的不同处理。
        components.percentEncodedQuery = query
        return components.url
    }

    /// 读用 GET;写与登录用 POST 表单,账号密码与歌单名都不进 URL。
    public static func request(
        for call: SynologyAudioStationCall,
        baseURL: URL,
        endpoint: SynologyAudioStationEndpoint,
        sid: String?
    ) -> URLRequest? {
        var request: URLRequest
        if call.usesPOST {
            guard endpoint.apiName == call.apiName,
                  let parameters = orderedParameters(for: call, endpoint: endpoint, sid: sid),
                  let body = formEncoded(parameters),
                  let url = endpointComponents(call: call, baseURL: baseURL, endpoint: endpoint)?.url else { return nil }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        } else {
            guard let url = url(for: call, baseURL: baseURL, endpoint: endpoint, sid: sid) else { return nil }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
        }
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func endpointComponents(
        call: SynologyAudioStationCall,
        baseURL: URL,
        endpoint: SynologyAudioStationEndpoint
    ) -> URLComponents? {
        guard isSafeAPIPath(endpoint.path), isSafePathSuffix(call.pathSuffix) else { return nil }
        let target = ProxyPrefixedBasePathPolicy.appending("webapi/\(endpoint.path)\(call.pathSuffix)", to: baseURL)
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/webapi/\(endpoint.path)\(call.pathSuffix)") else { return nil }
        components.query = nil
        components.fragment = nil
        return components
    }

    /// 路径后缀只可能是转码流的 `/0.<格式>`。
    private static func isSafePathSuffix(_ suffix: String) -> Bool {
        suffix.isEmpty || SynologyAudioStationTranscodeFormat.allCases.contains { suffix == "/0.\($0.rawValue)" }
    }

    // MARK: - 各接口的调用

    public static func loginCall(
        account: String,
        password: String,
        otp: String?,
        deviceName: String?,
        deviceID: String?
    ) -> SynologyAudioStationCall {
        // 参数与群晖直连 `SynologyAPI.login` 一致,只有会话名不同。
        var parameters = [
            SynologyAudioStationParameter("account", account),
            SynologyAudioStationParameter("passwd", password),
            SynologyAudioStationParameter("session", sessionName),
            SynologyAudioStationParameter("format", "sid"),
        ]
        if let otp, !otp.isEmpty {
            parameters.append(SynologyAudioStationParameter("otp_code", otp))
        }
        if let deviceName, !deviceName.isEmpty {
            parameters.append(SynologyAudioStationParameter("device_name", deviceName))
            parameters.append(SynologyAudioStationParameter("enable_device_token", "yes"))
        }
        if let deviceID, !deviceID.isEmpty {
            parameters.append(SynologyAudioStationParameter("device_id", deviceID))
        }
        return SynologyAudioStationCall(interface: .auth, method: "login", parameters: parameters, usesPOST: true)
    }

    public static func logoutCall() -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .auth, method: "logout", parameters: [
            SynologyAudioStationParameter("session", sessionName),
        ])
    }

    public static func infoCall() -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .info, method: "getinfo")
    }

    /// 按标题排序:几份资料都列了这个排序键。翻页期间曲库若有增删,`total`
    /// 会变,由 `SynologyAudioStationCatalogPagination` 拒收。
    public static func songListCall(offset: Int, limit: Int) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .song, method: "list", parameters: [
            SynologyAudioStationParameter("library", library),
            SynologyAudioStationParameter("additional", songAdditional),
            SynologyAudioStationParameter("sort_by", "title"),
            SynologyAudioStationParameter("sort_direction", "ASC"),
            SynologyAudioStationParameter("offset", String(offset)),
            SynologyAudioStationParameter("limit", String(limit)),
        ])
    }

    public static func songInfoCall(id: String) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .song, method: "getinfo", parameters: [
            SynologyAudioStationParameter("id", id),
            SynologyAudioStationParameter("library", library),
            SynologyAudioStationParameter("additional", songAdditional),
        ])
    }

    public static func setRatingCall(id: String, rating: Int) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .song, method: "setrating", parameters: [
            SynologyAudioStationParameter("id", id),
            SynologyAudioStationParameter("rating", String(rating)),
        ], usesPOST: true)
    }

    public static func playlistListCall(offset: Int, limit: Int) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .playlist, method: "list", parameters: [
            SynologyAudioStationParameter("library", library),
            SynologyAudioStationParameter("offset", String(offset)),
            SynologyAudioStationParameter("limit", String(limit)),
        ])
    }

    public static func playlistInfoCall(id: String, songsOffset: Int, songsLimit: Int) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .playlist, method: "getinfo", parameters: [
            SynologyAudioStationParameter("id", id),
            SynologyAudioStationParameter("library", library),
            SynologyAudioStationParameter("additional", playlistSongAdditional),
            SynologyAudioStationParameter("songs_offset", String(songsOffset)),
            SynologyAudioStationParameter("songs_limit", String(songsLimit)),
        ])
    }

    public static func createPlaylistCall(name: String, shared: Bool) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .playlist, method: "create", parameters: [
            SynologyAudioStationParameter("library", shared ? "shared" : "personal"),
            SynologyAudioStationParameter("name", name),
        ], usesPOST: true)
    }

    public static func renamePlaylistCall(id: String, newName: String) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .playlist, method: "rename", parameters: [
            SynologyAudioStationParameter("library", library),
            SynologyAudioStationParameter("id", id),
            SynologyAudioStationParameter("new_name", newName),
        ], usesPOST: true)
    }

    public static func deletePlaylistCall(id: String) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .playlist, method: "delete", parameters: [
            SynologyAudioStationParameter("id", id),
        ], usesPOST: true)
    }

    /// 按下标剪接:从 `offset` 起删掉 `limit` 首,再在 `offset` 处插入 `songIDs`。
    /// 追加用 `offset = -1, limit = 0`;`skip_duplicate` 不带时,已在歌单里的歌会让整次调用报 411。
    public static func updatePlaylistSongsCall(
        id: String,
        offset: Int,
        limit: Int,
        songIDs: [String],
        skipDuplicates: Bool
    ) -> SynologyAudioStationCall {
        var parameters = [
            SynologyAudioStationParameter("id", id),
            SynologyAudioStationParameter("offset", String(offset)),
            SynologyAudioStationParameter("limit", String(limit)),
            SynologyAudioStationParameter("songs", songIDs.joined(separator: ",")),
        ]
        if skipDuplicates { parameters.append(SynologyAudioStationParameter("skip_duplicate", "true")) }
        return SynologyAudioStationCall(interface: .playlist, method: "updatesongs", parameters: parameters, usesPOST: true)
    }

    /// 列出一个电台容器里的条目。`container` 是固定容器名,或 SHOUTcast 流派条目的
    /// `id`(`SHOUTcast_genre_Jazz`)。
    public static func radioListCall(
        container: String,
        offset: Int,
        limit: Int
    ) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .radio, method: "list", parameters: [
            SynologyAudioStationParameter("container", container),
            SynologyAudioStationParameter("offset", String(offset)),
            SynologyAudioStationParameter("limit", String(limit)),
        ])
    }

    public static func lyricsCall(id: String) -> SynologyAudioStationCall {
        SynologyAudioStationCall(interface: .lyrics, method: "getlyrics", parameters: [
            SynologyAudioStationParameter("id", id),
        ])
    }

    /// 刻意不带 `output_default=true`:那会在没有封面时回一张群晖的默认图,Primuse
    /// 需要拿到「没有」,才会接着走自己的刮削。
    public static func coverCall(for reference: SynologyAudioStationCoverReference) -> SynologyAudioStationCall {
        switch reference {
        case .song(let id, _):
            return SynologyAudioStationCall(interface: .cover, method: "getsongcover", parameters: [
                SynologyAudioStationParameter("id", id),
                SynologyAudioStationParameter("library", library),
            ])
        case .album(let name, let albumArtist):
            return SynologyAudioStationCall(interface: .cover, method: "getcover", parameters: [
                SynologyAudioStationParameter("album_name", name),
                SynologyAudioStationParameter("album_artist_name", albumArtist),
                SynologyAudioStationParameter("library", library),
            ])
        }
    }

    /// `method=stream` 回原文件字节;转码时 DSM 要求路径后面带 `/0.<格式>`。
    /// 整轨(CUE)切出来的虚拟音轨没有独立文件,`stream` 播不了,一律转码。
    public static func streamCall(id: String, transcode: SynologyAudioStationTranscodeFormat?) -> SynologyAudioStationCall {
        guard let format = transcode ?? (isVirtualTrackID(id) ? .mp3 : nil) else {
            return SynologyAudioStationCall(interface: .stream, method: "stream", parameters: [
                SynologyAudioStationParameter("id", id),
            ])
        }
        return SynologyAudioStationCall(interface: .stream, method: "transcode", parameters: [
            SynologyAudioStationParameter("id", id),
            SynologyAudioStationParameter("format", format.rawValue),
        ], pathSuffix: "/0.\(format.rawValue)")
    }

    /// 交给播放层的链接。`extraQueryItems` 给连接器挂播放层自己的标记(如转码标记),
    /// 它们排在 `_sid` 前面;DSM 忽略不认识的参数。
    public static func streamURL(
        baseURL: URL,
        endpoint: SynologyAudioStationEndpoint,
        id: String,
        transcode: SynologyAudioStationTranscodeFormat?,
        extraQueryItems: [URLQueryItem] = [],
        sid: String
    ) -> URL? {
        guard isCatalogSongID(id) else { return nil }
        return url(for: streamCall(id: id, transcode: transcode), baseURL: baseURL, endpoint: endpoint,
                   sid: sid, extraQueryItems: extraQueryItems)
    }

    // MARK: - 曲目路径 ↔ id

    /// 与 Subsonic 的 `/songs/{id}.{suffix}` 同一约定。只接受目录里的曲目 id。
    public static func trackPath(id: String, fileExtension: String) -> String? {
        guard isCatalogSongID(id), isSafeExtension(fileExtension) else { return nil }
        return "\(songPathPrefix)\(id).\(fileExtension)"
    }

    public static func songID(fromTrackPath path: String) -> String? {
        guard path.hasPrefix(songPathPrefix) else { return nil }
        let name = path.dropFirst(songPathPrefix.count)
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let id = String(name[..<dot])
        let fileExtension = String(name[name.index(after: dot)...])
        guard let rebuilt = trackPath(id: id, fileExtension: fileExtension), rebuilt == path else { return nil }
        return id
    }

    /// 目录里的曲目 id 形如 `music_6906`,整轨虚拟音轨形如 `music_v_1111`。歌单里还可能
    /// 出现尚未入库的条目,id 是 `music_/volume1/…` 这样的 NAS 路径 —— 它们不在曲库里,
    /// 不能拼进播放路径。
    public static func isCatalogSongID(_ id: String) -> Bool {
        guard id.hasPrefix("music_") else { return false }
        var rest = Substring(id.dropFirst("music_".count))
        if let underscore = rest.firstIndex(of: "_") {
            let tag = rest[..<underscore]
            guard !tag.isEmpty, tag.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return false }
            rest = rest[rest.index(after: underscore)...]
        }
        return !rest.isEmpty && rest.count <= 18 && rest.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    public static func isVirtualTrackID(_ id: String) -> Bool {
        id.hasPrefix("music_v_") && isCatalogSongID(id)
    }

    /// 歌单 id 形如 `playlist_personal_normal/开车`、`playlist_shared_normal/1`、
    /// `playlist_personal_smart/名字`;名字部分可以是任何文字。
    public static func isPlaylistID(_ id: String) -> Bool {
        guard id.hasPrefix("playlist_"), let slash = id.firstIndex(of: "/"),
              id.index(after: slash) < id.endIndex else { return false }
        return !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func isSmartPlaylistID(_ id: String) -> Bool {
        guard isPlaylistID(id), let slash = id.firstIndex(of: "/") else { return false }
        return id[..<slash].hasSuffix("_smart")
    }

    private static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 10
            && value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    // MARK: - 响应解码

    /// 统一信封 `{success, data, error:{code, errors}}`。容忍 UTF-8 BOM,容忍整个响应
    /// 或 `data` 被再包一层成 JSON 字符串,容忍数字写成字符串。不是信封就是无效响应。
    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from body: Data
    ) throws -> SynologyAudioStationReply<Value> {
        let envelope: SynologyAudioStationEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(SynologyAudioStationEnvelope<Value>.self, from: normalizedBody(body))
        } catch {
            throw SynologyAudioStationError.invalidResponse
        }
        if let failure = envelope.failure { return .failure(failure) }
        guard let value = envelope.value else { throw SynologyAudioStationError.invalidResponse }
        return .success(value)
    }

    static func normalizedBody(_ body: Data) -> Data {
        var normalized = strippingBOMAndWhitespace(body)
        // 有的节点把整个 JSON 再序列化成一个字符串返回。
        if normalized.first == UInt8(ascii: "\""),
           let text = try? JSONSerialization.jsonObject(with: normalized, options: [.fragmentsAllowed]) as? String {
            normalized = strippingBOMAndWhitespace(Data(text.utf8))
        }
        return normalized
    }

    private static func strippingBOMAndWhitespace(_ body: Data) -> Data {
        var slice = body[...]
        if slice.starts(with: [0xEF, 0xBB, 0xBF]) { slice = slice.dropFirst(3) }
        while let first = slice.first, [0x20, 0x09, 0x0A, 0x0D].contains(first) { slice = slice.dropFirst() }
        return Data(slice)
    }

    /// 二进制端点(封面、音频)在会话失效等情况下会回 HTTP 200 + JSON 错误体。
    /// 只在它确实像文档时才尝试解析:音频的中间 Range 本来就可能以 `{` 开头。
    public static func failureEnvelope(in body: Data, response: HTTPURLResponse) -> SynologyAudioStationFailure? {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let declaresDocument = contentType.contains("json") || contentType.hasPrefix("text/") || contentType.contains("html")
        let looksLikeDocument = response.statusCode != 206 && body.count <= 64 * 1_024
            && strippingBOMAndWhitespace(body.prefix(64)).first.map { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "\"") } == true
        guard declaresDocument || looksLikeDocument,
              case .failure(let failure)? = try? decode(SynologyAudioStationEmpty.self, from: body) else { return nil }
        return failure
    }

    // MARK: - 错误映射

    /// 100–150 是所有接口通用的;400 以上按接口各有含义(400–410 属于登录,411 只对
    /// 歌单有意义),所以按调用的接口解释。
    public static func error(for failure: SynologyAudioStationFailure, call: SynologyAudioStationCall) -> SynologyAudioStationError {
        let code = failure.code
        if call.interface == .auth {
            switch code {
            case 400: return .invalidCredentials
            case 401: return .accountDisabled
            // 402 是「拒绝访问」;带着 `session=AudioStation` 登录时,最可能的原因是
            // 账号没有这个套件的权限,与登录后 105 给用户的处理办法相同。
            case 402: return .noAudioStationPermission
            case 403, 406: return .twoFactorRequired(token: failure.token, types: failure.types)
            case 404: return .invalidOneTimePassword
            case 407: return .ipBlocked
            case 408, 409, 410: return .passwordExpired(code: code)
            default: break
            }
        }
        if call.interface == .playlist, code == 411 { return .duplicateInPlaylist }
        switch code {
        case 102, 103: return .apiNotFound(code: code)
        case 104: return .unsupportedVersion(api: call.apiName)
        case 105: return call.isMutation ? .operationNotPermitted : .noAudioStationPermission
        case 106, 107, 119, 150: return .sessionExpired(code: code)
        case 109, 110, 111, 117, 118: return .serverBusy(code: code)
        default: return .server(code: code)
        }
    }

    /// 这些码说明手里的 `_sid` 可能已经不能用:106 超时、107 被重复登录挤掉、119 失效、
    /// 150 登录 IP 与请求 IP 不符(换了网络路线)。105 也重登一次 —— 群晖直连的下载
    /// 同样把它当作会话失效;重登后仍是 105 才当成真的没有权限。
    public static func renewsSession(after code: Int) -> Bool {
        [105, 106, 107, 119, 150].contains(code)
    }

    // MARK: - 封面与图片

    /// 只认常见位图签名:封面端点出错时回的是 JSON,不能当成图片存进缓存。
    public static func isImageData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return false }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.starts(with: Array("GIF8".utf8)) { return true }
        if bytes.starts(with: Array("BM".utf8)) { return true }
        guard bytes.count >= 12 else { return false }
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        // HEIF / AVIF:ISO BMFF 的 `ftyp` 盒。
        return Array(bytes[4..<8]) == Array("ftyp".utf8)
    }

    // MARK: - 流派与目录

    /// Audio Station 把多值流派用 `; ` 拼成一串,同一个值还常被重复拼接
    /// (`90年代; 90年代`),超过字段容量时最后一段会被截断。拆开、去重(不分大小写,
    /// 保留第一次出现的写法)后仍用 `; ` 合并:流派本身可能含逗号
    /// (`Folk, World, & Country`),换成逗号拼接会分不清边界。
    public static func normalizedGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var pieces = raw.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if raw.utf8.count >= genreFieldCapacity, pieces.count > 1, let last = pieces.last, !last.isEmpty,
           pieces.dropLast().contains(where: { $0.count > last.count && $0.lowercased().hasPrefix(last.lowercased()) }) {
            pieces.removeLast()
        }
        var seen: Set<String> = []
        var result: [String] = []
        for piece in pieces {
            guard let value = MediaMetadataTextRepair.repaired(piece),
                  seen.insert(value.lowercased()).inserted else { continue }
            result.append(value)
        }
        return result.isEmpty ? nil : result.joined(separator: "; ")
    }

    /// 曲目所在的库根:共享文件夹(`/music`),或个人曲库(`/homes/<用户>/music`)。
    public static func libraryRoot(forNASPath path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        if parts[0] == "homes", parts.count >= 4, parts[2] == "music" {
            return "/homes/\(parts[1])/music"
        }
        return "/\(parts[0])"
    }
}

// MARK: - 接口

public enum SynologyAudioStationInterface: String, CaseIterable, Sendable {
    case auth = "SYNO.API.Auth"
    case info = "SYNO.AudioStation.Info"
    case song = "SYNO.AudioStation.Song"
    case playlist = "SYNO.AudioStation.Playlist"
    case stream = "SYNO.AudioStation.Stream"
    case cover = "SYNO.AudioStation.Cover"
    case lyrics = "SYNO.AudioStation.Lyrics"
    case radio = "SYNO.AudioStation.Radio"

    /// 我们按哪个版本写的请求与解码。
    public var preferredVersion: Int {
        switch self {
        // 群晖直连在生产环境用的就是 v7。
        case .auth: 7
        // 手上带 `privilege` / `transcode_capability` 的 Info 样本就是 v6 的响应。
        case .info: 6
        case .song, .playlist, .cover: 3
        case .stream, .lyrics: 2
        // v2 只比 v1 多一个 `search` 方法,`list` 按 v1 的形状写。
        case .radio: 1
        }
    }

    /// 我们依赖的请求形状最早出现在哪个版本。
    public var minimumVersion: Int {
        switch self {
        // `format=sid` 与 `otp_code` 从 v3 起才有。
        case .auth: 3
        default: 1
        }
    }

    /// 缺了它们整个音乐源就没法用;其余接口缺了只影响对应功能。
    public var isEssential: Bool {
        self == .song || self == .stream
    }
}

public struct SynologyAudioStationAPIDescriptor: Decodable, Equatable, Sendable {
    public let path: String
    public let minVersion: Int
    public let maxVersion: Int

    public init(path: String, minVersion: Int, maxVersion: Int) {
        self.path = path
        self.minVersion = minVersion
        self.maxVersion = maxVersion
    }

    private enum CodingKeys: String, CodingKey { case path, minVersion, maxVersion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let path = container.audioStationString(.path),
              let minVersion = container.audioStationInt(.minVersion),
              let maxVersion = container.audioStationInt(.maxVersion) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Incomplete API descriptor"))
        }
        self.init(path: path, minVersion: minVersion, maxVersion: maxVersion)
    }

    /// 单个接口描述残缺时只丢掉它,不让整张表解不出来。
    struct Table: Decodable, Sendable {
        let descriptors: [String: SynologyAudioStationAPIDescriptor]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SynologyAudioStationCodingKey.self)
            var descriptors: [String: SynologyAudioStationAPIDescriptor] = [:]
            for key in container.allKeys {
                if let value = try? container.decode(SynologyAudioStationAPIDescriptor.self, forKey: key) {
                    descriptors[key.stringValue] = value
                }
            }
            self.descriptors = descriptors
        }
    }
}

public struct SynologyAudioStationEndpoint: Equatable, Sendable {
    public let apiName: String
    public let path: String
    public let version: Int

    public init(interface: SynologyAudioStationInterface, path: String, version: Int) {
        self.init(apiName: interface.rawValue, path: path, version: version)
    }

    init(apiName: String, path: String, version: Int) {
        self.apiName = apiName
        self.path = path
        self.version = version
    }
}

public struct SynologyAudioStationAPICatalog: Equatable, Sendable {
    public let endpoints: [SynologyAudioStationInterface: SynologyAudioStationEndpoint]
    let rejected: Set<SynologyAudioStationInterface>

    public func endpoint(for interface: SynologyAudioStationInterface) throws -> SynologyAudioStationEndpoint {
        if let endpoint = endpoints[interface] { return endpoint }
        if rejected.contains(interface) { throw SynologyAudioStationError.unsupportedVersion(api: interface.rawValue) }
        if interface.isEssential { throw SynologyAudioStationError.audioStationUnavailable }
        throw SynologyAudioStationError.apiNotFound(code: 102)
    }
}

// MARK: - 调用

public struct SynologyAudioStationParameter: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct SynologyAudioStationCall: Equatable, Sendable {
    public let interface: SynologyAudioStationInterface?
    public let apiName: String
    public let method: String
    public let parameters: [SynologyAudioStationParameter]
    public let usesPOST: Bool
    /// 只有转码流需要(`/0.mp3`)。
    public let pathSuffix: String

    public init(
        interface: SynologyAudioStationInterface,
        method: String,
        parameters: [SynologyAudioStationParameter] = [],
        usesPOST: Bool = false,
        pathSuffix: String = ""
    ) {
        self.init(interface: interface, apiName: interface.rawValue, method: method,
                  parameters: parameters, usesPOST: usesPOST, pathSuffix: pathSuffix)
    }

    init(
        interface: SynologyAudioStationInterface?,
        apiName: String,
        method: String,
        parameters: [SynologyAudioStationParameter] = [],
        usesPOST: Bool = false,
        pathSuffix: String = ""
    ) {
        self.interface = interface
        self.apiName = apiName
        self.method = method
        self.parameters = parameters
        self.usesPOST = usesPOST
        self.pathSuffix = pathSuffix
    }

    /// 写操作(评分、歌单增删改)。登录也用 POST,但不算。
    public var isMutation: Bool { usesPOST && interface != .auth }
}

public enum SynologyAudioStationTranscodeFormat: String, CaseIterable, Sendable {
    case mp3
    /// 无损但体积大;`transcode_capability` 里有它才能用。
    case wav
}

// MARK: - 信封

public struct SynologyAudioStationFailure: Equatable, Sendable {
    public let code: Int
    /// 两步验证时 DSM 在 `error.errors.token` 带回的令牌。
    public let token: String?
    /// `error.errors.types[].type`,例如 `otp`。
    public let types: [String]

    public init(code: Int, token: String? = nil, types: [String] = []) {
        self.code = code
        self.token = token
        self.types = types
    }
}

public enum SynologyAudioStationReply<Value> {
    case success(Value)
    case failure(SynologyAudioStationFailure)
}

extension SynologyAudioStationReply: Sendable where Value: Sendable {}

/// 写操作成功时常常不带 `data`。
public struct SynologyAudioStationEmpty: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}

struct SynologyAudioStationEnvelope<Value: Decodable>: Decodable {
    let value: Value?
    let failure: SynologyAudioStationFailure?

    private enum CodingKeys: String, CodingKey { case success, data, error }
    private enum ErrorKeys: String, CodingKey { case code, errors }
    private enum DetailKeys: String, CodingKey { case token, types }

    /// `types` 的元素是 `{"type":"otp"}`,也容忍直接写成字符串;每个元素只读一次。
    private struct VerificationType: Decodable {
        let value: String?

        private enum Keys: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: Keys.self) {
                value = container.audioStationString(.type)
            } else {
                value = try? decoder.singleValueContainer().decode(String.self)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let success = container.audioStationBool(.success) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing success flag"))
        }
        if success {
            value = try Self.decodeValue(in: container)
            failure = nil
            return
        }
        value = nil
        let error = try? container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
        // 没有码的失败按 100(未知错误)处理,仍然是失败,不能当成功。
        let code = error?.audioStationInt(.code) ?? 100
        // 其他接口的 `errors` 可能是数组(比如 Pin 的 `[0]`),那就没有令牌可带。
        let details = try? error?.nestedContainer(keyedBy: DetailKeys.self, forKey: .errors)
        let types = ((try? details?.decodeIfPresent([VerificationType].self, forKey: .types)) ?? nil)?
            .compactMap(\.value) ?? []
        failure = SynologyAudioStationFailure(code: code, token: details?.audioStationString(.token), types: types)
    }

    private static func decodeValue(in container: KeyedDecodingContainer<CodingKeys>) throws -> Value {
        guard container.contains(.data), (try? container.decodeNil(forKey: .data)) != true else {
            return try JSONDecoder().decode(Value.self, from: Data("{}".utf8))
        }
        do {
            return try container.decode(Value.self, forKey: .data)
        } catch {
            // `data` 本身被序列化成字符串的情形。
            guard let text = try? container.decode(String.self, forKey: .data) else { throw error }
            return try JSONDecoder().decode(Value.self, from: SynologyAudioStationAPI.normalizedBody(Data(text.utf8)))
        }
    }
}

// MARK: - 模型

public struct SynologyAudioStationInfo: Decodable, Equatable, Sendable {
    public let versionString: String?
    public let isManager: Bool?
    public let canEditPlaylists: Bool?
    public let canEditTags: Bool?
    /// 服务端能转成的格式,例如 `["wav", "mp3"]`。
    public let transcodeCapability: [String]
    public let downloadEnabled: Bool?
    public let personalLibraryEnabled: Bool?
    public let hasMusicShare: Bool?

    private enum CodingKeys: String, CodingKey {
        case versionString = "version_string"
        case isManager = "is_manager"
        case privilege, settings
        case transcodeCapability = "transcode_capability"
        case personalLibraryEnabled = "enable_personal_library"
        case hasMusicShare = "has_music_share"
    }
    private enum PrivilegeKeys: String, CodingKey {
        case playlistEdit = "playlist_edit"
        case tagEdit = "tag_edit"
    }
    private enum SettingsKeys: String, CodingKey {
        case enableDownload = "enable_download"
    }

    public init(from decoder: Decoder) throws {
        // 各版本的 Info 字段差别很大(v1 只有 `path` 与对象形式的 `version`),全部按可选解。
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versionString = container.audioStationString(.versionString)
        isManager = container.audioStationBool(.isManager)
        let privilege = try? container.nestedContainer(keyedBy: PrivilegeKeys.self, forKey: .privilege)
        canEditPlaylists = privilege?.audioStationBool(.playlistEdit)
        canEditTags = privilege?.audioStationBool(.tagEdit)
        let settings = try? container.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings)
        downloadEnabled = settings?.audioStationBool(.enableDownload)
        let capability = try? container.decodeIfPresent([String].self, forKey: .transcodeCapability)
        transcodeCapability = (capability ?? []).map { $0.lowercased() }
        personalLibraryEnabled = container.audioStationBool(.personalLibraryEnabled)
        hasMusicShare = container.audioStationBool(.hasMusicShare)
    }

    public func supportsTranscode(to format: SynologyAudioStationTranscodeFormat) -> Bool {
        transcodeCapability.contains(format.rawValue)
    }
}

public struct SynologyAudioStationSong: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String?
    /// NAS 上的真实路径,例如 `/music/王菲/…/美丽的震荡.flac`。
    public let path: String?
    public let type: String?
    public let album: String?
    public let albumArtist: String?
    public let artist: String?
    public let composer: String?
    public let rawGenre: String?
    public let rawTrackNumber: Int?
    public let rawDiscNumber: Int?
    public let rawYear: Int?
    /// 服务端报的是 bps。
    public let bitRateBitsPerSecond: Int?
    public let codec: String?
    public let container: String?
    public let duration: Double?
    public let fileSize: Int64?
    /// `song_audio.frequency`。
    public let sampleRate: Int?
    /// 0–5,0 表示没评过。
    public let rawRating: Int?
    public let replayGainTrackGain: Double?
    public let replayGainTrackPeak: Double?
    public let replayGainAlbumGain: Double?
    public let replayGainAlbumPeak: Double?

    private enum CodingKeys: String, CodingKey { case id, title, path, type, additional }
    private enum AdditionalKeys: String, CodingKey {
        case tag = "song_tag"
        case audio = "song_audio"
        case rating = "song_rating"
    }
    private enum TagKeys: String, CodingKey {
        case album, artist, composer, genre, track, disc, year
        case albumArtist = "album_artist"
        case trackGain = "rg_track_gain"
        case trackPeak = "rg_track_peak"
        case albumGain = "rg_album_gain"
        case albumPeak = "rg_album_peak"
    }
    private enum AudioKeys: String, CodingKey { case bitrate, codec, container, duration, filesize, frequency }
    private enum RatingKeys: String, CodingKey { case rating }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.audioStationString(.id), !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing song id"))
        }
        self.id = id
        title = container.audioStationString(.title)
        path = container.audioStationString(.path)
        type = container.audioStationString(.type)
        let additional = try? container.nestedContainer(keyedBy: AdditionalKeys.self, forKey: .additional)
        let tag = try? additional?.nestedContainer(keyedBy: TagKeys.self, forKey: .tag)
        album = tag?.audioStationString(.album)
        albumArtist = tag?.audioStationString(.albumArtist)
        artist = tag?.audioStationString(.artist)
        composer = tag?.audioStationString(.composer)
        rawGenre = tag?.audioStationString(.genre)
        rawTrackNumber = tag?.audioStationInt(.track)
        rawDiscNumber = tag?.audioStationInt(.disc)
        rawYear = tag?.audioStationInt(.year)
        replayGainTrackGain = tag?.audioStationDouble(.trackGain)
        replayGainTrackPeak = tag?.audioStationDouble(.trackPeak)
        replayGainAlbumGain = tag?.audioStationDouble(.albumGain)
        replayGainAlbumPeak = tag?.audioStationDouble(.albumPeak)
        let audio = try? additional?.nestedContainer(keyedBy: AudioKeys.self, forKey: .audio)
        bitRateBitsPerSecond = audio?.audioStationInt(.bitrate)
        codec = audio?.audioStationString(.codec)
        self.container = audio?.audioStationString(.container)
        duration = audio?.audioStationDouble(.duration)
        fileSize = audio?.audioStationInt64(.filesize)
        sampleRate = audio?.audioStationInt(.frequency)
        let rating = try? additional?.nestedContainer(keyedBy: RatingKeys.self, forKey: .rating)
        rawRating = rating?.audioStationInt(.rating)
    }

    public var isVirtualTrack: Bool { SynologyAudioStationAPI.isVirtualTrackID(id) }
    public var isCatalogSong: Bool { SynologyAudioStationAPI.isCatalogSongID(id) }

    /// 实际交到播放器手里的格式。虚拟音轨永远是转码出来的 mp3 —— 播放层按扩展名挑
    /// 解码器,标成原始的 FLAC 会拿 FLAC 解码器去开 mp3。
    public var audioFormat: AudioFormat? {
        if isVirtualTrack { return .mp3 }
        let codec = codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let format = Self.format(token: container, codec: codec) { return format }
        return Self.format(token: path.map { ($0 as NSString).pathExtension }, codec: codec)
    }

    /// `/songs/<id>.<扩展名>`;id 不是目录曲目或格式认不出时为 nil。
    public var trackPath: String? {
        audioFormat.flatMap { SynologyAudioStationAPI.trackPath(id: id, fileExtension: $0.rawValue) }
    }

    public var trackNumber: Int? { rawTrackNumber.flatMap { $0 > 0 ? $0 : nil } }
    public var discNumber: Int? { rawDiscNumber.flatMap { $0 > 0 ? $0 : nil } }
    public var year: Int? { rawYear.flatMap { $0 > 0 ? $0 : nil } }
    public var genre: String? { SynologyAudioStationAPI.normalizedGenre(rawGenre) }
    /// 评分 1–5;0 与缺失都当作没评分,与 `ServerRatingConnector` 的 nil = 清除一致。
    public var userRating: Int? { rawRating.flatMap { (1...5).contains($0) ? $0 : nil } }

    /// kbps。虚拟音轨播的是转码流,原文件的码率对它没有意义。
    public var bitRateKbps: Int? {
        guard !isVirtualTrack, let bitRateBitsPerSecond, bitRateBitsPerSecond > 0 else { return nil }
        return max(1, Int((Double(bitRateBitsPerSecond) / 1_000).rounded()))
    }

    public var hasUsableTitle: Bool { ServerCatalogMetadataInspectionPolicy.hasUsableTitle(title) }

    /// 标签里没有标题时退回文件名(去掉扩展名)。
    public var displayTitle: String {
        if let title = MediaMetadataTextRepair.repaired(title) { return title }
        if let name = path.map({ (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }),
           let repaired = MediaMetadataTextRepair.repaired(name) {
            return repaired
        }
        return id
    }

    /// 单曲封面的引用;文件大小变了(通常是改过标签)就换一个引用,让封面缓存失效。
    public var coverReference: SynologyAudioStationCoverReference? {
        isCatalogSong ? .song(id: id, revision: fileSize.map(String.init)) : nil
    }

    public var folderPlacement: SynologyAudioStationFolderPlacement {
        SynologyAudioStationFolderPlacement(
            providerFilePath: path?.isEmpty == false ? path : nil,
            libraryRoot: SynologyAudioStationAPI.libraryRoot(forNASPath: path),
            artistName: MediaMetadataTextRepair.repaired(albumArtist) ?? MediaMetadataTextRepair.repaired(artist),
            albumName: MediaMetadataTextRepair.repaired(album)
        )
    }

    /// Audio Station 只列音频,所以 MP4 家族容器一律按音频的 m4a 处理(AAC 与 ALAC 都走它);
    /// Ogg 里装 Opus 时要交给 Opus 解码器。
    private static func format(token: String?, codec: String?) -> AudioFormat? {
        guard let token = token?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased(),
              !token.isEmpty else { return nil }
        switch token {
        case "mp4", "m4a", "m4b", "m4v", "mov", "3gp": return .m4a
        case "ogg", "oga": return codec == "opus" ? .opus : .ogg
        default: return AudioFormat.from(fileExtension: token)
        }
    }
}

/// 喂给 App 层 `ConnectorLibraryFolderHierarchy.location` 的三样东西:NAS 路径、
/// 它所在的库根(`declaredLibraryRoots`),以及路径不可用时的「艺人 / 专辑」兜底。
public struct SynologyAudioStationFolderPlacement: Equatable, Sendable {
    public let providerFilePath: String?
    public let libraryRoot: String?
    public let artistName: String?
    public let albumName: String?
}

public struct SynologyAudioStationSongPage: Decodable, Sendable {
    public let songs: [SynologyAudioStationSong]
    public let total: Int
    public let offset: Int?

    private enum CodingKeys: String, CodingKey { case songs, total, offset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let total = container.audioStationInt(.total) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing total"))
        }
        self.total = total
        offset = container.audioStationInt(.offset)
        songs = try container.decodeIfPresent([SynologyAudioStationSong].self, forKey: .songs) ?? []
    }
}

/// 整库快照不完整时拒收,不让任何一端据此删歌。
public struct SynologyAudioStationCatalogPagination: Sendable {
    private var total: Int?
    private var seen: Set<String> = []
    public private(set) var offset = 0

    public init() {}

    public mutating func accept(_ page: SynologyAudioStationSongPage, requestedLimit: Int) throws -> Bool {
        guard requestedLimit > 0, page.total >= 0,
              page.offset == nil || page.offset == offset,
              page.songs.count <= requestedLimit,
              total == nil || total == page.total,
              page.songs.count <= page.total - offset else { throw SynologyAudioStationError.invalidResponse }
        total = page.total
        for song in page.songs {
            guard seen.insert(song.id).inserted else { throw SynologyAudioStationError.invalidResponse }
        }
        offset += page.songs.count
        if offset == page.total { return true }
        guard page.songs.count == requestedLimit else { throw SynologyAudioStationError.invalidResponse }
        return false
    }
}

public struct SynologyAudioStationSongInfo: Decodable, Sendable {
    public let songs: [SynologyAudioStationSong]

    private enum CodingKeys: String, CodingKey { case songs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.songs) {
            songs = try container.decode([SynologyAudioStationSong].self, forKey: .songs)
        } else {
            // 少数版本直接把曲目对象放在 `data` 里。
            songs = [try SynologyAudioStationSong(from: decoder)]
        }
    }
}

public struct SynologyAudioStationPlaylist: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// `personal` 或 `shared`。
    public let library: String?
    /// `normal` 或 `smart`。
    public let type: String?
    public let sharingStatus: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, library, type
        case sharingStatus = "sharing_status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.audioStationString(.id), SynologyAudioStationAPI.isPlaylistID(id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid playlist id"))
        }
        self.id = id
        name = container.audioStationString(.name) ?? id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
        library = container.audioStationString(.library)
        type = container.audioStationString(.type)
        sharingStatus = container.audioStationString(.sharingStatus)
    }

    /// 智能歌单由规则生成,只读。
    public var isSmart: Bool { type == "smart" || SynologyAudioStationAPI.isSmartPlaylistID(id) }
    public var isReadOnly: Bool { isSmart }
    public var isShared: Bool { library == "shared" || id.hasPrefix("playlist_shared_") }
    /// 存放「分享出去的歌」的内部歌单,不展示给用户。
    public var isSystem: Bool {
        name == SynologyAudioStationAPI.systemPlaylistName
            || id.hasSuffix("/\(SynologyAudioStationAPI.systemPlaylistName)")
    }
}

public struct SynologyAudioStationPlaylistPage: Decodable, Sendable {
    public let playlists: [SynologyAudioStationPlaylist]
    public let total: Int
    public let offset: Int?

    private enum CodingKeys: String, CodingKey { case playlists, total, offset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let total = container.audioStationInt(.total) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing total"))
        }
        self.total = total
        offset = container.audioStationInt(.offset)
        playlists = try container.decodeIfPresent([SynologyAudioStationPlaylist].self, forKey: .playlists) ?? []
    }
}

/// `Playlist getinfo` 的一页:`data.playlists[0].additional.songs`。
public struct SynologyAudioStationPlaylistSongsPage: Decodable, Sendable {
    public let playlist: SynologyAudioStationPlaylist
    public let songs: [SynologyAudioStationSong]
    public let songsTotal: Int
    public let songsOffset: Int?

    private enum CodingKeys: String, CodingKey { case playlists }
    private enum EntryKeys: String, CodingKey { case additional }
    private enum AdditionalKeys: String, CodingKey {
        case songs
        case songsTotal = "songs_total"
        case songsOffset = "songs_offset"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var entries = try container.nestedUnkeyedContainer(forKey: .playlists)
        guard entries.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one playlist"))
        }
        let entryDecoder = try entries.superDecoder()
        playlist = try SynologyAudioStationPlaylist(from: entryDecoder)
        let entry = try entryDecoder.container(keyedBy: EntryKeys.self)
        let additional = try entry.nestedContainer(keyedBy: AdditionalKeys.self, forKey: .additional)
        songs = try additional.decodeIfPresent([SynologyAudioStationSong].self, forKey: .songs) ?? []
        guard let songsTotal = additional.audioStationInt(.songsTotal) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing songs_total"))
        }
        self.songsTotal = songsTotal
        songsOffset = additional.audioStationInt(.songsOffset)
    }
}

/// 歌单曲目逐页拼接到 `songs_total`。同一首歌可以在歌单里出现多次,所以不查重;
/// 服务端不认 `songs_limit`、一次给完剩余全部时也接受。
public struct SynologyAudioStationPlaylistPagination: Sendable {
    private var total: Int?
    public private(set) var offset = 0

    public init() {}

    public mutating func accept(_ page: SynologyAudioStationPlaylistSongsPage, requestedLimit: Int) throws -> Bool {
        guard requestedLimit > 0, page.songsTotal >= 0,
              page.songsOffset == nil || page.songsOffset == offset,
              total == nil || total == page.songsTotal,
              page.songs.count <= page.songsTotal - offset else { throw SynologyAudioStationError.invalidResponse }
        total = page.songsTotal
        offset += page.songs.count
        if offset == page.songsTotal { return true }
        guard page.songs.count == requestedLimit else { throw SynologyAudioStationError.invalidResponse }
        return false
    }
}

/// 「INTERNET 广播」下的三个固定容器。
public enum SynologyAudioStationRadioContainer: String, CaseIterable, Sendable {
    /// 「我收藏的广播」:多半是从 SHOUTcast 收藏的台,地址是 `tunein-station.pls` 包装。
    case favorite = "Favorite"
    /// 「用户定义的广播」:按地址自己加的台。
    case userDefined = "UserDefined"
    /// SHOUTcast 目录:下面一层是流派子目录(每个流派最多约 200 台),台在流派里。
    case shoutcast = "SHOUTcast"
}

/// 镜像电台在服务端所在的文件夹。
public enum SynologyAudioStationRadioFolder: Hashable, Sendable {
    case favorite
    case userDefined
    /// SHOUTcast 的一个流派,值是服务端给的流派名。
    case genre(String)
}

/// 容器里的一条。`type` 为 `station` 或 `container`(子目录,例如 SHOUTcast 的流派)。
/// 服务端的 `id` 由名字和地址拼成(`radio_<名字> <地址>`),改名就会变,不拿它当身份。
public struct SynologyAudioStationRadio: Decodable, Equatable, Sendable {
    public let id: String?
    public let title: String?
    public let type: String?
    public let url: String?
    public let desc: String?

    private enum CodingKeys: String, CodingKey { case id, title, type, url, desc }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.audioStationString(.id)
        title = container.audioStationString(.title)
        type = container.audioStationString(.type)
        url = container.audioStationString(.url)
        desc = container.audioStationString(.desc)
    }

    public var isContainer: Bool { type?.lowercased() == "container" }
}

public struct SynologyAudioStationRadioPage: Decodable, Sendable {
    public let radios: [SynologyAudioStationRadio]
    public let total: Int
    public let offset: Int?

    private enum CodingKeys: String, CodingKey { case radios, total, offset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radios = try container.decodeIfPresent([SynologyAudioStationRadio].self, forKey: .radios) ?? []
        // 不带 `total` 的实现一次给完全部。
        total = container.audioStationInt(.total) ?? radios.count
        offset = container.audioStationInt(.offset)
    }
}

struct SynologyAudioStationLoginData: Decodable, Sendable {
    let sid: String?
    let deviceID: String?

    private enum CodingKeys: String, CodingKey {
        case sid, did
        case deviceID = "device_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sid = container.audioStationString(.sid)
        // 与 `SynologyStreamResolver.trustedDeviceID` 同样先认 `did` 再认 `device_id`。
        deviceID = [container.audioStationString(.did), container.audioStationString(.deviceID)]
            .compactMap { $0 }.first { !$0.isEmpty }
    }
}

struct SynologyAudioStationLyricsData: Decodable, Sendable {
    let lyrics: String?

    private enum CodingKeys: String, CodingKey { case lyrics }

    init(from decoder: Decoder) throws {
        lyrics = try decoder.container(keyedBy: CodingKeys.self).audioStationString(.lyrics)
    }
}

struct SynologyAudioStationCreatedPlaylist: Decodable, Sendable {
    let id: String?

    private enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).audioStationString(.id)
    }
}

// MARK: - 封面引用

/// 存进 `Song.coverArtFileName` 的封面引用。只含服务端的稳定标识,不含 `_sid`
/// 等凭据 —— 曲库快照会跨设备同步。
public enum SynologyAudioStationCoverReference: Hashable, Sendable {
    case song(id: String, revision: String?)
    case album(name: String, albumArtist: String)

    static let prefix = "synology-audiostation:cover:"

    public var rawValue: String {
        switch self {
        case .song(let id, let revision):
            if let revision, Self.isSafeToken(revision) { return "\(Self.prefix)song:\(id):\(revision)" }
            return "\(Self.prefix)song:\(id)"
        case .album(let name, let albumArtist):
            return "\(Self.prefix)album:\(Self.base64URL(name)):\(Self.base64URL(albumArtist))"
        }
    }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else { return nil }
        let parts = rawValue.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        switch parts.first {
        case "song":
            guard (2...3).contains(parts.count), SynologyAudioStationAPI.isCatalogSongID(parts[1]) else { return nil }
            let revision = parts.count == 3 ? parts[2] : nil
            if let revision, !Self.isSafeToken(revision) { return nil }
            self = .song(id: parts[1], revision: revision)
        case "album":
            guard parts.count == 3, let name = Self.decodeBase64URL(parts[1]), !name.isEmpty,
                  let albumArtist = Self.decodeBase64URL(parts[2]) else { return nil }
            self = .album(name: name, albumArtist: albumArtist)
        default:
            return nil
        }
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32
            && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }) else { return nil }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 错误

/// Audio Station 的结构化错误。这里不提供界面文案:需要本地化的描述由连接器层给出。
public enum SynologyAudioStationError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingCredential
    case invalidURL
    case invalidResponse
    case badServerResponse(Int)
    /// `SYNO.API.Info` 里没有 Audio Station 接口:套件没装或没启动。
    case audioStationUnavailable
    case unsupportedVersion(api: String)
    case apiNotFound(code: Int)
    /// 需要两步验证码(403;406 为管理员强制)。`token` / `types` 原样带回。
    case twoFactorRequired(token: String?, types: [String])
    case invalidOneTimePassword
    case invalidCredentials
    case accountDisabled
    /// 账号没有 Audio Station 权限(105,或登录时的 402)—— 新用户最常见的坑:
    /// 要在 DSM「控制面板 › 应用程序权限」里给这个账号开 Audio Station。
    case noAudioStationPermission
    /// 能用 Audio Station,但没有这次写操作的权限(例如共享歌单的编辑权)。
    case operationNotPermitted
    case sessionExpired(code: Int)
    case ipBlocked
    case passwordExpired(code: Int)
    case duplicateInPlaylist
    case serverBusy(code: Int)
    /// 原始流不支持 Range(回 200 而不是 206)。
    case rangeNotSupported
    /// 整轨虚拟音轨没有可直接读取的原文件,只能走转码。
    case transcodeRequired
    case server(code: Int)

    /// 与 `SynologyAuthenticationPolicy.requiresTwoFactorAuthentication` 覆盖同一组 DSM 码。
    public var requiresOneTimePassword: Bool {
        switch self {
        case .twoFactorRequired, .invalidOneTimePassword: true
        default: false
        }
    }

    /// 只有 400 能靠重新输入账号密码解决。
    public var requiresCredentialPrompt: Bool { self == .invalidCredentials }

    public var description: String {
        switch self {
        case .missingCredential: "missing credential"
        case .invalidURL: "invalid URL"
        case .invalidResponse: "invalid response"
        case .badServerResponse(let status): "HTTP \(status)"
        case .audioStationUnavailable: "Audio Station unavailable"
        case .unsupportedVersion(let api): "unsupported version: \(api)"
        case .apiNotFound(let code): "API not found (\(code))"
        case .twoFactorRequired(_, let types): "two-factor code required \(types)"
        case .invalidOneTimePassword: "invalid one-time password"
        case .invalidCredentials: "invalid credentials"
        case .accountDisabled: "account disabled"
        case .noAudioStationPermission: "no Audio Station permission"
        case .operationNotPermitted: "operation not permitted"
        case .sessionExpired(let code): "session expired (\(code))"
        case .ipBlocked: "IP blocked"
        case .passwordExpired(let code): "password expired (\(code))"
        case .duplicateInPlaylist: "song already in playlist"
        case .serverBusy(let code): "server busy (\(code))"
        case .rangeNotSupported: "range requests not supported"
        case .transcodeRequired: "transcode required"
        case .server(let code): "DSM error \(code)"
        }
    }
}

// MARK: - 宽松解码

struct SynologyAudioStationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// DSM 的数字字段时而是数字、时而是字符串(`"0"`、`"-8.19"`),布尔值也可能是 0/1。
extension KeyedDecodingContainer {
    func audioStationString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return String(value) }
        return nil
    }

    func audioStationInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Self.exactInteger(value) }
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(trimmed) ?? Double(trimmed).flatMap(Self.exactInteger)
    }

    func audioStationInt(_ key: Key) -> Int? {
        audioStationInt64(key).flatMap { Int(exactly: $0) }
    }

    func audioStationDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return value }
        guard let text = try? decodeIfPresent(String.self, forKey: key),
              let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return value
    }

    func audioStationBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func exactInteger(_ value: Double) -> Int64? {
        guard value.isFinite, value.rounded() == value, abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int64(value)
    }
}
