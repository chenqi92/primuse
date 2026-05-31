import SwiftUI

struct ArtworkView: View {
    let data: Data?
    var cornerRadius: CGFloat = 16

    var body: some View {
        Group {
            if let data, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(radius: 10, y: 5)
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    ArtworkView(data: nil)
        .padding(40)
}
