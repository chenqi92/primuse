import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

actor ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let cacheDirectory: URL

    private init() {
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
        guard let data = try? Data(contentsOf: fileURL),
              let image = PlatformImage(data: data) else {
            return nil
        }

        memoryCache.setObject(image, forKey: key as NSString)
        return image
    }

    func store(_ image: PlatformImage, forKey key: String) {
        memoryCache.setObject(image, forKey: key as NSString)

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
