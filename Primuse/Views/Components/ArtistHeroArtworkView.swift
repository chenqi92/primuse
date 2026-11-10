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
    var onAppearanceChange: (Color?, [LiquidBackdropColor]) -> Void = { _, _ in }
    var onNameArtworkChange: (PlatformImage?) -> Void = { _ in }
    var allowsMetadataNetwork = false
    var metadataNetworkGeneration: UInt64 = 0

    @Environment(MusicLibrary.self) private var library
    @State private var source: LoadedSource?
    @State private var prepared: PreparedField?
    @State private var unprocessedArtistID: String?
    @State private var captionWeight = 1.0

    private struct LoadedSource {
        let artistID: String
        let image: PlatformImage
    }

    private struct Request: Hashable {
        let artistID: String
        let imageID: ObjectIdentifier
        let width: Double
        let height: Double
        let allowsMetadataNetwork: Bool
        let networkGeneration: UInt64
    }

    private struct PreparedField {
        let request: Request
        let source: PlatformImage
        let image: CGImage
        let captionColor: ArtistHeroArtworkColor?
        let palette: [LiquidBackdropColor]
    }

    private var geometry: ArtistHeroArtworkGeometry? {
        // Safe-area/title space may make the header taller than its width.
        // It must not enlarge a square portrait and crop its sides a second time.
        ArtistHeroArtworkGeometry(width: size.width, photoHeight: min(size.width, size.height))
    }

    private var image: PlatformImage? {
        source?.artistID == artist.id ? source?.image : nil
    }

    private var request: Request? {
        guard let image, let geometry else { return nil }
        return Request(artistID: artist.id, imageID: ObjectIdentifier(image),
                       width: geometry.width, height: geometry.photoHeight,
                       allowsMetadataNetwork: allowsMetadataNetwork,
                       networkGeneration: metadataNetworkGeneration)
    }

    var body: some View {
        let geometry = geometry
        let request = request
        let photoHeight = geometry?.photoHeight ?? size.height
        ZStack(alignment: .top) {
            if let geometry, let prepared, prepared.request.artistID == artist.id,
               unprocessedArtistID != artist.id {
                Image(decorative: prepared.image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: geometry.totalHeight)

                UploadedArtworkAnimation(
                    contentID: library.artworkPresentation(for: LibraryArtworkOwner(kind: .artist, id: artist.id)).uploadedContentID,
                    presentationRole: .animatedHero
                ) {
                    Image(uiImage: prepared.source).resizable().scaledToFill()
                }
                    .frame(width: size.width, height: photoHeight)
                    .clipped()
                    .mask {
                        opacityMask(height: photoHeight, opacity: geometry.sharpOpacity)
                    }
            } else if unprocessedArtistID != artist.id {
                Image(systemName: "music.mic")
                    .font(.system(size: min(size.width, size.height) * 0.25))
                    .foregroundStyle(.secondary)
                    .frame(width: size.width, height: photoHeight)
            }

            // Load invisibly, then commit the matching sharp image, field and
            // sampled page colors together. A partial field is never displayed.
            ArtistArtworkView(
                artist: artist,
                size: max(size.width, size.height),
                cornerRadius: 0,
                fillsProposedSize: true,
                onImageChange: { image in
                    if let image {
                        previewRecord("image_received", flags: ["hasCGImage": image.cgImage != nil])
                        source = LoadedSource(artistID: artist.id, image: image)
                    } else {
                        source = nil
                    }
                }
            )
            .id(artist.id)
            .frame(width: size.width, height: photoHeight)
            .clipped()
            .opacity(unprocessedArtistID == artist.id ? 1 : 0)
            .onPreferenceChange(ArtworkImagePreferenceKey.self) { artwork in
                // A resolved MusicKit view can draw an image without exposing
                // CPU pixels. Keep that view visible instead of hiding it forever.
                if let artwork, artwork.image == nil {
                    showUnprocessedArtwork()
                }
            }

        }
        .frame(width: size.width, height: geometry?.totalHeight ?? size.height, alignment: .top)
        .modifier(ArtistHeroPhotoParallaxModifier())
        .mask {
            if let geometry {
                opacityMask(height: geometry.totalHeight) {
                    geometry.finalOpacity(at: $0, captionWeight: captionWeight)
                }
            } else {
                Color.black
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            previewRecord("task_started")
            guard let request, let geometry, let image else {
                prepared = nil
                captionWeight = 1
                onImageChange(nil)
                onAppearanceChange(nil, [])
                onNameArtworkChange(nil)
                return
            }
            guard let cgImage = image.cgImage else {
                previewRecord("no_readable_pixels")
                showUnprocessedArtwork()
                return
            }
            let orientation = Self.exifOrientation(image.imageOrientation)
            let rendering = Task.detached(priority: .utility) {
                let field = ArtistHeroArtworkField.prepare(
                    image: cgImage, geometry: geometry, exifOrientation: orientation
                )
                return (field, ThemeService.extractLiquidPalette(from: image))
            }
            let (result, palette) = await withTaskCancellationHandler {
                await rendering.value
            } onCancel: {
                rendering.cancel()
            }
            guard !Task.isCancelled, self.request == request else { return }
            guard let result else {
                previewRecord("field_unavailable")
                showUnprocessedArtwork()
                return
            }
            let cachedBackground = await ArtistHeroBackgroundResolver.shared.resolve(
                artistName: artist.name, image: cgImage, exifOrientation: orientation,
                allowNetwork: false
            )
            guard !Task.isCancelled, self.request == request else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                prepared = PreparedField(request: request, source: image, image: result.image,
                                         captionColor: result.captionColor, palette: palette)
                unprocessedArtistID = nil
                onImageChange(image)
                applyBackground(cachedBackground ?? result.sourceBackground ?? result.edgeColor)
                onNameArtworkChange(nil)
            }
            // The portrait does not wait for the optional MusicKit metadata.
            // A matching, verified Apple color may refine the page background;
            // it can never change the photograph or revive a stale request.
            guard allowsMetadataNetwork, cachedBackground == nil else {
                previewRecord("network_not_needed_or_disallowed")
                return
            }
            previewRecord("network_started")
            let metadataName = artist.name
            let metadataNetworkAllowed = allowsMetadataNetwork
            let official = await ArtistHeroBackgroundResolver.shared.resolve(
                artistName: metadataName, image: cgImage, exifOrientation: orientation,
                allowNetwork: metadataNetworkAllowed
            )
            previewRecord("network_completed", flags: ["background": official != nil])
            guard !Task.isCancelled, self.request == request,
                  prepared?.request == request, unprocessedArtistID != artist.id else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                if let official { applyBackground(official) }
            }
        }
    }

    private func previewRecord(_ stage: String, flags: [String: Bool] = [:]) {
        #if PRIMUSE_ARTIST_HERO_PREVIEW
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let file = base.appendingPathComponent("Primuse/ArtistHeroColors/hero-preview-diagnostics.json")
        var events: [[String: Any]] = []
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attributes[.size] as? NSNumber, size.intValue <= 8_192,
           let bytes = try? Data(contentsOf: file),
           let stored = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
            events = Array(stored.suffix(11))
        }
        events.append(["stage": stage, "time": Date().timeIntervalSince1970,
                       "allowsNetwork": allowsMetadataNetwork,
                       "pathGeneration": metadataNetworkGeneration, "flags": flags])
        guard let bytes = try? JSONSerialization.data(withJSONObject: events), bytes.count <= 8_192 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: file, options: .atomic)
        #endif
    }

    private func applyBackground(_ color: ArtistHeroArtworkColor?) {
        guard let color else {
            captionWeight = 1
            onAppearanceChange(nil, [])
            onNameArtworkChange(nil)
            return
        }
        if let caption = prepared?.captionColor {
            // Reevaluate only when the prepared image or scene color changes.
            // Dark scenes keep the measured linear fade; bright photographs
            // retain enough separation for the artist name and controls.
            captionWeight = ArtistHeroCaptionFade.weight(photo: caption, background: color)
        } else {
            captionWeight = 1
        }
        let tint = Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
        let sample = LiquidBackdropColor(red: color.red, green: color.green, blue: color.blue)
        // Classic uses the scene color; Mesh retains the matching portrait's palette.
        let palette = prepared?.palette ?? []
        onAppearanceChange(tint, palette.isEmpty ? [sample] : palette)
    }

    private func showUnprocessedArtwork() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            unprocessedArtistID = artist.id
            prepared = nil
            source = nil
            captionWeight = 1
            // Do not invent a tint from an image hidden under MusicKit's view.
            onImageChange(nil)
            onAppearanceChange(nil, [])
            onNameArtworkChange(nil)
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

/// Keep the photograph and its prepared blur on one slow-moving plane. The
/// final fade above stays in the header's normal flow, so the moving image
/// cannot expose a sharp lower edge behind the title or the release card.
struct ArtistHeroPhotoParallaxModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reducesMotion = reduceMotion
        content.visualEffect { effect, proxy in
            let scrollY = proxy.frame(in: .scrollView(axis: .vertical)).minY
            let distance = min(max(0, -scrollY), proxy.size.height * 2)
            // Render-time geometry avoids publishing a new view state or
            // preparing another blur field for every scroll frame.
            return effect.offset(y: reducesMotion ? 0 : distance * 0.5)
        }
    }
}
#endif
