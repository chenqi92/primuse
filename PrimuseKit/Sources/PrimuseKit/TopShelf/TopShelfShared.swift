import Foundation

/// Apple TV「顶部内容展示」(Top Shelf) 的跨进程数据契约。
///
/// Top Shelf 扩展是独立进程,读不到主 app 私有容器里的曲库快照,所以主 app 把
/// 一份精简的展示数据(最近播放 / 资料库专辑 + 预取好的封面)写进 App Group 共享
/// 容器,扩展直接读本地文件秒开,无需联网、无需凭据。
public enum TopShelfShared {
    /// App Group 标识(主 app / tvOS app / Top Shelf 扩展三方共享)。
    public static let appGroupID = "group.com.welape.yuanyin"
}

public struct TopShelfItem: Codable, Identifiable, Sendable, Equatable {
    public var id: String              // 歌曲 id(可播放项)或专辑 id
    public var title: String
    public var subtitle: String        // 艺术家 / 专辑
    public var imageFileName: String?  // App Group 封面目录内的文件名;nil 表示用占位
    public var playURL: String         // 点击后打开 app 的 deep link

    public init(id: String, title: String, subtitle: String,
                imageFileName: String? = nil, playURL: String) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.imageFileName = imageFileName; self.playURL = playURL
    }
}

public struct TopShelfSection: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var items: [TopShelfItem]

    public init(id: String, title: String, items: [TopShelfItem]) {
        self.id = id; self.title = title; self.items = items
    }
}

public struct TopShelfPayload: Codable, Sendable, Equatable {
    public var sections: [TopShelfSection]
    public var updatedAt: Date

    public init(sections: [TopShelfSection], updatedAt: Date = Date()) {
        self.sections = sections; self.updatedAt = updatedAt
    }
}

/// App Group 容器里 Top Shelf 数据的读写入口(主 app 写、扩展读)。
public enum TopShelfStore {
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TopShelfShared.appGroupID)
    }

    /// 数据与封面实际存放的目录。tvOS 真机上 app 和扩展都只能写共享容器里的 `Library/Caches`,
    /// 写容器根目录会报没有权限(模拟器不拦)。系统空间紧张时这里可能被清掉,主 app 下次发布会重写。
    static func storageDirectory(inContainer container: URL) -> URL {
        container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    private static var storageDirectory: URL? {
        containerURL.map(storageDirectory(inContainer:))
    }

    /// 封面缩略图目录(主 app 预取写入)。
    public static var coversDirectory: URL? {
        guard let base = storageDirectory else { return nil }
        let dir = base.appendingPathComponent("TopShelfCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var payloadURL: URL? {
        storageDirectory?.appendingPathComponent("topshelf.json")
    }

    public static func coverURL(_ fileName: String) -> URL? {
        coversDirectory?.appendingPathComponent(fileName)
    }

    public static func load() -> TopShelfPayload? {
        guard let url = payloadURL, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TopShelfPayload.self, from: data)
    }

    public static func save(_ payload: TopShelfPayload) throws {
        guard let url = payloadURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(payload).write(to: url, options: .atomic)
    }
}
