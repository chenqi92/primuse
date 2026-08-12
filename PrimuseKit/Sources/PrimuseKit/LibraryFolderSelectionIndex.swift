import Foundation

public enum LibraryFolderSelectionState: Equatable, Sendable {
    case none
    case partial
    case all

    public init(selectedCount: Int, songCount: Int) {
        guard songCount > 0, selectedCount > 0 else {
            self = .none
            return
        }
        self = selectedCount >= songCount ? .all : .partial
    }
}

public struct LibraryFolderSelectionVersion: Hashable, Sendable {
    public let folderRevision: Int
    public let rowOrderRevision: Int

    public init(folderRevision: Int, rowOrderRevision: Int) {
        self.folderRevision = folderRevision
        self.rowOrderRevision = rowOrderRevision
    }
}

public struct LibraryFolderSelectionSnapshot: Equatable, Sendable {
    public let nodeID: LibraryFolderNodeID
    public let version: LibraryFolderSelectionVersion
    public let selectedCount: Int
    public let songCount: Int

    public var state: LibraryFolderSelectionState {
        LibraryFolderSelectionState(
            selectedCount: selectedCount,
            songCount: songCount
        )
    }
}

/// Tracks the selection count of registered folder scopes incrementally.
/// Folder rows register their descendant IDs once per immutable folder/list
/// version. Later song-selection changes touch only groups that contain a
/// changed ID, so rendering a large folder never rescans all of its songs.
public struct LibraryFolderSelectionIndex: Sendable {
    private struct Group: Sendable {
        let version: LibraryFolderSelectionVersion
        let songIDs: Set<String>
        var selectedCount: Int
    }

    private var groupsByNodeID: [LibraryFolderNodeID: Group] = [:]
    private var nodeIDsBySongID: [String: Set<LibraryFolderNodeID>] = [:]

    public init() {}

    public mutating func register(
        nodeID: LibraryFolderNodeID,
        version: LibraryFolderSelectionVersion,
        songIDs: [String],
        selectedSongIDs: Set<String>
    ) -> LibraryFolderSelectionSnapshot {
        if let existing = groupsByNodeID[nodeID], existing.version == version {
            return snapshot(nodeID: nodeID, group: existing)
        }

        if let existing = groupsByNodeID[nodeID] {
            unregister(nodeID: nodeID, songIDs: existing.songIDs)
        }

        let uniqueSongIDs = Set(songIDs)
        let selectedCount = uniqueSongIDs.reduce(into: 0) { count, songID in
            if selectedSongIDs.contains(songID) {
                count += 1
            }
        }
        let group = Group(
            version: version,
            songIDs: uniqueSongIDs,
            selectedCount: selectedCount
        )
        groupsByNodeID[nodeID] = group
        for songID in uniqueSongIDs {
            nodeIDsBySongID[songID, default: []].insert(nodeID)
        }
        return snapshot(nodeID: nodeID, group: group)
    }

    public mutating func selectionDidChange(
        changedSongIDs: Set<String>,
        selectedSongIDs: Set<String>
    ) -> [LibraryFolderSelectionSnapshot] {
        guard !changedSongIDs.isEmpty, !groupsByNodeID.isEmpty else { return [] }

        var deltasByNodeID: [LibraryFolderNodeID: Int] = [:]
        for songID in changedSongIDs {
            let delta = selectedSongIDs.contains(songID) ? 1 : -1
            for nodeID in nodeIDsBySongID[songID] ?? [] {
                deltasByNodeID[nodeID, default: 0] += delta
            }
        }

        var snapshots: [LibraryFolderSelectionSnapshot] = []
        snapshots.reserveCapacity(deltasByNodeID.count)
        for (nodeID, delta) in deltasByNodeID {
            guard var group = groupsByNodeID[nodeID] else { continue }
            group.selectedCount = min(
                group.songIDs.count,
                max(0, group.selectedCount + delta)
            )
            groupsByNodeID[nodeID] = group
            snapshots.append(snapshot(nodeID: nodeID, group: group))
        }
        return snapshots
    }

    private func snapshot(
        nodeID: LibraryFolderNodeID,
        group: Group
    ) -> LibraryFolderSelectionSnapshot {
        LibraryFolderSelectionSnapshot(
            nodeID: nodeID,
            version: group.version,
            selectedCount: group.selectedCount,
            songCount: group.songIDs.count
        )
    }

    private mutating func unregister(
        nodeID: LibraryFolderNodeID,
        songIDs: Set<String>
    ) {
        for songID in songIDs {
            guard var nodeIDs = nodeIDsBySongID[songID] else { continue }
            nodeIDs.remove(nodeID)
            if nodeIDs.isEmpty {
                nodeIDsBySongID.removeValue(forKey: songID)
            } else {
                nodeIDsBySongID[songID] = nodeIDs
            }
        }
    }
}
