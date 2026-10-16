import Foundation

/// What is kept by book id, carried over when the library gives a book a new
/// one (`SpokenWordBookGrouping.renamedBookIDs(from:to:)`).
///
/// A book's id follows its grouping. Most often it changes when the first
/// tags are read: a folder of untagged files is a book named after the folder
/// until the backfill reads the album off one chapter, and the whole folder
/// joins that album's book. Speed, archive, favourite, shelf order, home
/// picks and offline downloads set before then are all under the old id.
///
/// Two ways to carry them:
/// - Settings kept on this device only move: the new id takes the old one's
///   place.
/// - Settings synced through iCloud are copied, and the old id keeps its own:
///   another device that has not read the tags yet still groups the book the
///   old way, and a removal synced from here would take its setting away
///   there. Where the new id has a setting of its own, the newer one stands,
///   as in any merge, so every device carrying the same renames reaches the
///   same state, whichever does it first.
public enum SpokenWordBookRenames {
    /// `ids` (an order kept by book id) with each renamed book where its old
    /// id stood. A new id already in the list keeps its own place, and two
    /// old ids that went to one book leave it at the first of their places.
    /// `keepingOldIDs` keeps the old id in front of the new one.
    public static func carrying(
        _ ids: [String],
        renames: [String: String],
        keepingOldIDs: Bool = false
    ) -> [String] {
        guard !renames.isEmpty else { return ids }
        let present = Set(ids)
        var seen = Set<String>()
        var result: [String] = []
        for id in ids {
            guard let newID = renames[id] else {
                if seen.insert(id).inserted { result.append(id) }
                continue
            }
            if keepingOldIDs, seen.insert(id).inserted { result.append(id) }
            if !present.contains(newID), seen.insert(newID).inserted { result.append(newID) }
        }
        return result
    }

    /// `history` (old id → new id, from earlier regroupings) with `renames`
    /// added, so an id something still holds (a widget, a timer) finds its
    /// book. The new ids are current, so entries starting at one go (a book
    /// renamed back stays unambiguous), and entries ending at an old id skip
    /// ahead to its new one. Past `limit` only the latest renames are kept.
    public static func recording(
        _ renames: [String: String],
        into history: [String: String],
        limit: Int = 512
    ) -> [String: String] {
        guard !renames.isEmpty else { return history }
        var next = history
        for newID in renames.values { next.removeValue(forKey: newID) }
        for (id, target) in next {
            if let newID = renames[target] { next[id] = newID }
        }
        next.merge(renames) { _, latest in latest }
        return next.count > limit ? renames : next
    }

    /// The id `id`'s book goes by now, following `history`.
    public static func currentID(for id: String, in history: [String: String]) -> String {
        history[id] ?? id
    }

    /// The new id's register after carrying the old ids' registers onto it:
    /// the newest of them all, its own included. Nil when nothing is to be
    /// written — a removal is only carried onto a register the new id has,
    /// since it adds nothing to a book with no setting.
    static func carriedRegister<Register>(
        own: Register?,
        carried: [Register],
        isRemoval: (Register) -> Bool,
        winner: (Register, Register) -> Register
    ) -> Register? {
        guard let first = carried.first else { return nil }
        let newest = carried.dropFirst().reduce(own.map { winner($0, first) } ?? first, winner)
        if own == nil, isRemoval(newest) { return nil }
        return newest
    }

    /// Old ids grouped by the new id they went to, both in a fixed order.
    static func oldIDsByNewID(_ renames: [String: String]) -> [(newID: String, oldIDs: [String])] {
        var grouped: [String: [String]] = [:]
        for (oldID, newID) in renames { grouped[newID, default: []].append(oldID) }
        return grouped.keys.sorted().map { ($0, grouped[$0, default: []].sorted()) }
    }
}

extension SpokenWordSyncPolicy {
    /// `state` with each renamed book's speed and archive mark also under its
    /// new id (see `SpokenWordBookRenames`): the old id keeps its registers,
    /// and the newer register stands where the new id has one too.
    public static func carryingBookState(
        _ state: SpokenWordSyncState,
        renames: [String: String]
    ) -> SpokenWordSyncState {
        var next = state
        for (newID, oldIDs) in SpokenWordBookRenames.oldIDsByNewID(renames) {
            if let rate = SpokenWordBookRenames.carriedRegister(
                own: state.rates[newID],
                carried: oldIDs.compactMap { state.rates[$0] },
                isRemoval: \.isTombstone,
                winner: { winner($0, $1) }
            ) {
                next.rates[newID] = rate
            }
            if let archived = SpokenWordBookRenames.carriedRegister(
                own: state.archived[newID],
                carried: oldIDs.compactMap { state.archived[$0] },
                isRemoval: \.isTombstone,
                winner: { winner($0, $1) }
            ) {
                next.archived[newID] = archived
            }
        }
        return next
    }
}

extension FavoriteCollectionSyncPolicy {
    /// `state` with each renamed favourite (`QuickAccessPinReference.id`,
    /// old → new) also collected under its new id when the newest decision
    /// says so, and placed right after the old id in the synced order. The
    /// order keeps its stamp: every device carrying the same renames writes
    /// the same order, and a longer order wins a tie, so the carried one
    /// spreads without overriding an order the listener set since.
    public static func carryingMembership(
        _ state: FavoriteCollectionSyncState,
        renames: [String: String]
    ) -> FavoriteCollectionSyncState {
        var next = state
        var collectedRenames: [String: String] = [:]
        for (newID, oldIDs) in SpokenWordBookRenames.oldIDsByNewID(renames) {
            guard let member = SpokenWordBookRenames.carriedRegister(
                own: state.members[newID],
                carried: oldIDs.compactMap { state.members[$0] },
                isRemoval: { !$0.isCollected },
                winner: { winner($0, $1) }
            ) else { continue }
            next.members[newID] = member
            if member.isCollected {
                for oldID in oldIDs { collectedRenames[oldID] = newID }
            }
        }
        if let order = state.order {
            let ids = SpokenWordBookRenames.carrying(order.ids, renames: collectedRenames, keepingOldIDs: true)
            if ids != order.ids { next.order = .init(ids: ids, stamp: order.stamp) }
        }
        return next
    }
}

extension AudiobookOfflinePolicy {
    /// Books kept offline, each renamed book under its new id. Kept on this
    /// device only, so the old id goes; a new id kept offline already keeps
    /// its title and takes the old one's chapters too.
    public static func carrying(_ records: [String: Record], renames: [String: String]) -> [String: Record] {
        var next = records
        for oldID in renames.keys.sorted() {
            guard let newID = renames[oldID], let record = next.removeValue(forKey: oldID) else { continue }
            if var existing = next[newID] {
                existing.songIDs = Array(Set(existing.songIDs).union(record.songIDs)).sorted()
                next[newID] = existing
            } else {
                next[newID] = record
            }
        }
        return next
    }
}
