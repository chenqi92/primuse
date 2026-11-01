#if canImport(CoreGraphics) && canImport(ImageIO)
import Foundation
import CoreFoundation
import CoreGraphics
import ImageIO
import CryptoKit
import PrimuseKit

/// Optional public, photo-verified color metadata. This never replaces artwork
/// and is deliberately separate from the hero's first-image readiness gate.
actor ArtistHeroBackgroundResolver {
    static let shared = ArtistHeroBackgroundResolver()

    private struct VerifiedMetadata: Sendable {
        let color: ArtistHeroArtworkColor
        let nameArtwork: ArtistHeroNameArtwork?
        let nameArtworkDigest: String?
    }

    private struct LookupResult: Sendable {
        let metadata: VerifiedMetadata
        let nameArtworkComplete: Bool
    }

    private struct CacheEntry {
        let metadata: VerifiedMetadata?
        let knowsNameArtwork: Bool
        let expires: Date
    }

    private struct StoredColor: Codable {
        let key: String
        let red: Double
        let green: Double
        let blue: Double
        let expires: Date
        let metadataSchema: Int?
        let nameArtworkDigest: String?
        let nameArtworkWidth: Int?
        let nameArtworkHeight: Int?
    }

    private var cache: [String: CacheEntry] = [:]
    private var recency: [String] = []
    private var persistedNameArtworkDigests: [String: String] = [:]
    private var pending: [String: Task<LookupResult?, Never>] = [:]
#if PRIMUSE_ARTIST_HERO_PREVIEW
    private var previewDiagnostics: [LookupDiagnostic] = []
#endif
    private let session: URLSession
    private let redirectDelegate: ArtistHeroPublicRedirectDelegate
    private let cacheFileURL: URL?

    init(cacheFileURL: URL? = nil, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let file = cacheFileURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Primuse/ArtistHeroColors/v1.json")
        self.cacheFileURL = file
        if let file, let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attributes[.size] as? NSNumber, size.intValue <= 128_000,
           let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([StoredColor].self, from: data) {
            for entry in stored.suffix(48) where entry.expires > Date()
                && entry.expires <= Date().addingTimeInterval(7 * 86_400 + 60)
                && entry.key.utf8.count == 64 && entry.key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                && [entry.red, entry.green, entry.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                let logo = Self.restoreNameArtwork(entry, indexFile: file)
                cache[entry.key] = CacheEntry(
                    metadata: VerifiedMetadata(color: ArtistHeroArtworkColor(red: entry.red, green: entry.green, blue: entry.blue),
                                               nameArtwork: logo, nameArtworkDigest: logo == nil ? nil : entry.nameArtworkDigest),
                    knowsNameArtwork: entry.metadataSchema == 2 && (entry.nameArtworkDigest == nil || logo != nil),
                    expires: entry.expires
                )
                if logo != nil { persistedNameArtworkDigests[entry.key] = entry.nameArtworkDigest }
                recency.removeAll { $0 == entry.key }
                recency.append(entry.key)
            }
        }
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 7
        let delegate = ArtistHeroPublicRedirectDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func resolve(artistName: String, image: CGImage, exifOrientation: Int32 = 1,
                 allowNetwork: Bool) async -> ArtistHeroArtworkColor? {
        await resolveMetadata(artistName: artistName, image: image, exifOrientation: exifOrientation,
                              allowNetwork: allowNetwork, wantsNameArtwork: false)?.color
    }

    func resolveNameArtwork(artistName: String, image: CGImage, exifOrientation: Int32 = 1,
                            allowNetwork: Bool) async -> ArtistHeroNameArtwork? {
        await resolveMetadata(artistName: artistName, image: image, exifOrientation: exifOrientation,
                              allowNetwork: allowNetwork, wantsNameArtwork: true)?.nameArtwork
    }

    private func resolveMetadata(artistName: String, image: CGImage, exifOrientation: Int32,
                                 allowNetwork: Bool, wantsNameArtwork: Bool) async -> VerifiedMetadata? {
        let name = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160, !Task.isCancelled,
              let signature = await Task.detached(priority: .utility, operation: {
                  ArtistHeroPhotoVerification.signature(image: image, exifOrientation: exifOrientation)
              }).value else { return nil }
        let identity = ArtistHeroMetadataPolicy.nameKey(name) + "\u{1F}" + signature.cacheToken
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let previous = cache[key], previous.expires > Date() {
            touch(key)
            // v4 color-only entries stay usable immediately. A logo consumer
            // upgrades them once through the same photo-verification pipeline.
            if !wantsNameArtwork || previous.knowsNameArtwork || !allowNetwork { return previous.metadata }
        }
        guard allowNetwork, !Task.isCancelled else { return nil }
        // A third artist may be the page still on screen. Let it use the next
        // slot instead of permanently dropping its optional metadata. Waiting
        // is cancellation-aware and bounded, with no retained request queue.
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(7))
        while true {
            guard !Task.isCancelled else { return nil }
            // Another caller may have completed this identity while we waited.
            if let previous = cache[key], previous.expires > Date() {
                touch(key)
                if !wantsNameArtwork || previous.knowsNameArtwork { return previous.metadata }
            }
            if let task = pending[key] {
                let result = await task.value
                let cached = cache[key].flatMap { $0.expires > Date() ? $0.metadata : nil }
                return Task.isCancelled ? nil : result?.metadata ?? cached
            }
            if pending.count < 2 { break }
            guard ContinuousClock.now < admissionDeadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        let previousMetadata = cache[key].flatMap { $0.expires > Date() ? $0.metadata : nil }
        let task = Task { await lookup(name: name, signature: signature) }
        pending[key] = task
        let lookup = await task.value
        pending[key] = nil
        let metadata = lookup?.metadata ?? previousMetadata
        let lifetime: TimeInterval = lookup?.nameArtworkComplete == true ? 7 * 86_400 : 300
        cache[key] = CacheEntry(metadata: metadata, knowsNameArtwork: true, expires: Date().addingTimeInterval(lifetime))
        touch(key)
        while recency.count > 48 {
            cache[recency.removeFirst()] = nil
        }
        if metadata != nil { persistSuccessfulColors() }
        return Task.isCancelled ? nil : metadata
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func persistSuccessfulColors() {
        guard let file = cacheFileURL else { return }
        let now = Date()
        let entries = recency.suffix(48).compactMap { key -> StoredColor? in
            guard let entry = cache[key], entry.expires > now, let metadata = entry.metadata else { return nil }
            let color = metadata.color
            let logo = metadata.nameArtwork
            return StoredColor(key: key, red: color.red, green: color.green, blue: color.blue, expires: entry.expires,
                               metadataSchema: entry.knowsNameArtwork ? 2 : nil,
                               nameArtworkDigest: metadata.nameArtworkDigest,
                               nameArtworkWidth: logo?.width, nameArtworkHeight: logo?.height)
        }
        guard let data = try? JSONEncoder().encode(entries), data.count <= 128_000 else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let directory = file.deletingLastPathComponent().appendingPathComponent("logos", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for entry in entries {
                let imageFile = directory.appendingPathComponent(entry.key + ".png")
                if let logo = cache[entry.key]?.metadata?.nameArtwork, let digest = entry.nameArtworkDigest,
                   persistedNameArtworkDigests[entry.key] != digest || !FileManager.default.fileExists(atPath: imageFile.path) {
                    try logo.data.write(to: imageFile, options: .atomic)
                    persistedNameArtworkDigests[entry.key] = digest
                }
            }
            try data.write(to: file, options: .atomic)
            let retained = Set(entries.compactMap { $0.nameArtworkDigest != nil ? $0.key + ".png" : nil })
            persistedNameArtworkDigests = persistedNameArtworkDigests.filter { retained.contains($0.key + ".png") }
            for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                let key = item.deletingPathExtension().lastPathComponent
                if item.pathExtension == "png", key.count == 64,
                   key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                   !retained.contains(item.lastPathComponent) { try? FileManager.default.removeItem(at: item) }
            }
        } catch {
            // A disposable cache must never interfere with the photograph.
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func restoreNameArtwork(_ entry: StoredColor, indexFile: URL) -> ArtistHeroNameArtwork? {
        guard let expected = entry.nameArtworkDigest, expected.count == 64 else { return nil }
        let file = indexFile.deletingLastPathComponent().appendingPathComponent("logos/" + entry.key + ".png")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= ArtistHeroNameArtwork.maximumBytes,
              let bytes = try? Data(contentsOf: file), digest(bytes) == expected,
              let logo = ArtistHeroNameArtwork(pngData: bytes),
              logo.width == entry.nameArtworkWidth, logo.height == entry.nameArtworkHeight else { return nil }
        return logo
    }

    /// Preview-only troubleshooting contains fixed stage labels and timings,
    /// never names, URLs, artwork, credentials or network error descriptions.
    private struct LookupDiagnostic: Sendable, Encodable {
#if PRIMUSE_ARTIST_HERO_PREVIEW
        struct Event: Codable, Sendable {
            let stage: String
            let result: String
            let elapsedMilliseconds: Int
            let requestMilliseconds: Int?
            let httpStatus: Int?
            let networkErrorCode: Int?
        }
        let lookupID = UUID().uuidString
        let startedAt = Date()
        var completed = false
        var colorAvailable = false
        var nameArtworkAvailable = false
        var events: [Event] = []
#endif
    }

    private func recordPreviewDiagnostic(_ diagnostic: inout LookupDiagnostic, stage: String,
                                         result: String, status: Int? = nil, requestStartedAt: Date? = nil,
                                         networkErrorCode: Int? = nil, color: Bool? = nil, nameArtwork: Bool? = nil) {
#if PRIMUSE_ARTIST_HERO_PREVIEW
        let now = Date()
        diagnostic.events.append(.init(stage: stage, result: result,
                                       elapsedMilliseconds: max(0, Int(now.timeIntervalSince(diagnostic.startedAt) * 1_000)),
                                       requestMilliseconds: requestStartedAt.map { max(0, Int(now.timeIntervalSince($0) * 1_000)) },
                                       httpStatus: status, networkErrorCode: networkErrorCode))
        diagnostic.events = Array(diagnostic.events.suffix(20))
        if let color { diagnostic.colorAvailable = color }
        if let nameArtwork { diagnostic.nameArtworkAvailable = nameArtwork }
        if stage == "lookup", result == "completed" { diagnostic.completed = true }
        previewDiagnostics.removeAll { $0.lookupID == diagnostic.lookupID }
        previewDiagnostics.append(diagnostic)
        previewDiagnostics = Array(previewDiagnostics.suffix(2))
        guard let directory = cacheFileURL?.deletingLastPathComponent() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(previewDiagnostics)
            guard data.count <= 16_000 else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("preview-diagnostics.json"), options: .atomic)
        } catch {
            // Diagnostics are disposable and must never affect metadata.
        }
#endif
    }

    /// Search order discovers possibilities only. The selected header and its
    /// actual photograph still have to pass the existing independent checks.
    private static func orderedCandidateArtistIDs(in data: Data, named name: String) -> [String] {
        guard data.count <= 128_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        let expected = ArtistHeroMetadataPolicy.nameKey(name)
        guard !expected.isEmpty else { return [] }
        var candidates: [(id: String, exact: Bool)] = []
        for item in results.prefix(12) {
            guard item["wrapperType"] as? String == "artist",
                  item["artistType"] as? String == "Artist",
                  let candidateName = item["artistName"] as? String,
                  !candidateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidateName.count <= 160 else { continue }
            let id: String
            if let string = item["artistId"] as? String { id = string }
            else if let number = item["artistId"] as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                    number.doubleValue.rounded() == number.doubleValue { id = number.stringValue }
            else { continue }
            guard !id.isEmpty, id.count <= 20, id.first != "0",
                  id.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            let exact = ArtistHeroMetadataPolicy.nameKey(candidateName) == expected
            if let index = candidates.firstIndex(where: { $0.id == id }) {
                candidates[index].exact = candidates[index].exact || exact
            } else {
                candidates.append((id, exact))
            }
        }
        // When the catalog knows this exact name, unrelated search results
        // cannot borrow a user-selected photograph to substitute their logo.
        // Only a genuinely absent exact-name group permits alias discovery.
        let exact = candidates.filter(\.exact)
        let pool = exact.isEmpty ? candidates : exact
        return Array(pool.prefix(3).map(\.id))
    }

    private func lookup(name: String, signature: ArtistHeroPhotoSignature) async -> LookupResult? {
        var diagnostic = LookupDiagnostic()
        var colorAvailable = false
        var nameArtworkAvailable = false
        recordPreviewDiagnostic(&diagnostic, stage: "lookup", result: "started")
        defer {
            recordPreviewDiagnostic(&diagnostic, stage: "lookup", result: "completed",
                                    color: colorAvailable, nameArtwork: nameArtworkAvailable)
        }
        let deadline = Date().addingTimeInterval(7)
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [URLQueryItem(name: "term", value: name), URLQueryItem(name: "entity", value: "musicArtist"),
                             URLQueryItem(name: "country", value: "CN"), URLQueryItem(name: "limit", value: "8")]
        guard let url = search.url,
              let searchData = await publicData(url, accept: "application/json", maximumBytes: 128_000, deadline: deadline,
                                                stage: "artistSearch", diagnostic: &diagnostic) else { return nil }
        let artistIDs = Self.orderedCandidateArtistIDs(in: searchData, named: name)
        guard !artistIDs.isEmpty else {
            recordPreviewDiagnostic(&diagnostic, stage: "artistIdentity", result: "rejected")
            return nil
        }
        recordPreviewDiagnostic(&diagnostic, stage: "artistIdentity", result: "accepted")
        for id in artistIDs {
            guard !Task.isCancelled, Date() < deadline else { break }
            guard let page = URL(string: "https://music.apple.com/cn/artist/\(id)"),
                  let html = await publicData(page, accept: "text/html", maximumBytes: ArtistHeroMetadataPolicy.maximumDocumentBytes, deadline: deadline,
                                             stage: "artistPage", diagnostic: &diagnostic) else { continue }
            let candidates = ArtistHeroMetadataPolicy.candidates(in: html, artistID: id)
            recordPreviewDiagnostic(&diagnostic, stage: "header", result: candidates.isEmpty ? "rejected" : "accepted")
            for candidate in candidates.prefix(2) {
                guard let bytes = await publicData(candidate.imageURL, accept: "image/*", maximumBytes: 2_000_000, deadline: deadline,
                                                   stage: "candidatePhoto", diagnostic: &diagnostic),
                      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { continue }
                let matches = await Task.detached(priority: .utility) {
                    guard let remote = ArtistHeroPhotoVerification.signature(image: image) else { return false }
                    return ArtistHeroPhotoVerification.matches(signature, remote)
                }.value
                recordPreviewDiagnostic(&diagnostic, stage: "photoVerification", result: matches ? "accepted" : "rejected")
                if matches, let value = UInt32(candidate.backgroundHex, radix: 16) {
                    colorAvailable = true
                    let color = ArtistHeroArtworkColor(red: Double((value >> 16) & 255) / 255,
                                                       green: Double((value >> 8) & 255) / 255,
                                                       blue: Double(value & 255) / 255)
                    var logo: ArtistHeroNameArtwork?
                    if let artwork = candidate.nameArtwork,
                       let bytes = await publicData(artwork.imageURL, accept: "image/png",
                                                    maximumBytes: ArtistHeroNameArtwork.maximumBytes, deadline: deadline,
                                                    stage: "nameArtwork", diagnostic: &diagnostic),
                       let decoded = ArtistHeroNameArtwork(pngData: bytes),
                       abs(log(Double(decoded.width) / Double(decoded.height) / (Double(artwork.width) / Double(artwork.height)))) < 0.05 {
                        logo = decoded
                    }
                    nameArtworkAvailable = logo != nil
                    recordPreviewDiagnostic(&diagnostic, stage: "nameArtworkValidation",
                                            result: logo != nil ? "accepted" : candidate.nameArtwork == nil ? "absent" : "unavailable")
                    return LookupResult(metadata: VerifiedMetadata(color: color, nameArtwork: logo,
                                                                   nameArtworkDigest: logo.map { Self.digest($0.data) }),
                                        nameArtworkComplete: candidate.nameArtwork == nil || logo != nil)
                }
            }
        }
        return nil
    }

    private func publicData(_ url: URL, accept: String, maximumBytes: Int, deadline: Date,
                            stage: String, diagnostic: inout LookupDiagnostic) async -> Data? {
        guard let host = url.host?.lowercased() else { return nil }
        var current = url
        // Apple's public artist URL can redirect to its canonical name path.
        // Follow at most two same-host HTTPS hops, each with a fresh public
        // request and the original total deadline; never inherit credentials.
        for hop in 0...2 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !Task.isCancelled,
                  current.scheme == "https", current.user == nil, current.password == nil, current.port == nil,
                  current.host?.lowercased() == host,
                  host == "itunes.apple.com" || host == "music.apple.com" || ArtistHeroMetadataPolicy.artworkAssetID(current) != nil
                    || (accept == "image/png" && ArtistHeroMetadataPolicy.isNameArtworkURL(current)) else {
                recordPreviewDiagnostic(&diagnostic, stage: stage,
                                        result: Task.isCancelled ? "cancelled" : remaining <= 0 ? "deadline" : "requestRejected")
                return nil
            }
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(3, remaining))
            request.httpShouldHandleCookies = false
            request.setValue(accept, forHTTPHeaderField: "Accept")
            let requestStartedAt = Date()
            recordPreviewDiagnostic(&diagnostic, stage: stage, result: "requestStarted")
            do {
                let (data, response) = try await TrustedHTTPTransport.dataWithoutRedirects(
                    for: request, session: session, maxBytes: maximumBytes
                )
                recordPreviewDiagnostic(&diagnostic, stage: stage, result: "response",
                                        status: (response as? HTTPURLResponse)?.statusCode, requestStartedAt: requestStartedAt)
                guard !Task.isCancelled, Date() <= deadline,
                      let http = response as? HTTPURLResponse,
                      response.url?.host?.lowercased() == host, data.count <= maximumBytes else { return nil }
                if [301, 302, 303, 307, 308].contains(http.statusCode), hop < 2,
                   let location = http.value(forHTTPHeaderField: "Location"),
                   let next = URL(string: location, relativeTo: current)?.absoluteURL {
                    current = next
                    continue
                }
                guard (200...299).contains(http.statusCode) else { return nil }
                return data
            } catch {
                recordPreviewDiagnostic(&diagnostic, stage: stage,
                                        result: Task.isCancelled ? "cancelled" : "transportFailure",
                                        requestStartedAt: requestStartedAt, networkErrorCode: (error as? URLError)?.code.rawValue)
                return nil
            }
        }
        return nil
    }
}

private final class ArtistHeroPublicRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
