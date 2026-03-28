import SwiftUI
import PrimuseKit

struct LyricsView: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var lyrics: [LyricLine] = []
    @State private var currentLineIndex: Int = 0

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
                                    .font(.title3)
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
                .onChange(of: currentLineIndex) { _, newIndex in
                    guard newIndex < lyrics.count else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(lyrics[newIndex].id, anchor: .center)
                    }
                }
            }
            .navigationTitle("lyrics_title")
            .navigationBarTitleDisplayMode(.inline)
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
}
