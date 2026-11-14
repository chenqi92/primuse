import Foundation

public enum MotionArtworkServiceSource: String, CaseIterable, Sendable {
    case disabled
    case custom

    public static func resolved(_ value: String, customEndpoint: String) -> Self {
        resolved(
            value,
            hasConfiguredEndpoints: !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// 旧版本记下的「来源」值：已下线的内置源（m8tec）一律算停用；从没选过时，配了服务就算自定义服务。
    public static func resolved(_ value: String, hasConfiguredEndpoints: Bool) -> Self {
        if value == "m8tec" { return .disabled }
        return Self(rawValue: value) ?? (hasConfiguredEndpoints ? .custom : .disabled)
    }

    public static func permitsEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return !["apple.com", "mzstatic.com", "m8tec.top"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 能不能当在线动态封面服务的地址：http / https、有主机、不带账号密码和片段，且不是受限的主机。
    /// 每一个动态封面源都要过这一关，加的时候拦一次，取封面前再拦一次。
    public static func isValidEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              NetworkEndpointIdentity(url: url) != nil,
              permitsEndpoint(url) else {
            return false
        }
        return true
    }
}

// MARK: - 动态封面源

/// 一个在线动态封面服务（刮削源里的「动态封面源」）。地址按 `MotionArtworkServiceRequest`
/// 的约定接 POST 查询；素材只认同一主机上的地址（见 `MotionArtworkEndpointClient`）。
public struct MotionArtworkEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, url: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, isEnabled
    }

    /// 名字和开关缺了不算坏数据：名字回退到主机，开关默认开。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedURL = try container.decode(String.self, forKey: .url)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        id = try container.decode(String.self, forKey: .id)
        url = decodedURL
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        if decodedName.isEmpty {
            name = MotionArtworkEndpointList.endpointURL(decodedURL)
                .map { MotionArtworkEndpointList.defaultName(for: $0) } ?? decodedURL
        } else {
            name = decodedName
        }
    }

    public var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 过了校验的地址；不合法或是受限主机时为 nil，这一条不会被请求。
    public var endpointURL: URL? {
        MotionArtworkEndpointList.endpointURL(url)
    }
}

/// 添加动态封面源被拒的原因。
public enum MotionArtworkEndpointRejection: Error, Equatable, Sendable {
    /// 不是 http / https 地址，或带了账号密码、片段。
    case invalid
    /// 受限的主机（Apple 的页面与图片 CDN、已下线的服务），不能拿来查动态封面。
    case blocked
    /// 同一个地址已经在列表里。
    case duplicate
}

/// 问一个动态封面源的结果，决定还要不要问下一个。
public enum MotionArtworkEndpointAttempt: Equatable, Sendable {
    /// 这个源给了能用的动态封面，不再往下问。
    case found
    /// 这个源没有、出错或这次不能问（只用 Wi-Fi 时在蜂窝网络下），问下一个。
    case missing
    /// 被打断了（取消、换了歌），后面的也不问了。
    case abandoned
}

/// 动态封面源列表：列表顺序就是优先级。整份存成一个 JSON 对象（`{"endpoints": [...]}`），
/// 经 iCloud 键值同步与离线设置备份原样带走。
public struct MotionArtworkEndpointList: Codable, Equatable, Sendable {
    public private(set) var endpoints: [MotionArtworkEndpoint]

    /// 从旧版单个服务地址迁移来的那一条用固定 id：几台设备各自迁移出来的是同一份，同步时不会多出重复的行。
    public static let legacyEndpointID = "legacy-endpoint"

    public init(endpoints: [MotionArtworkEndpoint] = []) {
        self.endpoints = Self.deduplicated(endpoints)
    }

    private enum CodingKeys: String, CodingKey {
        case endpoints
    }

