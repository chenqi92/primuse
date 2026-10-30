import Foundation

/// 分组只组织歌单引用，不修改歌单、成员或音乐源；未在本机加载的引用也保留。
public struct PlaylistGrouping: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.library.playlistGroups.v1"

    public struct Group: Codable, Identifiable, Equatable, Sendable {
        public let id: String
        public var name: String
    }

    public private(set) var groups: [Group] = []
    public private(set) var memberships: [String: String] = [:]

    public init() {}

    public static func reference(id: String, smart: Bool = false) -> String {
        (smart ? "smart:" : "playlist:") + id
    }

    public static func decode(_ rawValue: String) -> Self {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func groupID(for reference: String) -> String? {
        guard let id = memberships[reference], groups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public func acceptsName(_ name: String, replacing id: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !groups.contains {
            $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    @discardableResult
    public mutating func create(name: String) -> String? {
        guard acceptsName(name) else { return nil }
        let group = Group(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        groups.append(group)
        return group.id
    }

    public mutating func rename(id: String, name: String) {
        guard acceptsName(name, replacing: id), let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func move(_ references: [String], to groupID: String?) {
        guard groupID == nil || groups.contains(where: { $0.id == groupID }) else { return }
        for reference in references { memberships[reference] = groupID }
    }

    public mutating func dissolve(id: String) {
        groups.removeAll { $0.id == id }
        memberships = memberships.filter { $0.value != id }
    }
}
