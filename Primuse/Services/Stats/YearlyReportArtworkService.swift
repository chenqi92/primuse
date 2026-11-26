import Foundation
import Observation
import PrimuseKit
import SwiftUI
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif
#if os(iOS)
import UIKit
typealias YearlyReportPlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias YearlyReportPlatformImage = NSImage
#endif

/// 年度报告插画的 Apple 托管按需资源包（iOS / macOS 26.4+）。
///
/// 插画不随主安装包下发；首次打开听歌统计或年度报告时在后台下载到本地。
/// 旧系统或离线环境下 `YearlyArtView` 自动回退到内置 SF Symbol 占位图。
/// Debug 构建可通过环境变量 `PRIMUSE_YEARLY_REPORT_ARTWORK=<目录>` 指向本地插画目录。
enum YearlyReportArtworkPack {
    static let assetPackID = "YearlyReportArtwork"
    static let artworkDirectory = "artwork"
    static let sentinelName = "decor_overview_hourglass"
    static let supportedExtensions = ["webp", "png"]

    #if DEBUG
    static var debugOverrideDirectory: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_YEARLY_REPORT_ARTWORK"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #endif

    nonisolated static var isSystemSupported: Bool {
        #if DEBUG
        if debugOverrideDirectory != nil { return true }
        #endif
        if #available(iOS 26.4, macOS 26.4, *) {
            return BackgroundAssetsPrerequisites.isSatisfied
        }
        return false
    }

    nonisolated static func imageURL(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        for ext in supportedExtensions {
            let candidate = directory.appendingPathComponent("\(name).\(ext)", isDirectory: false)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func locateDirectory() -> URL? {
        #if DEBUG
        if let dir = debugOverrideDirectory {
            return resolvedArtworkDirectory(from: dir)
        }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, *),
           let manager = BackgroundAssetsPrerequisites.manager,
           manager.assetPackIsAvailableLocally(withID: assetPackID),
           let url = try? manager.url(for: FilePath(artworkDirectory)) {
            return resolvedArtworkDirectory(from: url)
        }
        #endif
        return nil
    }

    nonisolated static func resolvedArtworkDirectory(from root: URL) -> URL? {
        if imageURL(named: sentinelName, in: root) != nil {
            return root
        }
        let nested = root.appendingPathComponent(artworkDirectory, isDirectory: true)
        if imageURL(named: sentinelName, in: nested) != nil {
            return nested
        }
        return nil
    }

    nonisolated static func download() async throws -> URL {
        if let local = locateDirectory() { return local }
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, *), let manager = BackgroundAssetsPrerequisites.manager {
            let pack = try await AppleHostedAssetPackResolver.assetPack(withID: assetPackID, manager: manager)
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            if let local = locateDirectory() { return local }
        }
        #endif
        throw YearlyReportArtworkError.unavailable
    }

    nonisolated static func remove() async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, *), let manager = BackgroundAssetsPrerequisites.manager {
            try? await manager.remove(assetPackWithID: assetPackID)
        }
        #endif
    }
}

enum YearlyReportArtworkError: Error, Sendable {
    case unavailable
}

@MainActor
@Observable
final class YearlyReportArtworkService {
    static let shared = YearlyReportArtworkService()

    private(set) var artworkDirectory: URL?

    @ObservationIgnored private let isSystemSupportedProvider: @Sendable () -> Bool
    @ObservationIgnored private let locateProvider: @Sendable () -> URL?
    @ObservationIgnored private let downloadProvider: @Sendable () async throws -> URL
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let imageCache: NSCache<NSString, YearlyReportPlatformImage>

    init(
        isSystemSupported: @escaping @Sendable () -> Bool = { YearlyReportArtworkPack.isSystemSupported },
        locate: @escaping @Sendable () -> URL? = { YearlyReportArtworkPack.locateDirectory() },
        download: @escaping @Sendable () async throws -> URL = { try await YearlyReportArtworkPack.download() }
    ) {
        self.isSystemSupportedProvider = isSystemSupported
        self.locateProvider = locate
        self.downloadProvider = download
        let cache = NSCache<NSString, YearlyReportPlatformImage>()
        cache.countLimit = 48
        self.imageCache = cache
    }

    func ensureAvailable() {
        guard artworkDirectory == nil, loadTask == nil else { return }
        let locate = locateProvider
        let isSupported = isSystemSupportedProvider
        let download = downloadProvider
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            let local = await Task.detached(priority: .userInitiated) {
                locate()
            }.value
            if let local {
                self?.setArtworkDirectory(local)
                return
            }
            guard isSupported() else { return }
            do {
                let downloaded = try await Task.detached(priority: .utility) {
                    try await download()
                }.value
                self?.setArtworkDirectory(downloaded)
            } catch is CancellationError {
                return
            } catch {
                plog("YearlyReportArtwork: on-demand fetch unavailable (\(error.localizedDescription))")
            }
        }
    }

    func waitForCurrentLoad() async {
        await loadTask?.value
    }

    func image(named name: String) -> Image? {
        if let directory = artworkDirectory {
            let key = name as NSString
            if let cached = imageCache.object(forKey: key) {
                return Self.swiftUIImage(from: cached)
            }
            if let url = YearlyReportArtworkPack.imageURL(named: name, in: directory),
               let loaded = Self.loadPlatformImage(from: url) {
                imageCache.setObject(loaded, forKey: key)
                return Self.swiftUIImage(from: loaded)
            }
        }
        return Self.bundledImage(named: name)
    }

    private func setArtworkDirectory(_ directory: URL) {
        if artworkDirectory != directory {
            imageCache.removeAllObjects()
            artworkDirectory = directory
        }
    }

    private static func loadPlatformImage(from url: URL) -> YearlyReportPlatformImage? {
        #if os(iOS)
        UIImage(contentsOfFile: url.path)
        #elseif os(macOS)
        NSImage(contentsOf: url)
        #endif
    }

    private static func swiftUIImage(from image: YearlyReportPlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #elseif os(macOS)
        Image(nsImage: image)
        #endif
    }

    private static func bundledImage(named name: String) -> Image? {
        #if os(iOS)
        UIImage(named: name).map { Image(uiImage: $0) }
        #elseif os(macOS)
        NSImage(named: name).map { Image(nsImage: $0) }
        #endif
    }
}
