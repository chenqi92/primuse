import Foundation
import Testing
@testable import PrimuseKit

@Suite("Photo-verified artist public color metadata")
struct ArtistHeroMetadataPolicyTests {
    private let id = "12345678"
    private let asset = "01234567-89ab-cdef-0123-456789abcdef"

    private func art(color: String = "35404b", host: String = "is1-ssl.mzstatic.com") -> [String: Any] {
        ["dictionary": ["bgColor": color, "width": 1080, "height": 1080,
                        "url": "https://\(host)/image/thumb/Features/v4/\(asset)/portrait.jpg/{w}x{h}{c}.{f}"]]
    }

    private func header(artwork: [String: Any]? = nil) -> [String: Any] {
        ["id": id, "artwork": artwork ?? art(),
         "contentDescriptor": ["kind": "artist", "identifiers": ["storeAdamID": id]]]
    }

    private func document(_ sections: [[String: Any]]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["data": [["data": ["sections": sections]]]])
        let body = String(decoding: json, as: UTF8.self)
        return Data("<script type='application/json' id='serialized-server-data'>\(body)</script>".utf8)
    }

    @Test("Search requires one exact normalized artist identity")
    func uniqueNames() throws {
        func row(_ id: Int, _ name: String) -> [String: Any] {
            ["artistId": id, "artistName": name, "wrapperType": "artist", "artistType": "Artist"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["results": [row(12, "陳奕迅"), row(13, "Another artist"), row(12, "陈奕迅")]])
        #expect(ArtistHeroMetadataPolicy.uniqueArtistID(in: data, named: " 陈奕迅 ") == "12")
        let ambiguous = try JSONSerialization.data(withJSONObject: ["results": [row(12, "Name"), row(13, "name")]])
        #expect(ArtistHeroMetadataPolicy.uniqueArtistID(in: ambiguous, named: "Name") == nil)
        #expect(ArtistHeroMetadataPolicy.uniqueArtistID(in: data, named: "Unknown") == nil)
    }

    @Test("Only the selected artist header supplies colors; album and related entries are ignored")
    func headerScope() throws {
        let data = try document([
            ["id": "Albums", "items": [header(artwork: art(color: "ff0000"))]],
            ["id": "Artists_ArtistDetailHeader", "items": [header()]],
        ])
        let parsed = ArtistHeroMetadataPolicy.candidates(in: data, artistID: id)
        #expect(parsed.count == 1)
        #expect(parsed.first?.backgroundHex == "35404b")
        #expect(parsed.first?.imageURL.absoluteString.hasSuffix("384x384bb.jpg") == true)
        #expect(ArtistHeroMetadataPolicy.candidates(in: data, artistID: "999") == [])
        var mismatched = header()
        mismatched["contentDescriptor"] = ["kind": "artist", "identifiers": ["storeAdamID": "999"]]
        #expect(ArtistHeroMetadataPolicy.candidates(in: try document([["id": "ArtistDetailHeader", "items": [mismatched]]]), artistID: id).isEmpty)
    }

    @Test("A backdrop's own color stays bound to its own photo candidate")
    func backdropOwnership() throws {
        var item = header()
        var backdrop = art(color: "112233")
        var dictionary = backdrop["dictionary"] as! [String: Any]
        dictionary["url"] = "https://is1-ssl.mzstatic.com/image/11111111-2222-3333-4444-555555555555/{w}x{h}{c}.{f}"
        backdrop["dictionary"] = dictionary
        item["colorBackdropArtwork"] = backdrop
        let values = ArtistHeroMetadataPolicy.candidates(in: try document([["id": "ArtistDetailHeader", "items": [item]]]), artistID: id)
        #expect(values.count == 2)
        #expect(values[0].backgroundHex == "112233")
        #expect(values[1].backgroundHex == "35404b")
        #expect(values[0].assetID != values[1].assetID)
    }

    @Test("Malformed, oversized and foreign-host candidates are rejected")
    func rejectUntrusted() throws {
        for invalid in [art(color: "white"), art(host: "mzstatic.com.attacker.test"), art(host: "user:secret@is1-ssl.mzstatic.com")] {
            #expect(ArtistHeroMetadataPolicy.candidates(in: try document([["id": "ArtistDetailHeader", "items": [header(artwork: invalid)]]]), artistID: id).isEmpty)
        }
        #expect(ArtistHeroMetadataPolicy.candidates(in: Data(repeating: 32, count: ArtistHeroMetadataPolicy.maximumDocumentBytes + 1), artistID: id).isEmpty)
        #expect(ArtistHeroMetadataPolicy.candidates(in: Data("<script>{}</script>".utf8), artistID: id).isEmpty)
        #expect(ArtistHeroMetadataPolicy.artworkAssetID(URL(string: "http://is1-ssl.mzstatic.com/image/\(asset)/test.jpg")!) == nil)
    }

    @Test("Official name artwork belongs to the verified artist header, never a related artist")
    func nameArtworkOwnership() throws {
        let logo: [String: Any] = ["dictionary": ["width": 3000, "height": 600,
            "url": "https://is1-ssl.mzstatic.com/image/logo/{w}x{h}{c}.{f}"]]
        var selected = header()
        selected["artistLogo"] = logo
        let values = ArtistHeroMetadataPolicy.candidates(in: try document([
            ["id": "Albums", "items": [selected]],
            ["id": "ArtistDetailHeader", "items": [selected]],
        ]), artistID: id)
        let parsed = try #require(values.first?.nameArtwork)
        #expect(parsed.width == 1200 && parsed.height == 240)
        #expect(parsed.imageURL.path.hasSuffix("1200x240bb.png"))
        let unrelated = try document([["id": "Albums", "items": [selected]],
                                      ["id": "ArtistDetailHeader", "items": [header()]]])
        #expect(ArtistHeroMetadataPolicy.candidates(in: unrelated, artistID: id).first?.nameArtwork == nil)
        selected["id"] = "87654321"
        #expect(ArtistHeroMetadataPolicy.candidates(in: try document([["id": "ArtistDetailHeader", "items": [selected]]]), artistID: id).isEmpty)
    }

    @Test("Non-PNG, foreign, credential-bearing and invalid-size logo candidates are ignored")
    func rejectInvalidNameArtwork() throws {
        let urls = ["https://is1-ssl.mzstatic.com/image/logo/name.jpg", "http://is1-ssl.mzstatic.com/image/logo/name.png",
                    "https://mzstatic.com.example/image/logo/name.png", "https://user:secret@is1-ssl.mzstatic.com/image/logo/name.png"]
        for url in urls {
            var item = header()
            item["artistLogo"] = ["dictionary": ["url": url, "width": 1000, "height": 200]]
            #expect(ArtistHeroMetadataPolicy.candidates(in: try document([["id": "ArtistDetailHeader", "items": [item]]]), artistID: id).first?.nameArtwork == nil)
        }
        var item = header()
        item["artistLogo"] = ["dictionary": ["url": "https://is1-ssl.mzstatic.com/image/logo/name.png", "width": 0, "height": 200]]
        #expect(ArtistHeroMetadataPolicy.candidates(in: try document([["id": "ArtistDetailHeader", "items": [item]]]), artistID: id).first?.nameArtwork == nil)
    }
}

