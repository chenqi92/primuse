import SwiftUI

/// Loads cover art from the covers cache directory by fileName.
/// Falls back to a gradient placeholder with music note.
struct CachedArtworkView: View {
    let coverFileName: String?
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    /// Single artwork directory — everything stored via MetadataAssetStore
    private static let artworkDir: URL = MetadataAssetStore.shared.artworkDirectoryURL

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderView
            }
        }
        .if(size != nil) { view in
            view.frame(width: size!, height: size!)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear { loadImage() }
        .onChange(of: coverFileName) { _, _ in loadImage() }
    }

    private var placeholderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [Color(.systemGray5), Color(.systemGray4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 200) * 0.25))
                .foregroundStyle(.secondary)
        }
    }

    private func loadImage() {
        guard let coverFileName, !coverFileName.isEmpty else {
            image = nil
            return
        }
        let url = Self.artworkDir.appendingPathComponent(coverFileName)
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            image = img
            return
        }
        image = nil
    }
}

// Helper for conditional modifier
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
