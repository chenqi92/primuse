#if os(macOS)
import SwiftUI
import XCTest
#if !PRIMUSE_AUDIO_VOLUME_SMOKE
@testable import Primuse
#endif

final class MacVolumeSliderTests: XCTestCase {
    @MainActor
    func testThicknessChangesTheNativeTrackAndRestoresItsDefaultRendering() throws {
        _ = NSApplication.shared
        let slider = PMWindowSafeSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0.6
        slider.controlSize = .small
        slider.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        slider.appearance = NSAppearance(named: .aqua)
        slider.trackFillColor = .systemBlue

        func render() throws -> NSBitmapImageRep {
            let image = try XCTUnwrap(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
            slider.cacheDisplay(in: slider.bounds, to: image)
            return image
        }
        let native = try render().representation(using: .png, properties: [:])
        let original = PMWindowSafeSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
        original.controlSize = slider.controlSize
        original.frame = slider.frame
        original.appearance = slider.appearance
        original.trackFillColor = slider.trackFillColor
        let originalImage = try XCTUnwrap(original.bitmapImageRepForCachingDisplay(in: original.bounds))
        original.cacheDisplay(in: original.bounds, to: originalImage)
        XCTAssertEqual(native, originalImage.representation(using: .png, properties: [:]))
        slider.trackThicknessScale = 1
        XCTAssertEqual(try render().representation(using: .png, properties: [:]), native)
        slider.trackThicknessScale = 1.8
        let thicker = try render()
        XCTAssertNotEqual(thicker.representation(using: .png, properties: [:]), native)
        slider.isTrackingMouse = true
        let pressed = try render()
        XCTAssertNotEqual(pressed.representation(using: .png, properties: [:]), thicker.representation(using: .png, properties: [:]))
        slider.isTrackingMouse = false
        slider.trackThicknessScale = 1
        XCTAssertEqual(try render().representation(using: .png, properties: [:]), native)
        for (name, bitmap) in [("mac-thick-track", thicker), ("mac-pressed-track", pressed)] {
            let image = NSImage(size: slider.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testTrackThicknessKeepsPressedStateLargerWithoutChangingSliderRange() {
        for scale: CGFloat in [0.7, 1, 1.4, 1.8] {
            let resting = PMThicknessSliderCell.trackHeight(base: 4, scale: scale, isActive: false)
            let pressed = PMThicknessSliderCell.trackHeight(base: 4, scale: scale, isActive: true)
            XCTAssertGreaterThan(pressed, resting)
        }
        let slider = PMWindowSafeSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0.6
        let original = slider.cell as! NSSliderCell
        slider.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let knobBefore = original.knobRect(flipped: false)
        slider.trackThicknessScale = 1.8
        XCTAssertEqual((slider.cell as! NSSliderCell).knobRect(flipped: false), knobBefore)
        XCTAssertEqual(slider.doubleValue, 0.6, accuracy: 0.0001)
    }

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
