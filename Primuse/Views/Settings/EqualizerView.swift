import SwiftUI
import PrimuseKit

struct EqualizerView: View {
    @Environment(EqualizerService.self) private var eq
    @State private var presetNameDraft = ""
    @State private var isNamingNewPreset = false
    @State private var renamingPreset: EQPreset?

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .eqPresetNamingAlerts(
            eq: eq,
            draft: $presetNameDraft,
            isNamingNewPreset: $isNamingNewPreset,
            renamingPreset: $renamingPreset
        )
    }

    private func beginNewPreset() {
        presetNameDraft = eq.suggestedPresetName
        isNamingNewPreset = true
    }

    private func beginRename(_ preset: EQPreset) {
        presetNameDraft = preset.name
        renamingPreset = preset
    }

    /// 内置预设、用户存的预设、自定义曲线,外加一张「存为预设」卡。
    @ViewBuilder
    private var presetCards: some View {
        ForEach(EQPreset.builtInPresets) { preset in
            presetCard(preset)
        }
        ForEach(eq.userPresets) { preset in
            presetCard(preset)
                .contextMenu { userPresetMenu(preset) }
        }
        presetCard(eq.customPreset)
        if eq.canAddPreset {
            savePresetCard
        }
    }

    @ViewBuilder
    private func userPresetMenu(_ preset: EQPreset) -> some View {
        Button {
            beginRename(preset)
        } label: {
            Label("eq_rename_preset", systemImage: "pencil")
        }
        if preset.bands != eq.bands {
            Button {
                eq.overwritePreset(id: preset.id)
            } label: {
                Label("eq_overwrite_preset", systemImage: "square.and.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) {
            eq.deletePreset(id: preset.id)
        } label: {
            Label("eq_delete_preset", systemImage: "trash")
        }
    }

    private var savePresetCard: some View {
        Button(action: beginNewPreset) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity)
                Text("eq_save_as_preset")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color.accentColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("eq_save_as_preset"))
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
                // 只跟总开关走；拖动频段时 isEnabled 不变,滑块仍是逐帧跟手的。
                .pmAnimation(.control, value: eq.isEnabled)
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
                    presetCards
                }
                .padding(.vertical, 4)
            } header: {
                Text("eq_preset")
            }
            .settingsAnchor("equalizer.preset")

            Section {
                EQDeviceBindingList(eq: eq)
            } header: {
                Text("eq_device_section_title")
            } footer: {
                Text("eq_device_section_hint")
            }
            .settingsAnchor("equalizer.devices")
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
            // 只跟总开关走；拖动频段时 isEnabled 不变,滑块仍是逐帧跟手的。
            .pmAnimation(.control, value: eq.isEnabled)

            Button("eq_reset") { eq.reset() }
                .settingsAnchor("equalizer.reset")
                .buttonStyle(.bordered)
                .controlSize(.small)

            Divider()
                .padding(.horizontal)

            // 预设:填充下半部分空白,每个预设以迷你均衡曲线 + 名称呈现
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                    presetCards
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .settingsAnchor("equalizer.preset")

                VStack(alignment: .leading, spacing: 8) {
                    Text("eq_device_section_title")
                        .font(.headline)
                    Text("eq_device_section_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    EQDeviceBindingList(eq: eq)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .settingsAnchor("equalizer.devices")
            }
            .frame(maxHeight: .infinity)
        }
        // 只留顶部间距:预设区的滚动视图要贴到底边,才能像其它设置页一样滚到标签栏、
        // 迷你播放条下面并柔和渐隐;底下再垫一截会让它停在半空、硬生生切掉。
        .padding(.top)
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

// MARK: - Output Device Bindings

/// 当前输出设备与绑定过预设的设备:每行一个预设菜单,选「不自动切换」即解绑。
struct EQDeviceBindingList: View {
    let eq: EqualizerService

