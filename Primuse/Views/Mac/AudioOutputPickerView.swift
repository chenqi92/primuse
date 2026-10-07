#if os(macOS)
import SwiftUI
import AudioToolbox
import AppKit

/// 弹在 AirPlay 按钮上方的输出设备 popover。每个设备一行,点击切换
/// Primuse 自己的输出 (不影响系统默认)。"跟随系统"那一行让用户回到
/// 默认行为,Primuse 跟系统 default output 走。
struct AudioOutputPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioEngine.self) private var engine
    @State private var manager = AudioOutputDeviceManager()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                    Text("audio_output")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "open_system_settings"), systemImage: "gear")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
                .help(Text("open_system_settings"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            // 设备少 (一般 ≤10 台), 直接全部平铺, popover 高度跟内容走, 不需要
            // ScrollView。之前用 ScrollView + maxHeight 240 + 强制隐滚动条, 还
            // 是会被系统"总是显示"模式偷偷加一条粗滚动条。
            VStack(alignment: .leading, spacing: 0) {
                deviceRow(
                    title: String(localized: "audio_output_follow_system"),
                    symbol: "checkmark.circle",
                    subtitle: systemDefaultSubtitle,
                    isSelected: engine.followsSystemOutput,
                    accent: nil
                ) {
                    followSystem()
                }

                if !manager.devices.isEmpty {
                    Rectangle()
                        .fill(PMColor.divider)
                        .frame(height: 0.5)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                }

                ForEach(manager.devices) { device in
                    deviceRow(
                        title: device.name,
                        symbol: device.symbolName,
                        subtitle: device.subtitle,
                        isSelected: engine.selectedOutputDeviceID == device.id,
                        accent: device.isAirPlay ? .accentColor : nil
                    ) {
                        applyDevice(device.id)
                    }
                }
            }
            .padding(.vertical, 6)

            if let errorMessage {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(PMColor.bad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }

            // 设置里开了独占输出：说清楚这台设备现在是独占还是共享。
            if let exclusive = engine.exclusiveOutputStatus.pickerDescription {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: engine.exclusiveOutputStatus.fallbackDescription == nil
                          ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(verbatim: exclusive)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(engine.exclusiveOutputStatus.fallbackDescription == nil
                                 ? PMColor.textMuted : PMColor.warn)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 280)
        // popover 一打开就会把键盘焦点放在第一个按钮上, 给它描一圈 accent 焦点环。
        // 行是整幅宽的, 环的左右两边落在 popover 边界外被裁掉, 只剩贴着行上下沿的
        // 两条横线, 看着像凭空多了两条分隔线。菜单是鼠标点开的, 关掉焦点描边。
        .focusEffectDisabled()
        // 系统 popover 已经包了 chrome (material + 圆角 + 边框 + 阴影 + 箭头), 不要
        // 再自己画 RoundedRectangle / strokeBorder / shadow, 否则跟系统 chrome 叠成
        // 双层框 (用户截图里那一圈外框就是这么来的)。同 CastDevicePickerSheet。
        .onAppear {
            manager.refresh()
        }
    }

    private var systemDefaultSubtitle: String {
        if let id = manager.systemDefaultID,
           let device = manager.devices.first(where: { $0.id == id }) {
            return "\(device.name) · \(device.subtitle)"
        }
        return "System Default · Core Audio"
    }

    private func deviceRow(title: String, symbol: String, subtitle: String?, isSelected: Bool,
                           accent: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(accent ?? PMColor.textMuted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                        // 只淡入淡出, 不缩放 —— 缩放会把行高一起撑动。
                        // 选择是在这里裸赋值的, 所以曲线附在过渡上, 跟行底色同一档。
                        .pmFadeTransition(motion: .hover)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .pmRowBackground(selected: isSelected, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func applyDevice(_ id: AudioDeviceID) {
        do {
            try engine.setOutputDevice(deviceID: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func followSystem() {
        errorMessage = nil
        do {
            try engine.followSystemOutput()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
