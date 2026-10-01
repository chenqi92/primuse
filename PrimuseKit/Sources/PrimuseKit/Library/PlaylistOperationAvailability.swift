import Foundation

public struct PlaylistOperationAvailability: Equatable, Sendable {
    public let supportsImport: Bool

    public static let standard = PlaylistOperationAvailability(supportsImport: true)
    public static let television = PlaylistOperationAvailability(supportsImport: false)

    public init(supportsImport: Bool) {
        self.supportsImport = supportsImport
    }
}

/// Where the songs of an imported playlist file go.
public enum PlaylistImportDestination: String, CaseIterable, Sendable, Equatable {
    case newPlaylist
    /// One of the listener's own playlists, typically the one this file was
    /// imported into last time. See `PlaylistImportMergePolicy`.
    case existingPlaylist
    /// The built-in liked list. Matched songs join what is already liked.
    case likedSongs
}

/// A liked list can be exported like any playlist, but importing it used to
/// produce an ordinary playlist: the file never said what it was. Exports now
/// carry a marker, and files written before that are recognised by the name
/// the liked list has in any of the app's languages. The result is only the
/// preselected destination; the listener confirms or changes it.
public enum PlaylistImportDestinationPolicy {
    public static let likedKindMarker = "liked"
    /// Ignored as a comment by every other M3U reader.
    public static let m3uKindDirective = "#PRIMUSE-KIND:"

    /// `hasSameNamePlaylist`: one of the listener's own playlists already has
    /// this name, so an updated copy of the same file goes into it instead of
    /// becoming a second playlist with the same name.
    public static func suggestedDestination(
        kindMarker: String?,
        playlistName: String,
        likedPlaylistNames: [String],
        hasSameNamePlaylist: Bool = false
    ) -> PlaylistImportDestination {
        let ordinary: PlaylistImportDestination = hasSameNamePlaylist ? .existingPlaylist : .newPlaylist
        if let kindMarker, !normalized(kindMarker).isEmpty {
            return normalized(kindMarker) == likedKindMarker ? .likedSongs : ordinary
        }
        let name = normalized(playlistName)
        guard !name.isEmpty else { return .newPlaylist }
        return likedPlaylistNames.contains { normalized($0) == name } ? .likedSongs : ordinary
    }

    public static func m3uKindLine(marker: String) -> String {
        m3uKindDirective + marker
    }

