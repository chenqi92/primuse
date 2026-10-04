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
    /// 服务端列出的条数，读不出而跳过的也算在内：只要它大于 0，一首都没认出来也不能当成歌单被清空。
    public let reportedTrackCount: Int
}

extension FnMusicPlaylist {
    fileprivate init(summary: FnMusicLibraryClient.Summary, tracks: FnMusicLibraryClient.PlaylistTracks) {
        self.init(id: summary.id, name: summary.name, coverReference: summary.coverReference,
                  trackIDs: tracks.ids, reportedTrackCount: tracks.listed)
    }
}

/// `isComplete == false` 表示有条目认不出被跳过了，这份清单不能证明哪首歌被取消了收藏。
public struct FnMusicFavoriteSnapshot: Sendable {
    public let trackIDs: [String]
    public let isComplete: Bool
}

public struct FnMusicPlaylistSnapshot: Sendable {
    public let playlists: [FnMusicPlaylist]
    public let failedPlaylistIDs: Set<String>
    /// An unreadable index entry cannot prove that any existing playlist was deleted.
    public let isIndexComplete: Bool
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

    /// `onPlaylist` 每读全一个歌单就交出一个，调用方可以先显示，不必等整轮读完：
    /// 中继慢、App 半路被挂起时，已经读到的歌单不会跟着最慢的那个一起等。
    public func playlists(
        diagnosticLogger: (@Sendable (String) -> Void)? = nil,
        onPlaylist: (@Sendable (FnMusicPlaylist) async -> Void)? = nil
    ) async throws -> FnMusicPlaylistSnapshot {
        let runID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        let log: @Sendable (String) -> Void = { message in
            diagnosticLogger?("FN playlists run=\(runID) \(message)")
        }
        var stage = "index"
        log("stage=index result=started")
        do {
            if diagnosticLogger != nil { try await logServerVersion(log) }
            let index = try await playlistIndex(diagnosticLogger: log)
            let summaries = index.summaries
            let result = index.isComplete ? "complete" : "partial"
            log("stage=index result=\(result) listed=\(index.listedCount) usable=\(summaries.count) invalid=\(index.invalidCount)")
            stage = "detail"
            var trackIDs: [String: PlaylistTracks] = [:]
            // 明细翻到一半失败（会话被顶掉、网络抖一下、歌单正被改）整份歌单就不会出现。
            // 一轮读完再把失败的补读一次，这时别的请求多半已经结束；两轮都没读全的才算失败。
            for attempt in 1...2 {
                for summary in summaries where trackIDs[summary.id] == nil {
                    try Task.checkCancellation()
                    let context = "playlist=\(LogRedactionPolicy.digest(summary.id)) attempt=\(attempt) expected=\(summary.trackCount.map(String.init) ?? "unknown")"
                    let tracks: PlaylistTracks
                    do {
                        tracks = try await playlistTracks(summary, diagnosticLogger: {
                            log("stage=detail-page \(context) \($0)")
                        })
                    } catch {
                        if OperationCancellationPolicy.isCancellation(error) { throw CancellationError() }
                        log("stage=detail result=failed \(context) \(LogRedactionPolicy.errorSummary(error))")
                        continue
                    }
                    trackIDs[summary.id] = tracks
                    log("stage=detail result=complete \(context) received=\(tracks.ids.count) id_shape=\(Self.identifierShape(tracks.ids.first))")
                    await onPlaylist?(FnMusicPlaylist(summary: summary, tracks: tracks))
                }
            }
            let playlists = summaries.compactMap { summary in
                trackIDs[summary.id].map { FnMusicPlaylist(summary: summary, tracks: $0) }
            }
            let failed = Set(summaries.map(\.id).filter { trackIDs[$0] == nil }).union(index.failedIDs)
            log("stage=fetch result=\(result) listed=\(index.listedCount) detailed=\(playlists.count) failed=\(failed.count) index_complete=\(index.isComplete) invalid=\(index.invalidCount) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000))")
            return FnMusicPlaylistSnapshot(playlists: playlists, failedPlaylistIDs: failed, isIndexComplete: index.isComplete)
        } catch {
            let result = OperationCancellationPolicy.isCancellation(error) ? "cancelled" : "failed"
            log("stage=\(stage) result=\(result) \(LogRedactionPolicy.errorSummary(error))")
            throw error
        }
    }

