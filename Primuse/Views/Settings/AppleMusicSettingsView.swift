import SwiftUI
import MusicKit
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 让用户在 Settings 主动 opt-in 给 Apple Music 权限。授权后 SearchView 才
/// 会去访问 catalog —— 避免用户搜歌时被无端弹系统授权对话框。
struct AppleMusicSettingsView: View {
    @Environment(AppleMusicService.self) private var appleMusic

    var body: some View {
        Form {
            Section {
                statusRow
                if appleMusic.authState == .notDetermined {
                    Button {
                        Task { await appleMusic.requestAuthorization() }
                    } label: {
                        Label(String(localized: "settings_apple_music_connect"),
                              systemImage: "music.note")
                    }
                } else if appleMusic.authState == .denied || appleMusic.authState == .restricted {
                    Text(String(localized: "settings_apple_music_denied"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: url) {
                            Label(String(localized: "settings_apple_music_connect"),
                                  systemImage: "gearshape")
                        }
                    }
                    #else
                    // macOS 走系统设置 → 隐私 → 媒体与 Apple Music。
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(String(localized: "settings_apple_music_connect"),
                              systemImage: "gearshape")
                    }
                    #endif
                }
            } footer: {
                Text(String(localized: "settings_apple_music_footer"))
                    .font(.footnote)
            }
        }
        .navigationTitle("settings_apple_music_section")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var statusRow: some View {
        HStack {
            Image(systemName: appleMusic.authState == .authorized
                  ? "checkmark.circle.fill"
                  : "circle.dashed")
                .foregroundStyle(appleMusic.authState == .authorized ? .green : .secondary)
            Text(statusText)
            Spacer()
        }
    }

    private var statusText: String {
        switch appleMusic.authState {
        case .authorized: return String(localized: "settings_apple_music_connected")
        case .denied, .restricted: return String(localized: "settings_apple_music_denied")
        case .notDetermined: return ""
        }
    }
}
