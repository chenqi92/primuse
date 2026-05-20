import SwiftUI
import PrimuseKit

/// DLNA Renderer 模式的设置面 ── toggle 开关 + 当前状态 + 控制端设备。
/// 开关持久化用 @AppStorage,实际生效由 onChange 调 service.start/stop。
struct DLNARendererSettingsView: View {
    @Environment(DLNARendererService.self) private var renderer
    @AppStorage("dlna.rendererEnabled") private var enabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "settings_dlna_enable"), isOn: $enabled)
                    .onChange(of: enabled) { _, new in
                        if new { renderer.start() } else { renderer.stop() }
                    }
                if renderer.isRunning && !renderer.statusText.isEmpty {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Text(renderer.statusText)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                }
            } footer: {
                Text(String(localized: "settings_dlna_footer"))
                    .font(.footnote)
            }

            if renderer.isRunning {
                Section(String(localized: "settings_dlna_devices_section")) {
                    if renderer.connectedDevices.isEmpty {
                        Text(String(localized: "settings_dlna_devices_empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(renderer.connectedDevices) { device in
                            deviceRow(device)
                        }
                    }
                }
            }
        }
        .navigationTitle("settings_dlna_section")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 用户上次打开 toggle 后 app 重启,需要恢复 service 状态。
            if enabled && !renderer.isRunning { renderer.start() }
        }
    }

    private func deviceRow(_ device: DLNARendererService.ConnectedDevice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: device.isCasting ? "play.circle.fill" : "network")
                .font(.body)
                .foregroundStyle(device.isCasting ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    if device.isCasting {
                        Text(String(localized: "dlna_device_casting"))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(device.address)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let detail = device.clientDescription {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(device.lastSeen.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
