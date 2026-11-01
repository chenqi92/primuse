#if os(iOS)
import SwiftUI
import UIKit
import PrimuseKit

/// One sharp image and its once-prepared, lower-resolution continuation.
/// The caller's layout remains the photograph's height, not the extended background's.
struct ArtistHeroArtworkView: View {
    let artist: Artist
    let size: CGSize
    var onImageChange: (PlatformImage?) -> Void

    @State private var source: LoadedSource?
    @State private var prepared: PreparedField?

    private struct LoadedSource {
        let artistID: String
        let image: PlatformImage
    }

    private struct Request: Hashable {
        let artistID: String
        let imageID: ObjectIdentifier
        let width: Double
        let height: Double
    }

    private struct PreparedField {
        let request: Request
        let image: CGImage
    }

    private var geometry: ArtistHeroArtworkGeometry? {
        ArtistHeroArtworkGeometry(width: size.width, photoHeight: size.height)
    }

    private var image: PlatformImage? {
        source?.artistID == artist.id ? source?.image : nil
    }

    private var request: Request? {
        guard let image, let geometry else { return nil }
        return Request(artistID: artist.id, imageID: ObjectIdentifier(image),
                       width: geometry.width, height: geometry.photoHeight)
    }

    var body: some View {
        let geometry = geometry
        let request = request
        ZStack(alignment: .top) {
            if let geometry, let request, let prepared, prepared.request == request {
                Image(decorative: prepared.image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: geometry.totalHeight)
            }

            ArtistArtworkView(
                artist: artist,
                size: max(size.width, size.height),
                cornerRadius: 0,
                fillsProposedSize: true,
                onImageChange: { image in
                    if let image {
                        source = LoadedSource(artistID: artist.id, image: image)
                    } else {
                        source = nil
                    }
                    onImageChange(image)
                }
            )
            .id(artist.id)
            .frame(width: size.width, height: size.height)
            .clipped()
            .mask {
                if let geometry {
                    opacityMask(height: size.height, opacity: geometry.sharpOpacity)
                } else {
                    Color.black
                }
            }

        }
        .frame(width: size.width, height: geometry?.totalHeight ?? size.height, alignment: .top)
        .mask {
            if let geometry {
                opacityMask(height: geometry.totalHeight, opacity: geometry.finalOpacity)
            } else {
                Color.black
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            guard let request, let geometry, let image, let cgImage = image.cgImage else {
                prepared = nil
                return
            }
            let orientation = Self.exifOrientation(image.imageOrientation)
            let rendering = Task.detached(priority: .utility) {
                ArtistHeroArtworkField.render(
                    image: cgImage, geometry: geometry, exifOrientation: orientation
                )
            }
            let result = await withTaskCancellationHandler {
                await rendering.value
            } onCancel: {
                rendering.cancel()
            }
            guard !Task.isCancelled, self.request == request else { return }
            prepared = result.map { PreparedField(request: request, image: $0) }
        }
    }

    /// Samples a smooth envelope, with a flat sharp region and no abrupt slope at either end.
    private func opacityMask(height: Double, opacity: (Double) -> Double) -> LinearGradient {
        LinearGradient(
            stops: (0...32).map { index in
                let location = Double(index) / 32
                return Gradient.Stop(color: .black.opacity(opacity(location * height)), location: location)
            },
            startPoint: .top, endPoint: .bottom
        )
    }

    private static func exifOrientation(_ orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
    }
}
#endif
