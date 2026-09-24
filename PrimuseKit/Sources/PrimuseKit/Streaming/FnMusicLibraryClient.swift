import CoreFoundation
import Foundation

private protocol FnMusicLibraryItem: Sendable { var id: String { get } }

public struct FnMusicLibraryRequest: Sendable {
    public let method: String
    public let path: String
    public let queryItems: [URLQueryItem]
    public let body: [String: String]?
}

public struct FnMusicPlaylist: Sendable {
    public let id: String
    public let name: String
    public let coverReference: String?
    public let trackIDs: [String]
}

public struct FnMusicPlaylistSnapshot: Sendable {
    public let playlists: [FnMusicPlaylist]
    public let failedPlaylistIDs: Set<String>
}

/// Uses each platform's existing authenticated session. Only complete pages
/// may become authoritative mirrors or replace a user's favorite state.
public struct FnMusicLibraryClient: Sendable {
    private let load: @Sendable (FnMusicLibraryRequest) async throws -> Data
    private static let pageSize = 50
    /// 没有 `total` 时靠短页判尾，这条上限只防"服务端不分页、每页都满"的死循环。
    private static let pageLimit = 1_000

    public init(load: @escaping @Sendable (FnMusicLibraryRequest) async throws -> Data) {
        self.load = load
    }

    public func playlists() async throws -> FnMusicPlaylistSnapshot {
        let summaries: [Summary] = try await index(path: "/playlist/list", parse: Summary.init)
        var playlists: [FnMusicPlaylist] = []
        var failed: Set<String> = []
        for summary in summaries {
            try Task.checkCancellation()
            do {
                let tracks: [Track] = try await pages(
                    path: "/track/playlist-detail/list",
                    query: [URLQueryItem(name: "playlistGUID", value: summary.id)],
                    expectedTotal: summary.trackCount,
                    allowsDuplicates: true,
                    parse: Track.init
                )
                playlists.append(FnMusicPlaylist(
                    id: summary.id, name: summary.name,
                    coverReference: summary.coverReference, trackIDs: tracks.map(\.id)
                ))
            } catch {
                if OperationCancellationPolicy.isCancellation(error) { throw CancellationError() }
                failed.insert(summary.id)
            }
        }
        return FnMusicPlaylistSnapshot(playlists: playlists, failedPlaylistIDs: failed)
    }

    public func favorites() async throws -> [String] {
        let tracks: [Track] = try await pages(path: "/favorite-track/list", parse: Track.init)
        return tracks.map(\.id)
    }

    public func setFavorite(trackID: String, isFavorite: Bool) async throws -> [String] {
        guard Self.validID(trackID) else { throw Self.invalidResponse("favorite id \(trackID) is not a track id") }
        let existing = try await favorites()
        if existing.contains(trackID) != isFavorite {
            try Task.checkCancellation()
            _ = try await load(FnMusicLibraryRequest(
                method: "POST",
                path: isFavorite ? "/favorite-track/create" : "/favorite-track/delete",
                queryItems: [], body: ["trackGUID": trackID]
            ))
        }
        let confirmed = try await favorites()
        guard confirmed.contains(trackID) == isFavorite else {
            throw Self.invalidResponse("favorite-track/list does not reflect the write to \(trackID)")
        }
        return confirmed
    }

    /// 歌单清单不分页：网页端不带 page/size 调 `/playlist/list`，只读 `list`。带着分页
    /// 参数去请求，服务端照单全给时条数正好是页大小整数倍就会多翻一页、拿到重复项报错。
    /// `total` 若给了仍要和条数对得上，免得截断的清单被当成权威镜像把本地歌单清空。
    private func index<Item: FnMusicLibraryItem>(
        path: String,
        parse: ([String: Any]) throws -> Item
    ) async throws -> [Item] {
        try Task.checkCancellation()
        let data = try await load(FnMusicLibraryRequest(method: "GET", path: path, queryItems: [], body: nil))
        try Task.checkCancellation()
        let current = try Self.page(path: path, data: data)
        if let total = current.total, total != current.list.count {
            throw Self.invalidResponse("\(path): \(current.list.count) items but total \(total)")
        }
        var seen: Set<String> = []
        return try current.list.map { json in
            let item = try parse(json)
            guard seen.insert(item.id).inserted else {
                throw Self.invalidResponse("\(path): repeated item \(item.id)")
            }
            return item
        }
    }

