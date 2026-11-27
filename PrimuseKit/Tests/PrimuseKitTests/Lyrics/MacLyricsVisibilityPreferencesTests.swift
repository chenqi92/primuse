import Foundation
import Testing
@testable import PrimuseKit

@Suite("Independent Mac lyrics visibility")
struct MacLyricsVisibilityPreferencesTests {
    @Test("Legacy users keep exactly the lyrics surface they had visible",
          arguments: [false, true], [false, true])
    func migratesLegacyVisibility(wasVisible: Bool, usedIsland: Bool) throws {
        try withDefaults { defaults in
            defaults.set(wasVisible, forKey: MacLyricsVisibilityPreferences.desktopKey)
            defaults.set(usedIsland, forKey: MacLyricsVisibilityPreferences.islandKey)
            let visibility = MacLyricsVisibilityPreferences.restore(in: defaults)
            #expect(visibility.desktop == (wasVisible && !usedIsland))
            #expect(visibility.island == (wasVisible && usedIsland))
        }
    }

    @Test("Either surface can close without hiding the other")
    func independentVisibility() throws {
        try withDefaults { defaults in
            _ = MacLyricsVisibilityPreferences.restore(in: defaults)
            MacLyricsVisibilityPreferences.setDesktopVisible(true, in: defaults)
            MacLyricsVisibilityPreferences.setIslandVisible(true, in: defaults)
            #expect(MacLyricsVisibilityPreferences.visibility(in: defaults).desktop)
            #expect(MacLyricsVisibilityPreferences.visibility(in: defaults).island)

            MacLyricsVisibilityPreferences.setDesktopVisible(false, in: defaults)
            #expect(!MacLyricsVisibilityPreferences.visibility(in: defaults).desktop)
            #expect(MacLyricsVisibilityPreferences.visibility(in: defaults).island)

            MacLyricsVisibilityPreferences.setDesktopVisible(true, in: defaults)
            MacLyricsVisibilityPreferences.setIslandVisible(false, in: defaults)
            #expect(MacLyricsVisibilityPreferences.visibility(in: defaults).desktop)
            #expect(!MacLyricsVisibilityPreferences.visibility(in: defaults).island)
        }
    }

    @Test("Relaunch restores both surfaces without repeating the legacy migration")
    func migrationRunsOnce() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: MacLyricsVisibilityPreferences.desktopKey)
            defaults.set(true, forKey: MacLyricsVisibilityPreferences.islandKey)
            _ = MacLyricsVisibilityPreferences.restore(in: defaults)
            MacLyricsVisibilityPreferences.setDesktopVisible(true, in: defaults)
            let restored = MacLyricsVisibilityPreferences.restore(in: defaults)
            #expect(restored.desktop && restored.island)
            MacLyricsVisibilityPreferences.setIslandVisible(false, in: defaults)
            let desktopOnly = MacLyricsVisibilityPreferences.restore(in: defaults)
            #expect(desktopOnly.desktop && !desktopOnly.island)
        }
    }

    @Test("An early visibility change migrates old preferences before changing one surface")
    func settersBeforeRestore() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: MacLyricsVisibilityPreferences.desktopKey)
            defaults.set(false, forKey: MacLyricsVisibilityPreferences.islandKey)
            MacLyricsVisibilityPreferences.setIslandVisible(true, in: defaults)
            let restored = MacLyricsVisibilityPreferences.restore(in: defaults)
            #expect(restored.desktop && restored.island)
        }
        try withDefaults { defaults in
            defaults.set(true, forKey: MacLyricsVisibilityPreferences.desktopKey)
            defaults.set(true, forKey: MacLyricsVisibilityPreferences.islandKey)
            MacLyricsVisibilityPreferences.setDesktopVisible(true, in: defaults)
            let restored = MacLyricsVisibilityPreferences.restore(in: defaults)
            #expect(restored.desktop && restored.island)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "MacLyricsVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