    var body: some View {
        VStack(spacing: 0) {
            if let device = eq.currentOutputDevice {
                row(device: device, presetID: eq.currentDeviceBinding?.presetID, isCurrent: true)
            } else if eq.bindingRows.isEmpty {
                Text("eq_device_unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            ForEach(Array(eq.bindingRows.enumerated()), id: \.element.id) { index, binding in
                if index > 0 || eq.currentOutputDevice != nil {
                    Divider()
                }
                row(device: binding.device, presetID: binding.presetID, isCurrent: false)
            }
        }
    }

    private func row(device: EQOutputDevice, presetID: String?, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind.eqSymbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.eqDisplayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: isCurrent
                    ? String(localized: "eq_device_current")
                    : device.kind.eqLocalizedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                if isCurrent {
                    Button {
                        eq.setBinding(for: device, presetID: nil)
                    } label: {
                        EQMenuCheckLabel(title: String(localized: "eq_device_no_auto_switch"), selected: presetID == nil)
                    }
                    Divider()
                }
                ForEach(eq.bindablePresets) { preset in
                    Button {
                        eq.setBinding(for: device, presetID: preset.id)
                    } label: {
                        EQMenuCheckLabel(title: preset.localizedName, selected: preset.id == presetID)
                    }
                }
                if !isCurrent {
                    Divider()
                    Button(role: .destructive) {
                        eq.setBinding(for: device, presetID: nil)
                    } label: {
                        Label("eq_device_remove", systemImage: "minus.circle")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: presetID.flatMap { eq.preset(withID: $0)?.localizedName }
                        ?? String(localized: "eq_device_no_auto_switch"))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(presetID == nil ? Color.secondary : Color.accentColor)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 菜单里的选中项只靠勾选图标表达;macOS 27 起菜单默认隐藏图标,要显式要求显示。
struct EQMenuCheckLabel: View {
    let title: String
    let selected: Bool

    var body: some View {
        if selected {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: "checkmark")
            }
            .labelStyle(.titleAndIcon)
        } else {
            Text(verbatim: title)
        }
    }
}

extension EQOutputDevice {
    /// 系统没给名字时用设备类型代替。
    var eqDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.eqLocalizedName : trimmed
    }
}

extension EQOutputDevice.Kind {
    var eqSymbolName: String {
        switch self {
        case .builtInSpeaker: return "speaker.wave.2"
        case .headphones: return "headphones"
        case .bluetooth: return "beats.headphones"
        case .usb: return "cable.connector"
        case .airPlay: return "airplayaudio"
        case .carAudio: return "car"
        case .hdmi: return "tv"
        case .other: return "hifispeaker"
        }
    }

    var eqLocalizedName: String {
        switch self {
        case .builtInSpeaker: return String(localized: "eq_device_kind_builtin")
        case .headphones: return String(localized: "eq_device_kind_headphones")
        case .bluetooth: return String(localized: "eq_device_kind_bluetooth")
        case .usb: return String(localized: "eq_device_kind_usb")
        case .airPlay: return "AirPlay"
        case .carAudio: return String(localized: "eq_device_kind_car")
        case .hdmi: return "HDMI"
        case .other: return String(localized: "eq_device_kind_other")
        }
    }
}

// MARK: - Preset Naming

extension View {
    /// 「存为预设」与「重命名」两个输入名字的弹框;iOS 与 Mac 设置页共用。
    func eqPresetNamingAlerts(
        eq: EqualizerService,
        draft: Binding<String>,
        isNamingNewPreset: Binding<Bool>,
        renamingPreset: Binding<EQPreset?>
    ) -> some View {
        let isRenaming = Binding(
            get: { renamingPreset.wrappedValue != nil },
            set: { if !$0 { renamingPreset.wrappedValue = nil } }
        )
        let nameIsUsable = EQPresetLibrary.normalizedName(draft.wrappedValue) != nil
        return self
            .alert("eq_save_preset_title", isPresented: isNamingNewPreset) {
                TextField("eq_preset_name_placeholder", text: draft)
                Button("cancel", role: .cancel) {}
                Button("save") {
                    _ = eq.saveCurrentCurve(named: draft.wrappedValue)
                }
                .disabled(!nameIsUsable)
            } message: {
                Text("eq_save_preset_message")
            }
            .alert("eq_rename_preset", isPresented: isRenaming) {
                TextField("eq_preset_name_placeholder", text: draft)
                Button("cancel", role: .cancel) {}
                Button("save") {
                    if let preset = renamingPreset.wrappedValue {
                        eq.renamePreset(id: preset.id, to: draft.wrappedValue)
                    }
                }
                .disabled(!nameIsUsable)
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
