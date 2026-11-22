import Foundation
import PrimuseKit
#if os(iOS)
#if os(iOS)
import UIKit
#endif
#else
import AppKit
#endif

actor ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let cacheDirectory: URL
    private var budgetGeneration = 0

    private init() {
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = DecodedImageCacheBudget.foregroundLimit(for: .imageCache)

        let cacheDir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        cacheDirectory = cacheDir.appendingPathComponent("cover_art")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func image(forKey key: String) -> PlatformImage? {
        // Check memory cache
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        let fileURL = cacheDirectory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let image = PlatformImage(data: data) else {
            return nil
        }

        memoryCache.setObject(image, forKey: key as NSString, cost: Self.pixelByteCost(of: image))
        return image
    }

    func store(_ image: PlatformImage, forKey key: String) {
        memoryCache.setObject(image, forKey: key as NSString, cost: Self.pixelByteCost(of: image))

        let fileURL = cacheDirectory.appendingPathComponent(key)
        #if os(iOS)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileURL)
        }
        #else
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: fileURL)
        }
        #endif
    }

    func store(data: Data, forKey key: String) {
        if let image = PlatformImage(data: data) {
            store(image, forKey: key)
        }
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// 换内存层的上限(`DecodedImageCacheBudget`):退到后台时先清空再压低,回到前台恢复。
    /// `generation` 递增;前后台切得快时晚到的旧一次不覆盖新的。
    func applyMemoryBudget(_ limit: Int, purge: Bool, generation: Int) {
        guard generation >= budgetGeneration else { return }
        budgetGeneration = generation
        if purge { memoryCache.removeAllObjects() }
        memoryCache.totalCostLimit = limit
    }

    private nonisolated static func pixelByteCost(of image: PlatformImage) -> Int {
        #if os(iOS)
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let scale = max(1, image.scale)
        let width = Int(ceil(image.size.width * scale))
        let height = Int(ceil(image.size.height * scale))
        return max(1, width * height * 4)
        #else
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let width = Int(ceil(image.size.width * 2))
        let height = Int(ceil(image.size.height * 2))
        return max(1, width * height * 4)
        #endif
    }

    func clearDiskCache() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for file in contents {
            try FileManager.default.removeItem(at: file)
        }
        memoryCache.removeAllObjects()
    }

    func diskCacheSize() throws -> Int64 {
        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        return try contents.reduce(0) { total, url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return total + Int64(size)
        }
    }
}
