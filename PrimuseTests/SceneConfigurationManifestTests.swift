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
}
