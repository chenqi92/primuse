import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

/// App 代理自己配主窗口场景之后,CarPlay 与外接屏仍要拿到 Info.plist 里登记的那份配置。
@MainActor
final class SceneConfigurationManifestTests: XCTestCase {
    func testCarPlayAndExternalDisplayResolveTheirManifestConfigurations() {
        let carPlay = UISceneSession.Role(rawValue: "CPTemplateApplicationSceneSessionRoleApplication")
        XCTAssertEqual(PrimuseAppDelegate.manifestConfigurationName(for: carPlay), "CarPlay")
        XCTAssertEqual(
            PrimuseAppDelegate.manifestConfigurationName(for: .windowExternalDisplayNonInteractive),
            "ExternalDisplay"
        )
        XCTAssertNil(PrimuseAppDelegate.manifestConfigurationName(for: .windowApplication))
    }

    func testExternalDisplayNowPlayingRendersInIndependentWindow() async throws {
        try await renderExternalDisplay(mode: .nowPlaying)
    }

    func testExternalDisplayImmersiveRendersInIndependentWindow() async throws {
        try await renderExternalDisplay(mode: .immersive)
    }

    private func renderExternalDisplay(mode: ExternalDisplayContentMode) async throws {
        let defaults = UserDefaults.standard
        let modeKey = ExternalDisplayContentMode.storageKey
        let previousMode = defaults.object(forKey: modeKey)
        defaults.set(mode.rawValue, forKey: modeKey)
        defer { defaults.set(previousMode, forKey: modeKey) }
        XCTAssertEqual(ExternalDisplayPreferences.shared.mode, mode)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let appeared = expectation(description: "External display content appeared")
        let host = UIHostingController(rootView: ExternalDisplaySceneContent()
            .onAppear { appeared.fulfill() })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        await fulfillment(of: [appeared], timeout: 5)
    }
}