    private func pages<Item: FnMusicLibraryItem>(
        path: String,
        query: [URLQueryItem] = [],
        expectedTotal: Int? = nil,
        allowsDuplicates: Bool = false,
        parse: ([String: Any]) throws -> Item
    ) async throws -> [Item] {
        var page = 1
        var total = expectedTotal
        var result: [Item] = []
        var seen: Set<String> = []
        while true {
            try Task.checkCancellation()
            let data = try await load(FnMusicLibraryRequest(
                method: "GET", path: path,
                queryItems: query + [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(Self.pageSize)),
                ], body: nil
            ))
            try Task.checkCancellation()
            let current = try Self.page(path: path, data: data)
            if let pageTotal = current.total {
                guard total == nil || total == pageTotal else {
                    throw Self.invalidResponse("\(path): total changed from \(total ?? -1) to \(pageTotal)")
                }
                total = pageTotal
            }
            for json in current.list {
                let item = try parse(json)
                guard allowsDuplicates || seen.insert(item.id).inserted else {
                    throw Self.invalidResponse("\(path): repeated item \(item.id)")
                }
                result.append(item)
            }
            if let total {
                guard result.count <= total else {
                    throw Self.invalidResponse("\(path): \(result.count) items exceed total \(total)")
                }
                if result.count == total { return result }
                guard current.list.count == Self.pageSize else {
                    throw Self.invalidResponse("\(path): page \(page) is short (\(current.list.count)) with total \(total)")
                }
            } else if current.list.count != Self.pageSize {
                // 没有 total 时短页就是末页；不分页、一次全给的清单也从这里返回。
                return result
            }
            page += 1
            guard page <= Self.pageLimit else {
                throw Self.invalidResponse("\(path): more than \(Self.pageLimit) pages")
            }
        }
    }

    private struct Page {
        var list: [[String: Any]]
        var total: Int?
    }

    /// 飞牛的分页对象是 `{list, total}`。空集合时 `list` 是 `null`（服务端把空切片
    /// 序列化成 null），命令类接口连整个 `data` 都是 null；歌单清单这种不分页的接口
    /// 可以不带 `total`。社区客户端 fn-music-tv 的 DTO 就是 `list = emptyList()`、
    /// `total = list.size` 并开着 `coerceInputValues`。这里按同一套规则读，其余都算坏响应。
    private static func page(path: String, data: Data) throws -> Page {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidResponse("\(path): page is not an object")
        }
        var page = Page(list: [], total: nil)
        if let raw = object["list"], !(raw is NSNull) {
            guard let list = raw as? [[String: Any]] else {
                throw invalidResponse("\(path): list is not an array of objects")
            }
            page.list = list
        }
        if let raw = object["total"], !(raw is NSNull) {
            guard let total = integer(raw), total >= 0 else {
                throw invalidResponse("\(path): total is not a count")
            }
            page.total = total
        }
        return page
    }

    private struct Track: FnMusicLibraryItem {
        let id: String
        init(_ json: [String: Any]) throws {
            guard let id = FnMusicLibraryClient.identifier(json["guid"] ?? json["trackGUID"] ?? json["id"]) else {
                throw FnMusicLibraryClient.invalidResponse("track without a usable guid")
            }
            self.id = id
        }
    }

    private struct Summary: FnMusicLibraryItem {
        let id: String
        let name: String
        let coverReference: String?
        let trackCount: Int?

        init(_ json: [String: Any]) throws {
            guard let id = FnMusicLibraryClient.identifier(json["guid"]),
                  let name = json["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FnMusicLibraryClient.invalidResponse("playlist without guid or name")
            }
            self.id = id
            self.name = name
            trackCount = FnMusicLibraryClient.integer(json["trackCount"])
            if let trackCount, trackCount < 0 { throw FnMusicLibraryClient.invalidResponse("negative trackCount") }
            if let rawCount = json["trackCount"], !(rawCount is NSNull), trackCount == nil {
                throw FnMusicLibraryClient.invalidResponse("trackCount is not a count")
            }
            coverReference = FnMusicLibraryClient.identifier(json["coverId"]).map {
                FnMusicAPIProtocol.coverReference(coverID: $0, revision: FnMusicLibraryClient.integer(json["updatedAt"]))
            }
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, validID(value) else { return nil }
        return value
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("/")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(),
           value.doubleValue == Double(value.intValue) { return value.intValue }
        return nil
    }

    /// `reason` 是给日志看的英文技术说明，跟在本地化文案后面：同一句「响应不是有效的
    /// 飞牛音乐 JSON」曾经把"空列表是 null"和"真的坏了"混在一起，三天都没人看得出来。
    private static func invalidResponse(_ reason: String) -> FnMusicServiceError {
        .invalidResponse(PMString("error.catalog.invalidFnMusicJSON") + " [\(reason)]")
    }
}
