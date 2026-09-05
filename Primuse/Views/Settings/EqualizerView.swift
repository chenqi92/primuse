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
    /// 频段滑块一段、底部预设卡片一段。
    private var macBody: some View {
        Form {
            Section {
                Toggle("eq_enabled", isOn: Binding(
                    get: { eq.isEnabled },
                    set: { eq.setEnabled($0) }
                ))
            }

            Section {
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
                    .settingsAnchor("equalizer.reset")
                        .controlSize(.small)
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(EQPreset.builtInPresets) { preset in
                        presetCard(preset)
                    }
                    presetCard(eq.customPreset)
                }
                .padding(.vertical, 4)
            } header: {
                Text("eq_preset")
            }
            .settingsAnchor("equalizer.preset")
        }
        .formStyle(.grouped)
    }
    #endif

    private var iosBody: some View {
        VStack(spacing: 14) {
            Toggle("eq_enabled", isOn: Binding(
                get: { eq.isEnabled },
                set: { eq.setEnabled($0) }
            ))
            .settingsAnchor("equalizer.enabled")
            .padding(.horizontal)

            // 频段滑块:占上半部分,固定高度
            HStack(spacing: 4) {
                ForEach(0..<PrimuseConstants.eqBandCount, id: \.self) { index in
                    bandSlider(index: index, height: 200)
                }
            }
            .settingsAnchor("equalizer.bands")
            .padding(.horizontal, 12)
            .opacity(eq.isEnabled ? 1 : 0.4)
            .disabled(!eq.isEnabled)

            Button("eq_reset") { eq.reset() }
                .settingsAnchor("equalizer.reset")
                .buttonStyle(.bordered)
                .controlSize(.small)

            Divider()
                .padding(.horizontal)

            // 预设:填充下半部分空白,每个预设以迷你均衡曲线 + 名称呈现
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                    ForEach(EQPreset.builtInPresets) { preset in
                        presetCard(preset)
                    }
                    presetCard(eq.customPreset)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .settingsAnchor("equalizer.preset")
            .frame(maxHeight: .infinity)
        }
        .padding(.vertical)
        .navigationTitle("equalizer")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 预设卡片:迷你 EQ 曲线缩略图 + 名称,选中态高亮。
    private func presetCard(_ preset: EQPreset) -> some View {
        let selected = eq.currentPreset.id == preset.id
        return Button {
            eq.applyPreset(preset)
        } label: {
            VStack(spacing: 5) {
                EQCurveThumbnail(
                    bands: preset.bands,
                    range: PrimuseConstants.eqMinGain...PrimuseConstants.eqMaxGain,
                    highlighted: selected
                )
                .frame(height: 34)
                .frame(maxWidth: .infinity)

                Text(preset.localizedName)
                    .font(.caption2)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// height 为 nil 时滑块撑满父容器剩余高度,给定值则固定。
    private func bandSlider(index: Int, height: CGFloat?) -> some View {
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
            .frame(maxHeight: height == nil ? .infinity : nil)
            Text(eq.bandFrequencyLabels[index])
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - EQ Curve Thumbnail

/// 把一组频段增益画成迷你均衡曲线(带 0dB 参考线与渐变填充),用于预设卡片。
private struct EQCurveThumbnail: View {
    let bands: [Float]
    let range: ClosedRange<Float>
    var highlighted: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = curvePoints(in: size)
            let lineColor: Color = highlighted ? .accentColor : .secondary

            ZStack {
                // 0dB 参考线
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

                // 曲线下方渐变填充
                curvePath(points: pts, fillTo: size.height)
                    .fill(
                        LinearGradient(
                            colors: [lineColor.opacity(0.35), lineColor.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                // 均衡曲线
                curvePath(points: pts, fillTo: nil)
                    .stroke(lineColor,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func curvePoints(in size: CGSize) -> [CGPoint] {
        guard bands.count > 1 else {
            return [CGPoint(x: 0, y: size.height / 2),
                    CGPoint(x: size.width, y: size.height / 2)]
        }
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let inset = size.height * 0.12   // 上下留边,极值不贴边
        let usable = size.height - inset * 2
        return bands.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(bands.count - 1)
            let norm = CGFloat((v - range.lowerBound) / span)
            let y = inset + usable * (1 - norm)
            return CGPoint(x: x, y: y)
        }
    }

    /// fillTo 非 nil 时生成闭合填充路径(下探到 fillTo 形成面积);否则只生成曲线本身。
    private func curvePath(points: [CGPoint], fillTo: CGFloat?) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            if let fillTo {
                path.move(to: CGPoint(x: first.x, y: fillTo))
                path.addLine(to: first)
            } else {
                path.move(to: first)
            }
            // 经过相邻点中点的二次曲线,小尺寸下更圆润
            for i in 1..<points.count {
                let prev = points[i - 1]
                let cur = points[i]
                let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                path.addQuadCurve(to: mid, control: prev)
            }
            path.addLine(to: last)
            if let fillTo {
                path.addLine(to: CGPoint(x: last.x, y: fillTo))
                path.closeSubpath()
            }
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
