#if os(iOS)
import SwiftUI
import AVKit
import PrimuseKit

struct FloatingLyricsRootModifier: ViewModifier {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PlayerAppearancePreferences.miniPlayerLyricsKey) private var miniLyrics = false
    @State private var consumerID = UUID()
    @State private var pictureInPicture = LyricsPictureInPicture.shared

    func body(content: Content) -> some View {
        content
            .onAppear { updateDemand() }
            .onChange(of: miniLyrics) { _, _ in updateDemand() }
            .onChange(of: scenePhase) { _, _ in updateDemand() }
            .onDisappear { FloatingLyricsService.shared.setConsumer(consumerID, active: false, player: player) }
            .sheet(isPresented: $pictureInPicture.showsPreview) {
                LyricsPictureInPictureSheet().environment(player)
            }
    }

    private func updateDemand() {
        FloatingLyricsService.shared.setConsumer(consumerID, active: miniLyrics && scenePhase == .active, player: player)
    }
}

struct MiniPlayerLyricsSubtitle: View {
    let artist: String
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(PlayerAppearancePreferences.miniPlayerLyricsKey) private var enabled = false
    private var text: String {
        let lyrics = FloatingLyricsService.shared
        return enabled && lyrics.songID == player.currentSong?.id ? lyrics.presentation.current ?? artist : artist
    }
    var body: some View {
        Text(verbatim: text)
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .accessibilityIdentifier("miniPlayerLyricLine")
    }
}

struct FloatingLyricsMenuItems: View {
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(PlayerAppearancePreferences.miniPlayerLyricsKey) private var miniLyrics = false
    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var controlsStorage = ""

    private var layout: NowPlayingControlLayout { .decode(controlsStorage) }

    var body: some View {
        if player.currentSong != nil, !player.currentItemIsSpokenWord, !player.isLiveRadio {
            if layout.showsMenuItem(.miniPlayerLyrics) {
                Toggle(isOn: $miniLyrics) {
                    Label("mini_player_show_lyrics", systemImage: "captions.bubble")
                }
            }
            if layout.showsMenuItem(.floatingLyrics), LyricsPictureInPicture.isSupported,
               !player.isMusicVideoPlaybackActive {
                Button { LyricsPictureInPicture.shared.showsPreview = true } label: {
                    Label("lyrics_pip_title", systemImage: "pip")
                }
                .accessibilityIdentifier("lyricsPictureInPicture")
            }
        }
    }
}

private struct LyricsPictureInPictureSheet: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var consumerID = UUID()
    @State private var pictureInPicture = LyricsPictureInPicture.shared
    private let service = FloatingLyricsService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                LyricsPictureInPicturePreview()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(service.presentation.current ?? service.title)
                Button {
                    if pictureInPicture.isActive { pictureInPicture.stop() }
                    else { pictureInPicture.start() }
                } label: {
                    Label(pictureInPicture.isActive ? "lyrics_pip_stop" : "lyrics_pip_start",
                          systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!pictureInPicture.isActive && (!pictureInPicture.isPossible || pictureInPicture.isStarting || !service.isAvailable))
                .accessibilityIdentifier("lyricsPictureInPictureStart")
            }
            .padding(24)
            .navigationTitle("lyrics_pip_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } } }
            .alert("lyrics_pip_title", isPresented: Binding(
                get: { pictureInPicture.errorMessage != nil }, set: { if !$0 { pictureInPicture.errorMessage = nil } }
            )) {
                Button("done", role: .cancel) { pictureInPicture.errorMessage = nil }
            } message: { Text(pictureInPicture.errorMessage ?? "") }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            updateDemand()
            pictureInPicture.previewDidAppear()
        }
        .onChange(of: scenePhase) { _, _ in updateDemand() }
        .onDisappear { service.setConsumer(consumerID, active: false, player: player) }
    }

    private func updateDemand() {
        service.setConsumer(consumerID, active: scenePhase == .active, player: player)
    }
}

private struct LyricsPictureInPicturePreview: UIViewRepresentable {
    func makeUIView(context: Context) -> LyricsSampleBufferView {
        let view = LyricsSampleBufferView()
        LyricsPictureInPicture.shared.attach(view)
        return view
    }
    func updateUIView(_ uiView: LyricsSampleBufferView, context: Context) {}
    static func dismantleUIView(_ uiView: LyricsSampleBufferView, coordinator: ()) {
        LyricsPictureInPicture.shared.detach(uiView)
    }
}
#endif
