import Foundation
import Testing
@testable import PrimuseKit

@Suite("MusicKit artist artwork URL policy")
struct ArtistHeroMetadataPolicyTests {
    @Test func onlyOfficialImageAssetsAreAccepted() {
        #expect(ArtistHeroMetadataPolicy.isArtworkURL(URL(string: "https://is1-ssl.mzstatic.com/image/thumb/photo/384x384bb.jpg")!))
        for value in ["https://music.apple.com/cn/artist/123", "https://itunes.apple.com/search", "https://mzstatic.com.attacker.test/image/photo.jpg", "http://is1-ssl.mzstatic.com/image/photo.jpg", "https://user:secret@is1-ssl.mzstatic.com/image/photo.jpg"] {
            #expect(!ArtistHeroMetadataPolicy.isArtworkURL(URL(string: value)!))
        }
    }
}

#if canImport(CoreGraphics) && canImport(CoreImage)
import CoreGraphics
import ImageIO

@Suite("Artist photo content verification")
struct ArtistHeroPhotoVerificationTests {
    private func bitmap(size: Int = 160, flipped: Bool = false, noisy: Bool = false, alpha: UInt8 = 255) throws -> CGImage {
        var data = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let px = flipped ? size - x - 1 : x
                let offset = (y * size + x) * 4
                let noise = noisy ? (x + y) % 3 - 1 : 0
                data[offset] = UInt8(max(0, min(255, 20 + px * 180 / size + noise)))
                data[offset + 1] = UInt8(max(0, min(255, 20 + y * 140 / size + noise)))
                data[offset + 2] = UInt8(40 + (px + y) * 80 / size)
                data[offset + 3] = alpha
            }
        }
        let provider = try #require(CGDataProvider(data: Data(data) as CFData))
        return try #require(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    @Test("Resize and small decode noise preserve photo identity")
    func resizeNoise() throws {
        let first = try #require(ArtistHeroPhotoVerification.signature(image: bitmap()))
        let resized = try #require(ArtistHeroPhotoVerification.signature(image: bitmap(size: 96, noisy: true)))
        #expect(ArtistHeroPhotoVerification.matches(first, resized))
    }

    @Test("The same histogram with a different composition cannot verify a color")
    func rejectComposition() throws {
        let first = try #require(ArtistHeroPhotoVerification.signature(image: bitmap()))
        let mirrored = try #require(ArtistHeroPhotoVerification.signature(image: bitmap(flipped: true)))
        #expect(!ArtistHeroPhotoVerification.matches(first, mirrored))
        let wrongShape = try #require(ArtistHeroPhotoSignature(samples: first.samples, aspectRatio: 1.5))
        #expect(!ArtistHeroPhotoVerification.matches(first, wrongShape))
    }

    @Test("Flat placeholders and partial transparency never pass photo verification")
    func rejectPlaceholder() throws {
        let flat = try #require(ArtistHeroPhotoSignature(samples: [UInt8](repeating: 120, count: 768), aspectRatio: 1))
        #expect(!ArtistHeroPhotoVerification.matches(flat, flat))
        #expect(ArtistHeroPhotoVerification.signature(image: try bitmap(alpha: 0)) == nil)
    }
}
#endif