#if canImport(CoreGraphics) && canImport(CoreImage)
import CoreGraphics
import ImageIO

@Suite("Bounded artist name PNG")
struct ArtistHeroNameArtworkTests {
    private func encoded(width: Int, type: String = "public.png") throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: (type == "public.jpeg" ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 8, width: width, height: 16))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("Keep the original PNG bytes and transparency, with bounded verified dimensions")
    func validPNG() throws {
        let bytes = try encoded(width: 500)
        let artwork = try #require(ArtistHeroNameArtwork(pngData: bytes))
        #expect(artwork.data == bytes)
        #expect(artwork.width == 500 && artwork.height == 32)
    }

    @Test("Reject oversized, truncated and disguised non-PNG payloads")
    func rejectInvalidPNG() throws {
        #expect(ArtistHeroNameArtwork(pngData: try encoded(width: 1201)) == nil)
        #expect(ArtistHeroNameArtwork(pngData: try encoded(width: 500, type: "public.jpeg")) == nil)
        let bytes = try encoded(width: 500)
        #expect(ArtistHeroNameArtwork(pngData: bytes.prefix(24)) == nil)
        #expect(ArtistHeroNameArtwork(pngData: Data(repeating: 0, count: ArtistHeroNameArtwork.maximumBytes + 1)) == nil)
    }
}

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
