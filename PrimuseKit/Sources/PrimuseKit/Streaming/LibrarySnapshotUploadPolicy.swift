import Foundation

/// 账号里给 Apple TV 用的曲库快照按上传设备各存一条记录(`library-snapshot.<设备 id>`),
/// 那条老的单例记录只保留音乐源、电台和这份设备清单。以前全账号只有一份曲库,
/// 谁最后上传谁赢: 手机扫的是 NAS A、iPad 扫的是 NAS B, 电视上的曲库就随着最后
/// 上传的那台来回变。现在电视按清单把每台设备的曲库都拉下来, 按歌曲 id 合并。
public struct LibrarySnapshotDeviceEntry: Codable, Equatable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var modifiedAt: Date
    public var songCount: Int

    public init(deviceID: String, deviceName: String, modifiedAt: Date, songCount: Int) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.modifiedAt = modifiedAt
        self.songCount = songCount
    }
}

public enum LibrarySnapshotDeviceManifestPolicy {
    /// 单例记录上存清单的字段(JSON)。新字段: 发布前要把 LibrarySnapshot 的 schema 部署到生产环境。
    public static let manifestFieldKey = "deviceSnapshots"

    public static func recordName(forDevice deviceID: String) -> String {
        "library-snapshot.\(deviceID)"
    }

    public static func decode(_ data: Data?) -> [LibrarySnapshotDeviceEntry] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibrarySnapshotDeviceEntry].self, from: data)) ?? []
    }

    public static func encode(_ entries: [LibrarySnapshotDeviceEntry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(entries.sorted { $0.deviceID < $1.deviceID })
    }

    /// 服务器上的清单并上本机这一行: 同一台设备覆盖自己的旧行, 别的设备的行原样保留。
    /// 上传撞上冲突时拿服务器最新的清单再并一次, 所以两台设备同时上传也不会互相抹掉。
    public static func merging(
        server: [LibrarySnapshotDeviceEntry],
        upserting entry: LibrarySnapshotDeviceEntry
    ) -> [LibrarySnapshotDeviceEntry] {
        var result = server.filter { $0.deviceID != entry.deviceID }
        result.append(entry)
        return result.sorted { $0.deviceID < $1.deviceID }
    }

    public static func removing(
        deviceID: String,
        from server: [LibrarySnapshotDeviceEntry]
    ) -> [LibrarySnapshotDeviceEntry] {
        server.filter { $0.deviceID != deviceID }.sorted { $0.deviceID < $1.deviceID }
    }

    /// 合并顺序: 最近上传的设备在前, 同一首歌以它的记录为准; 时间相同按设备 id 打平局。
    public static func mergeOrder(_ entries: [LibrarySnapshotDeviceEntry]) -> [LibrarySnapshotDeviceEntry] {
        entries.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.deviceID < $1.deviceID
        }
    }

    /// 电视端用来判断「云端有没有变」的合成标记: 单例与每条设备记录的 changeTag 一起算。
    public static func compositeChangeTag(
        manifestRecordTag: String?,
        deviceRecordTags: [String: String?]
    ) -> String {
        let parts = deviceRecordTags.keys.sorted().map { key -> String in
            let tag = deviceRecordTags[key].flatMap { $0 } ?? ""
            return "\(key)=\(tag)"
        }
        return ([manifestRecordTag ?? ""] + parts).joined(separator: "|")
    }

    /// 歌词 blob(`{文件名: base64}`)按设备合并: 排在前面的设备优先, 后面的只补缺。
    public static func mergingLyricsBlobs(_ blobs: [[String: String]]) -> [String: String] {
        var merged: [String: String] = [:]
        for blob in blobs {
            for (name, value) in blob where merged[name] == nil {
                merged[name] = value
            }
        }
        return merged
    }
}