    /// 坏掉的单条跳过，不连累整份列表。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decodeIfPresent([LossyEndpoint].self, forKey: .endpoints) ?? []
        endpoints = Self.deduplicated(entries.compactMap(\.endpoint))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoints, forKey: .endpoints)
    }

    private struct LossyEndpoint: Decodable {
        let endpoint: MotionArtworkEndpoint?

        init(from decoder: Decoder) throws {
            endpoint = try? MotionArtworkEndpoint(from: decoder)
        }
    }

    /// 解不出来（或还没存过）就是空列表。
    public init(data: Data?) {
        let decoded = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        self.init(endpoints: decoded?.endpoints ?? [])
    }

    public func encodedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    public var isEmpty: Bool { endpoints.isEmpty }

    /// 实际要问的源：开着且地址过了校验的，按列表顺序。
    public var usableEndpoints: [MotionArtworkEndpoint] {
        endpoints.filter { $0.isEnabled && $0.endpointURL != nil }
    }

    // MARK: 校验

    /// 去掉首尾空白后解析并校验；不合法或是受限主机时为 nil。
    public static func endpointURL(_ raw: String) -> URL? {
        guard case .success(let url) = validate(raw) else { return nil }
        return url
    }

    public static func validate(_ raw: String) -> Result<URL, MotionArtworkEndpointRejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return .failure(.invalid)
        }
        guard MotionArtworkServiceSource.permitsEndpoint(url) else { return .failure(.blocked) }
        guard MotionArtworkServiceSource.isValidEndpoint(url) else { return .failure(.invalid) }
        return .success(url)
    }

    /// 没填名字时显示的名字：地址的主机名。
    public static func defaultName(for url: URL) -> String {
        url.host?.lowercased() ?? url.absoluteString
    }

    // MARK: 编辑

    /// 加到列表末尾（优先级最低）。名字留空就用主机名。
    @discardableResult
    public mutating func add(
        name: String,
        url raw: String,
        id: String = UUID().uuidString
    ) -> Result<MotionArtworkEndpoint, MotionArtworkEndpointRejection> {
        let url: URL
        switch Self.validate(raw) {
        case .success(let validated): url = validated
        case .failure(let rejection): return .failure(rejection)
        }
        let trimmedURL = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contains(url: trimmedURL) else { return .failure(.duplicate) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = MotionArtworkEndpoint(
            id: endpoints.contains { $0.id == id } ? UUID().uuidString : id,
            name: trimmedName.isEmpty ? Self.defaultName(for: url) : trimmedName,
            url: trimmedURL
        )
        endpoints.append(endpoint)
        return .success(endpoint)
    }

    public func contains(url raw: String) -> Bool {
        let key = Self.comparisonKey(raw)
        return endpoints.contains { Self.comparisonKey($0.url) == key }
    }

    public mutating func remove(id: String) {
        endpoints.removeAll { $0.id == id }
    }

    public mutating func setEnabled(_ isEnabled: Bool, id: String) {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        endpoints[index].isEnabled = isEnabled
    }

    /// 与 SwiftUI `onMove` 同样的语义：`toOffset` 是移动前列表里的插入位置。
    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let valid = fromOffsets.filter { endpoints.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { endpoints[$0] }
        var remaining = endpoints.enumerated()
            .filter { !valid.contains($0.offset) }
            .map(\.element)
        let clampedTarget = min(max(toOffset, 0), endpoints.count)
        let removedBeforeTarget = valid.filter { $0 < clampedTarget }.count
        let insertion = min(max(clampedTarget - removedBeforeTarget, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        endpoints = remaining
    }

    // MARK: 迁移

    /// 旧版本只有一个服务地址。新列表还从没存过（`storedData == nil`）且旧地址能用时，返回由它生成的
    /// 一条，调用方存下后就不会再迁移；其余情况（已经存过、旧地址为空、不合法或是受限主机）返回 nil。
    /// 用户把列表删空以后存的是空列表，不会被旧地址又补回来。
    public static func migratingLegacyEndpoint(
        storedData: Data?,
        legacyEndpoint: String?
    ) -> MotionArtworkEndpointList? {
        guard storedData == nil, let legacyEndpoint else { return nil }
        var list = MotionArtworkEndpointList()
        guard case .success = list.add(name: "", url: legacyEndpoint, id: legacyEndpointID) else {
            return nil
        }
        return list
    }

    // MARK: 按顺序问

    /// 按顺序问每个源，第一个给出动态封面的就用；某个源没有或出错就问下一个，被打断就停。
    /// 返回给出封面的那个源。`attempt` 在调用方的 actor 上执行。
    public static func firstFound(
        in endpoints: [MotionArtworkEndpoint],
        isolation: isolated (any Actor)? = #isolation,
        attempt: (MotionArtworkEndpoint) async -> MotionArtworkEndpointAttempt
    ) async -> MotionArtworkEndpoint? {
        for endpoint in endpoints {
            switch await attempt(endpoint) {
            case .found: return endpoint
            case .missing: continue
            case .abandoned: return nil
            }
        }
        return nil
    }

    private static func comparisonKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 同一个 id 只留第一条：同步来的数据坏了也不会让列表出现两行同 id。
    private static func deduplicated(_ endpoints: [MotionArtworkEndpoint]) -> [MotionArtworkEndpoint] {
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0.id).inserted }
    }
}

