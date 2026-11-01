#if os(iOS)
import Intents
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class SiriRadioIntentRoutingTests: XCTestCase {
    func testPhysicalDeviceAcceptsPlaybackDonation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Siri donation acceptance requires a physical device")
        #else
        let id = "primuse-siri-test-" + UUID().uuidString
        let item = INMediaItem(identifier: id, title: "Primuse Playback Test", type: .radioStation, artwork: nil)
        let intent = INPlayMediaIntent(mediaItems: nil, mediaContainer: item, playShuffled: nil,
            playbackRepeatMode: .unknown, resumePlayback: nil, playbackQueueLocation: .unknown,
            playbackSpeed: nil, mediaSearch: nil)
        let interaction = SiriMediaInteractionDonor.playbackInteraction(intent, identifier: id)
        let donationError: NSError? = await withCheckedContinuation { continuation in
            interaction.donate { error in continuation.resume(returning: error as NSError?) }
        }
        let cleanupError: NSError? = await withCheckedContinuation { continuation in
            INInteraction.delete(with: [id]) { error in continuation.resume(returning: error as NSError?) }
        }
        XCTAssertNil(donationError, donationError.map { "\($0.domain):\($0.code)" } ?? "")
        XCTAssertNil(cleanupError, cleanupError.map { "\($0.domain):\($0.code)" } ?? "")
        #endif
    }

    func testPlaybackDonationIncludesSuccessfulResponseAndIncomingDirection() {
        let station = INMediaItem(identifier: "radio:fixture", title: "Fixture", type: .radioStation, artwork: nil)
        let intent = INPlayMediaIntent(mediaItems: nil, mediaContainer: station, playShuffled: nil,
            playbackRepeatMode: .unknown, resumePlayback: nil, playbackQueueLocation: .unknown,
            playbackSpeed: nil, mediaSearch: nil)
        let interaction = SiriMediaInteractionDonor.playbackInteraction(intent, identifier: "radio:fixture")
        XCTAssertEqual((interaction.intentResponse as? INPlayMediaIntentResponse)?.code, .success)
        XCTAssertEqual(interaction.intentHandlingStatus, .success)
        XCTAssertEqual(interaction.direction, .incoming)
        XCTAssertEqual(interaction.identifier, "radio:fixture")
        XCTAssertEqual((interaction.intent as? INPlayMediaIntent)?.mediaContainer?.identifier, "radio:fixture")
    }

    func testAppBundleDeclaresBothMediaIntentsForColdLaunch() {
        let supported = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "INIntentsSupported") as? [String]

        XCTAssertEqual(
            Set(supported ?? []),
            Set(["INPlayMediaIntent", "INSearchForMediaIntent"])
        )
        let donationTypes = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        XCTAssertTrue(donationTypes?.contains("INPlayMediaIntent") == true)
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
