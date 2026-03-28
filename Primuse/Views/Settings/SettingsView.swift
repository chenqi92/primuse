import SwiftUI
import PrimuseKit

struct SettingsView: View {
    @State private var cacheSize: String = "0 MB"
    @State private var showClearCacheAlert = false

    var body: some View {
        NavigationStack {
            List {
                Section("playback") {
                    NavigationLink {
                        EqualizerView()
                    } label: {
                        Label("equalizer", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("playback_settings", systemImage: "play.circle")
                    }

                    NavigationLink {
                        AudioOutputView()
                    } label: {
                        Label("audio_output", systemImage: "hifispeaker")
                    }
                }

                Section("library") {
                    HStack {
                        Label("cache_size", systemImage: "internaldrive")
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        Label("clear_cache", systemImage: "trash")
                    }
                }

                Section("about") {
                    HStack {
                        Text("version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("build")
                        Spacer()
                        Text("1")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        LicensesView()
                    } label: {
                        Text("licenses")
                    }
                }
            }
            .navigationTitle("settings_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .confirmationDialog("clear_cache_confirm", isPresented: $showClearCacheAlert) {
                Button("clear", role: .destructive) {
                    clearCache()
                }
                Button("cancel", role: .cancel) {}
            }
        }
    }

    private func clearCache() {
        // Will be connected to cache manager
        cacheSize = "0 MB"
    }
}

struct PlaybackSettingsView: View {
    @State private var gaplessPlayback = true
    @State private var crossfade = false
    @State private var crossfadeDuration: Double = 3.0
    @State private var replayGain = false

    var body: some View {
        Form {
            Section("playback") {
                Toggle("gapless_playback", isOn: $gaplessPlayback)
                Toggle("crossfade", isOn: $crossfade)

                if crossfade {
                    VStack(alignment: .leading) {
                        Text("crossfade_duration")
                            .font(.caption)
                        Slider(value: $crossfadeDuration, in: 1...12, step: 1) {
                            Text("\(Int(crossfadeDuration))s")
                        }
                        Text("\(Int(crossfadeDuration)) \(String(localized: "seconds"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("replay_gain", isOn: $replayGain)
            }
        }
        .navigationTitle("playback_settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AudioOutputView: View {
    var body: some View {
        List {
            Section("current_output") {
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Text("iPhone Speaker")
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }

            Section {
                Text("audio_output_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("audio_output")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("open_source") {
                licenseRow("GRDB.swift", "MIT License")
                licenseRow("AMSMB2", "LGPL 2.1")
                licenseRow("FileProvider", "MIT License")
                licenseRow("FFmpeg", "LGPL 2.1")
            }
        }
        .navigationTitle("licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseRow(_ name: String, _ license: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