    public static func kindMarker(fromM3ULine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix(m3uKindDirective) else { return nil }
        let value = trimmed.dropFirst(m3uKindDirective.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// 更新过的歌单文件再导入一次时，合并进上次导入的那个歌单，而不是再建一个同名的（#174）。
///
/// 合并只往里加：原有的歌和顺序都不动，文件里删掉的歌也不会从歌单里拿走。
/// 「已经有了」按同一首歌认，不按 id 认 —— 导入时挑的是音质最好的那份，跟歌单里
/// 原来那份可能来自不同的音乐源。
///
/// 能合并进去的只有用户自己的歌单。服务端镜像、Apple Music 镜像和文件夹歌单的内容
/// 由各自的来源决定，下次同步就会被覆盖；它们重名也不算目标，由调用方事先滤掉。
public enum PlaylistImportMergePolicy {
    /// 一个可以接收合并的歌单。
    public struct Target: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let updatedAt: Date

        public init(id: String, name: String, updatedAt: Date) {
            self.id = id
            self.name = name
            self.updatedAt = updatedAt
        }
    }

    public static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        let name = PlaylistImportDestinationPolicy.normalized(lhs)
        return !name.isEmpty && name == PlaylistImportDestinationPolicy.normalized(rhs)
    }

    /// 和导入的歌单同名的目标。重复导入过几次的人会有好几个同名的，最近改过的在前，
    /// 它最可能是上次合并进去的那个。
    public static func sameNameTargets(_ targets: [Target], importedName: String) -> [Target] {
        targets
            .filter { isSameName($0.name, importedName) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 给选择器用的顺序：同名的排最前，其余保持调用方的顺序（歌单列表的顺序）。
    public static func orderedTargets(_ targets: [Target], importedName: String) -> [Target] {
        let sameName = sameNameTargets(targets, importedName: importedName)
        let sameNameIDs = Set(sameName.map(\.id))
        return sameName + targets.filter { !sameNameIDs.contains($0.id) }
    }

    /// 歌单里的一条：曲库里的歌，或置灰占位（id 带 `pending:` 前缀）。`key` 为 nil 表示
    /// 拿不到元数据（歌所在的源暂时不在库里），只能按 id 认。
    public struct Member: Sendable, Equatable {
        public let id: String
        public let key: ExternalTrackMatchPolicy.Key?

        public init(id: String, key: ExternalTrackMatchPolicy.Key?) {
            self.id = id
            self.key = key
        }

        public var isPending: Bool { PlaylistPendingEntry.isPendingID(id) }
    }

    public struct Plan: Sendable, Equatable {
        /// 合并后的完整成员，按歌单顺序。
        public var memberIDs: [String]
        /// 接在末尾的歌。
        public var appendedSongCount = 0
        /// 接在末尾的置灰占位。调用方要把它们的元数据登记进占位表。
        public var appendedPendingIDs: [String] = []
        /// 原来置灰、这次导入的歌对上了，原位换成歌的条数。
        public var resolvedPendingCount = 0
        /// 歌单里已经有了而没有再加的条数。
        public var alreadyPresentCount = 0

        public var hasChanges: Bool {
            appendedSongCount > 0 || !appendedPendingIDs.isEmpty || resolvedPendingCount > 0
        }
    }

    /// 怎么算「已经有了」：
    /// - 歌对歌：同一个 id，或规则判为「就是它」（别的源里的同一首）。只是「可能是」的
    ///   不算 —— 现场版、另一个版本照样加进去。
    /// - 置灰占位：歌单里有「可能是」它的歌或占位就不再加。它本来就是灰的、点不了，
    ///   多一条只是重复；上次导入时用户亲手确认成某首歌的，这次又会以占位的样子回来。
    /// - 导入的歌正好是歌单里某条占位（「就是它」）：原位点亮，不再接到末尾。
    public static func plan(existing: [Member], incoming: [Member]) -> Plan {
        var plan = Plan(memberIDs: existing.map(\.id))
        var presentIDs = Set(plan.memberIDs)
        var buckets: [String: [Slot]] = [:]

        func register(_ key: ExternalTrackMatchPolicy.Key?, at position: Int, isPending: Bool) {
            guard let key, key.isMatchable else { return }
            buckets[key.coreTitle, default: []].append(Slot(position: position, key: key, isPending: isPending))
        }

        func append(_ member: Member) {
            register(member.key, at: plan.memberIDs.count, isPending: member.isPending)
            plan.memberIDs.append(member.id)
            if member.isPending {
                plan.appendedPendingIDs.append(member.id)
            } else {
                plan.appendedSongCount += 1
            }
        }

        for (position, member) in existing.enumerated() {
            register(member.key, at: position, isPending: member.isPending)
        }

        for member in incoming {
            guard presentIDs.insert(member.id).inserted else {
                plan.alreadyPresentCount += 1
                continue
            }
            guard let key = member.key, key.isMatchable else {
                append(member)
                continue
            }
            let slots = buckets[key.coreTitle] ?? []
            if member.isPending {
                let duplicate = slots.contains {
                    $0.key == key || ExternalTrackMatchPolicy.verdict(key, $0.key) >= .probable
                }
                if duplicate {
                    plan.alreadyPresentCount += 1
                } else {
                    append(member)
                }
                continue
            }
            if slots.contains(where: { !$0.isPending && ExternalTrackMatchPolicy.verdict(key, $0.key) == .confident }) {
                plan.alreadyPresentCount += 1
                continue
            }
            if let slot = slots.firstIndex(where: {
                $0.isPending && ExternalTrackMatchPolicy.verdict(key, $0.key) == .confident
            }) {
                let position = slots[slot].position
                plan.memberIDs[position] = member.id
                buckets[key.coreTitle]?[slot] = Slot(position: position, key: key, isPending: false)
                plan.resolvedPendingCount += 1
                continue
            }
            append(member)
        }
        return plan
    }

    private struct Slot {
        let position: Int
        let key: ExternalTrackMatchPolicy.Key
        let isPending: Bool
    }
}
