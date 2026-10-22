import Foundation
import Testing
@testable import PrimuseKit

@Suite struct ListeningDiscoveryDefaultsTests {
    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let domain = "ListeningDiscoveryDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        body(defaults, domain)
    }

    @Test(arguments: ListeningDiscoveryDefaults.Platform.allCases)
    func freshInstallShowsBothSpaces(platform: ListeningDiscoveryDefaults.Platform) {
        withDefaults { defaults, domain in
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
            defaults.register(defaults: [ListeningDiscoveryDefaults.homePodcastsKey: false])
            #expect(ListeningDiscoveryDefaults.initializeIfNeeded(platform: platform, defaults: defaults, domainName: domain))
            if platform == .tvOS {
                let tabs = TVTabBarConfiguration.decode(defaults.string(forKey: TVTabBarConfiguration.storageKey) ?? "")
                #expect(tabs.isShown(.podcasts))
                #expect(tabs.isShown(.spokenWord))
            } else {
                // Execute the real old launch migrations after the fresh-install seed.
                LibrarySectionLayoutPolicy.migrateDefaultHiddenIfNeeded(defaults: defaults)
                LibrarySectionLayoutPolicy.hideNewSectionIfNeeded("podcasts", migrationKey: ListeningDiscoveryDefaults.podcastsMigrationKey, defaults: defaults)
                let hidden = LibrarySectionLayoutPolicy.decodeNames(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) ?? "")
                #expect(hidden == (platform == .macOS ? ["recommendations"] : ["recommendations", "statistics"]))
                #expect(defaults.bool(forKey: ListeningDiscoveryDefaults.homePodcastsKey))
                #expect(defaults.bool(forKey: ListeningDiscoveryDefaults.homeAudiobooksKey))
            }
        }
    }

    @Test(arguments: ["primuse.hasSeenOnboarding", "primuse.library.defaultHiddenSections.v2", "primuse_playback_settings_v1", "pm.mac.appIcon", "tv.scannedSourceIDs", "tvAppearance"])
    func upgradeWithImplicitPreferencesDoesNotEnablePodcasts(existingKey: String) {
        for platform in ListeningDiscoveryDefaults.Platform.allCases {
            withDefaults { defaults, domain in
                defaults.set("old value", forKey: existingKey)
                let before = defaults.persistentDomain(forName: domain)!
                #expect(!ListeningDiscoveryDefaults.initializeIfNeeded(platform: platform, defaults: defaults, domainName: domain))
                var after = defaults.persistentDomain(forName: domain)!
                after.removeValue(forKey: ListeningDiscoveryDefaults.initializedKey)
                #expect(NSDictionary(dictionary: after) == NSDictionary(dictionary: before))
            }
        }
    }

    @Test(arguments: [true, false])
    func explicitChoicesAndFutureTogglesSurvive(enabled: Bool) {
        for platform in ListeningDiscoveryDefaults.Platform.allCases {
            withDefaults { defaults, domain in
                defaults.set(enabled, forKey: ListeningDiscoveryDefaults.homePodcastsKey)
                defaults.set(enabled, forKey: ListeningDiscoveryDefaults.homeAudiobooksKey)
                let hidden = LibrarySectionLayoutPolicy.encodeNames(enabled ? [] : ["spokenWord", "podcasts"])
                defaults.set(hidden, forKey: LibrarySectionLayoutPolicy.hiddenKey)
                var tabs = TVTabBarConfiguration.default
                tabs.setShown(enabled, for: .podcasts)
                tabs.setShown(enabled, for: .spokenWord)
                let savedTabs = tabs.encoded()
                defaults.set(savedTabs, forKey: TVTabBarConfiguration.storageKey)
                #expect(!ListeningDiscoveryDefaults.initializeIfNeeded(platform: platform, defaults: defaults, domainName: domain))
                #expect(defaults.string(forKey: LibrarySectionLayoutPolicy.hiddenKey) == hidden)
                #expect(defaults.string(forKey: TVTabBarConfiguration.storageKey) == savedTabs)
                #expect(defaults.bool(forKey: ListeningDiscoveryDefaults.homePodcastsKey) == enabled)
                #expect(defaults.bool(forKey: ListeningDiscoveryDefaults.homeAudiobooksKey) == enabled)
            }
        }
    }

    @Test(arguments: ListeningDiscoveryDefaults.Platform.allCases)
    func reopeningFreshInstallDoesNotResetChoices(platform: ListeningDiscoveryDefaults.Platform) {
        withDefaults { defaults, domain in
            #expect(ListeningDiscoveryDefaults.initializeIfNeeded(platform: platform, defaults: defaults, domainName: domain))
            defaults.set(false, forKey: ListeningDiscoveryDefaults.homePodcastsKey)
            defaults.set(false, forKey: ListeningDiscoveryDefaults.homeAudiobooksKey)
            defaults.set("[\"podcasts\",\"spokenWord\"]", forKey: LibrarySectionLayoutPolicy.hiddenKey)
            var tabs = TVTabBarConfiguration.default
            tabs.setShown(false, for: .podcasts)
            tabs.setShown(false, for: .spokenWord)
            defaults.set(tabs.encoded(), forKey: TVTabBarConfiguration.storageKey)
            let before = defaults.persistentDomain(forName: domain)!
            #expect(!ListeningDiscoveryDefaults.initializeIfNeeded(platform: platform, defaults: defaults, domainName: domain))
            #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!) == NSDictionary(dictionary: before))
        }
    }
}
