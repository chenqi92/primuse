#if os(macOS)
import SwiftUI
import XCTest
#if !PRIMUSE_AUDIO_VOLUME_SMOKE
@testable import Primuse
#endif

final class MacVolumeSliderTests: XCTestCase {
    @MainActor
    func testModelRefreshDoesNotMoveKnobAwayFromPointerDuringTracking() {
        let slider = PMWindowSafeSlider(value: 0.72, minValue: 0, maxValue: 1, target: nil, action: nil)
        let coordinator = PMVolumeSlider.Coordinator(value: .constant(0.2))

        slider.isTrackingMouse = true
        coordinator.updateValue(0.2, on: slider)
        XCTAssertEqual(slider.doubleValue, 0.72, accuracy: 0.0001)

        slider.isTrackingMouse = false
        coordinator.updateValue(0.41, on: slider)
        XCTAssertEqual(slider.doubleValue, 0.41, accuracy: 0.0001)
    }

    @MainActor
    func testNativeActionPublishesTheKnobValueSynchronously() {
        var volume = 0.2
        let slider = PMWindowSafeSlider(value: 0.73, minValue: 0, maxValue: 1, target: nil, action: nil)
        let coordinator = PMVolumeSlider.Coordinator(value: Binding(
            get: { volume },
            set: { volume = $0 }
        ))

        coordinator.valueChanged(slider)

        XCTAssertEqual(volume, 0.73, accuracy: 0.0001)
        XCTAssertEqual(slider.doubleValue, volume, accuracy: 0.0001)
    }
}
#endif
