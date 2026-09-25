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

/// 歌曲、专辑没有封面时的默认封面：用户当前选的 App 图标（它的预览资源，带浅色/深色
/// 两套）。换了图标，没封面的歌跟着换。预览图是满版方图、自带底色，这里只负责铺满；
/// 圆角与裁切交给调用方原有的 clipShape。
struct DefaultCoverArtwork: View {
    /// 当前图标的预览资源名。两个设置都是 @Observable，读它的视图会随切换刷新。
    @MainActor
    static var assetName: String {
        #if os(iOS)
        let service = AppIconService.shared
        return service.options.first { $0.id == service.currentIconID }?.previewAsset ?? "AppIconPreview"
        #elseif os(macOS)
        return MacAppIcon.option(for: MacUIPreferences.shared.appIconID).previewAsset
        #else
        return "AppIconPreview"
        #endif
    }

    var body: some View {
        Image(Self.assetName)
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
