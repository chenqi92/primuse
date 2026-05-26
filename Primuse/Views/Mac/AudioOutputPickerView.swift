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
    @State private var selectedID: AudioDeviceID?
    @State private var followsSystem: Bool = true
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    deviceRow(
                        title: String(localized: "audio_output_follow_system"),
                        symbol: "checkmark.circle",
                        isSelected: followsSystem,
                        accent: nil
                    ) {
                        followsSystem = true
                        if let sysID = manager.systemDefaultID { applyDevice(sysID) }
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
                            isSelected: !followsSystem && selectedID == device.id,
                            accent: device.isAirPlay ? .accentColor : nil
                        ) {
                            followsSystem = false
                            applyDevice(device.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(minHeight: 60, maxHeight: 240)

            if let errorMessage {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(PMColor.bad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PMColor.bg.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
        .onAppear {
            manager.refresh()
            // 没显式选过的话,初始就跟随系统。
            if let cur = engine.currentOutputDeviceID {
                selectedID = cur
                followsSystem = (cur == manager.systemDefaultID)
            }
        }
    }

    private func deviceRow(title: String, symbol: String, isSelected: Bool,
                           accent: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(accent ?? PMColor.textMuted)
                    .frame(width: 20)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
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
            selectedID = id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
