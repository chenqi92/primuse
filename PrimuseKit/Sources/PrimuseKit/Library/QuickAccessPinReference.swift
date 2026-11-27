import Foundation

/// Versioned persistence for the Library/Home favorites (formerly a capped
/// quick-access selection).
///
/// Version 1 stored a bare array and rendered Liked Songs outside that array,
/// which meant it could neither be hidden nor reordered. Version 2 stores the
/// complete ordered selection, including Liked Songs. Decoding a legacy array
/// prepends the supplied default pin once, preserving the old visible result.
public enum QuickAccessPinKind: String, Codable, Sendable {
    /// `book`: an audiobook on the shelf, by its book id. Older builds skip
    /// the kind when they decode the list (`QuickAccessPinStorageCodec`).
    case album, artist, playlist, folder, book
}

public struct QuickAccessPinReference: Codable, Hashable, Identifiable, Sendable {
    public let kind: QuickAccessPinKind
    public let itemID: String

    public init(kind: QuickAccessPinKind, itemID: String) {
        self.kind = kind
        self.itemID = itemID
    }

    public var id: String { "\(kind.rawValue):\(itemID)" }
}

extension QuickAccessPinReference {
    /// 收藏的目录。`itemID` 是「来源 id · 节点类型 · 相对路径」用 U+001F 拼起来的串：
    /// 和首页目录置顶列表的 JSON 不同，它不受编码器键序影响，同一个目录永远是同一个串。
    public static func folder(_ id: LibraryFolderNodeID) -> QuickAccessPinReference {
        QuickAccessPinReference(
            kind: .folder,
            itemID: [id.sourceID, id.kind.rawValue, id.normalizedRelativePath].joined(separator: "\u{1F}")
        )
    }

    public var folderNodeID: LibraryFolderNodeID? {
        guard kind == .folder else { return nil }
        let parts = itemID.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = LibraryFolderNodeKind(rawValue: String(parts[1])) else { return nil }
        return LibraryFolderNodeID(
            sourceID: String(parts[0]),
            kind: kind,
            normalizedRelativePath: String(parts[2])
        )
    }
}

/// 收藏不再有数量上限：存多少读多少。读的时候认不出类型的条目（更新的版本存下的）
/// 跳过，不让整份收藏因为一条读不懂就退回默认。
public enum QuickAccessPinStorageCodec {
    private struct Envelope: Encodable {
        let version: Int
        let pins: [QuickAccessPinReference]
    }

    private struct StoredEnvelope: Decodable {
        let version: Int
        let pins: [StoredPin]
    }

    private struct StoredPin: Decodable {
        let pin: QuickAccessPinReference?

        private enum CodingKeys: String, CodingKey { case kind, itemID }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = (try? container.decode(String.self, forKey: .kind)).flatMap(QuickAccessPinKind.init(rawValue:))
            let itemID = try? container.decode(String.self, forKey: .itemID)
            if let kind, let itemID {
                pin = QuickAccessPinReference(kind: kind, itemID: itemID)
            } else {
                pin = nil
            }
        }
    }

    public static func decode(
        _ rawValue: String,
        defaultPins: [QuickAccessPinReference]
    ) -> [QuickAccessPinReference] {
        guard !rawValue.isEmpty, let data = rawValue.data(using: .utf8) else {
            return normalized(defaultPins)
        }

        if let envelope = try? JSONDecoder().decode(StoredEnvelope.self, from: data),
           envelope.version >= 2 {
            return normalized(envelope.pins.compactMap(\.pin))
        }

        if let legacyPins = try? JSONDecoder().decode([StoredPin].self, from: data) {
            return normalized(defaultPins + legacyPins.compactMap(\.pin))
        }

        return normalized(defaultPins)
    }

    public static func encode(_ pins: [QuickAccessPinReference]) -> String {
        let envelope = Envelope(version: 2, pins: normalized(pins))
        guard let data = try? JSONEncoder().encode(envelope) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalized(_ pins: [QuickAccessPinReference]) -> [QuickAccessPinReference] {
        var seen = Set<QuickAccessPinReference>()
        return pins.filter { seen.insert($0).inserted }
    }
}

extension QuickAccessPinReference {
    /// 由 `id`（「类型:条目 id」）还原。条目 id 里自己也可能带冒号（有声书的书 id），只按第一个拆。
    public init?(id: String) {
        guard let colon = id.firstIndex(of: ":"),
              let kind = QuickAccessPinKind(rawValue: String(id[..<colon])) else { return nil }
        self.init(kind: kind, itemID: String(id[id.index(after: colon)...]))
    }
}
