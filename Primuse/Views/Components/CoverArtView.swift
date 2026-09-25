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
                DefaultCoverArtwork()
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

/// 歌曲、专辑没有封面时的默认封面：「Chris's Muse」插画（资源 DefaultCover，
/// 浅色/深色各一张，不随用户挑选的 App 图标变化）。插画本身是满版方图、自带底色，
/// 这里只负责铺满；圆角与裁切交给调用方原有的 clipShape。
struct DefaultCoverArtwork: View {
    var body: some View {
        Image("DefaultCover")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
    }
}

#if os(macOS)
struct MacDefaultArtwork: View {
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DefaultCoverArtwork()
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
