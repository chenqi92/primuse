import SwiftUI
import PrimuseKit

struct EqualizerView: View {
    @Environment(EqualizerService.self) private var eq

    var body: some View {
        VStack(spacing: 20) {
            // Enable toggle
            Toggle("eq_enabled", isOn: Binding(
                get: { eq.isEnabled },
                set: { eq.setEnabled($0) }
            ))
            .padding(.horizontal)

            // Preset picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EQPreset.builtInPresets) { preset in
                        Button {
                            eq.applyPreset(preset)
                        } label: {
                            Text(preset.localizedName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    eq.currentPreset.id == preset.id
                                    ? AnyShapeStyle(.tint)
                                    : AnyShapeStyle(.ultraThinMaterial)
                                )
                                .foregroundStyle(
                                    eq.currentPreset.id == preset.id ? .white : .primary
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal)
            }

            // EQ Bands
            HStack(spacing: 4) {
                ForEach(0..<PrimuseConstants.eqBandCount, id: \.self) { index in
                    VStack(spacing: 4) {
                        // Gain value
                        Text(String(format: "%.0f", eq.bands[index]))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        // Vertical slider
                        VerticalSlider(
                            value: Binding(
                                get: { eq.bands[index] },
                                set: { eq.setBand(index, gain: $0) }
                            ),
                            range: PrimuseConstants.eqMinGain...PrimuseConstants.eqMaxGain
                        )
                        .frame(height: 200)

                        // Frequency label
                        Text(eq.bandFrequencyLabels[index])
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .opacity(eq.isEnabled ? 1 : 0.4)
            .disabled(!eq.isEnabled)

            // Reset button
            Button("eq_reset") {
                eq.reset()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.top)
        .navigationTitle("equalizer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Vertical Slider

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let normalizedValue = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let yPosition = height * (1 - normalizedValue)

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 4)

                // Fill
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.tint)
                        .frame(width: 4, height: max(0, height - yPosition))
                }

                // Center line
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 12, height: 1)
                    .position(x: geometry.size.width / 2, y: height / 2)

                // Thumb
                Circle()
                    .fill(.tint)
                    .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                    .shadow(radius: 2)
                    .position(x: geometry.size.width / 2, y: yPosition)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let normalized = 1 - Float(gesture.location.y / height)
                        let clamped = min(max(normalized, 0), 1)
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }
}