    fileprivate struct PlaylistTracks {
        var ids: [String]
        var listed: Int
    }

    private func playlistTracks(
        _ summary: Summary,
        diagnosticLogger: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlaylistTracks {
        let rows: Rows<Track> = try await pages(
            path: "/track/playlist-detail/list",
            query: [URLQueryItem(name: "playlistGUID", value: summary.id)],
            expectedTotal: summary.trackCount,
            allowsDuplicates: true,
            diagnosticLogger: diagnosticLogger,
            parse: Track.init
        )
        return PlaylistTracks(ids: rows.items.map(\.id), listed: rows.listed)
    }

    public func favorites(diagnosticLogger: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        try await favoriteSnapshot(diagnosticLogger: diagnosticLogger).trackIDs
    }

    public func favoriteSnapshot(diagnosticLogger: (@Sendable (String) -> Void)? = nil) async throws -> FnMusicFavoriteSnapshot {
        let runID = String(UUID().uuidString.prefix(8))
        let log: @Sendable (String) -> Void = { message in
            diagnosticLogger?("FN favorites run=\(runID) \(message)")
        }
        log("stage=fetch result=started")
        do {
            let rows: Rows<Track> = try await pages(path: "/favorite-track/list", diagnosticLogger: log, parse: Track.init)
            log("stage=fetch result=complete received=\(rows.items.count) id_shape=\(Self.identifierShape(rows.items.first?.id))")
            return FnMusicFavoriteSnapshot(trackIDs: rows.items.map(\.id), isComplete: rows.items.count == rows.listed)
        } catch {
            let result = OperationCancellationPolicy.isCancellation(error) ? "cancelled" : "failed"
            log("stage=fetch result=\(result) \(LogRedactionPolicy.errorSummary(error))")
            throw error
        }
    }

    private func logServerVersion(_ log: @Sendable (String) -> Void) async throws {
        do {
            try Task.checkCancellation()
            let data = try await load(FnMusicLibraryRequest(method: "GET", path: "/sys/config", queryItems: [], body: nil))
            try Task.checkCancellation()
            let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            log("stage=server api=v1 server_version=\(Self.versionLabel(config?["serverVersion"])) media_version=\(Self.versionLabel(config?["mediasrvVersion"]))")
        } catch {
            if OperationCancellationPolicy.isCancellation(error) { throw error }
            log("stage=server result=unavailable \(LogRedactionPolicy.errorSummary(error))")
        }
    }

    private static func versionLabel(_ value: Any?) -> String {
        guard let value = value as? String, value.count <= 32 else { return "unknown" }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return "unknown" }
        return value
    }

    public func setFavorite(trackID: String, isFavorite: Bool) async throws -> FnMusicFavoriteSnapshot {
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
        let confirmed = try await favoriteSnapshot()
        guard confirmed.trackIDs.contains(trackID) == isFavorite else {
            throw Self.invalidResponse("favorite-track/list does not reflect the write to \(trackID)")
        }
        return confirmed
    }

    /// 歌单清单不分页：网页端不带 page/size 调 `/playlist/list`，只读 `list`。带着分页
    /// 参数去请求，服务端照单全给时条数正好是页大小整数倍就会多翻一页、拿到重复项报错。
    /// `total` 若给了仍要和条数对得上，免得截断的清单被当成权威镜像把本地歌单清空。
    private struct PlaylistIndex {
        var summaries: [Summary] = []
        var failedIDs: Set<String> = []
        var listedCount = 0
        var invalidCount = 0
        var isComplete: Bool { invalidCount == 0 }
    }

