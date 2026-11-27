import Foundation

public enum AppleMusicLocalAssetError: String, Error, LocalizedError, Sendable, CaseIterable {
    case managedDownload
    case protectedContent
    case unavailable
    case unreadable
    case invalidFile
    case libraryUnavailable

    public var errorDescription: String? {
        switch self {
        case .managedDownload:
            String(localized: "appleMusic.localAsset.managedDownload", bundle: .primuseKit)
        case .protectedContent:
            String(localized: "appleMusic.localAsset.protectedContent", bundle: .primuseKit)
        case .unavailable:
            String(localized: "appleMusic.localAsset.unavailable", bundle: .primuseKit)
        case .unreadable:
            String(localized: "appleMusic.localAsset.unreadable", bundle: .primuseKit)
        case .invalidFile:
            String(localized: "appleMusic.localAsset.invalidFile", bundle: .primuseKit)
        case .libraryUnavailable:
            String(localized: "appleMusic.localAsset.libraryUnavailable", bundle: .primuseKit)
        }
    }
}

/// The library's local URL is a location, not proof that its contents can be
/// decoded outside MusicKit. Keep the same checks for import and later lookup.
public struct AppleMusicLocalAsset: Sendable {
    public let url: URL?
    public let isSong: Bool
    public let isFileLocation: Bool
    public let isProtected: Bool

    public init(url: URL?, isSong: Bool, isFileLocation: Bool, isProtected: Bool) {
        self.url = url
        self.isSong = isSong
        self.isFileLocation = isFileLocation
        self.isProtected = isProtected
    }

    public func validatedURL() throws -> URL {
        guard isSong else { throw AppleMusicLocalAssetError.invalidFile }
        guard let url, url.isFileURL else { throw AppleMusicLocalAssetError.unavailable }
        try Self.validateProtection(at: url)
        guard !isProtected else { throw AppleMusicLocalAssetError.protectedContent }
        guard isFileLocation else { throw AppleMusicLocalAssetError.unavailable }

        // Resolve aliases represented as symlinks before checking file type,
        // including links to a file inside an Apple-managed download package.
        var resolved = url.resolvingSymlinksInPath()
        resolved.removeAllCachedResourceValues()
        try Self.validateProtection(at: resolved)
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileReadNoPermissionError {
                throw AppleMusicLocalAssetError.unreadable
            }
            throw AppleMusicLocalAssetError.unavailable
        }
        guard values.isRegularFile == true else { throw AppleMusicLocalAssetError.invalidFile }
        guard FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw AppleMusicLocalAssetError.unreadable
        }
        guard let size = values.fileSize, size > 0 else { throw AppleMusicLocalAssetError.invalidFile }
        return url
    }

    private static func validateProtection(at url: URL) throws {
        if url.pathComponents.contains(where: { ($0 as NSString).pathExtension.lowercased() == "movpkg" }) {
            throw AppleMusicLocalAssetError.managedDownload
        }
        if url.pathExtension.lowercased() == "m4p" {
            throw AppleMusicLocalAssetError.protectedContent
        }
    }
}
