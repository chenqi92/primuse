#if os(macOS)
import SwiftUI

/// Native macOS slider that opts out of `isMovableByWindowBackground`.
///
/// SwiftUI's `Slider` can still be treated as draggable window background in
/// borderless/hidden-titlebar windows, which makes volume drags move the whole
/// window. Keeping this as an AppKit control lets the slider own mouse tracking.
struct PMVolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var controlSize: NSControl.ControlSize = .mini
    var isEnabled = true
    /// 已填充那一段的颜色。nil 时 AppKit 用系统强调色，和 app 自己的主题色对不上。
    var fillColor: Color?
    var accessibilityLabel: String = String(localized: "volume")
    var accessibilityHelp: String?
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = PMWindowSafeSlider(
            value: clampedValue,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.sliderType = .linear
        slider.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        slider.controlSize = controlSize
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel(accessibilityLabel)
        applyConfiguration(to: slider, context: context)
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        applyConfiguration(to: nsView, context: context)
    }

    private var clampedValue: Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func applyConfiguration(to slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        if slider.controlSize != controlSize { slider.controlSize = controlSize }
        if slider.isEnabled != isEnabled { slider.isEnabled = isEnabled }
        let trackFillColor = fillColor.map { NSColor($0) }
        if slider.trackFillColor != trackFillColor { slider.trackFillColor = trackFillColor }
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.setAccessibilityHelp(accessibilityHelp)
        (slider as? PMWindowSafeSlider)?.onEditingChanged = onEditingChanged
        context.coordinator.updateValue(clampedValue, on: slider)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        func updateValue(_ value: Double, on slider: NSSlider) {
            // AppKit owns the knob until mouse tracking finishes. A SwiftUI
            // refresh must not replace its position with an earlier binding.
            guard (slider as? PMWindowSafeSlider)?.isTrackingMouse != true else { return }
            if abs(slider.doubleValue - value) > 0.0005 {
                slider.doubleValue = value
            }
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

final class PMWindowSafeSlider: NSSlider {
    var isTrackingMouse = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let wasMovableByBackground = window?.isMovableByWindowBackground
        window?.isMovableByWindowBackground = false
        isTrackingMouse = true
        onEditingChanged(true)
        defer {
            isTrackingMouse = false
            onEditingChanged(false)
            if let wasMovableByBackground {
                window?.isMovableByWindowBackground = wasMovableByBackground
            }
        }
        super.mouseDown(with: event)
    }
}

#endif
