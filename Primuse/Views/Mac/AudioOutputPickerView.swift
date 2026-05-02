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
                Text("audio_output").font(.headline)
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "open_system_settings"), systemImage: "gear")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(Text("open_system_settings"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

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
                        Divider().padding(.vertical, 4)
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
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 280)
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
                    .foregroundStyle(accent ?? .secondary)
                    .frame(width: 20)
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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
