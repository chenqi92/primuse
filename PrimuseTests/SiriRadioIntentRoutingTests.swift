#if os(iOS)
import Intents
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class SiriRadioIntentRoutingTests: XCTestCase {
    func testAppBundleDeclaresBothMediaIntentsForColdLaunch() {
        let supported = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "INIntentsSupported") as? [String]

        XCTAssertEqual(
            Set(supported ?? []),
            Set(["INPlayMediaIntent", "INSearchForMediaIntent"])
        )
    }

    /// 系统最多认三个 Siri 别名,多一个整个 App 就装不上(installd 直接拒绝)。
    func testAppBundleDeclaresAtMostThreeAlternativeAppNames() {
        let names = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "INAlternativeAppNames") as? [[String: Any]]

        XCTAssertNotNil(names)
        XCTAssertLessThanOrEqual(names?.count ?? 0, 3)
    }

    func testColdAppDelegateRoutesMediaSearchToTheRadioCapableHandler() {
        let delegate = PrimuseAppDelegate()
        let intent = INSearchForMediaIntent(mediaItems: nil, mediaSearch: nil)

        let handler = delegate.application(UIApplication.shared, handlerFor: intent)

        XCTAssertTrue(handler is PlayMediaIntentHandler)
        XCTAssertTrue(handler is any INSearchForMediaIntentHandling)
    }

    func testColdAppDelegateKeepsPlayMediaRoutingOnTheSameHandler() {
        let delegate = PrimuseAppDelegate()
        let intent = INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .unknown,
            resumePlayback: false,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: nil
        )

        let handler = delegate.application(UIApplication.shared, handlerFor: intent)

        XCTAssertTrue(handler is PlayMediaIntentHandler)
        XCTAssertTrue(handler is any INPlayMediaIntentHandling)
    }
}
#endif
