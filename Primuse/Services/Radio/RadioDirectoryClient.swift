import Foundation
import PrimuseKit

/// radio-browser.info 的最小只读客户端。社区维护的公开电台目录，免费、不需要
/// API key，只用来搜索电台名并拿回流地址 —— 不上报任何本地数据。
///
/// 只读；发出去的只有用户主动输入的搜索词，以及取热门电台时的两位地区码
/// （`Locale.current.region`）。不会把曲库、设备信息或已有电台传出去。
enum RadioDirectoryClient {
    /// 目录要求带一个可识别的 UA，否则会被限流。
    fileprivate static let userAgent = "Primuse/1.0"
    /// 一次请求最多换几台镜像。
    private static let maximumMirrorAttempts = 3

    struct Result: Identifiable, Sendable {
        let id: String
        let name: String
        let streamURL: String
        let codec: String?
        let bitrate: Int?
        let country: String?
        /// 目录记录的台标地址。搜索结果列表直接拿它显示缩略图，
        /// 用户勾选之前就能看清是不是自己要的台。
        let faviconURL: String?
        /// 电台主页。没有 favicon 时留给主页图标抓取当输入。
        let homepageURL: String?
    }

    enum Failure: LocalizedError {
        case badResponse
        case emptyQuery

        var errorDescription: String? {
            switch self {
            case .badResponse: return String(localized: "radio_batch_directory_failed")
            case .emptyQuery: return String(localized: "radio_batch_directory_placeholder")
            }
        }
    }

    private struct Payload: Decodable {
        let stationuuid: String
        let name: String
        let url_resolved: String?
        let url: String
        let codec: String?
        let bitrate: Int?
        let country: String?
        let favicon: String?
        let homepage: String?
    }

    static func search(name: String, limit: Int = 30) async throws -> [Result] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw Failure.emptyQuery }

        return try await searchStations(queryItems: [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
        ])
    }

    /// 投票最多的台。`countryCode` 是 ISO 3166-1 两位地区码,传 nil 取全球。
    /// 电视端添加电台时还没输入就先摆出来,遥控器打字太费劲。
    static func topStations(countryCode: String?, limit: Int = 30) async throws -> [Result] {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
        ]
        if let countryCode, !countryCode.isEmpty {
            items.append(URLQueryItem(name: "countrycode", value: countryCode))
        }
        return try await searchStations(queryItems: items)
    }

    /// 目录里不少台的编码写的是 "UNKNOWN",显示出来只是噪音,当作没有。
    private static func cleanedCodec(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.caseInsensitiveCompare("unknown") != .orderedSame else { return nil }
        return raw
    }

    /// 三个入口共用的请求：从当前镜像开始，连不上、超时、TLS 失败、5xx 或 429 就换下一台再试，
    /// 最多试 `maximumMirrorAttempts` 台；其余 4xx 与设备自己没网不换（换谁都一样），
    /// 解码失败由调用方处理，也不换。全部失败时抛最后一次的错误。
    private static func perform(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Data {
        let hosts = await RadioDirectoryMirrors.shared.orderedHosts()
        var lastError: Error = Failure.badResponse
        for host in hosts.prefix(maximumMirrorAttempts) {
            try Task.checkCancellation()
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            if !queryItems.isEmpty { components.queryItems = queryItems }
            guard let url = components.url else { throw Failure.badResponse }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue(
                    "application/x-www-form-urlencoded",
                    forHTTPHeaderField: "Content-Type"
                )
                request.httpBody = body
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where warrantsFailover(error) {
                lastError = error
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
            switch http.statusCode {
            case 200..<300:
                await RadioDirectoryMirrors.shared.noteSucceeded(host)
                return data
            case 429, 500...599:
                lastError = Failure.badResponse
            default:
                throw Failure.badResponse
            }
        }
        throw lastError
    }

    /// 换一台镜像可能就好的网络失败。设备没联网、蜂窝被禁用、任务被取消这些换谁都一样。
    private static func warrantsFailover(_ error: URLError) -> Bool {
        switch error.code {
        case .cancelled, .notConnectedToInternet, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive, .badURL, .unsupportedURL,
             .appTransportSecurityRequiresSecureConnection:
            return false
        default:
            return true
        }
    }

    private static func searchStations(queryItems: [URLQueryItem]) async throws -> [Result] {
        let data = try await perform(
            path: "/json/stations/search",
            queryItems: queryItems,
            timeout: 15
        )
        let payloads = try JSONDecoder().decode([Payload].self, from: data)
        return payloads.compactMap { payload in
            // url_resolved 已经跟过重定向，比 url 更可能直接可播。
            let stream = payload.url_resolved?.isEmpty == false ? payload.url_resolved! : payload.url
            guard RadioStationValidation.normalizedURLString(stream) != nil else { return nil }
            return Result(
                id: payload.stationuuid,
                name: RadioStationValidation.normalizedName(payload.name),
                streamURL: stream,
                codec: cleanedCodec(payload.codec),
                bitrate: payload.bitrate.flatMap { $0 > 0 ? $0 : nil },
                country: payload.country?.isEmpty == false ? payload.country : nil,
                faviconURL: RadioLogoURLPolicy.normalized(payload.favicon),
                homepageURL: RadioLogoURLPolicy.normalized(payload.homepage)
            )
        }
    }

    /// 拿流地址回查目录，取它记录的台标。
    ///
    /// 这是台标自动发现的最后一条线索：用户手动粘贴进来的电台，只要目录里
    /// 收录过同一个流地址，就能白捡一张 favicon。查不到是常态，所以任何
    /// 失败都只是返回 `nil`，不往上抛。
    static func lookup(streamURL: String) async -> Result? {
        guard let normalized = RadioStationValidation.normalizedURLString(streamURL) else {
            return nil
        }

        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "url", value: normalized)]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }

        guard let data = try? await perform(
                  path: "/json/stations/byurl",
                  method: "POST",
                  body: body,
                  timeout: 10
              ),
              let payloads = try? JSONDecoder().decode([Payload].self, from: data) else {
            return nil
        }

        // 同一个流可能被不同人提交过好几遍，取第一个带台标的。
        let mapped = payloads.map { payload in
            Result(
                id: payload.stationuuid,
                name: RadioStationValidation.normalizedName(payload.name),
                streamURL: payload.url_resolved?.isEmpty == false ? payload.url_resolved! : payload.url,
                codec: cleanedCodec(payload.codec),
                bitrate: payload.bitrate.flatMap { $0 > 0 ? $0 : nil },
                country: payload.country?.isEmpty == false ? payload.country : nil,
                faviconURL: RadioLogoURLPolicy.normalized(payload.favicon),
                homepageURL: RadioLogoURLPolicy.normalized(payload.homepage)
            )
        }
        return mapped.first { $0.faviconURL != nil } ?? mapped.first
    }

    /// 把目录结果转成批量添加页的候选，复用同一套判重逻辑。
    ///
    /// 走结构化条目而不是把结果拼回文本再解析一遍 —— 拼文本会把 favicon
    /// 和主页地址丢掉，而那正是用户在搜索结果里看到的那张图。
    static func candidates(
        from results: [Result],
        existing: [RadioStation]
    ) -> [RadioImportCandidate] {
        RadioImportParser.candidates(
            from: results.map { result in
                RadioImportParser.Entry(
                    name: result.displayName,
                    urlString: result.streamURL,
                    logoURLString: result.faviconURL,
                    homepageURLString: result.homepageURL,
                    logoSource: .directoryFavicon
                )
            },
            existing: existing
        )
    }
}

