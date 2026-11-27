import Foundation
import PrimuseKit

/// Google Drive 的变更推送:起始游标与按游标对账(整盘源按文件夹归属,已选文件源只看文件)。
extension GoogleDriveSource {
    func initialChangeCursors(for roots: [String]) async throws -> [String: String] {
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/changes/startPageToken")!
        components.queryItems = [.init(name: "supportsAllDrives", value: "true")]
        let requestURL = components.url!
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: requestURL, accessToken: tok)
        }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursor = json["startPageToken"] as? String,
              !cursor.isEmpty else {
            throw CloudDriveError.apiError(http.statusCode, "Google Drive startPageToken")
        }
        return ["account": cursor]
    }

    func changes(
        since cursors: [String: String],
        roots: [String],
        index: SourceSyncIndex
    ) async throws -> IncrementalSourceChanges {
        guard var pageToken = cursors["account"], !pageToken.isEmpty else {
            return IncrementalSourceChanges(cursors: cursors, requiresDeepScan: true)
        }
        // 半迁移(令牌和配置对不上)时整轮对账不做,和列目录一样抛「需要重新选择文件」。
        for root in roots { _ = try await resolvedAccessMode(forPath: root) }
        let accessMode = try await resolvedAccessMode(forPath: nil)
        let normalizedRoots = Set(roots.map { $0.isEmpty || $0 == "/" ? "root" : $0 })
        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []
        var liveStableKeys: Set<String> = []
        var requiresDeep = false
        var ancestryCache: [String: Bool] = [:]
        var finalCursor: String?

        repeat {
            let token = try await getToken()
            var components = URLComponents(string: "\(Self.apiBase)/changes")!
            components.queryItems = [
                .init(name: "pageToken", value: pageToken),
                .init(name: "pageSize", value: "1000"),
                .init(name: "includeRemoved", value: "true"),
                .init(name: "supportsAllDrives", value: "true"),
                .init(name: "includeItemsFromAllDrives", value: "true"),
                .init(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,size,modifiedTime,md5Checksum,headRevisionId,parents,trashed))"),
            ]
            let requestURL = components.url!
            let (data, http) = try await helper.withTokenRetry(
                initialToken: token,
                refresh: refreshToken
            ) { @Sendable tok in
                try await self.helper.makeAuthorizedRequest(url: requestURL, accessToken: tok)
            }
            if http.statusCode == 410 {
                return IncrementalSourceChanges(
                    cursors: cursors,
                    requiresDeepScan: true
                )
            }
            guard http.statusCode == 200 else {
                throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let entries = json["changes"] as? [[String: Any]] ?? []
            for change in entries {
                guard let fileID = change["fileId"] as? String else { continue }
                let existing = index[fileID]
                let file = change["file"] as? [String: Any]
                let removed = change["removed"] as? Bool == true || file?["trashed"] as? Bool == true
                if removed {
                    if let existing {
                        deletedKeys.insert(fileID)
                        if let parent = existing.parentPath { changedParents.insert(parent) }
                    }
                    continue
                }
                guard let file else { continue }
                deletedKeys.remove(fileID)
                liveStableKeys.insert(fileID)
                if accessMode == .pickedFiles {
                    // Under `drive.file`, parent folders are not authorized to the
                    // app so walking folder ancestry returns 404/403. Reconciling
                    // the flat authorized file list is a single files.list call.
                    if (file["mimeType"] as? String) != "application/vnd.google-apps.folder" {
                        requiresDeep = true
                    }
                    continue
                }
                let parents = file["parents"] as? [String] ?? []
                let parent = parents.first
                let inScope: Bool
                if normalizedRoots.contains("root") {
                    inScope = true
                } else if let parent {
                    if let cached = ancestryCache[parent] {
                        inScope = cached
                    } else {
                        let value = try await folder(parent, belongsToAny: normalizedRoots)
                        ancestryCache[parent] = value
                        inScope = value
                    }
                } else {
                    inScope = existing != nil
                }
                if let oldParent = existing?.parentPath { changedParents.insert(oldParent) }
                guard inScope else { continue }
                if (file["mimeType"] as? String) == "application/vnd.google-apps.folder" {
                    requiresDeep = true
                } else if let parent {
                    changedParents.insert(parent)
                }
            }
            if let next = json["nextPageToken"] as? String, !next.isEmpty {
                pageToken = next
            } else {
                finalCursor = json["newStartPageToken"] as? String
                pageToken = ""
            }
        } while !pageToken.isEmpty

        guard let finalCursor, !finalCursor.isEmpty else {
            throw CloudDriveError.invalidResponse
        }
        deletedKeys.subtract(liveStableKeys)
        return IncrementalSourceChanges(
            cursors: ["account": finalCursor],
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            requiresDeepScan: requiresDeep
        )
    }

    private func folder(_ folderID: String, belongsToAny roots: Set<String>) async throws -> Bool {
        var current: String? = folderID
        var visited: Set<String> = []
        for _ in 0..<128 {
            guard let id = current, visited.insert(id).inserted else { return false }
            if roots.contains(id) { return true }
            let token = try await getToken()
            var components = URLComponents(string: "\(Self.apiBase)/files/\(id)")!
            components.queryItems = [.init(name: "fields", value: "id,parents,trashed")]
            let requestURL = components.url!
            let (data, http) = try await helper.withTokenRetry(
                initialToken: token,
                refresh: refreshToken
            ) { @Sendable tok in
                try await self.helper.makeAuthorizedRequest(url: requestURL, accessToken: tok)
            }
            if http.statusCode == 404 { return false }
            guard http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["trashed"] as? Bool != true else { return false }
            current = (json["parents"] as? [String])?.first
            if current == nil { return false }
        }
        return false
    }
}
