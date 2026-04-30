import SwiftUI
import PrimuseKit

struct LyricsView: View {
    @Environment(AudioPlayerService.self) private var player
    @AppStorage("lyricsFontScale") private var fontScale: Double = 1.0
    @State private var lyrics: [LyricLine] = []
    @State private var currentLineIndex: Int = 0
    @State private var pinchScale: CGFloat = 1.0
    @State private var isPinching: Bool = false

    private let baseFontSize: CGFloat = 20
    private let minScale: Double = 0.7
    private let maxScale: Double = 1.8

    private var effectiveScale: Double {
        let combined = fontScale * Double(pinchScale)
        return min(max(combined, minScale), maxScale)
    }

    private var fontSize: CGFloat {
        baseFontSize * CGFloat(effectiveScale)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if lyrics.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "text.quote")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("no_lyrics")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 100)
                        } else {
                            ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                                Text(line.text)
                                    .font(.system(size: fontSize))
                                    .fontWeight(index == currentLineIndex ? .bold : .regular)
                                    .foregroundStyle(index == currentLineIndex ? .primary : .secondary)
                                    .multilineTextAlignment(.center)
                                    .id(line.id)
                                    .onTapGesture {
                                        player.seek(to: line.timestamp)
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 40)
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            isPinching = true
                            pinchScale = value.magnification
                        }
                        .onEnded { value in
                            let next = fontScale * Double(value.magnification)
                            fontScale = min(max(next, minScale), maxScale)
                            pinchScale = 1.0
                            isPinching = false
                        }
                )
                .onChange(of: currentLineIndex) { _, newIndex in
                    guard !isPinching, newIndex < lyrics.count else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(lyrics[newIndex].id, anchor: .center)
                    }
                }
            }
            .navigationTitle("lyrics_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(selection: $fontScale) {
                            Text("lyrics_font_small").tag(0.85)
                            Text("lyrics_font_medium").tag(1.0)
                            Text("lyrics_font_large").tag(1.2)
                            Text("lyrics_font_xlarge").tag(1.5)
                        } label: {
                            Text("lyrics_font_size")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task(id: player.currentSong?.id) {
                await loadLyrics()
            }
            .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
                updateCurrentLine()
            }
        }
    }

    private func updateCurrentLine() {
        let time = player.currentTime
        for (index, line) in lyrics.enumerated().reversed() {
            if time >= line.timestamp {
                if currentLineIndex != index {
                    currentLineIndex = index
                }
                break
            }
        }
    }

    private func loadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []
            return
        }

        lyrics = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) ?? []
        currentLineIndex = 0
    }
}
