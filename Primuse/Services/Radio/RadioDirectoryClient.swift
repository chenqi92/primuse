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
                country: payload.country?.isEmpty == false ? payload.country : nil
            )
        }
    }

    /// 把目录结果转成批量添加页的候选，复用同一套判重逻辑。
    static func candidates(
        from results: [Result],
        existing: [RadioStation]
    ) -> [RadioImportCandidate] {
        // 走 `名字, URL` 的纯文本形态喂给解析器，判重和归一化就只有一份实现。
        let lines = results
            .map { "\($0.displayName), \($0.streamURL)" }
            .joined(separator: "\n")
        return RadioImportParser.parse(lines, existing: existing, source: .plainText)
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
