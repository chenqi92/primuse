import Foundation
import PrimuseKit

/// 按用户已有的流地址回查 radio-browser.info，只用于补全台标和主页。
struct RadioDirectoryClient: Sendable {
    private static let shared = RadioDirectoryClient()
    private let session: URLSession
    private let mirrors: RadioDirectoryMirrors
    private let quotaRegistry: RequestQuotaRegistry
    fileprivate static let service = RequestQuota.Service(
        id: "radio-browser.directory",
        policy: .init(maximumAttempts: 1, timeout: 45)
    )

    init(session: URLSession = .shared, mirrors: RadioDirectoryMirrors = .shared,
         quotaRegistry: RequestQuotaRegistry = .shared) {
        self.session = session
        self.mirrors = mirrors
        self.quotaRegistry = quotaRegistry
    }

    static func lookup(streamURL: String) async -> Result? {
        await shared.lookup(streamURL: streamURL)
    }

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
        /// 目录记录的台标地址。
        let faviconURL: String?
        /// 电台主页。没有 favicon 时留给主页图标抓取当输入。
        let homepageURL: String?
    }

    private enum Failure: Error {
        case badResponse
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

    /// 目录里不少台的编码写的是 "UNKNOWN",显示出来只是噪音,当作没有。
    private static func cleanedCodec(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.caseInsensitiveCompare("unknown") != .orderedSame else { return nil }
        return raw
    }

    /// 从当前镜像开始，连不上、超时、TLS 失败、5xx 或 429 就换下一台再试，
    /// 最多试 `maximumMirrorAttempts` 台；其余 4xx 与设备自己没网不换（换谁都一样），
    /// 解码失败由调用方处理，也不换。全部失败时抛最后一次的错误。
    private func perform(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Data {
        let hosts = await mirrors.orderedHosts()
        var lastError: Error = Failure.badResponse
        for host in hosts.prefix(Self.maximumMirrorAttempts) {
            try Task.checkCancellation()
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            guard let url = components.url else { throw Failure.badResponse }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue(
                    "application/x-www-form-urlencoded",
                    forHTTPHeaderField: "Content-Type"
                )
                request.httpBody = body
            }

            guard let quota = RequestQuota(service: Self.service, url: url) else {
                throw Failure.badResponse
            }
            let preparedRequest = request
            do {
                // Mirror failover owns the three-attempt budget. The executor
                // only admits one send and retains this endpoint's cooldown.
                let (data, _) = try await quotaRegistry.execute(for: quota, timeout: timeout) {
                    try await session.data(for: preparedRequest)
                }
                await mirrors.noteSucceeded(host)
                return data
            } catch let error as URLError where Self.warrantsFailover(error) {
                lastError = error
            } catch let failure as HTTPResponseFailure
                where failure.statusCode == 429 || (500...599).contains(failure.statusCode) {
                lastError = failure
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

    /// 拿流地址回查目录，取它记录的台标。
    ///
    /// 这是台标自动发现的最后一条线索：用户手动粘贴进来的电台，只要目录里
    /// 收录过同一个流地址，就能白捡一张 favicon。查不到是常态，所以任何
    /// 失败都只是返回 `nil`，不往上抛。
    func lookup(streamURL: String) async -> Result? {
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
                codec: Self.cleanedCodec(payload.codec),
                bitrate: payload.bitrate.flatMap { $0 > 0 ? $0 : nil },
                country: payload.country?.isEmpty == false ? payload.country : nil,
                faviconURL: RadioLogoURLPolicy.normalized(payload.favicon),
                homepageURL: RadioLogoURLPolicy.normalized(payload.homepage)
            )
        }
        return mapped.first { $0.faviconURL != nil } ?? mapped.first
    }
}

/// radio-browser 的镜像名单。官方的做法是先取服务器列表再挑一台，而不是写死一台：
/// 进程内只取一次 `all.api.radio-browser.info/json/servers`，打乱顺序分摊各台负载；
/// 取不到时先用内置名单，隔几分钟再试。请求在哪台上成功就把它排到最前，下次从它开始。
actor RadioDirectoryMirrors {
    static let shared = RadioDirectoryMirrors()

    /// 2026-09 实测：服务器列表里只剩 de1，de2 和 all 解析到同一台机器，fi1 / nl1 / at1 / fr1
    /// 已经没有 DNS 记录。所以内置名单只收还能解析的名字；all 放最后，它是官方的轮询入口，
    /// 以后加了镜像也会被它带上。真正的故障转移靠运行时取到的列表。
    private static let fallbackHosts = [
        "de1.api.radio-browser.info",
        "de2.api.radio-browser.info",
        "all.api.radio-browser.info",
    ]
    private let serverListURL: URL?
    private let session: URLSession
    private let quotaRegistry: RequestQuotaRegistry
    private static let listRetryInterval: Duration = .seconds(300)

    private struct Server: Decodable {
        let name: String
    }

    private var fetchedOrder: [String]?
    private var fallbackOrder = fallbackHosts

    init(hosts: [String]? = nil, session: URLSession = .shared,
         quotaRegistry: RequestQuotaRegistry = .shared,
         serverListURL: URL? = URL(string: "https://all.api.radio-browser.info/json/servers")) {
        if let hosts { fetchedOrder = hosts }
        self.session = session
        self.quotaRegistry = quotaRegistry
        self.serverListURL = serverListURL
    }
    private var listTask: Task<Void, Never>?
    private var listGeneration: UUID?
    private var listWaiters: [UUID: CheckedContinuation<[String], Never>] = [:]
    private var lastListFailure: ContinuousClock.Instant?

    func orderedHosts() async -> [String] {
        if let fetchedOrder { return fetchedOrder }
        if let lastListFailure,
           ContinuousClock.now - lastListFailure < Self.listRetryInterval {
            return fallbackOrder
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return fallbackOrder }
            return await withCheckedContinuation { continuation in
                listWaiters[id] = continuation
                guard listTask == nil else { return }
                let generation = UUID()
                listGeneration = generation
                listTask = Task {
                    let names = await self.fetchServerNames()
                    self.finishDiscovery(names, generation: generation)
                }
            }
        } onCancel: {
            Task { await self.cancelDiscoveryWaiter(id) }
        }
    }

    private func finishDiscovery(_ names: [String]?, generation: UUID) {
        guard listGeneration == generation else { return }
        listTask = nil
        listGeneration = nil
        if let names, !names.isEmpty {
            let shuffled = names.shuffled()
            fetchedOrder = shuffled + fallbackOrder.filter { !shuffled.contains($0) }
        } else {
            lastListFailure = .now
        }
        let waiters = listWaiters.values
        listWaiters.removeAll()
        for continuation in waiters { continuation.resume(returning: fetchedOrder ?? fallbackOrder) }
    }

    private func cancelDiscoveryWaiter(_ id: UUID) {
        guard let continuation = listWaiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: fallbackOrder)
        if listWaiters.isEmpty {
            listTask?.cancel()
            listTask = nil
            listGeneration = nil
        }
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

    private func fetchServerNames() async -> [String]? {
        guard let serverListURL else { return nil }
        var request = URLRequest(url: serverListURL)
        request.timeoutInterval = 6
        request.setValue(RadioDirectoryClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let quota = RequestQuota(service: RadioDirectoryClient.service, url: serverListURL) else { return nil }
        let preparedRequest = request
        let result = try? await quotaRegistry.execute(for: quota, timeout: 6) {
            try await self.session.data(for: preparedRequest)
        }
        guard let data = result?.data,
              let servers = try? JSONDecoder().decode([Server].self, from: data) else { return nil }
        // 同一台镜像按 IPv4 / IPv6 各列一次，按名字去重。
        var seen = Set<String>()
        return servers.compactMap { Self.mirrorHost($0.name) }.filter { seen.insert($0).inserted }
    }

    /// 名单是从网上取来的：只收 radio-browser 自己域名下的主机名，
    /// 回查的流地址不会被一条异常记录带去别的服务器。
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