private extension RadioDirectoryClient.Result {
    /// 名字后缀带上国家和码率，同名台在结果里才分得清。
    var displayName: String {
        var suffix: [String] = []
        if let country, !country.isEmpty { suffix.append(country) }
        if let bitrate { suffix.append("\(bitrate)k") }
        guard !suffix.isEmpty else { return name }
        return "\(name) (\(suffix.joined(separator: " · ")))"
    }
}

/// radio-browser 的镜像名单。官方的做法是先取服务器列表再挑一台，而不是写死一台：
/// 进程内只取一次 `all.api.radio-browser.info/json/servers`，打乱顺序分摊各台负载；
/// 取不到时先用内置名单，隔几分钟再试。请求在哪台上成功就把它排到最前，下次从它开始。
private actor RadioDirectoryMirrors {
    static let shared = RadioDirectoryMirrors()

    /// 2026-09 实测：服务器列表里只剩 de1，de2 和 all 解析到同一台机器，fi1 / nl1 / at1 / fr1
    /// 已经没有 DNS 记录。所以内置名单只收还能解析的名字；all 放最后，它是官方的轮询入口，
    /// 以后加了镜像也会被它带上。真正的故障转移靠运行时取到的列表。
    private static let fallbackHosts = [
        "de1.api.radio-browser.info",
        "de2.api.radio-browser.info",
        "all.api.radio-browser.info",
    ]
    private static let serverListURL = URL(string: "https://all.api.radio-browser.info/json/servers")
    private static let listRetryInterval: Duration = .seconds(300)

    private struct Server: Decodable {
        let name: String
    }

    private var fetchedOrder: [String]?
    private var fallbackOrder = fallbackHosts
    private var listTask: Task<[String]?, Never>?
    private var lastListFailure: ContinuousClock.Instant?

    func orderedHosts() async -> [String] {
        if let fetchedOrder { return fetchedOrder }
        if let lastListFailure,
           ContinuousClock.now - lastListFailure < Self.listRetryInterval {
            return fallbackOrder
        }
        // 并发的几个请求共用同一次取列表。
        let task: Task<[String]?, Never>
        if let listTask {
            task = listTask
        } else {
            task = Task { await Self.fetchServerNames() }
            listTask = task
        }
        let names = await task.value
        listTask = nil
        if fetchedOrder == nil {
            if let names, !names.isEmpty {
                let shuffled = names.shuffled()
                fetchedOrder = shuffled + fallbackOrder.filter { !shuffled.contains($0) }
            } else {
                lastListFailure = .now
            }
        }
        return fetchedOrder ?? fallbackOrder
    }

    func noteSucceeded(_ host: String) {
        if let fetchedOrder {
            self.fetchedOrder = Self.promoting(host, in: fetchedOrder)
        } else {
            fallbackOrder = Self.promoting(host, in: fallbackOrder)
        }
    }

    private static func promoting(_ host: String, in order: [String]) -> [String] {
        guard let index = order.firstIndex(of: host), index > 0 else { return order }
        var order = order
        order.remove(at: index)
        order.insert(host, at: 0)
        return order
    }

    private static func fetchServerNames() async -> [String]? {
        guard let serverListURL else { return nil }
        var request = URLRequest(url: serverListURL)
        request.timeoutInterval = 6
        request.setValue(RadioDirectoryClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let servers = try? JSONDecoder().decode([Server].self, from: data) else {
            return nil
        }
        // 同一台镜像按 IPv4 / IPv6 各列一次，按名字去重。
        var seen = Set<String>()
        return servers.compactMap { mirrorHost($0.name) }.filter { seen.insert($0).inserted }
    }

    /// 名单是从网上取来的：只收 radio-browser 自己域名下的主机名，
    /// 搜索词和地区码不会被一条异常记录带去别的服务器。
    private static func mirrorHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.hasSuffix(".radio-browser.info"),
              host.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
              }) else {
            return nil
        }
        return host
    }
}
