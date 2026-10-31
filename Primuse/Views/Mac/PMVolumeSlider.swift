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
    var trackThicknessScale: CGFloat? = nil
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
        if let slider = slider as? PMWindowSafeSlider, slider.trackThicknessScale != trackThicknessScale {
            slider.trackThicknessScale = trackThicknessScale
            slider.needsDisplay = true
        }
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

final class PMThicknessSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let slider = controlView as? PMWindowSafeSlider,
              let scale = slider.trackThicknessScale,
              !isVertical, scale != 1 || slider.isTrackingMouse else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let height = Self.trackHeight(base: rect.height, scale: scale, isActive: slider.isTrackingMouse)
        let track = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let path = NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let fill = slider.trackFillColor ?? .controlAccentColor
        fill.withAlphaComponent(slider.isEnabled ? 1 : 0.4).setFill()
        let width = min(track.width, max(0, knobRect(flipped: flipped).midX - track.minX))
        NSRect(x: track.minX, y: track.minY, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func trackHeight(base: CGFloat, scale: CGFloat, isActive: Bool) -> CGFloat {
        base * scale + (isActive ? min(2, base) : 0)
    }
}

final class PMWindowSafeSlider: NSSlider {
    private var systemSliderCell: NSSliderCell?
    private var thicknessSliderCell: PMThicknessSliderCell?
    var trackThicknessScale: CGFloat? {
        didSet { updateTrackDrawing() }
    }
    var isTrackingMouse = false {
        didSet { updateTrackDrawing() }
    }
    var onEditingChanged: (Bool) -> Void = { _ in }

    private func updateTrackDrawing() {
        defer { needsDisplay = true }
        guard let current = cell as? NSSliderCell else { return }
        let custom = trackThicknessScale.map { $0 != 1 || isTrackingMouse } ?? false
        guard custom != (current is PMThicknessSliderCell) else { return }
        if systemSliderCell == nil { systemSliderCell = current }
        if custom, thicknessSliderCell == nil { thicknessSliderCell = PMThicknessSliderCell() }
        guard let replacement = custom ? thicknessSliderCell : systemSliderCell else { return }
        let fill = trackFillColor
        replacement.minValue = current.minValue
        replacement.maxValue = current.maxValue
        replacement.doubleValue = current.doubleValue
        replacement.controlSize = current.controlSize
        replacement.sliderType = current.sliderType
        replacement.isVertical = current.isVertical
        replacement.isEnabled = current.isEnabled
        replacement.isContinuous = current.isContinuous
        replacement.target = current.target
        replacement.action = current.action
        replacement.altIncrementValue = current.altIncrementValue
        replacement.numberOfTickMarks = current.numberOfTickMarks
        replacement.tickMarkPosition = current.tickMarkPosition
        replacement.allowsTickMarkValuesOnly = current.allowsTickMarkValuesOnly
        cell = replacement
        trackFillColor = fill
        sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

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
