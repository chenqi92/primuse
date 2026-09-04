import SwiftUI

#if os(iOS)
struct ImmersiveLibraryDetailScrollView<Header: View, Content: View>: View {
    private let header: (CGFloat) -> Header
    private let content: Content

    init(
        @ViewBuilder header: @escaping (CGFloat) -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header(geometry.safeAreaInsets.top)
                    content
                }
                // Horizontal artwork shelves must not determine the page width.
                .frame(width: geometry.size.width)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
#endif

struct LibraryDetailActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var emphasized = false
    var onArtwork = true
    var fillsWidth = false
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(emphasized || onArtwork ? Color.white : Color.accentColor)
                .padding(.horizontal, 20)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 48)
                .background(
                    emphasized ? Color.accentColor
                        : (onArtwork ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.12)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

struct MediaDetailActionBar: View {
    let canPlay: Bool
    let canShuffle: Bool
    let playAction: () -> Void
    let shuffleAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: playAction) {
                Label("play_all", systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPlay)

            Button(action: shuffleAction) {
                Label("shuffle", systemImage: "shuffle")
                    .frame(minWidth: 112)
            }
            .buttonStyle(.bordered)
            .disabled(!canShuffle)

            #if os(macOS)
            // macOS 详情区按钮靠左,不撑满。
            Spacer(minLength: 0)
            #endif
        }
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
        #if os(iOS)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        #endif
    }
}