    private func playlistIndex(
        diagnosticLogger: (@Sendable (String) -> Void)?
    ) async throws -> PlaylistIndex {
        let path = "/playlist/list"
        try Task.checkCancellation()
        let data = try await load(FnMusicLibraryRequest(method: "GET", path: path, queryItems: [], body: nil))
        try Task.checkCancellation()
        let current = try Self.page(path: path, data: data)
        diagnosticLogger?("stage=index result=received received=\(current.list.count) reported_total=\(current.total.map(String.init) ?? "unknown")")
        if let total = current.total, total != current.list.count {
            throw Self.invalidResponse("\(path): \(current.list.count) items but total \(total)")
        }
        var seen: Set<String> = []
        var result = PlaylistIndex(listedCount: current.list.count)
        for (row, raw) in current.list.enumerated() {
            guard let json = raw as? [String: Any] else {
                result.invalidCount += 1
                diagnosticLogger?("stage=index result=invalid-item row=\(row + 1) item=\(Self.fieldState(raw))")
                continue
            }
            let item: Summary
            do {
                item = try Summary(json)
            } catch {
                result.invalidCount += 1
                if let id = Self.playlistIdentifier(json["guid"]) { result.failedIDs.insert(id) }
                diagnosticLogger?("stage=index result=invalid-item row=\(row + 1) \(Self.playlistFieldStates(json))")
                continue
            }
            guard seen.insert(item.id).inserted else {
                result.invalidCount += 1
                result.failedIDs.insert(item.id)
                diagnosticLogger?("stage=index result=invalid-item row=\(row + 1) reason=duplicate-id")
                continue
            }
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnosticLogger?("stage=index result=name-fallback row=\(row + 1) name=\(Self.fieldState(json["name"]))")
            }
            result.summaries.append(item)
        }
        let failedIDs = result.failedIDs
        result.summaries.removeAll { failedIDs.contains($0.id) }
        return result
    }

    private func pages<Item: FnMusicLibraryItem>(
        path: String,
        query: [URLQueryItem] = [],
        expectedTotal: Int? = nil,
        allowsDuplicates: Bool = false,
        diagnosticLogger: (@Sendable (String) -> Void)? = nil,
        parse: ([String: Any]) throws -> Item
    ) async throws -> Rows<Item> {
        var page = 1
        var total = expectedTotal
        var result: [Item] = []
        var seen: Set<String> = []
        // 翻页与 total 按服务端给出的行数算；认不出的单行只跳过它自己。那一行本来就对不上
        // 本地曲库，拿整份歌单或收藏去陪葬反而让读得出的歌也同步不了。
        var received = 0
        var skipped = 0
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
            diagnosticLogger?("page=\(page) received=\(current.list.count) accumulated=\(received) reported_total=\(current.total.map(String.init) ?? "unknown")")
            if let pageTotal = current.total {
                guard total == nil || total == pageTotal else {
                    throw Self.invalidResponse("\(path): total changed from \(total ?? -1) to \(pageTotal)")
                }
                total = pageTotal
            }
            received += current.list.count
            for (row, raw) in current.list.enumerated() {
                guard let json = raw as? [String: Any] else {
                    skipped += 1
                    diagnosticLogger?("page=\(page) result=invalid-item row=\(row + 1) item=\(Self.fieldState(raw)) action=skip")
                    continue
                }
                let item: Item
                do {
                    item = try parse(json)
                } catch {
                    skipped += 1
                    diagnosticLogger?("page=\(page) result=invalid-item row=\(row + 1) guid=\(Self.fieldState(json["guid"])) trackGUID=\(Self.fieldState(json["trackGUID"])) id=\(Self.fieldState(json["id"])) access=\(Self.accessState(json["accessStatus"])) action=skip")
                    continue
                }
                guard allowsDuplicates || seen.insert(item.id).inserted else {
                    throw Self.invalidResponse("\(path): repeated item \(item.id)")
                }
                result.append(item)
            }
            let finished: Bool
            if let total {
                guard received <= total else {
                    throw Self.invalidResponse("\(path): \(received) items exceed total \(total)")
                }
                finished = received == total
                guard finished || current.list.count == Self.pageSize else {
                    throw Self.invalidResponse("\(path): page \(page) is short (\(current.list.count)) with total \(total)")
                }
            } else {
                // 没有 total 时短页就是末页；不分页、一次全给的清单也从这里返回。
                finished = current.list.count != Self.pageSize
            }
            if finished {
                if skipped > 0 { diagnosticLogger?("result=skipped-items skipped=\(skipped) kept=\(result.count)") }
                return Rows(items: result, listed: received)
            }
            page += 1
            guard page <= Self.pageLimit else {
                throw Self.invalidResponse("\(path): more than \(Self.pageLimit) pages")
            }
        }
    }

    private struct Rows<Item> {
        var items: [Item]
        /// 服务端给出的行数，含认不出而跳过的。
        var listed: Int
    }

    private struct Page {
        var list: [Any]
        var total: Int?
    }

    private static func playlistFieldStates(_ json: [String: Any]) -> String {
        "guid=\(fieldState(json["guid"], playlistIdentifier: true)) "
            + "name=\(fieldState(json["name"])) "
            + "id=\(fieldState(json["id"], identifier: true)) "
            + "playlistGUID=\(fieldState(json["playlistGUID"], identifier: true)) "
            + "title=\(fieldState(json["title"])) "
            + "trackCount=\(fieldState(json["trackCount"]))"
    }

    private static func fieldState(_ value: Any?, identifier: Bool = false, playlistIdentifier: Bool = false) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        if let string = value as? String {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty-string" }
            if playlistIdentifier { return Self.playlistIdentifier(string) == nil ? "invalid-string" : "string" }
            return identifier && !validID(string) ? "invalid-string" : "string"
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "other"
    }

    /// 只描述 id 的形状、不带内容（`hex32`、`len=40 chars=alnum,slash`），
    /// 歌单读出来却对不上曲库时，靠它认出服务端是不是换了 id 格式。
    private static func identifierShape(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "none" }
        let scalars = id.unicodeScalars
        if scalars.allSatisfy({ $0.properties.isASCIIHexDigit }) { return "hex\(scalars.count)" }
        let classes: [(String, (Unicode.Scalar) -> Bool)] = [
            ("alnum", { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.isASCIIHexDigit) }),
            ("dash", { $0 == "-" || $0 == "_" }),
            ("dot", { $0 == "." || $0 == ":" }),
            ("slash", { $0 == "/" || $0 == "\\" }),
            ("space", { $0.properties.isWhitespace }),
            ("control", { CharacterSet.controlCharacters.contains($0) }),
        ]
        var present = classes.filter { scalars.contains(where: $0.1) }.map(\.0)
        if scalars.contains(where: { scalar in !classes.contains { $0.1(scalar) } }) { present.append("other") }
        return "len=\(scalars.count) chars=\(present.joined(separator: ","))"
    }

    private static func accessState(_ value: Any?) -> String {
        switch integer(value) {
        case 0: return "available"
        case 1, 3: return "missing"
        case 2, 4: return "permission-denied"
        default: return "unknown"
        }
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
            guard let list = raw as? [Any] else {
                throw invalidResponse("\(path): list is not an array")
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

    /// 曲目 id 只拿去对本地曲库、不拼路径，取法要和曲库扫描（`FnMusicCatalogTrack`）一致：
    /// 去首尾空白、非空就收。原先另套文件名规则，飞牛 1.0.10 上曲库照收的 guid 到了歌单明细、
    /// 收藏里被判无效，一首不过整份歌单作废，歌单和收藏一个都同步不下来。
    private struct Track: FnMusicLibraryItem {
        let id: String
        init(_ json: [String: Any]) throws {
            guard let id = fnMusicFirstNonemptyString(json, keys: ["guid", "trackGUID", "id"]) else {
                throw FnMusicLibraryClient.invalidResponse("track without a usable guid")
            }
            self.id = id
        }
    }

    fileprivate struct Summary: FnMusicLibraryItem {
        let id: String
        let name: String
        let coverReference: String?
        let trackCount: Int?

        init(_ json: [String: Any]) throws {
            guard let id = FnMusicLibraryClient.playlistIdentifier(json["guid"]) else {
                throw FnMusicLibraryClient.invalidResponse("playlist without guid or name")
            }
            self.id = id
            self.name = json["name"] as? String ?? ""
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

    /// Playlist IDs are opaque query values, never filesystem components.
    /// Preserve whitespace, separators and Unicode format characters exactly.
    private static func playlistIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
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
