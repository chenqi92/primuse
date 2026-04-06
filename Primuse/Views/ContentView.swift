import SwiftUI
import PrimuseKit

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(String(localized: "home_title"), systemImage: "house.fill", value: 0) {
                    HomeView(
                        switchToSettingsTab: { selectedTab = 3 }
                    )
                }

                Tab(String(localized: "library_title"), systemImage: "books.vertical", value: 1) {
                    LibraryView()
                }

                Tab(String(localized: "search_title"), systemImage: "magnifyingglass", value: 2, role: .search) {
                    SearchView(searchText: $searchText)
                }

                Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 3) {
                    SettingsView()
                }
            }
            .tabBarMinimizeBehavior(player.currentSong != nil ? .onScrollDown : .never)
            .tabViewBottomAccessory(isEnabled: player.currentSong != nil) {
                NowPlayingAccessory(onTap: {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) {
                        showNowPlaying = true
                    }
                })
            }

            // Player overlay — uses manual offset (no system transition/fullScreenCover)
            PlayerOverlay(isPresented: $showNowPlaying)
        }
        .onChange(of: library.visibleSongs.count) { _, _ in
            guard let cs = player.currentSong else { return }
            if !library.visibleSongs.contains(where: { $0.id == cs.id }) {
                player.stop(); player.queue = []; showNowPlaying = false
            }
        }
        // SSL trust prompt
        .alert(
            String(localized: "ssl_trust_title"),
            isPresented: Binding(
                get: { SSLTrustStore.shared.pendingTrustRequest != nil },
                set: { if !$0 { SSLTrustStore.shared.resolveTrustRequest(approved: false) } }
            )
        ) {
            Button(String(localized: "trust_domain"), role: .destructive) {
                SSLTrustStore.shared.resolveTrustRequest(approved: true)
            }
            Button(String(localized: "dont_trust"), role: .cancel) {
                SSLTrustStore.shared.resolveTrustRequest(approved: false)
            }
        } message: {
            if let domain = SSLTrustStore.shared.pendingTrustRequest?.domain {
                Text("ssl_trust_message \(domain)")
            }
        }
    }
}

// MARK: - Player Overlay (handles position, drag, rounded corners)

struct PlayerOverlay: View {
    @Binding var isPresented: Bool
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var dismissScale: CGFloat = 1
    @State private var dismissOpacity: CGFloat = 1
    @State private var screenHeight: CGFloat = 900

    /// Device screen corner radius (matches physical display)
    private let deviceCornerRadius: CGFloat = 55

    private var dismissProgress: CGFloat {
        min(1, max(0, dragOffset / 400))
    }

    /// Corner radius ramps up to device screen corner radius as user drags down
    private var topCornerRadius: CGFloat {
        if isDismissing { return deviceCornerRadius }
        return dragOffset > 5 ? min(deviceCornerRadius, dragOffset * 1.5) : 0
    }

    /// Bottom corner radius during dismiss (all corners round as it shrinks)
    private var bottomCornerRadius: CGFloat {
        isDismissing ? deviceCornerRadius : 0
    }

    var body: some View {
        NowPlayingView()
            .background {
                GeometryReader { geo in
                    Color.clear.onAppear { screenHeight = geo.size.height }
                }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: topCornerRadius,
                    bottomLeadingRadius: bottomCornerRadius,
                    bottomTrailingRadius: bottomCornerRadius,
                    topTrailingRadius: topCornerRadius
                )
            )
            .scaleEffect(
                isDismissing ? dismissScale : (1 - dismissProgress * 0.04),
                anchor: .bottom
            )
            .opacity(isDismissing ? dismissOpacity : 1)
            .offset(y: isPresented || isDismissing ? dragOffset : screenHeight + 100)
            .ignoresSafeArea()
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isDismissing, isPresented else { return }
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        guard !isDismissing, isPresented else { return }
                        if dragOffset > 150 || value.predictedEndTranslation.height > 500 {
                            dismissPlayer()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .animation(.spring(response: 0.45, dampingFraction: 0.92), value: isPresented)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: dragOffset)
    }

    private func dismissPlayer() {
        isDismissing = true
        // Shrink toward the mini player at the bottom
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            dismissScale = 0.12
            dismissOpacity = 0
            dragOffset = screenHeight * 0.6
        } completion: {
            isPresented = false
            // Reset for next presentation
            dragOffset = 0
            dismissScale = 1
            dismissOpacity = 1
            isDismissing = false
        }
    }
}

// MARK: - Now Playing Accessory (adapts to inline/expanded)

struct NowPlayingAccessory: View {
    var onTap: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        ZStack {
            // Background tap area → opens player
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            HStack(spacing: 0) {
                // Fixed left: cover art
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: isInline ? 32 : 40,
                    cornerRadius: isInline ? 6 : 8,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath
                )
                .padding(.trailing, isInline ? 10 : 10)

                // Flexible middle: song title fills remaining space
                Text(player.currentSong?.title ?? "")
                    .font(isInline ? .caption : .caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Fixed right: transport controls
                HStack(spacing: isInline ? 0 : 4) {
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(isInline ? .subheadline : .body)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: isInline ? 28 : 32, height: isInline ? 28 : 32)
                    }

                    if !isInline {
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.caption)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, isInline ? 12 : 8)
            .padding(.vertical, isInline ? 2 : 4)
        }
    }
}



#Preview {
    ContentView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
