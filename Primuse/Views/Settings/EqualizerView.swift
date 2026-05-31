import SwiftUI
import PrimuseKit

struct EqualizerView: View {
    @Environment(EqualizerService.self) private var eq

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    /// macOS 版用 grouped Form 视觉,跟其他设置 tab 对齐:启用开关一段、
    /// 预设/EQ 一段、底部一行重置。VStack 太"空旷"——这里收紧到一屏内能
    /// 看完,EQ 高度 160 也比 200 更适合 macOS 设置窗口。
    private var macBody: some View {
        Form {
            Section {
                Toggle("eq_enabled", isOn: Binding(
                    get: { eq.isEnabled },
                    set: { eq.setEnabled($0) }
                ))
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(EQPreset.builtInPresets) { preset in
                            presetChip(preset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 36)

                HStack(spacing: 4) {
                    ForEach(0..<PrimuseConstants.eqBandCount, id: \.self) { index in
                        bandSlider(index: index, height: 160)
                    }
                }
                .opacity(eq.isEnabled ? 1 : 0.4)
                .disabled(!eq.isEnabled)
                .padding(.vertical, 6)

                HStack {
                    Spacer()
                    Button("eq_reset") { eq.reset() }
                        .controlSize(.small)
                }
            } header: {
                Text("eq_preset")
            }
        }
        .formStyle(.grouped)
    }
    #endif

    private var iosBody: some View {
        VStack(spacing: 20) {
            Toggle("eq_enabled", isOn: Binding(
                get: { eq.isEnabled },
                set: { eq.setEnabled($0) }
            ))
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EQPreset.builtInPresets) { preset in
                        presetChip(preset)
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 4) {
                ForEach(0..<PrimuseConstants.eqBandCount, id: \.self) { index in
                    bandSlider(index: index, height: 200)
                }
            }
            .padding(.horizontal, 12)
            .opacity(eq.isEnabled ? 1 : 0.4)
            .disabled(!eq.isEnabled)

            Button("eq_reset") { eq.reset() }
                .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.top)
        .navigationTitle("equalizer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presetChip(_ preset: EQPreset) -> some View {
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
        .buttonStyle(.plain)
    }

    private func bandSlider(index: Int, height: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%.0f", eq.bands[index]))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            VerticalSlider(
                value: Binding(
                    get: { eq.bands[index] },
                    set: { eq.setBand(index, gain: $0) }
                ),
                range: PrimuseConstants.eqMinGain...PrimuseConstants.eqMaxGain
            )
            .frame(height: height)
            Text(eq.bandFrequencyLabels[index])
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
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
