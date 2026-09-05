import SwiftUI

struct CoverArtView: View {
    let data: Data?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let data, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                #if os(macOS)
                MacDefaultArtwork()
                #else
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
                #endif
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

#Preview {
    HStack(spacing: 16) {
        CoverArtView(data: nil, size: 40)
        CoverArtView(data: nil, size: 60)
        CoverArtView(data: nil, size: 100)
    }
    .padding()
}

#if os(macOS)
struct MacDefaultArtwork: View {
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("AppIconPreview")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    if isLoading, side >= 120 {
                        VStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Text("app_name")
                                    .font(.system(size: min(max(side * 0.055, 10), 20), weight: .medium))
                                if !reduceMotion {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, side * 0.07)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}
#endif
