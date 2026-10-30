#if os(iOS) || os(tvOS)
import UIKit
import XCTest
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

@MainActor
final class AppIconServiceTests: XCTestCase {
    func testEasterEggRequiresSevenConsecutiveTapsAndResetsAfterOpening() {
        var trigger = AppIconEasterEggTrigger()
        for tap in 0..<6 { XCTAssertFalse(trigger.recordTap(at: Double(tap) * 0.2)) }
        XCTAssertTrue(trigger.recordTap(at: 1.2))
        XCTAssertFalse(trigger.recordTap(at: 1.4))
        for tap in 0..<5 { XCTAssertFalse(trigger.recordTap(at: 2 + Double(tap) * 0.2)) }
        XCTAssertFalse(trigger.recordTap(at: 5))
        for tap in 1..<6 { XCTAssertFalse(trigger.recordTap(at: 5 + Double(tap) * 0.2)) }
        XCTAssertTrue(trigger.recordTap(at: 6.2))
    }

    func testHiddenIconCanBeSelectedRestoredAndReplacedWithoutEnteringRegularCatalog() async throws {
        let system = IconSystem()
        let (service, defaults) = try fixture(system)
        let hidden = try XCTUnwrap(service.hiddenOptions.first)
        XCTAssertFalse(service.options.contains(hidden))
        XCTAssertFalse(hidden.supportsAppearance)
        let selected = await service.setIcon(hidden)
        XCTAssertTrue(selected)
        XCTAssertEqual(system.current, hidden.alternateName)
        let (restored, _) = try fixture(system, stored: try XCTUnwrap(defaults.string(forKey: AppIconService.storageKey)))
        XCTAssertEqual(restored.currentIconID, hidden.id)
        await restored.restorePrimaryIconIfNeeded()
        XCTAssertEqual(system.requested.count, 1)
        XCTAssertEqual(restored.currentIconID, hidden.id)
        XCTAssertFalse(restored.options.contains(hidden))
        let replaced = await restored.setIcon(restored.options[0])
        XCTAssertTrue(replaced)
        XCTAssertNil(system.current)
    }

    func testFailedHiddenIconChangeRetainsPreviousSelection() async throws {
        let system = IconSystem()
        system.current = "AppIcon19"
        system.failure = NSError(domain: NSCocoaErrorDomain, code: 1)
        let (service, defaults) = try fixture(system, stored: "AppIcon19")
        let selected = await service.setIcon(try XCTUnwrap(service.hiddenOptions.first))
        XCTAssertFalse(selected)
        XCTAssertEqual(service.currentIconID, "AppIcon19")
        XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "AppIcon19")
    }
    @MainActor
    private final class IconSystem {
        var current: String?
        var requested: [String?] = []
        var failure: Error?

        func change(to name: String?) async throws {
            requested.append(name)
            if let failure { throw failure }
            current = name
        }
    }

    private func fixture(_ system: IconSystem, stored: String = "") throws -> (AppIconService, UserDefaults) {
        let suite = "AppIconServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(stored, forKey: AppIconService.storageKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = AppIconService(defaults: defaults, supportsIcons: { true },
                                     liveIconName: { system.current }, changeIcon: { try await system.change(to: $0) })
        return (service, defaults)
    }

    func testRetiredSelectionResetsTheSystemIconOnActivation() async throws {
        for retired in ["AppIcon21", "AppIcon14"] {
            let system = IconSystem()
            system.current = retired
            let (service, defaults) = try fixture(system, stored: retired)
            XCTAssertFalse(service.options.contains { $0.id == retired })
            XCTAssertEqual(service.currentIconID, "")
            await service.restorePrimaryIconIfNeeded()
            XCTAssertNil(system.current)
            XCTAssertEqual(system.requested.count, 1)
            XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "")
        }
    }

    func testFailedChangeKeepsTheActualIconAndCanBeRetried() async throws {
        let system = IconSystem()
        system.current = "AppIcon19"
        system.failure = NSError(domain: NSCocoaErrorDomain, code: 1)
        let (service, defaults) = try fixture(system, stored: "AppIcon19")
        let target = try XCTUnwrap(service.options.first { $0.id == "AppIcon20" })
        let failed = await service.setIcon(target)
        XCTAssertFalse(failed)
        XCTAssertEqual(service.currentIconID, "AppIcon19")
        XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "AppIcon19")
        XCTAssertNotNil(service.lastError)
        XCTAssertFalse(service.isChangingIcon)

        system.failure = nil
        let succeeded = await service.setIcon(target)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(system.current, "AppIcon20")
        XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "AppIcon20")
        XCTAssertNil(service.lastError)
    }

    func testActivationReconcilesWithSystemAndAvoidsRedundantChanges() async throws {
        let system = IconSystem()
        system.current = "AppIcon16"
        let (service, defaults) = try fixture(system, stored: "AppIcon19")
        await service.restorePrimaryIconIfNeeded()
        XCTAssertEqual(service.currentIconID, "AppIcon16")
        XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "AppIcon16")
        let option = try XCTUnwrap(service.options.first { $0.id == "AppIcon16" })
        let succeeded = await service.setIcon(option)
        XCTAssertTrue(succeeded)
        XCTAssertTrue(system.requested.isEmpty)
        let restored = await service.setIcon(service.options[0])
        XCTAssertTrue(restored)
        XCTAssertNil(system.current)
        XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "")
    }

    func testConcurrentChangesCannotOverwriteAnInFlightChoice() async throws {
        let defaults = try fixture(IconSystem()).1
        var finish: CheckedContinuation<Void, Never>?
        var current: String?
        let service = AppIconService(defaults: defaults, supportsIcons: { true }, liveIconName: { current }) { name in
            await withCheckedContinuation { finish = $0 }
            current = name
        }
        let first = Task { await service.setIcon(service.options[1]) }
        while finish == nil { await Task.yield() }
        XCTAssertTrue(service.isChangingIcon)
        XCTAssertEqual(defaults.string(forKey: AppIconService.storageKey), "")
        let second = await service.setIcon(service.options[2])
        XCTAssertFalse(second)
        finish?.resume()
        let succeeded = await first.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(service.currentIconID, service.options[1].id)
    }

    func testEverySelectableIconIsBundledAndRetiredIconsAreAbsent() throws {
        let service = try fixture(IconSystem()).0
        let bundleIcons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        #if os(tvOS)
        let names = try XCTUnwrap(bundleIcons["CFBundleAlternateIcons"] as? [String])
        #else
        let names = Array(try XCTUnwrap(bundleIcons["CFBundleAlternateIcons"] as? [String: Any]).keys)
        #endif
        XCTAssertEqual(Set(names), Set(service.availableOptions.compactMap(\.alternateName)))
        XCTAssertFalse(names.contains("AppIcon21"))
        XCTAssertFalse(names.contains("AppIcon14"))
        for option in service.availableOptions {
            XCTAssertNotNil(UIImage(named: option.previewAsset), option.id)
            #if os(tvOS)
            let name = option.id.isEmpty ? "AppIcon" : option.id
            XCTAssertNotNil(UIImage(named: name + "TVPreview"), name)
            XCTAssertNotNil(UIImage(named: name + "Mark"), name)
            #endif
        }
    }

}
#endif
