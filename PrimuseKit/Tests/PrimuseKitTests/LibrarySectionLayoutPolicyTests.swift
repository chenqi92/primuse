import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library section order, default-hidden sections and the upgrade rule")
struct LibrarySectionLayoutPolicyTests {
    private let defaultOrder = [
        "favorites", "songs", "albums", "artists", "genres", "folders", "releaseDate",
        "playlists", "radio", "spokenWord", "recommendations", "statistics",
    ]
    private let defaultHidden: Set<String> = ["recommendations", "statistics"]
    private let known: (String) -> String? = { $0 == "retired" ? nil : $0 }

    @Test("Nothing stored follows the default order")
    func emptyStorageUsesDefaultOrder() {
        #expect(LibrarySectionLayoutPolicy.completedOrder([], defaultOrder: defaultOrder) == defaultOrder)
    }

    @Test("A new section lands next to its default neighbour, not at the front")
    func newSectionFollowsItsNeighbour() {
        // The previous default, saved after a drag: recommendations first, no releaseDate yet.
        let stored = [
            "recommendations", "favorites", "songs", "spokenWord", "albums", "artists",
            "genres", "playlists", "folders", "radio", "statistics",
        ]
        let order = LibrarySectionLayoutPolicy.completedOrder(stored, defaultOrder: defaultOrder)
        #expect(order == [
            "recommendations", "favorites", "songs", "spokenWord", "albums", "artists",
            "genres", "playlists", "folders", "releaseDate", "radio", "statistics",
        ])
        // Everything the user arranged keeps its relative order.
        #expect(order.filter(stored.contains) == stored)
    }

    @Test("Duplicates and unknown names are dropped; every section appears once")
    func storedOrderIsNormalised() {
        let order = LibrarySectionLayoutPolicy.completedOrder(
            ["songs", "songs", "retired", "radio"],
            defaultOrder: defaultOrder
        )
        #expect(Set(order) == Set(defaultOrder))
        #expect(order.count == defaultOrder.count)
        #expect(!order.contains("retired"))
        #expect(order.firstIndex(of: "songs")! < order.firstIndex(of: "radio")!)
    }

    @Test("A section whose default neighbours are all missing goes first")
    func sectionWithoutAnchorGoesFirst() {
        let order = LibrarySectionLayoutPolicy.completedOrder(["radio"], defaultOrder: ["favorites", "radio"])
        #expect(order == ["favorites", "radio"])
    }

    @Test("Never-set visibility uses the default hidden sections; any stored value wins")
    func hiddenResolution() {
        #expect(LibrarySectionLayoutPolicy.hidden(rawValue: "", defaultHidden: defaultHidden, section: known) == defaultHidden)
        #expect(LibrarySectionLayoutPolicy.hidden(rawValue: "[]", defaultHidden: defaultHidden, section: known).isEmpty)
        #expect(
            LibrarySectionLayoutPolicy.hidden(
                rawValue: #"["favorites","retired"]"#, defaultHidden: defaultHidden, section: known
            ) == ["favorites"]
        )
        // A damaged value is treated like an unset one rather than showing everything.
        #expect(LibrarySectionLayoutPolicy.hidden(rawValue: "{", defaultHidden: defaultHidden, section: known) == defaultHidden)
        #expect(LibrarySectionLayoutPolicy.storedHidden("", section: known) == nil)
    }

    @Test("Upgrading keeps everything visible only for people who arranged the library but never hid anything")
    func upgradeRule() {
        // Rearranged, never hid anything: the old empty value meant "show all".
        #expect(LibrarySectionLayoutPolicy.upgradeAction(
            storedOrderRawValue: #"["songs","albums"]"#, storedHiddenRawValue: nil, alreadyMigrated: false
        ) == .keepEverythingVisible)
        #expect(LibrarySectionLayoutPolicy.upgradeAction(
            storedOrderRawValue: #"["songs","albums"]"#, storedHiddenRawValue: "", alreadyMigrated: false
        ) == .keepEverythingVisible)
        // Already chose what to hide: untouched.
        #expect(LibrarySectionLayoutPolicy.upgradeAction(
            storedOrderRawValue: #"["songs"]"#, storedHiddenRawValue: #"["radio"]"#, alreadyMigrated: false
        ) == .none)
        #expect(LibrarySectionLayoutPolicy.upgradeAction(
            storedOrderRawValue: nil, storedHiddenRawValue: "[]", alreadyMigrated: false
        ) == .none)
        // Fresh install or never customised: the new defaults apply.
        #expect(LibrarySectionLayoutPolicy.upgradeAction(
            storedOrderRawValue: nil, storedHiddenRawValue: nil, alreadyMigrated: false
        ) == .none)
        // Runs once: someone who installs the new version and later drags the order keeps the defaults.
        #expect(LibrarySectionLayoutPolicy.upgradeAction(
            storedOrderRawValue: #"["songs"]"#, storedHiddenRawValue: nil, alreadyMigrated: true
        ) == .none)
    }

    @Test("The migration writes the visible-everything state once and marks itself done")
    func migrationOnUserDefaults() throws {
        let suite = "LibrarySectionLayoutPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(#"["albums","songs"]"#, forKey: LibrarySectionLayoutPolicy.orderKey)
        let first = LibrarySectionLayoutPolicy.migrateDefaultHiddenIfNeeded(defaults: defaults)
        #expect(first == .keepEverythingVisible)
        #expect(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) == "[]")
        #expect(defaults.bool(forKey: LibrarySectionLayoutPolicy.defaultHiddenMigrationKey))

        defaults.removeObject(forKey: LibrarySectionLayoutPolicy.hiddenKey)
        let second = LibrarySectionLayoutPolicy.migrateDefaultHiddenIfNeeded(defaults: defaults)
        #expect(second == .none)
        #expect(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) == nil)
    }

    @Test("A fresh install is marked migrated without writing anything")
    func freshInstallMigration() throws {
        let suite = "LibrarySectionLayoutPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let action = LibrarySectionLayoutPolicy.migrateDefaultHiddenIfNeeded(defaults: defaults)
        #expect(action == .none)
        #expect(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) == nil)
        #expect(defaults.bool(forKey: LibrarySectionLayoutPolicy.defaultHiddenMigrationKey))
    }

    @Test("A section added later as hidden joins a stored hidden set once")
    func newDefaultHiddenSection() throws {
        #expect(LibrarySectionLayoutPolicy.hidingNewSection("podcasts", storedHiddenRawValue: nil, alreadyMigrated: false) == nil)
        #expect(LibrarySectionLayoutPolicy.hidingNewSection("podcasts", storedHiddenRawValue: "", alreadyMigrated: false) == nil)
        #expect(LibrarySectionLayoutPolicy.hidingNewSection("podcasts", storedHiddenRawValue: "[]", alreadyMigrated: false) == #"["podcasts"]"#)
        #expect(LibrarySectionLayoutPolicy.hidingNewSection("podcasts", storedHiddenRawValue: #"["podcasts"]"#, alreadyMigrated: false) == nil)
        #expect(LibrarySectionLayoutPolicy.hidingNewSection("podcasts", storedHiddenRawValue: "[]", alreadyMigrated: true) == nil)

        let suite = "LibrarySectionLayoutPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(#"["statistics"]"#, forKey: LibrarySectionLayoutPolicy.hiddenKey)
        #expect(LibrarySectionLayoutPolicy.hideNewSectionIfNeeded("podcasts", migrationKey: "m", defaults: defaults))
        #expect(LibrarySectionLayoutPolicy.decodeNames(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) ?? "") == ["statistics", "podcasts"])
        // 用户之后自己把播客打开:迁移不再插手。
        defaults.set(#"["statistics"]"#, forKey: LibrarySectionLayoutPolicy.hiddenKey)
        #expect(!LibrarySectionLayoutPolicy.hideNewSectionIfNeeded("podcasts", migrationKey: "m", defaults: defaults))
        #expect(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) == #"["statistics"]"#)
    }

    @Test("Names round-trip through the stored JSON")
    func namesRoundTrip() {
        let raw = LibrarySectionLayoutPolicy.encodeNames(["songs", "releaseDate"])
        #expect(LibrarySectionLayoutPolicy.decodeNames(raw) == ["songs", "releaseDate"])
        #expect(LibrarySectionLayoutPolicy.decodeNames("") == nil)
        #expect(LibrarySectionLayoutPolicy.decodeNames("not json") == nil)
    }

    @Test("A default-hidden section with content is shown once, then left to the listener")
    func revealingASectionOnce() {
        let defaults = ["recommendations", "podcasts"]
        // Never set: written out as the defaults minus the section.
        let fromDefaults = LibrarySectionLayoutPolicy.revealingSection(
            "podcasts", storedHiddenRawValue: nil, defaultHidden: defaults, alreadyRevealed: false
        )
        #expect(fromDefaults.flatMap(LibrarySectionLayoutPolicy.decodeNames) == ["recommendations"])
        // A stored set keeps everything else the listener hid.
        let stored = LibrarySectionLayoutPolicy.encodeNames(["statistics", "podcasts"])
        let fromStored = LibrarySectionLayoutPolicy.revealingSection(
            "podcasts", storedHiddenRawValue: stored, defaultHidden: defaults, alreadyRevealed: false
        )
        #expect(fromStored.flatMap(LibrarySectionLayoutPolicy.decodeNames) == ["statistics"])
        // Already shown, or already done once: nothing to write.
        #expect(LibrarySectionLayoutPolicy.revealingSection(
            "podcasts", storedHiddenRawValue: LibrarySectionLayoutPolicy.encodeNames([]),
            defaultHidden: defaults, alreadyRevealed: false
        ) == nil)
        #expect(LibrarySectionLayoutPolicy.revealingSection(
            "podcasts", storedHiddenRawValue: stored, defaultHidden: defaults, alreadyRevealed: true
        ) == nil)
    }
}
