import SwiftUI
import PrimuseKit

struct CoverArtView: View {
    let data: Data?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8
    /// Mac 上没有数据时是否画音符。默认不画：没数据多半是「还没有当前歌曲」
    /// 或「封面还在读」，冷启动续播恢复前画音符会先闪一下再变成封面。
    /// 只有确认这首歌没有封面时才传 true。
    var showsMissingArtworkIcon = false

    var body: some View {
        Group {
            if let data, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                #if os(macOS)
                if showsMissingArtworkIcon {
                    MacDefaultArtwork()
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
                #else
                OptionalAppIconArtwork {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.ultraThinMaterial)
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.secondary)
                    }
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
    var body: some View {
        OptionalAppIconArtwork {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.32))
                            .foregroundStyle(.secondary)
                    }
            }
            .accessibilityHidden(true)
        }
    }
}
#endif

struct OptionalAppIconArtwork<Fallback: View>: View {
    @AppStorage(MissingArtworkStyle.storageKey) private var styleRawValue = MissingArtworkStyle.standard.rawValue
    let symbol: String
    private let fallback: Fallback

    init(symbol: String = "music.note", @ViewBuilder fallback: () -> Fallback) {
        self.symbol = symbol
        self.fallback = fallback()
    }

    var body: some View {
        if MissingArtworkStyle(storedValue: styleRawValue).usesAppIcon(forPlaceholderSymbol: symbol) {
            CurrentAppIconArtwork()
        } else {
            fallback
        }
    }
}

struct CurrentAppIconArtwork: View {
    #if os(macOS)
    @AppStorage("pm.mac.appIcon") private var iconID = ""
    #else
    @AppStorage("primuse.appIconChoice") private var iconID = ""
    #endif

    private var previewAsset: String {
        #if os(macOS)
        MacAppIcon.option(for: iconID).previewAsset
        #else
        AppIconService.shared.availableOptions.first { $0.id == iconID }?.previewAsset ?? "AppIconPreview"
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            Image(previewAsset)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .accessibilityHidden(true)
    }
}
