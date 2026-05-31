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
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary

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

            if appleMusic.authState == .authorized {
                librarySection
            }
        }
        .navigationTitle("settings_apple_music_section")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// 把 Apple Music 用户资料库拉进猿音 Library。state 切换时直接 reflect
    /// 在 UI 上, 用户能看到 syncing / 完成数 / 失败原因。
    private var librarySection: some View {
        Section {
            statusContent
            Button {
                appleMusicLibrary.sync()
            } label: {
                Label(syncButtonTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing)
        } header: {
            Text("apple_music_library_section")
        } footer: {
            Text("apple_music_library_footer")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch appleMusicLibrary.state {
        case .idle:
            Text("apple_music_library_idle").foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("apple_music_library_syncing").foregroundStyle(.secondary)
            }
        case .done(let count, let at):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(String(format: String(localized: "apple_music_library_done_format"),
                            count, Self.formattedDate(at)))
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = appleMusicLibrary.state { return true }
        return false
    }

    private var syncButtonTitle: String {
        switch appleMusicLibrary.state {
        case .done: return String(localized: "apple_music_library_resync")
        default: return String(localized: "apple_music_library_sync")
        }
    }

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
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
