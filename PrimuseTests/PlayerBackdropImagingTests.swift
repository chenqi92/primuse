import CoreGraphics
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class PlayerBackdropImagingTests: XCTestCase {
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(PlayerBackdropImaging.jpegData(image, quality: 0.9))
    }

    func testTwelveMegapixelPhotoIsStoredAtScreenSizeAndDecodesQuickly() throws {
        let original = try makeJPEG(width: 4032, height: 3024)
        let maxPixel = PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: 2868)

        let importStart = Date()
        let id = try XCTUnwrap(PlayerBackdropImageStore.importImage(original, maxPixel: maxPixel))
        let importSeconds = Date().timeIntervalSince(importStart)
        defer { PlayerBackdropImageStore.remove(id: id) }

        XCTAssertTrue(PlayerBackdropImageStore.exists(id: id))
        XCTAssertTrue(LibraryArtworkContentIDPolicy.isValid(id))
        let stored = try XCTUnwrap(PlayerBackdropImageStore.data(id: id))
        XCTAssertLessThan(stored.count, original.count)
        XCTAssertEqual(PlayerBackdropImaging.contentID(for: stored), id)

        let decodeStart = Date()
        let url = try XCTUnwrap(PlayerBackdropImageStore.fileURL(id: id))
        let decoded = try XCTUnwrap(PlayerBackdropImaging.decodedImage(url: url, maxPixel: maxPixel))
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        XCTAssertEqual(max(decoded.width, decoded.height), maxPixel)
        XCTAssertEqual(min(decoded.width, decoded.height), maxPixel * 3 / 4)
        // 计时只记下来看，不做断言：编译机常年高负载，计时断言会假失败。
        print("🖼 backdrop import 12MP=\(importSeconds)s decode=\(decodeSeconds)s")

        // 同一张图再导入一次得到同一个 id，不重复占空间。
        XCTAssertEqual(PlayerBackdropImageStore.importImage(original, maxPixel: maxPixel), id)
    }

    func testUnreadableDataIsRejected() {
        XCTAssertNil(PlayerBackdropImageStore.importImage(Data("not an image".utf8), maxPixel: 2_048))
        XCTAssertNil(PlayerBackdropImageStore.importImage(Data(), maxPixel: 2_048))
    }

    func testTransferredImageMustMatchItsID() throws {
        let jpeg = try makeJPEG(width: 640, height: 360)
        let id = PlayerBackdropImaging.contentID(for: jpeg)
        XCTAssertNil(PlayerBackdropImageStore.storeProcessed(jpeg, expectedID: String(repeating: "0", count: 64)))
        XCTAssertEqual(PlayerBackdropImageStore.storeProcessed(jpeg, expectedID: id), id)
        PlayerBackdropImageStore.remove(id: id)
        XCTAssertFalse(PlayerBackdropImageStore.exists(id: id))
    }

    func testCoverBlurIsASmallStaticBitmap() throws {
        let data = try makeJPEG(width: 1_200, height: 1_200)
        let cover = try XCTUnwrap(PlayerBackdropImaging.decodedImage(data: data, maxPixel: 1_200))
        let blurred = try XCTUnwrap(PlayerBackdropImaging.blurredBackdrop(from: cover))
        XCTAssertLessThanOrEqual(max(blurred.width, blurred.height), PlayerBackdropPixelPolicy.blurSourcePixel)
        XCTAssertGreaterThan(blurred.width, 0)
    }

    /// 铺满封面的延伸底图：封面下沿那一条接上它的镜像，接缝处是封面最下面的颜色，两头是往上一点的颜色。
    func testFullBleedExtensionMirrorsTheBottomEdgeAroundTheSeam() throws {
        let side = 400
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // CGContext 原点在左下：先铺橙色，再在最下面 10% 画一道红。
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.9, green: 0.08, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side / 10))
        let cover = try XCTUnwrap(context.makeImage())

        let extended = try XCTUnwrap(PlayerBackdropImaging.fullBleedExtension(from: cover, fraction: 0.4))
        XCTAssertLessThanOrEqual(extended.width, 96)
        // 上下两半各是封面高度的 0.4，按同一比例缩小。
        XCTAssertEqual(Double(extended.height), Double(extended.width) * 0.8, accuracy: 2)

        let pixels = try rgbaPixels(of: extended)
        func green(row: Int) -> UInt8 { pixels[(row * extended.width + extended.width / 2) * 4 + 1] }
        let seam = extended.height / 2
        XCTAssertLessThan(green(row: seam), green(row: 1))
        XCTAssertLessThan(green(row: seam), green(row: extended.height - 2))
    }

    private func rgbaPixels(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testCustomImageListStaysLocalAndRemovingDeletesTheFile() throws {
        let suite = "PlayerBackdropImagingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        let first = try XCTUnwrap(PlayerBackdropImageStore.importImage(try makeJPEG(width: 800, height: 600), maxPixel: 1_280))
        let second = try XCTUnwrap(PlayerBackdropImageStore.importImage(try makeJPEG(width: 600, height: 800), maxPixel: 1_280))
        defer {
            PlayerBackdropImageStore.remove(id: first)
            PlayerBackdropImageStore.remove(id: second)
        }

        store.update { $0.source = .customImages }
        XCTAssertEqual(store.effectiveSource, .coverAmbient)
        store.appendCustomImages([first, second, first])
        XCTAssertEqual(store.customImageIDs, [first, second])
        XCTAssertEqual(store.effectiveSource, .customImages)
        XCTAssertEqual(defaults.stringArray(forKey: PlayerBackdropSettings.customImagesStorageKey), [first, second])

        // 同步的那份设置里只有来源与轮播，没有图片列表。
        let synced = try XCTUnwrap(defaults.data(forKey: PlayerBackdropSettings.storageKey))
        XCTAssertFalse(String(decoding: synced, as: UTF8.self).contains(first))

        store.removeCustomImage(first)
        XCTAssertEqual(store.customImageIDs, [second])
        XCTAssertFalse(PlayerBackdropImageStore.exists(id: first))

        let reloaded = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        XCTAssertEqual(reloaded.customImageIDs, [second])
        XCTAssertEqual(reloaded.settings.source, .customImages)
    }
}
