import SwiftUI
import PrimuseKit

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var showNowPlaying = false

    @ViewBuilder
    private var tabRoot: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "home_title"), systemImage: "house.fill", value: 0) {
                HomeView(switchToSettingsTab: { selectedTab = 3 })
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
    }

    var body: some View {
        ZStack {
            // iOS 26 tabViewBottomAccessory modifier 一旦挂上, 即使闭包返回
            // EmptyView 也会保留 accessory 的视觉占位 (底部一条透明空白)。
            // 所以这里走 if/else 分支, currentSong 为 nil 时整个 modifier
            // 不挂, 让 TabBar 紧贴底部。
            if player.currentSong != nil {
                tabRoot
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        NowPlayingAccessory(onTap: { showNowPlaying = true })
                    }
            } else {
                tabRoot
            }

            // Player overlay — mounted on demand. NowPlayingView holds heavy
            // observers (player, library, lyrics) and a 0.3s timer; keeping it
            // mounted while the user is on the song list means scrolling pays
            // for those observations every time anything in the player state
            // changes. The slide-in animation is driven by PlayerOverlay's
            // own internal `entered` state on first appear.
            if showNowPlaying {
                PlayerOverlay(isPresented: $showNowPlaying)
            }
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
    /// Drives the entrance animation. Starts `false` on mount so the first
    /// frame renders off-screen (offset = screenHeight + 100); `onAppear`
    /// flips it inside a `withAnimation` so SwiftUI animates the offset to 0.
    /// Without this, the view would render immediately on-screen with no
    /// slide-in because `if showNowPlaying` mounts the view *during*
    /// presentation, not before.
    @State private var entered = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var dismissScale: CGFloat = 1
    @State private var dismissOpacity: CGFloat = 1
    @State private var screenHeight: CGFloat = UIScreen.main.bounds.height

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
            .offset(y: entered ? dragOffset : screenHeight + 100)
            .ignoresSafeArea()
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isDismissing, entered else { return }
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        guard !isDismissing, entered else { return }
                        if dragOffset > 150 || value.predictedEndTranslation.height > 500 {
                            dismissPlayer()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .animation(.spring(response: 0.45, dampingFraction: 0.92), value: entered)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: dragOffset)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) {
                    entered = true
                }
            }
    }

    private func dismissPlayer() {
        isDismissing = true
        // Shrink toward the mini player at the bottom; on completion, drop
        // `isPresented` so the parent unmounts the overlay entirely. State
        // reset is unnecessary — the next presentation gets fresh @State.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            dismissScale = 0.12
            dismissOpacity = 0
            dragOffset = screenHeight * 0.6
        } completion: {
            isPresented = false
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
                        ZStack {
                            Image(systemName: "play.fill")
                                .font(isInline ? .subheadline : .body)
                                .opacity(0)
                            if player.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(isInline ? .subheadline : .body)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: isInline ? 28 : 32, height: isInline ? 28 : 32)
                    }
                    .disabled(player.isLoading)

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
