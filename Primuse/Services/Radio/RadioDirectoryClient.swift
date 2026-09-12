import Foundation
import PrimuseKit

/// radio-browser.info 的最小只读客户端。社区维护的公开电台目录，免费、不需要
/// API key，只用来搜索电台名并拿回流地址 —— 不上报任何本地数据。
///
/// 只读且只发出用户主动输入的搜索词；不会把曲库、设备信息或已有电台传出去。
enum RadioDirectoryClient {
    /// 官方建议轮询 all.api 的 DNS 拿可用镜像；这里直接用带负载均衡的入口，
    /// 少一次往返。失败时上层会把错误原样展示给用户。
    private static let host = "https://de1.api.radio-browser.info"

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

        var components = URLComponents(string: "\(host)/json/stations/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
        ]
        guard let url = components?.url else { throw Failure.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 目录要求带一个可识别的 UA，否则会被限流。
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse
        }

        let payloads = try JSONDecoder().decode([Payload].self, from: data)
        return payloads.compactMap { payload in
            // url_resolved 已经跟过重定向，比 url 更可能直接可播。
            let stream = payload.url_resolved?.isEmpty == false ? payload.url_resolved! : payload.url
            guard RadioStationValidation.normalizedURLString(stream) != nil else { return nil }
            return Result(
                id: payload.stationuuid,
                name: RadioStationValidation.normalizedName(payload.name),
                streamURL: stream,
                codec: payload.codec?.isEmpty == false ? payload.codec : nil,
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
        guard let normalized = RadioStationValidation.normalizedURLString(streamURL),
              let url = URL(string: "\(host)/json/stations/byurl") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "url", value: normalized)]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payloads = try? JSONDecoder().decode([Payload].self, from: data) else {
            return nil
        }

        // 同一个流可能被不同人提交过好几遍，取第一个带台标的。
        let mapped = payloads.map { payload in
            Result(
                id: payload.stationuuid,
                name: RadioStationValidation.normalizedName(payload.name),
                streamURL: payload.url_resolved?.isEmpty == false ? payload.url_resolved! : payload.url,
                codec: payload.codec?.isEmpty == false ? payload.codec : nil,
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