public struct MotionArtworkServiceRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let input: MotionArtworkLookupInput
    public let acceptedKinds: [MotionArtworkAssetKind]
    public let acceptedMIMETypes: [String]

    public init(input: MotionArtworkLookupInput) {
        schemaVersion = Self.currentSchemaVersion
        self.input = input
        acceptedKinds = [.animatedImage]
        acceptedMIMETypes = MotionArtworkServiceResolver.supportedAnimatedImageMIMETypes.sorted()
    }
}

public struct MotionArtworkServiceCandidate: Codable, Equatable, Sendable {
    public let album: MotionArtworkAlbumCandidate
    public let assets: [MotionArtworkAsset]

    public init(album: MotionArtworkAlbumCandidate, assets: [MotionArtworkAsset]) {
        self.album = album
        self.assets = assets
    }
}

public struct MotionArtworkServiceResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let candidates: [MotionArtworkServiceCandidate]

    public init(
        schemaVersion: Int = MotionArtworkServiceRequest.currentSchemaVersion,
        candidates: [MotionArtworkServiceCandidate]
    ) {
        self.schemaVersion = schemaVersion
        self.candidates = candidates
    }
}

public enum MotionArtworkServiceResolver {
    public static let supportedAnimatedImageMIMETypes: Set<String> = [
        "image/apng",
        "image/gif",
        "image/png",
        "image/webp",
    ]

    public static func resolve(
        input: MotionArtworkLookupInput,
        response: MotionArtworkServiceResponse,
        now: Date = Date()
    ) -> MotionArtworkLookupResult {
        guard response.schemaVersion == MotionArtworkServiceRequest.currentSchemaVersion else {
            return .unsupported
        }

        let identityResolution = MotionArtworkCandidateMatcher.resolve(
            input,
            among: response.candidates.map(\.album)
        )
        switch identityResolution {
        case .notFound:
            return .notFound
        case .ambiguous(let candidates):
            return .ambiguous(candidates)
        case .matched(let album):
            guard let entry = response.candidates.first(where: { $0.album == album }) else {
                return .notFound
            }
            guard let asset = preferredAsset(in: entry.assets, now: now) else {
                return .unsupported
            }
            return .asset(asset)
        }
    }

    public static func preferredAsset(
        in assets: [MotionArtworkAsset],
        now: Date = Date()
    ) -> MotionArtworkAsset? {
        assets
            .filter { asset in
                guard asset.kind == .animatedImage,
                      !asset.providerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      isSafeRemoteURL(asset.assetURL),
                      asset.expiresAt.map({ $0 > now }) ?? true else {
                    return false
                }
                if let mimeType = normalizedMIMEType(asset.mimeType) {
                    return supportedAnimatedImageMIMETypes.contains(mimeType)
                }
                return true
            }
            .sorted(by: assetIsPreferred)
            .first
    }

    public static func isSafeRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            return false
        }
        return true
    }

    private static func normalizedMIMEType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func assetIsPreferred(
        _ lhs: MotionArtworkAsset,
        _ rhs: MotionArtworkAsset
    ) -> Bool {
        let left = assetRank(lhs)
        let right = assetRank(rhs)
        if left.squareRank != right.squareRank { return left.squareRank > right.squareRank }
        if left.pixelArea != right.pixelArea { return left.pixelArea > right.pixelArea }
        return stableAssetKey(lhs) < stableAssetKey(rhs)
    }

    private static func assetRank(
        _ asset: MotionArtworkAsset
    ) -> (squareRank: Int, pixelArea: Int64) {
        guard let width = asset.pixelWidth,
              let height = asset.pixelHeight,
              width > 0,
              height > 0,
              width <= ArtworkAnimationLimits.default.maximumDimension,
              height <= ArtworkAnimationLimits.default.maximumDimension else {
            return (0, 0)
        }
        let ratio = Double(width) / Double(height)
        let squareRank = abs(ratio - 1) < 0.001 ? 2 : (0.9...1.1).contains(ratio) ? 1 : 0
        return (squareRank, Int64(width) * Int64(height))
    }

    private static func stableAssetKey(_ asset: MotionArtworkAsset) -> String {
        [
            asset.providerIdentifier,
            asset.assetIdentifier ?? "",
            asset.assetURL.absoluteString,
        ].joined(separator: "\u{1F}")
    }
}
