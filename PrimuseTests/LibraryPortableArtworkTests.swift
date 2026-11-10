import Foundation
import CloudKit
import CryptoKit
import ImageIO
import MediaPlayer
import PrimuseKit
import UIKit
import UniformTypeIdentifiers
import SwiftUI
import Vision
import XCTest
@testable import Primuse

@MainActor
final class LibraryPortableArtworkTests: XCTestCase {
    private actor ArtistPhotoStub {
        var data: Data?
        private(set) var requests = 0
        init(_ data: Data?) { self.data = data }
        func set(_ data: Data?) { self.data = data }
        func fetch() -> Data? { requests += 1; return data }
    }

    func testAppleMusicArtistPhotoReplacesLegacyCacheAndCanForceRefresh() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let old = try image(color: .red)
        let portrait = try image(color: .green)
        let updated = try image(color: .blue)
        _ = await store.storeArtistImage(old, forArtistID: "artist")
        _ = await store.storeArtistImage(old, forArtistID: ArtistArtworkResolutionPolicy.cacheID(baseID: "artist", maximumPixels: 1536))
        let stub = ArtistPhotoStub(portrait)
        let fetcher = ArtworkFetchService(assetStore: store, isArtistLookupAuthorized: { true }, artistPhotoLookup: { _ in await stub.fetch() })
        let first = await fetcher.fetchArtistImage(artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: true)
        XCTAssertEqual(first, portrait)
        await stub.set(updated)
        let cached = await fetcher.fetchArtistImage(artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: true)
        XCTAssertEqual(cached, portrait)
        let refreshed = await fetcher.fetchArtistImage(artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: true, forceRefresh: true)
        XCTAssertEqual(refreshed, updated)
        XCTAssertNil(store.cachedArtistImage(forArtistID: ArtistArtworkResolutionPolicy.appleMusicCacheID(artistID: "artist")),
                     "Catalog artist photos stay in memory and are never written to disk")
        let otherSource = await fetcher.fetchArtistImage(
            artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: false, forceRefresh: true)
        XCTAssertNil(otherSource, "Artists without Apple Music songs never use the catalog photo")
        let requests = await stub.requests
        XCTAssertEqual(requests, 2)
    }

    func testAppleMusicArtistRefreshFailurePreservesPhotoAndManualRetryBypassesBackoff() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let portrait = try image(color: .green)
        let key = ArtistArtworkResolutionPolicy.appleMusicCacheID(artistID: "artist")
        _ = await store.storeArtistImage(portrait, forArtistID: key)
        let stub = ArtistPhotoStub(nil)
        let fetcher = ArtworkFetchService(assetStore: store, isArtistLookupAuthorized: { true }, artistPhotoLookup: { _ in await stub.fetch() })
        let failed = await fetcher.fetchArtistImage(artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: true, forceRefresh: true)
        XCTAssertNil(failed, "A failed manual refresh must not report an old cache as success")
        XCTAssertEqual(store.cachedArtistImage(forArtistID: key), portrait)
        let missing = await fetcher.fetchArtistImage(artistName: "Other Artist", artistID: "other", isAppleMusicArtist: true)
        XCTAssertNil(missing)
        let suppressed = await fetcher.fetchArtistImage(artistName: "Other Artist", artistID: "other", isAppleMusicArtist: true)
        XCTAssertNil(suppressed)
        let requests = await stub.requests
        XCTAssertEqual(requests, 2)
        await stub.set(portrait)
        let retried = await fetcher.fetchArtistImage(artistName: "Other Artist", artistID: "other", isAppleMusicArtist: true, forceRefresh: true)
        XCTAssertEqual(retried, portrait)
        let requestsAfterRetry = await stub.requests
        XCTAssertEqual(requestsAfterRetry, 3)
    }

    func testAppleMusicArtistPhotoDoesNotRequestAuthorizationOrAcceptInvalidImage() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let stub = ArtistPhotoStub(Data("not an image".utf8))
        let denied = ArtworkFetchService(assetStore: store, isArtistLookupAuthorized: { false }, artistPhotoLookup: { _ in await stub.fetch() })
        let result = await denied.fetchArtistImage(artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: true, forceRefresh: true)
        XCTAssertNil(result)
        let requests = await stub.requests
        XCTAssertEqual(requests, 0)
        let authorized = ArtworkFetchService(assetStore: store, isArtistLookupAuthorized: { true }, artistPhotoLookup: { _ in await stub.fetch() })
        let invalid = await authorized.fetchArtistImage(artistName: "Paper Lantern", artistID: "artist", isAppleMusicArtist: true)
        XCTAssertNil(invalid)
        XCTAssertNil(store.cachedArtistImage(forArtistID: ArtistArtworkResolutionPolicy.appleMusicCacheID(artistID: "artist")))
    }

    private func animatedUploadGIF(paddingBytes: Int = 0) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (color, delay) in [(UIColor.red, 0.12), (UIColor.blue, 0.18)] {
            let frame = try decoded(image(color: color))
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var bytes = output as Data
        if paddingBytes > 0 {
            var comment = Data([0x21, 0xFE])
            var remaining = paddingBytes
            while remaining > 0 {
                let count = min(255, remaining)
                comment.append(UInt8(count))
                comment.append(Data(repeating: 65, count: count))
                remaining -= count
            }
            comment.append(0)
            bytes.insert(contentsOf: comment, at: bytes.count - 1)
        }
        return bytes
    }

    func testSongGIFSurvivesPortableSyncRestartAndSnapshotWithStaleMirror() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = MetadataAssetStore(storageDirectory: root.appendingPathComponent("sender"))
        let gif = try XCTUnwrap(LibraryArtworkImageProcessor.processUpload(animatedUploadGIF(paddingBytes: 700_000)))
        var songs: [Song] = []
        for id in ["first", "second"] {
            var song = Song(id: id, title: id, fileFormat: .mp3, filePath: "/\(id).mp3", sourceID: "source")
            song.coverArtFileName = await sender.storeAttributedCover(gif, songID: id, origin: .selected)
            XCTAssertNotNil(song.coverArtFileName)
            // The evictable per-song mirror must never override a user's selection.
            sender.storeCoverSync(try image(color: .green), for: id)
            songs.append(song)
        }
        let reference = try XCTUnwrap(songs[0].coverArtFileName)
        let portable = try XCTUnwrap(SongTagEditStore.portableContentID(ofCoverNamed: reference, assets: sender))
        XCTAssertEqual(sender.customArtworkData(contentID: portable), gif)
        let reopened = MetadataAssetStore(storageDirectory: sender.customArtworkDirectoryURL.deletingLastPathComponent())
        XCTAssertEqual(reopened.readCoverData(named: reference), gif)
        let identity = try XCTUnwrap(sender.coverContentIdentifier(named: reference))
        XCTAssertEqual(sender.preparePortableCover(named: reference, contentIdentifier: identity)?.data, gif)

        let prepared = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(try snapshot(songs), assetStore: sender)
        let transfer = try XCTUnwrap(prepared)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        let custom = try XCTUnwrap(payload["artworkAssets"] as? [String: String]).compactMapValues { Data(base64Encoded: $0) }
        let cached = (payload["cachedArtworkAssets"] as? [String: String] ?? [:]).compactMapValues { Data(base64Encoded: $0) }
        XCTAssertEqual(custom.count, 1)
        XCTAssertEqual(custom[portable], gif)
        XCTAssertTrue(cached.isEmpty, "Selected images are carried once, without a stale mirror")
        let receiver = MetadataAssetStore(storageDirectory: root.appendingPathComponent("receiver"))
        let restored = MusicLibrary.restorePortableArtwork(customAssets: custom, cachedAssets: cached,
            references: payload["artworkCacheReferences"] as? [String: String] ?? [:],
            eligibleNames: MusicLibrary.portableArtworkEligibleNames(songs: songs, assetStore: receiver), assetStore: receiver)
        XCTAssertEqual(restored.custom, 1)
        XCTAssertEqual(receiver.readCoverData(named: reference), gif)
        let legacyReference = receiver.expectedCoverFileName(for: "legacy")
        XCTAssertTrue(receiver.installPortableCachedArtwork(gif, contentID: portable, referenceFileNames: [legacyReference]))
        XCTAssertEqual(receiver.readCoverData(named: legacyReference), gif)
        await sender.clearAll()
        XCTAssertEqual(sender.readCoverData(named: reference), gif)
    }

    func testLargeSongGIFCloudAssetIsPrivateAndValidatesContent() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let gif = try animatedUploadGIF(paddingBytes: 700_000)
        let contentID = try XCTUnwrap(assets.storeCustomArtworkSync(gif))
        let id = CloudKitSyncService.songCoverAssetPrefix + contentID
        XCTAssertEqual(CloudKitSyncService.songCoverAssetContentID(id), contentID)
        XCTAssertNil(CloudKitSyncService.songCoverAssetContentID(CloudKitSyncService.songCoverAssetPrefix + "../invalid"))
        XCTAssertEqual(CloudKitSyncService.channel(for: "Playlist", id: id), .sources)
        XCTAssertEqual(CloudKitSyncService.channel(for: "Playlist", id: "normal"), .playlists)
        let family = UserDefaults.standard.object(forKey: "primuse.familySharing.enabled")
        defer { UserDefaults.standard.set(family, forKey: "primuse.familySharing.enabled") }
        CloudKitSyncService.familySharingEnabled = true
        XCTAssertEqual(CloudKitSyncService.zoneFor(recordType: "Playlist", id: id).zoneName, "PrimuseSync")
        let record = CKRecord(recordType: "Playlist", recordID: .init(recordName: "Playlist/" + id))
        XCTAssertTrue(CloudKitSyncService.writeSongCoverAsset(gif, contentID: contentID, to: record,
            assetDirectory: assets.customArtworkDirectoryURL))
        XCTAssertNil(record["name"], "Asset records must not become empty playlists in older clients")
        XCTAssertEqual(CloudKitSyncService.readSongCoverAsset(record, contentID: contentID), gif)
        let rebuilt = CKRecord(recordType: "Playlist", recordID: record.recordID)
        XCTAssertTrue(CloudKitSyncService.writeSongCoverAsset(gif, contentID: contentID, to: rebuilt,
            assetDirectory: assets.customArtworkDirectoryURL))
        XCTAssertTrue(CloudKitSyncService.differingRecordKeys(rebuilt, record).isEmpty)
        XCTAssertNil(CloudKitSyncService.readSongCoverAsset(record, contentID: String(repeating: "0", count: 64)))
        try Data("damaged".utf8).write(to: assets.customArtworkDirectoryURL.appendingPathComponent("\(contentID).jpg"))
        XCTAssertNil(CloudKitSyncService.readSongCoverAsset(record, contentID: contentID))
    }

    func testSongGIFWritesCompatibleStillToAudioSource() async throws {
        let gif = try animatedUploadGIF()
        let connector = SongGIFWritebackConnector()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/song.flac", sourceID: "source")
        let report = await TagMetadataWritebackCoordinator.write(mode: .embedded, connector: connector,
            original: song, updated: song, coverData: gif)
        let written = await connector.cover
        let still = try XCTUnwrap(written)
        XCTAssertTrue(LibraryArtworkImageProcessor.isReusablePortableJPEG(still))
        XCTAssertEqual(ArtworkImageCompatibility.inspect(still)?.isAnimated, false)
        XCTAssertFalse(report.shouldAbortLocalSave)
        XCTAssertNotNil(report.localSaveNotice)
        XCTAssertEqual(ArtworkImageCompatibility.inspect(gif)?.frameCount, 2)
    }

    func testSelectedSongGIFAnimatesPlayerAndKeepsListPosterStatic() async throws {
        let key = PlayerAppearancePreferences.animatedArtworkEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        await library.whenReady()
        let assets = MetadataAssetStore.shared
        let gif = try animatedUploadGIF(paddingBytes: 987)
        let contentID = SHA256.hash(data: gif).map { String(format: "%02x", $0) }.joined()
        let existed = assets.hasCustomArtwork(contentID: contentID)
        let songID = "gif-ui-" + UUID().uuidString
        let stored = await assets.storeAttributedCover(gif, songID: songID, origin: .selected)
        let reference = try XCTUnwrap(stored)
        defer {
            if !existed { try? FileManager.default.removeItem(at: assets.customArtworkDirectoryURL.appendingPathComponent("\(contentID).jpg")) }
            try? FileManager.default.removeItem(at: assets.artworkDirectoryURL.appendingPathComponent(assets.expectedCoverFileName(for: songID)))
        }
        func artwork(_ reference: String) -> some View {
            HStack(spacing: 0) {
                CachedArtworkView(coverRef: reference, songID: songID, size: 80, cornerRadius: 0, presentationRole: .animatedHero)
                CachedArtworkView(coverRef: reference, songID: songID, size: 80, cornerRadius: 0)
            }
            .environment(library).environment(SourceManager(sourcesProvider: { [] })).environment(\.scenePhase, .active)
        }
        let (window, host, original) = try hostHeroTestView(artwork(reference), size: CGSize(width: 160, height: 80))
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        var frames = Set<String>()
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try heroTestSnapshot(host.view)
            let pixel = try rgb(snapshot, x: 40, y: 40)
            if pixel.0 > 200 && pixel.2 < 50 { frames.insert("red") }
            if pixel.2 > 200 && pixel.0 < 50 { frames.insert("blue") }
            if frames.count == 2 { break }
        }
        XCTAssertEqual(frames, ["red", "blue"])
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(80))
            let pixel = try rgb(heroTestSnapshot(host.view), x: 120, y: 40)
            XCTAssertGreaterThan(pixel.0, 200)
            XCTAssertLessThan(pixel.2, 50)
        }
        XCTAssertEqual(assets.readCoverData(named: reference), gif)
        let green = try XCTUnwrap(LibraryArtworkImageProcessor.processUpload(image(color: .green)))
        let greenID = SHA256.hash(data: green).map { String(format: "%02x", $0) }.joined()
        let greenExisted = assets.hasCustomArtwork(contentID: greenID)
        let replacement = await assets.storeAttributedCover(green, songID: songID, origin: .selected)
        defer {
            if !greenExisted { try? FileManager.default.removeItem(at: assets.customArtworkDirectoryURL.appendingPathComponent("\(greenID).jpg")) }
        }
        host.rootView = artwork(try XCTUnwrap(replacement))
        var replaced = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try heroTestSnapshot(host.view)
            let pixels = try [40, 120].map { try rgb(snapshot, x: $0, y: 40) }
            if pixels.allSatisfy({ $0.1 > 200 && $0.0 < 50 && $0.2 < 50 }) { replaced = true; break }
        }
        XCTAssertTrue(replaced, "Changing a song to a still must clear its previous animated frames")
    }

    func testCustomGIFPreservesFramesTimingAndStorageAcrossRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gif = try animatedUploadGIF(paddingBytes: 700_000)
        let processed = try XCTUnwrap(LibraryArtworkImageProcessor.processUpload(gif))
        XCTAssertEqual(processed, gif)
        let descriptor = try XCTUnwrap(ArtworkImageCompatibility.inspect(processed))
        XCTAssertEqual(descriptor.frameCount, 2)
        XCTAssertEqual(descriptor.loopCount, 0)
        XCTAssertEqual(descriptor.duration, 0.3, accuracy: 0.01)
        let store = MetadataAssetStore(storageDirectory: root)
        let id = try XCTUnwrap(store.storeCustomArtworkSync(processed))
        XCTAssertEqual(MetadataAssetStore(storageDirectory: root).customArtworkData(contentID: id), gif)
        XCTAssertNil(store.storeCustomArtworkSync(gif, expectedContentID: String(repeating: "0", count: 64)))
        let still = try XCTUnwrap(LibraryArtworkImageProcessor.process(gif))
        XCTAssertEqual(ArtworkImageCompatibility.inspect(still)?.format, .jpeg)
        XCTAssertEqual(ArtworkImageCompatibility.inspect(still)?.isAnimated, false)
    }

    func testCustomGIFRejectsTruncatedAndOversizedAnimations() throws {
        let gif = try animatedUploadGIF()
        XCTAssertNil(LibraryArtworkImageProcessor.processUpload(gif.dropLast(8)))
        let oversized = try animatedUploadGIF(paddingBytes: LibraryArtworkContentIDPolicy.maximumAnimatedArtworkBytes)
        XCTAssertNil(LibraryArtworkImageProcessor.processUpload(oversized))
        XCTAssertFalse(LibraryArtworkImageProcessor.isValidStoredArtwork(oversized))
        let still = try XCTUnwrap(LibraryArtworkImageProcessor.processUpload(image()))
        XCTAssertEqual(ArtworkImageCompatibility.inspect(still)?.format, .jpeg)
    }

    func testGIFCloudEnvelopeUsesAssetAndClearsItWhenReplacingWithStill() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gif = try animatedUploadGIF(paddingBytes: 700_000)
        let store = MetadataAssetStore(storageDirectory: root)
        let id = try XCTUnwrap(store.storeCustomArtworkSync(gif))
        for kind in [LibraryArtworkOwner.Kind.album, .artist, .playlist] {
            let value = LibraryArtworkOverride(owner: .init(kind: kind, id: "fixture"), mode: .uploaded, uploadedContentID: id)
            let envelope = LibraryArtworkCloudEnvelope(override: value, uploadedArtworkData: gif)
            let record = CKRecord(recordType: "Playlist")
            XCTAssertTrue(CloudKitSyncService.writeArtworkOverrideEnvelope(envelope, to: record) { bytes in
                let url = root.appendingPathComponent("animation.gif")
                try? bytes.write(to: url)
                return url
            })
            let inline = try XCTUnwrap(record["songIdentities"] as? Data)
            XCTAssertNil(try JSONDecoder().decode(LibraryArtworkCloudEnvelope.self, from: inline).uploadedArtworkData)
            XCTAssertNotNil(record["songIdentitiesAsset"] as? CKAsset)
            XCTAssertEqual(CloudKitSyncService.readArtworkOverrideEnvelope(record), envelope)
            let previousAsset = record["songIdentitiesAsset"] as? CKAsset
            XCTAssertFalse(CloudKitSyncService.writeArtworkOverrideEnvelope(envelope, to: record, assetURL: { _ in nil }))
            XCTAssertEqual((record["songIdentitiesAsset"] as? CKAsset)?.fileURL, previousAsset?.fileURL)

            var jpeg = try XCTUnwrap(LibraryArtworkImageProcessor.process(gif))
            jpeg.append(Data(repeating: 0, count: LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes - jpeg.count))
            var stillValue = value
            stillValue.uploadedContentID = try XCTUnwrap(store.storeCustomArtworkSync(jpeg))
            let replacement = LibraryArtworkCloudEnvelope(override: stillValue, uploadedArtworkData: jpeg)
            XCTAssertTrue(CloudKitSyncService.writeArtworkOverrideEnvelope(replacement, to: record, assetURL: { _ in
                XCTFail("Small JPEGs must remain readable by the inline format")
                return nil
            }))
            XCTAssertNil(record["songIdentitiesAsset"])
            XCTAssertEqual(CloudKitSyncService.readArtworkOverrideEnvelope(record), replacement)
        }
    }

    func testPortableSnapshotRestoresGIFWithoutFlattening() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = MetadataAssetStore(storageDirectory: root.appendingPathComponent("sender"))
        let receiver = MetadataAssetStore(storageDirectory: root.appendingPathComponent("receiver"))
        let gif = try animatedUploadGIF(paddingBytes: 700_000)
        let id = try XCTUnwrap(sender.storeCustomArtworkSync(gif))
        let values = [LibraryArtworkOwner.Kind.album, .artist, .playlist].map {
            LibraryArtworkOverride(owner: .init(kind: $0, id: "fixture"), mode: .uploaded, uploadedContentID: id)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot([])) as? [String: Any])
        object["artworkOverrides"] = try JSONSerialization.jsonObject(with: encoder.encode(values))
        let input = try JSONSerialization.data(withJSONObject: object)
        let result = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(input, assetStore: sender)
        let transfer = try XCTUnwrap(result)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        let encoded = try XCTUnwrap(payload["artworkAssets"] as? [String: String])
        XCTAssertEqual(encoded.count, 1)
        let assets = encoded.compactMapValues { Data(base64Encoded: $0) }
        let restored = MusicLibrary.restorePortableArtwork(customAssets: assets, cachedAssets: [:], references: [:], eligibleNames: [], assetStore: receiver)
        XCTAssertEqual(restored.custom, 1)
        XCTAssertEqual(receiver.customArtworkData(contentID: id), gif)
    }

    func testUploadedGIFAnimatesDetailSurfacesAndKeepsListPosterStatic() async throws {
        let key = PlayerAppearancePreferences.animatedArtworkEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, artist) = try await heroTestArtist(in: root)
        let album = Album(id: "gif-album", title: "GIF album", artistName: artist.name)
        let playlist = library.createPlaylist(name: "GIF playlist")
        let gif = try animatedUploadGIF()
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        for owner in [LibraryArtworkOwner(kind: .album, id: album.id), .init(kind: .artist, id: artist.id), .init(kind: .playlist, id: playlist.id)] {
            if let url = try installHeroTestArtwork(gif, library: library, owner: owner) { cleanup.append(url) }
        }
        let view = VStack(spacing: 0) {
            HStack(spacing: 0) {
                AlbumArtworkView(album: album, size: 80, cornerRadius: 0, presentationRole: .animatedHero)
                ArtistArtworkView(artist: artist, size: 80, cornerRadius: 0, presentationRole: .animatedHero)
                PlaylistArtworkView(playlist: playlist, size: 80, cornerRadius: 0, presentationRole: .animatedHero)
            }
            HStack(spacing: 0) {
                AlbumArtworkView(album: album, size: 80, cornerRadius: 0)
                ArtistArtworkView(artist: artist, size: 80, cornerRadius: 0)
                PlaylistArtworkView(playlist: playlist, size: 80, cornerRadius: 0)
            }
            ArtistHeroArtworkView(artist: artist, size: CGSize(width: 240, height: 240), onImageChange: { _ in })
        }
        .frame(width: 240, height: 400, alignment: .top)
        .environment(library)
        .environment(SourceManager(sourcesProvider: { [] }))
        .environment(\.scenePhase, .active)
        let (window, host, original) = try hostHeroTestView(view, size: CGSize(width: 240, height: 400))
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        var observed = Array(repeating: Set<String>(), count: 4)
        for _ in 0..<45 {
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try heroTestSnapshot(host.view)
            for (index, point) in [(40, 40), (120, 40), (200, 40), (120, 200)].enumerated() {
                let pixel = try rgb(snapshot, x: point.0, y: point.1)
                if pixel.0 > 200 && pixel.2 < 50 { observed[index].insert("red") }
                if pixel.2 > 200 && pixel.0 < 50 { observed[index].insert("blue") }
            }
            if observed.allSatisfy({ $0.count == 2 }) { break }
        }
        XCTAssertTrue(observed.allSatisfy { $0 == ["red", "blue"] }, "Every detail surface must animate: \(observed)")
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try heroTestSnapshot(host.view)
            for x in [40, 120, 200] {
                let pixel = try rgb(snapshot, x: x, y: 120)
                XCTAssertGreaterThan(pixel.0, 200)
                XCTAssertLessThan(pixel.2, 50)
            }
        }
        UserDefaults.standard.set(false, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try heroTestSnapshot(host.view)
            for (x, y) in [(40, 40), (120, 40), (200, 40), (120, 200)] {
                let pixel = try rgb(snapshot, x: x, y: y)
                XCTAssertGreaterThan(pixel.0, 200)
                XCTAssertLessThan(pixel.2, 50)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        let green = try image(color: .green)
        for owner in [LibraryArtworkOwner(kind: .album, id: album.id), .init(kind: .artist, id: artist.id), .init(kind: .playlist, id: playlist.id)] {
            if let url = try installHeroTestArtwork(green, library: library, owner: owner) { cleanup.append(url) }
        }
        var replaced = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try heroTestSnapshot(host.view)
            let pixels = try [(40, 40), (120, 40), (200, 40), (120, 200)].map { try rgb(snapshot, x: $0.0, y: $0.1) }
            if pixels.allSatisfy({ $0.1 > 200 && $0.0 < 50 && $0.2 < 50 }) {
                replaced = true
                break
            }
        }
        XCTAssertTrue(replaced, "Replacing the GIF must remove its animated frames from every detail surface")
    }

    func testRemovedSourceArtworkWithoutSongRowsReclaimsBothSizesAndPreservesOtherSources() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let reference = "/books/cover.jpg"
        let small = try image(color: .red)
        let full = try image(color: .blue)
        let surviving = try image(color: .green)
        _ = await assets.cacheSourceCover(small, songID: nil, sourceID: "removed", reference: reference, maximumPixels: 480)
        _ = await assets.cacheSourceCover(full, songID: nil, sourceID: "removed", reference: reference, maximumPixels: 1536)
        _ = await assets.cacheSourceCover(surviving, songID: nil, sourceID: "retained", reference: reference, maximumPixels: 480)
        XCTAssertNil(assets.cachedSourceCover(sourceID: "readded", reference: reference, maximumPixels: 480))

        await assets.invalidateSourceArtworkCaches(forSourceIDs: ["removed"], lastWrittenBefore: Date())

        let restarted = MetadataAssetStore(storageDirectory: root)
        XCTAssertNil(restarted.cachedSourceCover(sourceID: "removed", reference: reference, maximumPixels: 480, allowsStale: true))
        XCTAssertNil(restarted.cachedSourceCover(sourceID: "removed", reference: reference, maximumPixels: 1536, allowsStale: true))
        XCTAssertEqual(restarted.cachedSourceCover(sourceID: "retained", reference: reference, maximumPixels: 480), surviving)
        XCTAssertEqual(restarted.artworkContentUsage().count, 1)
    }

    func testRemovedSongAssetsKeepSharedAndReusableArtworkButReclaimUnmatchableLyrics() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let reusable = try image(color: .red)
        let shared = try image(color: .green)
        let unique = try image(color: .blue)
        let custom = try image(color: .orange)
        let specs: [(String, Data, StoredArtworkOrigin)] = [
            ("album-song", reusable, .embedded), ("shared-song", shared, .sidecar),
            ("unique-song", unique, .scraped), ("custom-song", custom, .selected)
        ]
        var removed: [Song] = []
        for (id, bytes, origin) in specs {
            let reference = await assets.storeAttributedCover(bytes, songID: id, origin: origin)
            let lyrics = await assets.storeLyrics([LyricLine(timestamp: 0, text: id)], for: id)
            removed.append(Song(id: id, title: id, fileFormat: .flac, filePath: "/\(id).flac",
                                sourceID: "removed", coverArtFileName: try XCTUnwrap(reference), lyricsFileName: lyrics))
        }
        let legacyName = await assets.storeLyrics([LyricLine(timestamp: 0, text: "legacy")], for: "legacy-cache-key")
        removed[2].lyricsFileName = legacyName
        let retainedLyrics = await assets.storeLyrics([LyricLine(timestamp: 0, text: "retained")], for: "retained-song")
        let retained = Song(id: "retained-song", title: "Retained", fileFormat: .flac, filePath: "/retained.flac",
                            sourceID: "other", coverArtFileName: removed[1].coverArtFileName, lyricsFileName: retainedLyrics)
        _ = await assets.storeAlbumCover(reusable, forAlbumID: "stable-album")
        _ = await assets.storeArtistImage(reusable, forArtistID: "stable-artist")
        let cutoff = Date()

        await assets.invalidateRemovedSongCaches(songs: removed, songIDs: Set(removed.map(\.id)),
                                                retainingSongs: [retained], lastWrittenBefore: cutoff)
        await assets.invalidateSourceArtworkCaches(forSourceIDs: ["removed"], lastWrittenBefore: cutoff)

        for song in removed {
            let lyrics = await assets.cachedLyrics(forSongID: song.id)
            XCTAssertNil(lyrics)
            XCTAssertNil(assets.readCoverData(named: assets.expectedCoverFileName(for: song.id)))
        }
        let legacyLyrics = await assets.lyrics(named: legacyName)
        XCTAssertNil(legacyLyrics)
        let remainingLyrics = await assets.cachedLyrics(forSongID: retained.id)
        XCTAssertEqual(remainingLyrics?.first?.text, "retained")
        XCTAssertNil(assets.readCoverData(named: try XCTUnwrap(removed[0].coverArtFileName)))
        XCTAssertNil(assets.readCoverData(named: try XCTUnwrap(removed[2].coverArtFileName)))
        XCTAssertEqual(assets.readCoverData(named: try XCTUnwrap(retained.coverArtFileName)), shared)
        XCTAssertEqual(assets.readCoverData(named: try XCTUnwrap(removed[3].coverArtFileName)), custom)
        let album = await assets.cachedAlbumCover(forAlbumID: "stable-album")
        let artist = await assets.cachedArtistImage(forArtistID: "stable-artist")
        XCTAssertEqual(album, reusable)
        XCTAssertEqual(artist, reusable)
        XCTAssertEqual(assets.artworkContentUsage().count, 2)
    }

    func testRemovedSourceCleanupHandlesLegacySongOnlyArtworkReceipts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let reference = "subsonic-cover/album"
        let song = Song(id: "legacy-song", title: "Legacy", fileFormat: .flac, filePath: "/track.flac",
                        sourceID: "old-server", coverArtFileName: reference)
        for pixels in [480, 1536] {
            _ = await assets.cacheSourceCover(try image(color: pixels == 480 ? .red : .blue), songID: song.id,
                                             sourceID: song.sourceID, reference: reference, maximumPixels: pixels)
            let key = try XCTUnwrap(SourceArtworkPolicy.cacheID(sourceID: song.sourceID, reference: reference, maximumPixels: pixels))
            let receipt = assets.artworkDirectoryURL.appendingPathComponent("receipts")
                .appendingPathComponent(assets.expectedCoverFileName(for: key) + ".json")
            try FileManager.default.removeItem(at: receipt)
        }
        let cutoff = Date()
        await assets.invalidateRemovedSongCaches(songs: [song], songIDs: [song.id], retainingSongs: [], lastWrittenBefore: cutoff)
        await assets.invalidateSourceArtworkCaches(forSourceIDs: [song.sourceID], lastWrittenBefore: cutoff)

        XCTAssertNil(assets.cachedSourceCover(sourceID: song.sourceID, reference: reference, maximumPixels: 480, allowsStale: true))
        XCTAssertNil(assets.cachedSourceCover(sourceID: song.sourceID, reference: reference, maximumPixels: 1536, allowsStale: true))
        XCTAssertEqual(assets.artworkContentUsage().count, 0)
        let receipts = try FileManager.default.contentsOfDirectory(atPath: assets.artworkDirectoryURL.appendingPathComponent("receipts").path)
        XCTAssertTrue(receipts.isEmpty)
    }

    func testRemovedSongCleanupPreservesLegacyAliasesReferencedByAnotherSong() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let bytes = try image()
        let oldID = "portable-original"
        let cover = await assets.storeCover(bytes, for: oldID)
        let lyrics = await assets.storeLyrics([LyricLine(timestamp: 0, text: "shared")], for: oldID)
        _ = await assets.cacheSourceCover(bytes, songID: oldID, sourceID: "removed", reference: "/original.jpg", maximumPixels: 480)
        let removed = Song(id: oldID, title: "Old", fileFormat: .flac, filePath: "/old.flac", sourceID: "removed",
                           coverArtFileName: cover, lyricsFileName: lyrics)
        let retained = Song(id: "portable-copy", title: "Copy", fileFormat: .flac, filePath: "/copy.flac", sourceID: "retained",
                            coverArtFileName: cover, lyricsFileName: lyrics)
        let cutoff = Date()
        await assets.invalidateRemovedSongCaches(songs: [removed], songIDs: [oldID], retainingSongs: [retained], lastWrittenBefore: cutoff)
        await assets.invalidateSourceArtworkCaches(forSourceIDs: ["removed"], retainingSongs: [retained], lastWrittenBefore: cutoff)

        XCTAssertEqual(assets.readCoverData(named: try XCTUnwrap(cover)), bytes)
        let remaining = await assets.lyrics(named: lyrics)
        XCTAssertEqual(remaining?.first?.text, "shared")
        XCTAssertEqual(assets.artworkContentUsage().count, 1)
    }

    func testRemovedSourceCleanupPreservesArtworkAndLyricsRewrittenAfterRemoval() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let reference = "/album/cover.jpg"
        let song = Song(id: "restored-song", title: "Restored", fileFormat: .flac, filePath: "/track.flac",
                        sourceID: "restored-source", coverArtFileName: reference)
        _ = await assets.cacheSourceCover(try image(color: .red), songID: song.id, sourceID: song.sourceID,
                                         reference: reference, maximumPixels: 480)
        _ = await assets.cacheLyrics([LyricLine(timestamp: 0, text: "old")], forSongID: song.id)
        let cutoff = Date()
        try await Task.sleep(for: .milliseconds(30))
        let updated = try image(color: .blue)
        _ = await assets.cacheSourceCover(updated, songID: song.id, sourceID: song.sourceID,
                                         reference: reference, maximumPixels: 480)
        _ = await assets.cacheLyrics([LyricLine(timestamp: 0, text: "new")], forSongID: song.id)
        await assets.invalidateRemovedSongCaches(songs: [song], songIDs: [song.id], retainingSongs: [], lastWrittenBefore: cutoff)
        await assets.invalidateSourceArtworkCaches(forSourceIDs: [song.sourceID], lastWrittenBefore: cutoff)

        XCTAssertEqual(assets.cachedSourceCover(sourceID: song.sourceID, reference: reference, maximumPixels: 480), updated)
        XCTAssertEqual(assets.readCoverData(named: assets.expectedCoverFileName(for: song.id)), updated)
        let lyrics = await assets.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(lyrics?.first?.text, "new")
        XCTAssertEqual(assets.artworkContentUsage().count, 1)
    }

    func testCacheCleanupPreservesAssetsRewrittenAfterCleanupStarted() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let songID = "readded-song"
        let name = SHA256.hash(data: Data(songID.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined() + ".json"
        let file = store.lyricsDirectoryURL.appendingPathComponent(name)
        try Data("old".utf8).write(to: file)
        let removedAt = Date()
        try await Task.sleep(for: .milliseconds(30))
        try Data("new".utf8).write(to: file, options: .atomic)
        await store.invalidateCaches(forSongIDs: [songID], lastWrittenBefore: removedAt)
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
    }

    func testRemovedSongCacheCleanupPreservesOtherSongsAndReservedLyrics() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        func legacyName(_ id: String, _ suffix: String) -> String {
            SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + suffix
        }
        let removedID = "removed-song"
        let reservedID = "reserved-song"
        let reservation = await store.beginLyricsMutation(forSongID: reservedID, expectedFingerprint: nil)
        XCTAssertNotNil(reservation)
        var removedFiles = [URL]()
        for id in [removedID, reservedID, "retained-song"] {
            for suffix in [".jpg", ".json", ".embedded.json", ".recheck"] {
                let parent = suffix == ".jpg" ? store.artworkDirectoryURL : store.lyricsDirectoryURL
                let file = parent.appendingPathComponent(legacyName(id, suffix))
                try Data("cache".utf8).write(to: file)
                if id == removedID || (id == reservedID && suffix != ".json") { removedFiles.append(file) }
            }
        }
        let missingIDs = (0..<512).map { "uncached-\($0)" }
        await store.invalidateCaches(forSongIDs: missingIDs + [removedID, reservedID])
        XCTAssertTrue(removedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lyricsDirectoryURL
            .appendingPathComponent(legacyName(reservedID, ".json")).path))
        for suffix in [".jpg", ".json", ".embedded.json", ".recheck"] {
            let parent = suffix == ".jpg" ? store.artworkDirectoryURL : store.lyricsDirectoryURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent(legacyName("retained-song", suffix)).path))
        }
    }

    func testAlbumArtworkPrefersFolderCoverOverScrapedAlbumCache() async throws {
        try await verifyAlbumCoverPriority(sourceExists: true, uploaded: false)
    }

    func testAlbumArtworkUsesCachedCoverWhenFolderCoverCannotBeRead() async throws {
        try await verifyAlbumCoverPriority(sourceExists: false, uploaded: false)
    }

    func testAlbumArtworkKeepsExplicitUploadAboveFolderCover() async throws {
        try await verifyAlbumCoverPriority(sourceExists: true, uploaded: true)
    }

    private func verifyAlbumCoverPriority(sourceExists: Bool, uploaded: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: UUID().uuidString, name: "Cover fixture", type: .local, basePath: root.path)
        let manager = SourceManager(sourcesProvider: { [source] })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let song = Song(id: UUID().uuidString, title: "Window at Dawn", albumTitle: UUID().uuidString,
                        artistName: "Paper Harbor", fileFormat: .flac, filePath: "/Album/track.flac",
                        sourceID: source.id, coverArtFileName: "/Album/cover.jpg")
        library.addSongs([song])
        await library.waitForPendingIndex()
        let album = try XCTUnwrap(library.visibleAlbums.first)
        XCTAssertFalse(MetadataAssetStore.shared.hasAlbumCover(forAlbumID: album.id))
        XCTAssertTrue(MusicScraperService.albumHasArtwork(album.id, in: library),
                      "A source cover must count as existing artwork before any album cache is created")
        if sourceExists {
            let folder = root.appendingPathComponent("Album")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try image(color: .green).write(to: folder.appendingPathComponent("cover.jpg"))
        }
        _ = await MetadataAssetStore.shared.storeAlbumCover(try image(color: .red), forAlbumID: album.id)
        let customFile = uploaded ? try installHeroTestArtwork(
            image(color: .blue), library: library, owner: LibraryArtworkOwner(kind: .album, id: album.id)
        ) : nil
        defer {
            MetadataAssetStore.shared.removeAlbumCoverSync(forAlbumID: album.id)
            MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id)
            for size in [480, 1536] {
                if let key = SourceArtworkPolicy.cacheID(sourceID: source.id, reference: song.coverArtFileName, maximumPixels: size) {
                    MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: key)
                }
            }
            if let customFile { try? FileManager.default.removeItem(at: customFile) }
        }
        let view = AlbumArtworkView(album: album, size: 120, cornerRadius: 0)
            .frame(width: 120, height: 120).ignoresSafeArea()
            .environment(library).environment(manager).environment(\.scenePhase, .inactive)
        let (window, host, original) = try hostHeroTestView(view, size: CGSize(width: 120, height: 120))
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        var actual = (0, 0, 0)
        let expected = uploaded ? 2 : (sourceExists ? 1 : 0)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            actual = try rgb(heroTestSnapshot(host.view), x: 60, y: 60)
            let channels = [actual.0, actual.1, actual.2]
            if channels[expected] > 220 && channels.enumerated().allSatisfy({ $0.offset == expected || $0.element < 35 }) {
                return
            }
        }
        XCTFail("Expected cover channel \(expected), got \(actual)")
    }

    func testLocalNowPlayingPublishesCachedCoverAndKeepsItDuringLyricsUpdates() async throws {
        try await withArtworkPlayer { player, _, sourceID in
            let song = Song(id: UUID().uuidString, title: "Cached cover", fileFormat: .flac,
                            filePath: "/cached.flac", sourceID: sourceID)
            defer { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
            await MetadataAssetStore.shared.cacheCover(try image(color: .red), forSongID: song.id)
            player.currentSong = song
            player.updateNowPlayingInfo()
            player.updateNowPlayingArtworkIfNeeded()
            try await waitForSystemArtwork(player, songID: song.id)
            let artwork = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
            XCTAssertNotNil(artwork.image(at: CGSize(width: 64, height: 64)))
            player.updateNowPlayingInfo(lyricsLineOnly: true)
            XCTAssertTrue(artwork === MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        }
    }

    func testLocalNowPlayingPublishesSidecarAndSwitchesToUncachedCover() async throws {
        try await withArtworkPlayer { player, root, sourceID in
            let songs = ["red", "blue"].map {
                Song(id: UUID().uuidString, title: $0, fileFormat: .flac,
                     filePath: "/\($0).flac", sourceID: sourceID, coverArtFileName: "/\($0).png")
            }
            defer {
                for song in songs {
                    MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id)
                    for size in [480, 1536] {
                        if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: song.coverArtFileName, maximumPixels: size) {
                            MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: key)
                        }
                    }
                }
            }
            try image(color: .red).write(to: root.appendingPathComponent("red.png"))
            try image(color: .blue).write(to: root.appendingPathComponent("blue.png"))
            for song in songs {
                player.currentSong = song
                player.updateNowPlayingInfo()
                player.updateNowPlayingArtworkIfNeeded()
                try await waitForSystemArtwork(player, songID: song.id)
            }
            player.currentSong = songs[0]
            player.updateNowPlayingInfo()
            XCTAssertEqual(player.publishedArtworkSongID, songs[0].id)
            XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
                            "Returning to a cached local song must include artwork in the first snapshot")
        }
    }

    func testLocalNowPlayingRecoversLateCoverWithoutViewAndRefreshesReplacement() async throws {
        try await withArtworkPlayer { player, _, sourceID in
            let song = Song(id: UUID().uuidString, title: "Late cover", fileFormat: .flac,
                            filePath: "/late.flac", sourceID: sourceID)
            defer { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
            player.currentSong = song
            player.updateNowPlayingArtworkIfNeeded()
            await player.nowPlayingArtworkLoadTask?.value
            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
            await MetadataAssetStore.shared.cacheCover(try image(color: .red), forSongID: song.id)
            try await waitForSystemArtwork(player, songID: song.id)
            func publishedData() -> Data? {
                (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?
                    .image(at: CGSize(width: 32, height: 16))?.pngData()
            }
            let old = try XCTUnwrap(publishedData())
            await MetadataAssetStore.shared.cacheCover(try image(color: .blue), forSongID: song.id)
            let deadline = Date().addingTimeInterval(5)
            while publishedData() == old, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let updated = try XCTUnwrap(publishedData())
            XCTAssertNotEqual(old, updated)
        }
    }

    func testLateCoverForPreviousSongDoesNotReplaceCurrentSystemArtwork() async throws {
        try await withArtworkPlayer { player, _, sourceID in
            let previous = Song(id: UUID().uuidString, title: "Previous", fileFormat: .flac,
                                filePath: "/previous.flac", sourceID: sourceID)
            let current = Song(id: UUID().uuidString, title: "Current", fileFormat: .flac,
                               filePath: "/current.flac", sourceID: sourceID)
            defer {
                for song in [previous, current] { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
            }
            player.currentSong = previous
            player.updateNowPlayingArtworkIfNeeded()
            await player.nowPlayingArtworkLoadTask?.value
            await MetadataAssetStore.shared.cacheCover(try image(color: .blue), forSongID: current.id)
            player.currentSong = current
            player.updateNowPlayingArtworkIfNeeded()
            try await waitForSystemArtwork(player, songID: current.id)
            await player.nowPlayingArtworkLoadTask?.value
            let old = try XCTUnwrap((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?
                .image(at: CGSize(width: 32, height: 16))?.pngData())
            await MetadataAssetStore.shared.cacheCover(try image(color: .red), forSongID: previous.id)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(player.publishedArtworkSongID, current.id)
            XCTAssertEqual((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?
                .image(at: CGSize(width: 32, height: 16))?.pngData(), old)
            player.stop()
            await MetadataAssetStore.shared.cacheCover(try image(color: .green), forSongID: current.id)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        }
    }

    func testLocalNowPlayingReadsEmbeddedCoverWithoutAudioCache() async throws {
        try await withArtworkPlayer { player, root, sourceID in
            let music = root.appendingPathComponent("Music", isDirectory: true)
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
            try image(color: .red).write(to: music.appendingPathComponent("cover.jpg"))
            var payload = Data([0]) + Data("image/png".utf8) + Data([0, 3, 0])
            payload.append(try image(color: .green))
            let length = UInt32(payload.count)
            var frame = Data("APIC".utf8)
            frame.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255), 0, 0])
            frame.append(payload)
            let count = frame.count
            var file = Data([0x49, 0x44, 0x33, 3, 0, 0,
                             UInt8((count >> 21) & 127), UInt8((count >> 14) & 127), UInt8((count >> 7) & 127), UInt8(count & 127)])
            file.append(frame)
            file.append(Data(repeating: 0, count: 4_096))
            try file.write(to: music.appendingPathComponent("embedded.mp3"))
            for reference in [nil, "missing-cache.jpg", "/Music/cover.jpg"] as [String?] {
                let song = Song(id: UUID().uuidString, title: "Embedded cover", fileFormat: .mp3,
                                filePath: "/Music/embedded.mp3", sourceID: sourceID, coverArtFileName: reference)
                defer { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
                let cachedAudio = await player.sourceManager?.cachedURLForBackgroundRead(for: song)
                XCTAssertNil(cachedAudio)
                player.currentSong = song
                player.updateNowPlayingInfo()
                player.updateNowPlayingArtworkIfNeeded()
                try await waitForSystemArtwork(player, songID: song.id)
                let image = try XCTUnwrap((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.image(at: CGSize(width: 32, height: 16)))
                var pixel = [UInt8](repeating: 0, count: 4)
                let cgImage = try XCTUnwrap(image.cgImage)
                try pixel.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                XCTAssertGreaterThan(pixel[1], 240, "The embedded green cover must win over the generic red folder cover")
                XCTAssertLessThan(pixel[0], 15)
            }
        }
    }

    private func waitForSystemArtwork(_ player: AudioPlayerService, songID: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while player.publishedArtworkSongID != songID {
            guard Date() < deadline else {
                XCTFail("Local cover was not published to Now Playing")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, songID)
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
    }

    private func withArtworkPlayer(_ body: (AudioPlayerService, URL, String) async throws -> Void) async throws {
        _ = AppServices.shared
        await Task.yield()
        let session = AudioSessionManager.shared
        let previousBegan = session.onInterruptionBegan
        let previousEnded = session.onInterruptionEnded
        let previousConfiguration = session.onConfigurationChange
        defer {
            session.onInterruptionBegan = previousBegan
            session.onInterruptionEnded = previousEnded
            session.onConfigurationChange = previousConfiguration
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID().uuidString
        let source = MusicSource(id: sourceID, name: "Music", type: .local, basePath: root.path)
        let manager = SourceManager(sourcesProvider: { [source] })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: sourceID))
        defer { defaults.removePersistentDomain(forName: sourceID) }
        let player = AudioPlayerService(
            sourceManager: manager, playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Artwork tests must not start playback") }
        )
        defer { player.stop() }
        await Task.yield()
        try await body(player, root, sourceID)
    }

    func testArtistPageKeepsGrayscalePortraitNeutralAndTracksOverrides() async throws {
        try await verifyArtistPageTint(portrait: .gray)
    }

    func testArtistPageUsesPortraitColorInsteadOfSongCover() async throws {
        try await verifyArtistPageTint(portrait: .blue)
    }

    func testArtistPageUsesSuccessfulFallbackCoverAfterPreferredCoverFails() async throws {
        try await verifyArtistPageTint(portrait: nil)
    }

    func testArtistPageDarkPortraitWithSkinToneKeepsDarkBackground() async throws {
        try await verifyArtistPageTint(portrait: .black, includesSkinTone: true)
    }

    func testArtistPageDefaultsToMeshWithIndependentAppearanceSettingsAndTracksOverrides() async throws {
        try await verifyArtistPageTint(portrait: .green, checksMeshSwitch: true)
    }

    func testArtistIntroAndAddEntryAppearBeforeReleasesInPortrait() async throws {
        try await verifyArtistPageTint(portrait: .black, synopsisLayout: .regular)
    }

    func testIntroEditorOffersAppleMusicOnlyForArtists() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let subjects: [LibraryInsightSubject] = [
            .artist(name: "Paper Lantern", genres: [], albums: [], tracks: []),
            .album(title: "Evening Window", artist: "Paper Lantern", year: nil, genres: [], tracks: [])
        ]
        for subject in subjects {
            let view = LibraryInsightEditorSheet(subject: subject, details: { subject }, record: nil) {}
                .environment(library).environment(AppServices.shared.musicIntelligence)
            let (window, host, original) = try hostHeroTestView(view, size: CGSize(width: 390, height: 844))
            defer {
                window.isHidden = true
                window.rootViewController = nil
                original?.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(400))
            let snapshot = try heroTestSnapshot(host.view)
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: snapshot).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertEqual(text.contains("Apple Music"), subject.kind == .artist, text)
            XCTAssertTrue(text.contains("Last.fm"), text)
            let attachment = XCTAttachment(image: UIImage(cgImage: snapshot))
            attachment.name = "intro-editor-\(subject.kind.rawValue)-sources"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testArtistIntroAndAddEntryRemainVisibleInLandscape() async throws {
        try await verifyArtistPageTint(portrait: .black, synopsisLayout: .compact)
    }

    private func verifyArtistPageTint(
        portrait: UIColor?,
        includesSkinTone: Bool = false,
        checksMeshSwitch: Bool = false,
        synopsisLayout: UserInterfaceSizeClass? = nil
    ) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let name = "Tint Artist \(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backdrop = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        backdrop.update { $0.ambientStyle = .classic }
        if !checksMeshSwitch {
            defaults.set(PlayerAmbientStyle.classic.rawValue, forKey: ArtistAppearancePreferences.colorStyleKey)
        }
        let songs = (0..<2).map { index in
            let id = UUID().uuidString
            return Song(id: id, title: "Track \(index)", albumTitle: "Tint Album", artistName: name,
                        fileFormat: .mp3, filePath: "/tint-\(index).mp3", sourceID: name,
                        coverArtFileName: MetadataAssetStore.shared.expectedCoverFileName(for: id))
        }
        for song in songs {
            await MetadataAssetStore.shared.cacheCover(try image(color: .red), forSongID: song.id)
        }
        defer {
            for song in songs { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
        }
        library.addSongs(songs)
        await library.waitForPendingIndex()
        let artist = try XCTUnwrap(library.visibleArtists.first { $0.name == name })
        let owner = LibraryArtworkOwner(kind: .artist, id: artist.id)
        let preferred = try XCTUnwrap(library.preferredArtworkSong(forArtistID: artist.id))
        let alternate = try XCTUnwrap(songs.first { $0.id != preferred.id })
        var portraitURL: URL?
        if let portrait {
            let data: Data
            if checksMeshSwitch {
                data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
                    UIColor.blue.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
                    UIColor.green.setFill()
                    context.fill(CGRect(x: 0, y: 40, width: 80, height: 40))
                }.pngData())
            } else if includesSkinTone {
                data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
                    portrait.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
                    UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1).setFill()
                    context.fill(CGRect(x: 28, y: 8, width: 24, height: 64))
                }.pngData())
            } else {
                data = try image(color: portrait)
            }
            let fileName = await MetadataAssetStore.shared.storeArtistImage(data, forArtistID: artist.id)
            portraitURL = MetadataAssetStore.shared.artworkDirectoryURL
                .appendingPathComponent("artist").appendingPathComponent(try XCTUnwrap(fileName))
        } else {
            MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: preferred.id)
        }
        defer { if let portraitURL { try? FileManager.default.removeItem(at: portraitURL) } }

        let services = AppServices.shared
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let size = synopsisLayout == .compact ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView:
            NavigationStack { ArtistDetailView(artist: artist, appearanceDefaults: defaults) }
                .frame(width: size.width, height: size.height)
                .environment(library)
                .environment(SourceManager(sourcesProvider: { [] }))
                .environment(SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources")))
                .environment(services.playerService).environment(services.metadataBackfill)
                .environment(services.musicIntelligence)
                .environment(services.scraperService).environment(services.scraperSettingsStore)
                .environment(services.playbackSettingsStore)
                .environment(services.themeService).environment(CoverTintProvider())
                .environment(services.batchRemoval)
                .environment(\.scenePhase, .inactive)
                .environment(\.horizontalSizeClass, .compact)
                .environment(\.verticalSizeClass, synopsisLayout ?? .regular)
                .environment(\.colorScheme, .light))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }

        func assertBackground(_ expected: UIColor, file: StaticString = #filePath, line: UInt = #line) async throws {
            var components = [UInt8](repeating: 0, count: 4)
            var matches = false
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let pixel = try XCTUnwrap(rendered.cgImage?.cropping(to: CGRect(x: 2, y: 700, width: 1, height: 1)))
                components.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                let r = Int(components[0]), g = Int(components[1]), b = Int(components[2])
                if expected == .black {
                    matches = max(r, g, b) < 25 && abs(r - b) < 5
                } else if expected == .gray {
                    matches = abs(r - g) < 5 && abs(g - b) < 5 && r < 140
                } else if expected == .red {
                    matches = r > g + 20 && r > b + 20
                } else if expected == .green {
                    matches = g > r + 20 && g > b + 20
                } else {
                    matches = b > r + 20 && b > g + 20
                }
                if matches { break }
            }
            XCTAssertTrue(matches, "Expected \(expected), background RGBA: \(components)", file: file, line: line)
        }

        func assertBackgroundVariation(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            var difference = 0
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let strip = try XCTUnwrap(rendered.cgImage?.cropping(to: CGRect(x: 0, y: 700, width: 390, height: 1)))
                var pixels = [UInt8](repeating: 0, count: 390 * 4)
                pixels.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 390, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 390 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(strip, in: CGRect(x: 0, y: 0, width: 390, height: 1))
                }
                difference = (0..<3).map { abs(Int(pixels[2 * 4 + $0]) - Int(pixels[387 * 4 + $0])) }.max() ?? 0
                if expected ? difference > 20 : difference < 5 { return }
            }
            XCTFail("Expected horizontal color variation: \(expected), difference: \(difference)", file: file, line: line)
        }

        func assertSoftensEdges(top: Bool, bottom: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            guard #available(iOS 26.0, *) else { return }
            func scrollViews(in view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                if let scroll = scrollViews(in: host.view).first(where: { $0.bounds.height > 600 }),
                   scroll.topEdgeEffect.isHidden == !top,
                   scroll.bottomEdgeEffect.isHidden == !bottom {
                    return
                }
            }
            XCTFail("Expected artist scroll edge softening: top=\(top), bottom=\(bottom)", file: file, line: line)
        }

        // Wait for the initial song/portrait race to settle before accepting a neutral loading state.
        try await Task.sleep(for: .milliseconds(700))
        if let synopsisLayout {
            let subject = LibraryInsightSubject.artist(name: name, genres: [], albums: [], tracks: [])
            let summary = "Fictional artist biography."
            for hasIntro in [false, true] {
                if hasIntro {
                    LibraryInsightStore.shared.saveEdit(subject, summary: summary, tags: [], aiDraft: nil, library: library)
                    _ = await library.persistNowAndWait()
                    try await Task.sleep(for: .milliseconds(300))
                }
                host.view.layoutIfNeeded()
                let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "artist-intro-\(synopsisLayout == .compact ? "landscape" : "portrait")-\(hasIntro ? "saved" : "empty")"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(rendered.cgImage)).perform([request])
                let lines = request.results ?? []
                let expected = hasIntro ? summary : String(localized: "library_insight_add")
                let intro = try XCTUnwrap(lines.first {
                    $0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "")
                        .localizedCaseInsensitiveContains(expected.replacingOccurrences(of: " ", with: "")) == true
                }, "The intro or its add entry must be readable without scrolling")
                let release = try XCTUnwrap(lines.first {
                    $0.topCandidates(1).first?.string.contains("Tint Album") == true
                }, "The latest release must remain below the intro")
                XCTAssertGreaterThan(intro.boundingBox.minY, release.boundingBox.maxY)
            }
            return
        }
        if checksMeshSwitch {
            try await assertBackgroundVariation(true)
            try await assertSoftensEdges(top: false, bottom: true)
            defaults.set(PlayerAmbientStyle.classic.rawValue, forKey: ArtistAppearancePreferences.colorStyleKey)
            backdrop.update { $0.ambientStyle = .mesh }
            try await assertBackgroundVariation(false)
            try await assertBackground(.blue)
            defaults.set(false, forKey: ArtistAppearancePreferences.softensEdgesKey)
            try await assertSoftensEdges(top: false, bottom: false)
            defaults.set(true, forKey: ArtistAppearancePreferences.softensEdgesKey)
            try await assertSoftensEdges(top: false, bottom: true)
            defaults.set(PlayerAmbientStyle.mesh.rawValue, forKey: ArtistAppearancePreferences.colorStyleKey)
            backdrop.update { $0.ambientStyle = .classic }
            try await assertBackgroundVariation(true)
            try await assertSoftensEdges(top: false, bottom: true)
            defaults.set(false, forKey: ArtistAppearancePreferences.softensEdgesKey)
            try await assertSoftensEdges(top: false, bottom: false)
            let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
            XCTAssertEqual(restoredDefaults.string(forKey: ArtistAppearancePreferences.colorStyleKey), "mesh")
            XCTAssertEqual(restoredDefaults.object(forKey: ArtistAppearancePreferences.softensEdgesKey) as? Bool, false)
        } else {
            try await assertBackground(portrait ?? .red)
        }
        let existingUploads = Set(try FileManager.default.contentsOfDirectory(
            at: MetadataAssetStore.shared.customArtworkDirectoryURL, includingPropertiesForKeys: nil))
        let contentID = try XCTUnwrap(MetadataAssetStore.shared.storeCustomArtworkSync(try image(color: .green, width: 113)))
        let uploadedURL = MetadataAssetStore.shared.customArtworkDirectoryURL.appendingPathComponent("\(contentID).jpg")
        defer { if !existingUploads.contains(uploadedURL) { try? FileManager.default.removeItem(at: uploadedURL) } }
        XCTAssertTrue(library.setUploadedArtwork(contentID: contentID, for: owner))
        try await assertBackground(.green)
        XCTAssertTrue(library.setArtwork(for: owner, to: alternate))
        try await assertBackground(.red)
        XCTAssertTrue(library.setAutomaticArtwork(for: owner))
        if checksMeshSwitch {
            try await assertBackgroundVariation(true)
        } else {
            try await assertBackground(portrait ?? .red)
        }
    }

    func testPlaylistCustomCoverKeepsDynamicHeaderAndUpdatesHomeArtwork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PlaylistCoverWallTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CollectionCoverWall.preferenceKey)

        let library = MusicLibrary(storageDirectory: root)
        let manager = SourceManager(sourcesProvider: { [] })
        let sources = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        let songs = (0..<4).map { index in
            let id = UUID().uuidString
            return Song(id: id, title: "Track \(index)", albumID: "album-\(index)", albumTitle: "Album \(index)",
                 fileFormat: .mp3, filePath: "/cover-wall-\(index).mp3", sourceID: suite,
                 coverArtFileName: MetadataAssetStore.shared.expectedCoverFileName(for: id))
        }
        for (index, song) in songs.enumerated() {
            await MetadataAssetStore.shared.cacheCover(try image(color: index == 0 ? .red : .blue), forSongID: song.id)
        }
        defer {
            for song in songs { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
        }
        library.addSongs(songs)
        await library.waitForPendingIndex()
        let playlist = library.createPlaylist(name: "Cover wall", songIDs: songs.map(\.id))
        let owner = LibraryArtworkOwner(kind: .playlist, id: playlist.id)
        XCTAssertTrue(CollectionCoverWall.isAvailable(for: library.songs(forPlaylist: playlist.id)))

        let services = AppServices.shared
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let host = UIHostingController(rootView:
            VStack(spacing: 0) {
                NavigationStack { PlaylistDetailView(playlist: playlist) }
                    .frame(height: 600)
                // Home cards use this same artwork surface.
                PlaylistArtworkView(playlist: playlist, size: 100, cornerRadius: 0)
                    .frame(height: 120)
            }
            .frame(width: 390, height: 720)
            .ignoresSafeArea()
            .environment(services.playerService).environment(library).environment(manager).environment(sources)
            .environment(services.metadataBackfill).environment(services.scraperService)
            .environment(services.scraperSettingsStore).environment(services.musicIntelligence)
            .environment(services.playbackSettingsStore).environment(services.themeService)
            .environment(services.coverTintProvider).environment(services.batchRemoval)
            .environment(\.scenePhase, .inactive)
            .environment(\.verticalSizeClass, .regular)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.colorScheme, .light)
            .defaultAppStorage(defaults))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }

        func pixels(in rect: CGRect) async throws -> [UInt8] {
            try await Task.sleep(for: .milliseconds(700))
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            add(XCTAttachment(image: rendered))
            let cgImage = try XCTUnwrap(rendered.cgImage?.cropping(to: rect))
            var result = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try result.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                    width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                    bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            return result
        }
        let headerRect = CGRect(x: 20, y: 120, width: 350, height: 160)
        let tileCenter = CGRect(x: 190, y: 655, width: 10, height: 10)
        let originalHeader = try await pixels(in: headerRect)
        let automaticTile = try await pixels(in: tileCenter)
        let automaticIsRed = automaticTile[0] > 200 && automaticTile[2] < 30
        let automaticIsBlue = automaticTile[2] > 200 && automaticTile[0] < 30
        XCTAssertTrue(automaticIsRed || automaticIsBlue, "Automatic artwork must resolve a playlist member")

        XCTAssertTrue(library.setArtwork(for: owner, to: songs[automaticIsRed ? 1 : 0]))
        let selectedHeader = try await pixels(in: headerRect)
        XCTAssertTrue(selectedHeader == originalHeader, "Selecting the home cover must preserve the dynamic header")
        let selectedTile = try await pixels(in: tileCenter)
        XCTAssertGreaterThan(selectedTile[automaticIsRed ? 2 : 0], 200)
        XCTAssertLessThan(selectedTile[automaticIsRed ? 0 : 2], 30)

        let uploadedData = try image(color: .green, width: 97)
        let existingFiles = Set(try FileManager.default.contentsOfDirectory(
            at: MetadataAssetStore.shared.customArtworkDirectoryURL, includingPropertiesForKeys: nil))
        let contentID = try XCTUnwrap(MetadataAssetStore.shared.storeCustomArtworkSync(uploadedData))
        let uploadedURL = MetadataAssetStore.shared.customArtworkDirectoryURL.appendingPathComponent("\(contentID).jpg")
        defer {
            if !existingFiles.contains(uploadedURL) { try? FileManager.default.removeItem(at: uploadedURL) }
        }
        XCTAssertTrue(library.setUploadedArtwork(contentID: contentID, for: owner))
        let uploadedHeader = try await pixels(in: headerRect)
        XCTAssertTrue(uploadedHeader == originalHeader, "Uploading the home cover must preserve the dynamic header")
        let uploadedTile = try await pixels(in: tileCenter)
        XCTAssertGreaterThan(uploadedTile[1], 200)
        XCTAssertLessThan(uploadedTile[0], 30)

        defaults.set(false, forKey: CollectionCoverWall.preferenceKey)
        let staticHeader = try await pixels(in: headerRect)
        XCTAssertTrue(staticHeader != originalHeader, "Disabling the wall must still restore the single cover")
        let staticTile = try await pixels(in: tileCenter)
        XCTAssertEqual(staticTile, uploadedTile)
    }

    func testCompanionPlanIncludesOwnedCollectionsAndDeduplicatesReferences() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let sourceID = UUID().uuidString
        let reference = "subsonic-cover/song"
        let song = Song(id: "song", title: "A quiet harbor", fileFormat: .flac,
            filePath: "/songs/song.flac", sourceID: sourceID, coverArtFileName: reference)
        let owned = try XCTUnwrap(SourceOwnedArtworkReference.make(sourceID: sourceID, reference: "subsonic-artist/portrait"))
        let artist = Artist(id: "artist", name: "Paper Lantern", thumbnailPath: owned)
        let playlist = Playlist(id: ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: "list"),
            name: "All Music", coverArtPath: "subsonic-cover/pl-list", hasDedicatedCoverArt: true)
        func plan() -> SourceManager.CompanionAssetPlan {
            SourceManager.companionAssetPlan(for: [song, song], artists: [artist, artist],
                playlists: [playlist, playlist], store: store)
        }
        XCTAssertEqual(plan().coverCount, 3)
        XCTAssertEqual(plan().collectionArtwork.count, 2)
        await store.cacheSourceCover(try image(), songID: song.id, sourceID: sourceID, reference: reference, maximumPixels: 480)
        await store.cacheSourceCover(try image(), songID: nil, sourceID: sourceID, reference: playlist.coverArtPath, maximumPixels: 480)
        let artistKey = SubsonicArtistArtworkRequest.cacheID(artistID: artist.id, reference: owned)
        _ = await store.storeArtistImage(try image(), forArtistID: artistKey)
        XCTAssertTrue(plan().collectionArtwork.isEmpty)
        XCTAssertTrue(plan().coverGroups.isEmpty)
    }

    func testSourceLyricsAbsenceExpiresAndInvalidatesWithSongRevisionAndClear() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let song = Song(id: "receipt", title: "A quiet harbor", fileFormat: .flac,
            filePath: "/songs/receipt.flac", sourceID: "server")
        let now = Date()
        await store.recordSourceLyricsAbsence(for: song, now: now)
        XCTAssertTrue(store.hasConfirmedSourceLyricsAbsence(for: song, now: now))
        XCTAssertFalse(store.hasCachedLyricsFile(forSongID: song.id))
        XCTAssertTrue(SourceManager.companionAssetPlan(for: [song], store: store).lyricsSongs.isEmpty)
        XCTAssertFalse(store.hasConfirmedSourceLyricsAbsence(for: song, now: now.addingTimeInterval(86_401)))
        var replaced = song
        replaced.revision = "new-version"
        XCTAssertFalse(store.hasConfirmedSourceLyricsAbsence(for: replaced, now: now))
        XCTAssertEqual(SourceManager.companionAssetPlan(for: [replaced], store: store).lyricsSongs.count, 1)
        _ = await store.invalidateLyricsCache(forSongID: song.id)
        XCTAssertFalse(store.hasConfirmedSourceLyricsAbsence(for: song))
        await store.recordSourceLyricsAbsence(for: song)
        await store.clearAll()
        XCTAssertFalse(store.hasConfirmedSourceLyricsAbsence(for: song))
    }

    func testCompanionBatchCachesCollectionsAndReportsRetryableFailures() async throws {
        let sourceID = UUID().uuidString
        let songID = UUID().uuidString
        let source = MusicSource(id: sourceID, name: "Batch fixture", type: .navidrome, host: "artwork.invalid")
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        await connector.setArtwork(try image(color: .red, width: 512))
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let song = Song(id: songID, title: "A quiet harbor", fileFormat: .flac,
            filePath: "/songs/\(songID).flac", sourceID: sourceID, coverArtFileName: "subsonic-cover/\(songID)")
        let owned = try XCTUnwrap(SourceOwnedArtworkReference.make(sourceID: sourceID, reference: "subsonic-artist/portrait"))
        let artist = Artist(id: UUID().uuidString, name: "Paper Lantern", thumbnailPath: owned)
        let artistKey = SubsonicArtistArtworkRequest.cacheID(artistID: artist.id, reference: owned)
        let playlist = Playlist(id: ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: "list"),
            name: "All Music", coverArtPath: "subsonic-cover/pl-list", hasDedicatedCoverArt: true)
        let store = MetadataAssetStore.shared
        let plan = SourceManager.companionAssetPlan(for: [song], artists: [artist], playlists: [playlist])
        XCTAssertEqual(plan.itemCount, 4)
        func run(_ plan: SourceManager.CompanionAssetPlan) async throws -> SourceManager.CompanionAssetProgress {
            manager.startCompanionAssetDownload(plan)
            let deadline = Date().addingTimeInterval(10)
            while manager.companionAssetProgress != nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(manager.companionAssetProgress)
            return try XCTUnwrap(manager.lastCompanionAssetResult)
        }
        defer { manager.cancelCompanionAssetDownload() }
        let saved = try await run(plan)
        XCTAssertEqual(saved.coversSaved, 3)
        XCTAssertEqual(saved.unavailable, 1)
        XCTAssertEqual(saved.failed, 0)
        XCTAssertTrue(saved.succeeded)
        XCTAssertTrue(SourceManager.companionAssetPlan(for: [song], artists: [artist], playlists: [playlist]).isEmpty)
        let artistPreview = await CachedArtworkView.resolveCachedImage(coverRef: owned, songID: nil,
            size: 300, sourceID: sourceID, artistID: artist.id)
        XCTAssertNotNil(artistPreview)

        await connector.setArtwork(nil)
        await connector.setLyrics(.unavailable)
        let missing = Song(id: UUID().uuidString, title: "No reply yet", fileFormat: .flac,
            filePath: "/songs/missing.flac", sourceID: sourceID, coverArtFileName: "subsonic-cover/missing")
        let failed = try await run(SourceManager.companionAssetPlan(for: [missing]))
        XCTAssertEqual(failed.failed, 2)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(SourceManager.companionAssetPlan(for: [missing]).itemCount, 2)
        await store.clearSourceLyricsAbsence(songID: song.id)
        store.invalidateCoverCacheSync(forSongID: song.id)
        for reference in [song.coverArtFileName!, playlist.coverArtPath!] {
            if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: 480) {
                store.invalidateCoverCacheSync(forSongID: key)
            }
        }
        let artistFile = SHA256.hash(data: Data("artist_\(artistKey)".utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
        try? FileManager.default.removeItem(at: store.artworkDirectoryURL.appendingPathComponent("artist/" + artistFile))
    }

    func testBatchLyricsAbsenceIsDifferentFromTransportFailure() async throws {
        let sourceID = UUID().uuidString
        let source = MusicSource(id: sourceID, name: "Lyrics fixture", type: .navidrome, host: "lyrics.invalid")
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        for (response, expectedAbsent) in [(ServerLyricsReadResult.absent, true), (.unavailable, false), (.content(""), false)] {
            let song = Song(id: UUID().uuidString, title: "A quiet harbor", fileFormat: .flac,
                filePath: "/songs/\(UUID().uuidString).flac", sourceID: sourceID)
            await connector.setLyrics(response)
            let result = await LyricsLoader.cacheSourceProvidedLyrics(for: song, sourceManager: manager)
            if expectedAbsent {
                guard case .absent = result else { XCTFail("Authoritative absence should be reported separately"); return }
            } else {
                guard case .failed = result else { XCTFail("An unavailable or unusable document must remain retryable"); return }
            }
            XCTAssertEqual(MetadataAssetStore.shared.hasConfirmedSourceLyricsAbsence(for: song), expectedAbsent)
            await MetadataAssetStore.shared.clearSourceLyricsAbsence(songID: song.id)
        }
    }

    func testDiskThumbnailDisplaysWhileFullCoverRequestIsSuspended() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        for storedPixels in [480, 1536] {
            let songID = UUID().uuidString
            let sourceID = UUID().uuidString
            let reference = "subsonic-cover/\(songID)"
            let source = MusicSource(id: sourceID, name: "Slow artwork", type: .navidrome, host: "artwork.invalid")
            let gate = UploadedArtworkReadGate()
            let connector = ServerCoverFixtureConnector(sourceID: sourceID, artworkGate: gate)
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
            let store = MetadataAssetStore.shared
            await store.cacheSourceCover(try image(color: .red, width: 480), songID: songID,
                sourceID: sourceID, reference: reference, maximumPixels: storedPixels)
            if storedPixels == 1536 {
                let key = try XCTUnwrap(SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: storedPixels))
                let file = store.artworkDirectoryURL.appendingPathComponent(store.expectedCoverFileName(for: key))
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-SourceArtworkPolicy.maximumAge - 60)], ofItemAtPath: file.path)
            }
            let resolved = expectation(description: "Disk preview appears before network completes")
            resolved.assertForOverFulfill = false
            let view = CachedArtworkView(coverRef: reference, songID: songID, size: 300,
                sourceID: sourceID, filePath: "/songs/\(songID).flac", fileFormat: .flac,
                onResolutionChange: { if $0 { resolved.fulfill() } }).environment(library).environment(manager)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            await fulfillment(of: [resolved], timeout: 3)
            XCTAssertNil(store.cachedSourceCover(sourceID: sourceID, reference: reference, maximumPixels: 1536))
            window.isHidden = true
            window.rootViewController = nil
            await gate.release()
            for pixels in [480, 1536] {
                if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: pixels) {
                    store.invalidateCoverCacheSync(forSongID: key)
                }
            }
            store.invalidateCoverCacheSync(forSongID: songID)
        }
    }

    func testPlaylistPreviewUsesDownloadedThumbnailBeforeMissingDedicatedCover() async throws {
        let sourceID = UUID().uuidString
        let songID = UUID().uuidString
        let reference = "subsonic-cover/\(songID)"
        let song = Song(id: songID, title: "A quiet harbor", fileFormat: .flac,
            filePath: "/songs/\(songID).flac", sourceID: sourceID, coverArtFileName: reference)
        let playlist = Playlist(id: ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: "list"),
            name: "All Music", coverArtPath: "subsonic-cover/pl-missing", hasDedicatedCoverArt: true)
        let store = MetadataAssetStore.shared
        await store.cacheSourceCover(try image(width: 480), songID: songID, sourceID: sourceID, reference: reference, maximumPixels: 480)
        let plan = PlaylistArtworkResolutionPolicy.makePlan(playlist: playlist, songs: [song])
        let preview = await PlaylistArtworkResourceResolver.cachedPreview(playlist: playlist, plan: plan, songs: [song], size: 300)
        XCTAssertNotNil(preview)
        XCTAssertNil(store.cachedSourceCover(sourceID: sourceID, reference: reference, maximumPixels: 1536))
        let musicKitPreview = await CachedArtworkView.resolveCachedImage(coverRef: reference,
            songID: songID, size: 300, sourceID: AppleMusicLibraryIdentity.sourceID)
        XCTAssertNil(musicKitPreview)
        let genericReference = "/Music/cover.jpg"
        await store.cacheSourceCover(try image(), songID: songID, sourceID: sourceID,
            reference: genericReference, maximumPixels: 480)
        let genericPreview = await CachedArtworkView.resolveCachedImage(coverRef: genericReference,
            songID: songID, size: 300, sourceID: sourceID, filePath: "/Music/song.flac")
        XCTAssertNil(genericPreview)
        if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: genericReference, maximumPixels: 480) {
            store.invalidateCoverCacheSync(forSongID: key)
        }
        store.invalidateCoverCacheSync(forSongID: songID)
        if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: 480) {
            store.invalidateCoverCacheSync(forSongID: key)
        }
    }

    func testLargeSourceArtworkIsBoundedAndPersistedAsAStaticImage() async throws {
        let sourceID = UUID().uuidString
        let songID = UUID().uuidString
        let reference = "subsonic-cover/\(songID)"
        let source = MusicSource(id: sourceID, name: "Large artwork", type: .navidrome, host: "artwork.invalid")
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        await connector.setArtwork(try animatedUploadGIF(paddingBytes: 9 * 1024 * 1024))
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let resolved = await CachedArtworkView.resolveImage(coverRef: reference, songID: songID, size: 64,
            sourceID: sourceID, filePath: "/songs/\(songID).flac", fileFormat: .flac, sourceManager: manager)
        XCTAssertNotNil(resolved)
        let stored = try XCTUnwrap(MetadataAssetStore.shared.cachedSourceCover(sourceID: sourceID, reference: reference, maximumPixels: 480))
        XCTAssertLessThan(stored.count, 8 * 1024 * 1024)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(stored as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        let limits = await connector.byteLimits
        XCTAssertEqual(limits, [32 * 1024 * 1024])
        MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: songID)
        if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: 480) {
            MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: key)
        }
    }

    func testEmbeddedSourceFallbackIsAvailableOfflineWithoutClaimingServerQuality() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let song = Song(id: "embedded", title: "A quiet harbor", fileFormat: .flac,
            filePath: "/songs/embedded.flac", sourceID: "server", coverArtFileName: "subsonic-cover/revision-1")
        let data = try image(width: 480)
        await store.cacheEmbeddedSourceCover(data, songID: song.id, sourceID: song.sourceID, reference: song.coverArtFileName!)
        XCTAssertTrue(SourceManager.companionAssetPlan(for: [song], store: store).coverGroups.isEmpty)
        XCTAssertEqual(store.displayCoverData(songID: song.id, reference: song.coverArtFileName), data)
        XCTAssertNil(store.cachedSourceCover(sourceID: song.sourceID, reference: song.coverArtFileName, maximumPixels: 1536))
        var replaced = song
        replaced.coverArtFileName = "subsonic-cover/revision-2"
        XCTAssertEqual(SourceManager.companionAssetPlan(for: [replaced], store: store).coverGroups.count, 1)
    }

    func testCompanionCompletionDoesNotTreatFailuresOrCancellationAsSuccess() {
        var result = SourceManager.CompanionAssetProgress(completed: 3, total: 3, coversSaved: 1, lyricsSaved: 1, unavailable: 1)
        XCTAssertTrue(result.succeeded)
        result.failed = 1
        XCTAssertFalse(result.succeeded)
        let text = CompanionAssetDownloadFlow.statusText(progress: nil, lastResult: result, foundNothing: false)
        XCTAssertTrue(text?.contains(String(format: String(localized: "companion_assets_download_failed_format"), 1)) == true)
        result.failed = 0
        result.cancelled = true
        XCTAssertFalse(result.succeeded)
        result.cancelled = false
        result.completed = 2
        XCTAssertFalse(result.succeeded)
    }

    func testServerPlayerKeepsOfflineFallbackProvisionalUntilFullCoverArrives() async throws {
        let songID = UUID().uuidString
        let sourceID = UUID().uuidString
        let reference = "subsonic-cover/mf-" + songID
        let thumbnailKey = try XCTUnwrap(SubsonicArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: 480))
        let fullKey = try XCTUnwrap(SubsonicArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: 1536))
        defer {
            for key in [songID, thumbnailKey, fullKey] {
                MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: key)
            }
        }
        let source = MusicSource(id: sourceID, name: "Artwork fixture", type: .navidrome, host: "artwork.invalid")
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        func resolve() async -> UIImage? {
            await CachedArtworkView.resolveImage(
                coverRef: reference, songID: songID, size: 512,
                sourceID: sourceID, filePath: "/songs/song.m4a", fileFormat: .m4a,
                sourceManager: manager, cacheDiscriminator: songID
            )
        }
        await MetadataAssetStore.shared.cacheCover(try image(width: 480), forSongID: songID)
        let song = Song(id: songID, title: "Artwork fixture", fileFormat: .m4a,
                        filePath: "/songs/song.m4a", sourceID: sourceID, coverArtFileName: reference)
        XCTAssertEqual(SourceManager.companionAssetPlan(for: [song]).coverGroups.count, 1)
        let legacy = await resolve()
        XCTAssertEqual(legacy?.cgImage?.width, 480)
        await MetadataAssetStore.shared.cacheSubsonicCover(
            try image(width: 480), songID: songID, sourceID: sourceID, reference: reference, maximumPixels: 480
        )
        let offlineThumbnail = await resolve()
        XCTAssertEqual(offlineThumbnail?.cgImage?.width, 480)
        await connector.setArtwork(try image(color: .blue, width: 1536))
        let full = await resolve()
        XCTAssertEqual(full?.cgImage?.width, 1536)
        XCTAssertTrue(SourceManager.companionAssetPlan(for: [song]).coverGroups.isEmpty)
        let purposes = await connector.purposes
        XCTAssertEqual(purposes.count, 3)
        XCTAssertTrue(purposes.allSatisfy { $0 == .fullResolution })
    }

    func testServerCoverCacheIgnoresUnverifiedSongMirrorAndTracksCoverRevision() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let old = try image(color: .red)
        let server = try image(color: .blue, width: 1024)
        let reference = "subsonic-cover/mf-chengdu_old"
        await store.cacheCover(old, forSongID: "song")
        let unverified = await store.cachedSubsonicCover(sourceID: "server", reference: reference, maximumPixels: 1536)
        XCTAssertNil(unverified)
        await store.cacheSubsonicCover(server, songID: "song", sourceID: "server", reference: reference, maximumPixels: 1536)
        let current = await store.cachedSubsonicCover(sourceID: "server", reference: reference, maximumPixels: 1536)
        let replaced = await store.cachedSubsonicCover(sourceID: "server", reference: "subsonic-cover/mf-chengdu_new", maximumPixels: 1536)
        let otherSource = await store.cachedSubsonicCover(sourceID: "other", reference: reference, maximumPixels: 1536)
        XCTAssertEqual(current, server)
        XCTAssertNil(replaced)
        XCTAssertNil(otherSource)
    }

    func testThumbnailDoesNotSatisfyOrDowngradeFullServerCover() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let thumbnail = try image(color: .red, width: 480)
        let full = try image(color: .blue, width: 1536)
        let reference = "subsonic-cover/mf-chengdu_version"
        await store.cacheSubsonicCover(thumbnail, songID: "song", sourceID: "server", reference: reference, maximumPixels: 192)
        let coldFull = await store.cachedSubsonicCover(sourceID: "server", reference: reference, maximumPixels: 1536)
        XCTAssertNil(coldFull)
        await store.cacheSubsonicCover(full, songID: "song", sourceID: "server", reference: reference, maximumPixels: 1536)
        await store.cacheSubsonicCover(thumbnail, songID: "song", sourceID: "server", reference: reference, maximumPixels: 192)
        let warmFull = await store.cachedSubsonicCover(sourceID: "server", reference: reference, maximumPixels: 1536)
        let warmThumbnail = await store.cachedSubsonicCover(sourceID: "server", reference: reference, maximumPixels: 192)
        let mirror = await store.cachedCoverData(forSongID: "song")
        XCTAssertEqual(warmFull, full)
        XCTAssertEqual(warmThumbnail, full)
        XCTAssertEqual(mirror, full)
    }

    func testAudiobookSourceCoverSurvivesStoreRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let bytes = try image()
        let references = [
            TingReaderAPIProtocol.coverReference(bookID: "book", libraryID: "library", coverPath: "/cover.jpg"),
            AudiobookshelfAPIProtocol.coverReference(itemID: "book", updatedAt: nil),
        ]
        for reference in references {
            let stored = await assets.cacheSourceCover(bytes, songID: reference, sourceID: "server",
                                                       reference: reference, maximumPixels: 1536)
            XCTAssertTrue(stored)
        }
        let restored = MetadataAssetStore(storageDirectory: root)
        for reference in references {
            XCTAssertEqual(restored.cachedSourceCover(sourceID: "server", reference: reference,
                                                     maximumPixels: 480, checksAge: false), bytes)
            XCTAssertEqual(restored.displayCoverData(songID: reference, reference: reference, allowsStale: false), bytes)
            XCTAssertNotNil(restored.displayCoverIdentity(songID: reference, reference: reference))
            XCTAssertNil(restored.cachedSourceCover(sourceID: "other", reference: reference, maximumPixels: 480))
        }
    }

    func testTingReaderCoverDoesNotRefetchAfterMemoryPurgeOrChapterChange() async throws {
        let sourceID = UUID().uuidString
        let songIDs = [UUID().uuidString, UUID().uuidString]
        let reference = TingReaderAPIProtocol.coverReference(bookID: "book", libraryID: "library", coverPath: "/cover.jpg")
        let source = MusicSource(id: sourceID, name: "Ting Reader fixture", type: .tingReader, host: "artwork.invalid")
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        defer {
            for songID in songIDs { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: songID) }
            for size in [480, 1536] {
                if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: size) {
                    MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: key)
                }
            }
            CachedArtworkView.purgeDecodedImageCache()
        }
        await connector.setArtwork(try image(width: 1024))
        for songID in [songIDs[0], songIDs[0], songIDs[1]] {
            CachedArtworkView.purgeDecodedImageCache()
            let cover = await CachedArtworkView.resolveImage(coverRef: reference, songID: songID, size: 512,
                sourceID: sourceID, filePath: "/tingreader/books/book/chapters/\(songID).mp3", fileFormat: .mp3,
                sourceManager: manager)
            XCTAssertNotNil(cover)
        }
        let purposes = await connector.purposes
        XCTAssertEqual(purposes.count, 1, "A cold decoded cache and another chapter must reuse the book's disk cover")
    }

    func testLiveTingReaderCoversRemainAvailableWithoutNetworkAfterMemoryPurge() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["PRIMUSE_QA_TING_URL"], let url = URL(string: address),
              let host = url.host,
              let username = environment["PRIMUSE_QA_TING_USER"],
              let password = environment["PRIMUSE_QA_TING_PASSWORD"] else {
            throw XCTSkip("Requires the isolated Ting Reader test server")
        }
        let sourceID = environment["PRIMUSE_QA_TING_SOURCE_ID"] ?? UUID().uuidString
        let reusesDiskCache = environment["PRIMUSE_QA_TING_REUSE_CACHE"] == "1"
        let retainsDiskCache = environment["PRIMUSE_QA_TING_RETAIN_CACHE"] == "1"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let requests = TingReaderArtworkRequestProbe()
        let connector = TingReaderSource(sourceID: sourceID, host: host, port: url.port,
            useSSL: url.scheme == "https", basePath: url.path, username: username, password: password,
            transport: TingReaderRequestTransport(data: { request in
                try await requests.record(request)
                return try await session.data(for: request)
            }, download: { request in
                try await requests.record(request)
                return try await session.download(for: request)
            }))
        let source = MusicSource(id: sourceID, name: "Ting Reader live fixture", type: .tingReader, host: host)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        var songs: [Song] = []
        for try await scanned in try await connector.scanSongs(from: "/") {
            if scanned.song.coverArtFileName != nil { songs.append(scanned.song) }
        }
        let references = Set(songs.compactMap(\.coverArtFileName))
        XCTAssertGreaterThanOrEqual(references.count, 2)
        XCTAssertGreaterThan(songs.count, references.count, "The fixture must include chapters sharing a book cover")
        defer {
            if !retainsDiskCache {
                for song in songs { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: song.id) }
                for reference in references {
                    for size in [480, 1536] {
                        if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: size) {
                            MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: key)
                        }
                    }
                }
            }
            CachedArtworkView.purgeDecodedImageCache()
        }
        if reusesDiskCache { await requests.blockNetwork() }
        for offline in [false, true] {
            if offline { await requests.blockNetwork() }
            for song in songs {
                CachedArtworkView.purgeDecodedImageCache()
                let cover = await CachedArtworkView.resolveImage(coverRef: song.coverArtFileName,
                    songID: song.id, size: 512, sourceID: sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat, sourceManager: manager)
                XCTAssertNotNil(cover, "A cached book cover must remain readable with network blocked: \(offline)")
            }
        }
        let counts = await requests.counts
        XCTAssertEqual(counts.covers, reusesDiskCache ? 0 : references.count, "Each book should download its cover only once across launches")
        XCTAssertEqual(counts.blocked, 0, "Reading disk covers must not attempt a network request")
        print("Ting Reader live cache: books=\(references.count), chapters=\(songs.count), coverDownloads=\(counts.covers), offlineRequests=\(counts.blocked)")
    }

    func testScanRevalidatesUnchangedCoverReferenceAndKeepsOfflineCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let reference = "https://nas.invalid/Items/album/Images/Primary?tag=unchanged"
        let old = try image(color: .red, width: 1536)
        let new = try image(color: .blue, width: 480)
        await assets.cacheSourceCover(old, songID: "song", sourceID: "server", reference: reference, maximumPixels: 1536)
        let oldEpoch = assets.artworkFreshnessToken(sourceID: "server")
        assets.revalidateArtwork(sourceID: "server")
        XCTAssertNotEqual(oldEpoch, assets.artworkFreshnessToken(sourceID: "server"))
        XCTAssertNil(assets.cachedSourceCover(sourceID: "server", reference: reference, maximumPixels: 1536))
        XCTAssertEqual(assets.cachedSourceCover(sourceID: "server", reference: reference, maximumPixels: 480, allowsStale: true), old)
        await assets.cacheSourceCover(new, songID: "song", sourceID: "server", reference: reference, maximumPixels: 480)
        XCTAssertEqual(assets.cachedSourceCover(sourceID: "server", reference: reference, maximumPixels: 480), new)
        XCTAssertEqual(assets.displayCoverData(songID: "song", reference: reference), new)
        XCTAssertNil(assets.cachedSourceCover(sourceID: "server", reference: reference, maximumPixels: 1536))
        let restored = MetadataAssetStore(storageDirectory: root)
        XCTAssertNil(restored.cachedSourceCover(sourceID: "server", reference: reference, maximumPixels: 1536))
    }

    func testSelectedArtworkSurvivesCacheClearAndRejectsLateSourceResult() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let chosen = try image(color: .red)
        let server = try image(color: .blue)
        let ticket = await assets.beginArtworkLoad(songID: "song", sourceID: "server", reference: "subsonic-cover/old")
        let stored = await assets.storeAttributedCover(chosen, songID: "song", origin: .selected)
        let reference = try XCTUnwrap(stored)
        let accepted = await assets.cacheSourceCover(server, songID: "song", sourceID: "server", reference: "subsonic-cover/old", maximumPixels: 1536, ticket: ticket)
        XCTAssertFalse(accepted)
        await assets.cacheCover(server, forSongID: "song")
        XCTAssertEqual(assets.displayCoverData(songID: "song", reference: reference), chosen)
        await assets.clearAll()
        XCTAssertEqual(assets.displayCoverData(songID: "song", reference: reference), chosen)
        XCTAssertTrue(assets.hasReadableCoverFile(named: reference))
    }

    func testSourceRevalidationRejectsInFlightOldBytesAndSurvivesRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let ticket = await assets.beginArtworkLoad(songID: "song", sourceID: "server", reference: "/cover.jpg")
        assets.revalidateArtwork(sourceID: "server")
        let accepted = await assets.cacheSourceCover(try image(), songID: "song", sourceID: "server", reference: "/cover.jpg", maximumPixels: 480, ticket: ticket)
        XCTAssertFalse(accepted)
        XCTAssertFalse(assets.hasFreshSourceCover(sourceID: "server", reference: "/cover.jpg", maximumPixels: 480))
        let restored = MetadataAssetStore(storageDirectory: root)
        XCTAssertEqual(restored.artworkFreshnessToken(sourceID: "server"), assets.artworkFreshnessToken(sourceID: "server"))
    }

    func testSourceCacheExpiresAndDoesNotPromoteLegacyMirror() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let reference = "/cover.jpg"
        await assets.cacheCover(try image(color: .red), forSongID: "song")
        XCTAssertNil(assets.displayCoverData(songID: "song", reference: reference))
        await assets.cacheSourceCover(try image(color: .blue), songID: "song", sourceID: "server", reference: reference, maximumPixels: 480)
        let key = try XCTUnwrap(SourceArtworkPolicy.cacheID(sourceID: "server", reference: reference, maximumPixels: 480))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-SourceArtworkPolicy.maximumAge - 1)],
            ofItemAtPath: assets.artworkDirectoryURL.appendingPathComponent(assets.expectedCoverFileName(for: key)).path)
        XCTAssertFalse(assets.hasFreshSourceCover(sourceID: "server", reference: reference, maximumPixels: 480))
        XCTAssertNotNil(assets.cachedSourceCover(sourceID: "server", reference: reference, maximumPixels: 480, allowsStale: true))
        XCTAssertNil(assets.displayCoverData(songID: "song", reference: "/new-cover.jpg"))
    }

    func testMountedResolverRevalidatesSameURLAfterScan() async throws {
        let songID = UUID().uuidString
        let sourceID = UUID().uuidString
        let reference = "subsonic-cover/mf-" + songID
        let source = MusicSource(id: sourceID, name: "Artwork fixture", type: .navidrome, host: "artwork.invalid")
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        func resolve() async -> UIImage? {
            await CachedArtworkView.resolveImage(coverRef: reference, songID: songID, size: 512,
                sourceID: sourceID, filePath: "/songs/song.m4a", fileFormat: .m4a, sourceManager: manager)
        }
        await connector.setArtwork(try image(width: 1024))
        let old = await resolve()
        XCTAssertEqual(old?.cgImage?.width, 1024)
        await connector.setArtwork(try image(color: .blue, width: 1536))
        MetadataAssetStore.shared.revalidateArtwork(sourceID: sourceID)
        let updated = await resolve()
        XCTAssertEqual(updated?.cgImage?.width, 1536)
        let purposes = await connector.purposes
        XCTAssertEqual(purposes.count, 2)
        for size in [480, 1536] {
            if let key = SourceArtworkPolicy.cacheID(sourceID: sourceID, reference: reference, maximumPixels: size) {
                await MetadataAssetStore.shared.invalidateCoverCache(forSongID: key)
            }
        }
        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
    }

    func testUnchangedServerFileRefreshesCoverAndKeepsExplicitSelection() async throws {
        let sourceID = UUID().uuidString
        let connector = ServerCoverFixtureConnector(sourceID: sourceID)
        let incoming = Song(id: "song", title: "成都", fileFormat: .mp3, filePath: "/song.mp3",
                            sourceID: sourceID, coverArtFileName: "subsonic-cover/new")
        await connector.setCatalog([incoming])
        for reference in ["subsonic-cover/old", "scraped-" + String(repeating: "a", count: 64) + ".jpg",
                          "selected-" + String(repeating: "b", count: 64) + ".jpg"] {
            for edited in [false, true] {
                var existing = incoming
                existing.coverArtFileName = reference
                if edited { existing.title = "手动标题"; existing.userMetadataEditedAt = Date() }
                let scanner = ConnectorScanner(connector: connector, sourceID: sourceID)
                var result: [Song] = []
                for try await update in await scanner.scan(directories: ["/"], existingSongs: [existing]) {
                    if update.carriesFullSnapshot { result = update.songs }
                }
                let refreshed = try XCTUnwrap(result.first)
                XCTAssertEqual(refreshed.coverArtFileName, reference.hasPrefix("selected-") ? reference : incoming.coverArtFileName)
                XCTAssertEqual(refreshed.title, edited ? existing.title : incoming.title)
            }
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPortableArtworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(jpeg: Bool = false, color: UIColor = .red, width: Int = 32) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: 16), format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        }
        return try XCTUnwrap(jpeg ? rendered.jpegData(compressionQuality: 0.8) : rendered.pngData())
    }

    private func snapshot(_ songs: [Song]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.data(withJSONObject: [
            "songs": JSONSerialization.jsonObject(with: encoder.encode(songs)),
            "playlists": []
        ])
    }

    func testWidgetCoverKeyFollowsReplacedSongCover() async throws {
        let songID = "widget-cover-\(UUID().uuidString)"
        let song = Song(id: songID, title: "Widget cover", fileFormat: .mp3,
                        filePath: "/widget.mp3", sourceID: "local")
        defer { MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: songID) }
        XCTAssertNil(WidgetBookCoverRenderer.coverContent(for: song))

        await MetadataAssetStore.shared.cacheCover(try image(color: .red), forSongID: songID)
        let first = try XCTUnwrap(WidgetBookCoverRenderer.coverContent(for: song))
        // 同一首歌换了封面:小组件的去重键要跟着变,「收听台」和正在播放才会重画。
        await MetadataAssetStore.shared.cacheCover(try image(color: .blue), forSongID: songID)
        let second = try XCTUnwrap(WidgetBookCoverRenderer.coverContent(for: song))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(
            WidgetBookCoverRenderer.coverKey(songID: songID, keepsWholeCover: false, coverContent: first),
            WidgetBookCoverRenderer.coverKey(songID: songID, keepsWholeCover: false, coverContent: second)
        )
        XCTAssertEqual(WidgetBookCoverRenderer.coverKey(songID: songID, keepsWholeCover: true),
                       songID + "\u{1F}book")
    }

    func testFirstPlayerFrameUsesThumbnailBeforeHighResolutionTaskStarts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let manager = SourceManager(sourcesProvider: { [] })
        let songID = UUID().uuidString
        let data = try image(color: .red, width: 768)
        await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
        let resolved = expectation(description: "Mini player thumbnail decoded")
        resolved.assertForOverFulfill = false
        let thumbnail = CachedArtworkView(
            coverRef: nil, songID: songID, size: 44, cornerRadius: 0,
            onResolutionChange: { if $0 { resolved.fulfill() } }
        ).environment(library).environment(manager)
        let host = UIHostingController(rootView: thumbnail)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [resolved], timeout: 5)

        // ImageRenderer renders synchronously without mounting a .task.
        // Both the entering player and an already-settled new surface must
        // show the cached cover on that very first frame.
        for settled in [false, true] {
            let hero = CachedArtworkView(
                coverRef: nil, songID: songID, size: 360, cornerRadius: 0,
                loadsHighResolution: settled
            ).artworkCrossfade().environment(library).environment(manager)
            let renderer = ImageRenderer(content: hero)
            renderer.scale = 1
            let rendered = try XCTUnwrap(renderer.uiImage?.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[0], 230, "First frame must show the red artwork")
            XCTAssertLessThan(pixel[1], 25)
            XCTAssertLessThan(pixel[2], 25)
            XCTAssertGreaterThan(pixel[3], 240)
        }
        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
    }

    func testCancelledUploadedArtworkReadDoesNotClearReplacementImage() async throws {
        let oldImage = try image(jpeg: true, color: .red)
        let newImage = try image(jpeg: true, color: .blue)

        for oldResult in [oldImage, nil] as [Data?] {
            let gate = UploadedArtworkReadGate()
            var displayedImage: UIImage?
            var updateCount = 0
            let oldTask = Task {
                await UploadedArtworkLoader.load(contentID: "old", readData: { _ in
                    await gate.suspend()
                    return oldResult
                }) {
                    displayedImage = $0
                    updateCount += 1
                }
            }
            await gate.waitUntilSuspended()
            oldTask.cancel()

            await UploadedArtworkLoader.load(contentID: "new", readData: { _ in newImage }) {
                displayedImage = $0
                updateCount += 1
            }
            let replacement = displayedImage
            XCTAssertNotNil(replacement)

            await gate.release()
            await oldTask.value
            XCTAssertTrue(displayedImage === replacement)
            XCTAssertEqual(updateCount, 1)
        }
    }

    func testCancelledUploadedArtworkReadDoesNotRestoreRemovedOverride() async throws {
        let data = try image(jpeg: true)
        let gate = UploadedArtworkReadGate()
        var displayedImage = UIImage(data: data)
        var updateCount = 0
        let oldTask = Task {
            await UploadedArtworkLoader.load(contentID: "old", readData: { _ in
                await gate.suspend()
                return data
            }) {
                displayedImage = $0
                updateCount += 1
            }
        }
        await gate.waitUntilSuspended()
        oldTask.cancel()

        await UploadedArtworkLoader.load(contentID: nil) {
            displayedImage = $0
            updateCount += 1
        }
        XCTAssertNil(displayedImage)

        await gate.release()
        await oldTask.value
        XCTAssertNil(displayedImage)
        XCTAssertEqual(updateCount, 1)
    }

    func testCurrentUploadedArtworkReadFailureClearsPreviousImage() async throws {
        let data = try image(jpeg: true)
        for result in [nil, Data("invalid image".utf8)] as [Data?] {
            var displayedImage = UIImage(data: data)
            XCTAssertNotNil(displayedImage)

            await UploadedArtworkLoader.load(contentID: "missing", readData: { _ in result }) {
                displayedImage = $0
            }
            XCTAssertNil(displayedImage)
        }
    }

    func testBoundedJPEGIsTransferredWithoutRecompression() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let original = try image(jpeg: true)
        store.storeCoverSync(original, for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let identity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let cover = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        XCTAssertEqual(cover.data, original)
        XCTAssertFalse(cover.requiredProcessing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.portableArtworkDirectoryURL.path))
    }

    func testScrapedCoverIsEmbeddedAsABoundedJPEG() throws {
        // 已经是合适 JPEG 的封面原样嵌入，不再重压一遍。
        let small = try image(jpeg: true)
        XCTAssertEqual(SidecarWriteService.embeddableCoverData(small), small)

        let large = try splitJPEG(width: 2400, height: 1600)
        let embedded = try XCTUnwrap(SidecarWriteService.embeddableCoverData(large))
        XCTAssertTrue(LibraryArtworkImageProcessor.isReusablePortableJPEG(embedded))
        let scaled = try decoded(embedded)
        XCTAssertEqual(scaled.width, 1200)
        XCTAssertEqual(scaled.height, 800)

        // PNG 也转成 JPEG：各家标签读取器都认 JPEG。
        let png = try image(width: 64)
        let fromPNG = try XCTUnwrap(SidecarWriteService.embeddableCoverData(png))
        XCTAssertEqual(Array(fromPNG.prefix(3)), [0xFF, 0xD8, 0xFF])

        XCTAssertNil(SidecarWriteService.embeddableCoverData(Data("not an image".utf8)))
    }

    func testTranscodedCoverIsReusedAcrossStoresAndInvalidatesOnReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        store.storeCoverSync(try image(), for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let firstIdentity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let first = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: firstIdentity))
        XCTAssertTrue(first.requiredProcessing)
        XCTAssertTrue(LibraryArtworkImageProcessor.isReusablePortableJPEG(first.data))

        let reopened = MetadataAssetStore(storageDirectory: root)
        let reused = try XCTUnwrap(reopened.preparePortableCover(named: name, contentIdentifier: firstIdentity))
        XCTAssertFalse(reused.requiredProcessing)
        XCTAssertEqual(reused.data, first.data)

        reopened.storeCoverSync(try image(color: .blue), for: "song")
        let replacementIdentity = try XCTUnwrap(reopened.coverContentIdentifier(named: name))
        XCTAssertNotEqual(replacementIdentity, firstIdentity)
        let replacement = try XCTUnwrap(reopened.preparePortableCover(named: name, contentIdentifier: replacementIdentity))
        XCTAssertTrue(replacement.requiredProcessing)
        XCTAssertNotEqual(replacement.data, first.data)
    }

    func testOversizedJPEGStillProducesBoundedTransportImage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let original = try image(jpeg: true, width: 1600)
        XCTAssertFalse(LibraryArtworkImageProcessor.isReusablePortableJPEG(original))
        store.storeCoverSync(original, for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let identity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let cover = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        XCTAssertTrue(cover.requiredProcessing)
        XCTAssertTrue(LibraryArtworkImageProcessor.isReusablePortableJPEG(cover.data))
        XCTAssertLessThanOrEqual(cover.data.count, LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes)
        XCTAssertEqual(store.readCoverData(named: name), original)
    }

    func testCorruptDerivedCacheIsRebuiltAndClearedWithArtworkCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        store.storeCoverSync(try image(), for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let identity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let first = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        let files = try FileManager.default.contentsOfDirectory(at: store.portableArtworkDirectoryURL, includingPropertiesForKeys: nil)
        let cache = try XCTUnwrap(files.first)
        try Data("invalid".utf8).write(to: cache)
        let recovered = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        XCTAssertTrue(recovered.requiredProcessing)
        XCTAssertEqual(recovered.data, first.data)
        await store.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testSnapshotDeduplicatesSharedCoversAndPreservesMetadataAtBudgetLimit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let songs = (0..<3).map {
            Song(id: "song-\($0)", title: "Song \($0)", fileFormat: .mp3,
                 filePath: "/song-\($0).mp3", sourceID: "source")
        }
        let original = try image(jpeg: true)
        for song in songs { store.storeCoverSync(original, for: song.id) }
        let data = try snapshot(songs)
        let prepared = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            data, assetStore: store, maximumArtworkBytes: original.count
        )
        let transfer = try XCTUnwrap(prepared)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["songs"] as? [[String: Any]])?.count, songs.count)
        XCTAssertEqual((object["cachedArtworkAssets"] as? [String: String])?.count, 1)
        XCTAssertEqual((object["artworkCacheReferences"] as? [String: String])?.count, songs.count)

        let overBudget = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            data, assetStore: store, maximumArtworkBytes: original.count - 1
        )
        let smallTransfer = try XCTUnwrap(overBudget)
        let smallObject = try XCTUnwrap(JSONSerialization.jsonObject(with: smallTransfer.data) as? [String: Any])
        XCTAssertEqual((smallObject["songs"] as? [[String: Any]])?.count, songs.count)
        XCTAssertNil(smallObject["cachedArtworkAssets"])
        XCTAssertNil(smallObject["artworkCacheReferences"])
    }

    /// 手动「清除封面与歌词」和容量驱逐留下的是同一种残局: ref 和 content 都
    /// 没了, 而 `Song.coverArtFileName` 还留在歌曲记录上。那个字段就是回填队列
    /// 判断「这首歌要不要重读封面」的唯一依据, 不摘掉就再也补不回来。清空必须
    /// 把删掉的 ref 一次性播出去, 让资料库摘掉它们。
    func testClearingAllAssetsAnnouncesTheClearedSongCoverReferences() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let cover = try image(jpeg: true)
        let songIDs = ["song-a", "song-b"]
        for songID in songIDs {
            store.storeCoverSync(cover, for: songID)
        }
        // 专辑封面是派生副本, 键也不同, 不该混进这份通知里。
        _ = await store.storeAlbumCover(cover, forAlbumID: "album-1")

        var observedRefs: Set<String>?
        let received = XCTestExpectation(description: "artwork content evicted")
        let token = NotificationCenter.default.addObserver(
            forName: .primuseArtworkContentEvicted,
            object: nil,
            queue: .main
        ) { note in
            observedRefs = note.userInfo?["refs"] as? Set<String>
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await store.clearAll()
        await fulfillment(of: [received], timeout: 5)

        XCTAssertEqual(
            observedRefs,
            Set(songIDs.map { store.expectedCoverFileName(for: $0) })
        )
        for songID in songIDs {
            let cached = await store.cachedCoverData(forSongID: songID)
            XCTAssertNil(cached)
        }
    }

    func testExhaustedArtworkBudgetStopsConvertingRemainingCovers() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let songs = (0..<3).map {
            Song(id: "song-\($0)", title: "Song \($0)", fileFormat: .mp3,
                 filePath: "/song-\($0).mp3", sourceID: "source")
        }
        for (song, color) in zip(songs, [UIColor.red, .blue, .green]) {
            store.storeCoverSync(try image(color: color), for: song.id)
        }
        let data = try snapshot(songs)
        let prepared = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            data, assetStore: store, maximumArtworkBytes: 1
        )
        let transfer = try XCTUnwrap(prepared)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["songs"] as? [[String: Any]])?.count, songs.count)
        XCTAssertNil(object["cachedArtworkAssets"])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.portableArtworkDirectoryURL.path)
        XCTAssertEqual(files.count, 1)
    }

    func testCancelledSnapshotPreparationDoesNotReturnPartialPayload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let song = Song(id: "cancelled", title: "Song", fileFormat: .mp3,
                        filePath: "/song.mp3", sourceID: "source")
        store.storeCoverSync(try image(), for: song.id)
        let data = try snapshot([song])
        let task = Task {
            await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(data, assetStore: store)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
}

private actor TingReaderArtworkRequestProbe {
    private var isOffline = false
    private(set) var counts = (covers: 0, blocked: 0)

    func blockNetwork() { isOffline = true }

    func record(_ request: URLRequest) throws {
        if isOffline {
            counts.blocked += 1
            throw URLError(.notConnectedToInternet)
        }
        if request.url?.path.hasSuffix("/api/proxy/cover") == true { counts.covers += 1 }
    }
}

private actor ServerCoverFixtureConnector: RefreshingMetadataSongConnector, ServerLyricsConnector {
    let sourceID: String
    var purposes: [ArtworkFetchPurpose] = []
    var byteLimits: [Int] = []
    private let artworkGate: UploadedArtworkReadGate?
    private var lyrics: ServerLyricsReadResult = .absent
    private var artwork: Data?
    private var catalog: [Song] = []
    init(sourceID: String, artworkGate: UploadedArtworkReadGate? = nil) {
        self.sourceID = sourceID
        self.artworkGate = artworkGate
    }
    func setLyrics(_ result: ServerLyricsReadResult) { lyrics = result }
    func readServerLyrics(for path: String) async -> ServerLyricsReadResult { lyrics }
    func fetchServerLyrics(for path: String) async -> String? {
        if case .content(let content) = lyrics { return content }
        return nil
    }
    func setArtwork(_ data: Data?) { artwork = data }
    func setCatalog(_ songs: [Song]) { catalog = songs }
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        .init { continuation in
            for song in catalog {
                continuation.yield(.init(song: song, displayName: song.title, titleMetadataInspected: true))
            }
            continuation.finish()
        }
    }
    func fetchArtworkData(for reference: String, maximumBytes: Int, purpose: ArtworkFetchPurpose) async throws -> Data? {
        purposes.append(purpose)
        byteLimits.append(maximumBytes)
        if let artworkGate { await artworkGate.suspend() }
        if let artwork, artwork.count > maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        return artwork
    }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { URL(fileURLWithPath: path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor UploadedArtworkReadGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspendedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !isReleased else { return }
        isSuspended = true
        suspendedWaiter?.resume()
        suspendedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspendedWaiter = $0 }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}


extension LibraryPortableArtworkTests {
    func testArtistRectangularArtworkMatchesTheHeroFieldCrop() async throws {
        try await verifyArtistArtworkCrop(source: .uploaded)
    }

    func testCachedArtistArtworkFillsTheRectangularHero() async throws {
        try await verifyArtistArtworkCrop(source: .artistCache)
    }

    func testFallbackSongArtworkFillsTheRectangularHero() async throws {
        try await verifyArtistArtworkCrop(source: .songCache)
    }

    private enum HeroTestArtworkSource {
        case uploaded, artistCache, songCache
    }

    private func verifyArtistArtworkCrop(source: HeroTestArtworkSource) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, artist) = try await heroTestArtist(in: root)
        let owner = LibraryArtworkOwner(kind: .artist, id: artist.id)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = try XCTUnwrap(UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 2_400), format: format
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 2_400))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 300, y: 0, width: 600, height: 2_400))
            UIColor.green.setFill()
            context.fill(CGRect(x: 900, y: 0, width: 300, height: 2_400))
        }.pngData())
        let cleanup: URL?
        switch source {
        case .uploaded:
            cleanup = try installHeroTestArtwork(data, library: library, owner: owner)
        case .artistCache:
            let cacheID = ArtistArtworkResolutionPolicy.cacheID(baseID: artist.id, maximumPixels: 1536)
            let fileName = await MetadataAssetStore.shared.storeArtistImage(data, forArtistID: cacheID)
            cleanup = MetadataAssetStore.shared.artworkDirectoryURL.appendingPathComponent("artist")
                .appendingPathComponent(try XCTUnwrap(fileName))
        case .songCache:
            let song = try XCTUnwrap(library.preferredArtworkSong(forArtistID: artist.id))
            await MetadataAssetStore.shared.cacheCover(data, forSongID: song.id)
            cleanup = MetadataAssetStore.shared.artworkDirectoryURL
                .appendingPathComponent(MetadataAssetStore.shared.expectedCoverFileName(for: song.id))
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        for (size, fillsProposedSize) in [
            (CGSize(width: 240, height: 360), true),
            (CGSize(width: 360, height: 240), true),
            (CGSize(width: 240, height: 240), false),
        ] {
            var displayed: UIImage?
            let view = ArtistArtworkView(
                artist: artist, size: max(size.width, size.height), cornerRadius: 0, showsPlaceholder: false,
                fillsProposedSize: fillsProposedSize, onImageChange: { displayed = $0 }
            )
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
            .environment(library)
            .environment(SourceManager(sourcesProvider: { [] }))
            .environment(\.scenePhase, .inactive)
            let (window, host, original) = try hostHeroTestView(view, size: size)
            defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
            var rendered: CGImage?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                let snapshot = try heroTestSnapshot(host.view)
                let left = try rgb(snapshot, x: Int(size.width * 0.1875), y: 20)
                let right = try rgb(snapshot, x: Int(size.width * 0.8125), y: Int(size.height) - 20)
                if left.0 > 220, left.2 < 35, right.1 > 220, right.2 < 35 {
                    rendered = snapshot
                    break
                }
            }
            let actual = try XCTUnwrap(rendered, "Artwork must fill the top and bottom of the \(size) frame")
            let source = try XCTUnwrap(displayed?.cgImage)
            let geometry = try XCTUnwrap(ArtistHeroArtworkGeometry(width: size.width, photoHeight: size.height))
            let field = try XCTUnwrap(ArtistHeroArtworkField.render(image: source, geometry: geometry))
            // Compare the actual hosted view with the independently prepared field.
            for fraction in [0.1875, 0.5, 0.8125] {
                let x = Int(size.width * fraction)
                let visible = try rgb(actual, x: x, y: 20)
                let derived = try rgb(field, x: x, y: 20)
                XCTAssertLessThan(abs(visible.0 - derived.0) + abs(visible.1 - derived.1) + abs(visible.2 - derived.2), 30)
            }
        }
    }

    func testArtistHeroKeepsWhiteArtworkSharpAndContinuesBelowItsLayoutFrame() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, artist) = try await heroTestArtist(in: root)
        let owner = LibraryArtworkOwner(kind: .artist, id: artist.id)
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        func upload(_ color: UIColor) throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let data = try XCTUnwrap(UIGraphicsImageRenderer(
                size: CGSize(width: 600, height: 800), format: format
            ).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            }.pngData())
            if let url = try installHeroTestArtwork(data, library: library, owner: owner) { cleanup.append(url) }
        }
        try upload(.white)
        let appearance = HeroAppearanceProbe()
        let view = ZStack(alignment: .top) {
            Color(uiColor: UIColor(white: 0.08, alpha: 1))
            ArtistHeroArtworkView(
                artist: artist, size: CGSize(width: 320, height: 400), onImageChange: { _ in },
                onAppearanceChange: { color, _ in
                    guard let color else { return }
                    appearance.color = UIColor(color)
                    appearance.count += 1
                }
            )
                // The actual square photograph retains 320pt of layout space; the
                // field must still paint below it, as in the detail header.
                .frame(width: 320, height: 320, alignment: .top)
        }
        .frame(width: 320, height: 760)
        .ignoresSafeArea()
        .environment(library)
        .environment(SourceManager(sourcesProvider: { [] }))
        .environment(\.scenePhase, .inactive)
        let (window, host, original) = try hostHeroTestView(view, size: CGSize(width: 320, height: 760))
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        var whiteSnapshot: CGImage?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = try heroTestSnapshot(host.view)
            let sharp = try rgb(snapshot, x: 160, y: 80)
            let field = try rgb(snapshot, x: 160, y: 224)
            let continued = try rgb(snapshot, x: 160, y: 328)
            let body = try rgb(snapshot, x: 160, y: 700)
            if min(sharp.0, sharp.1, sharp.2) > 240 {
                XCTAssertGreaterThan(appearance.count, 0, "A visible sharp source must already have a prepared appearance")
                XCTAssertGreaterThan(field.0, body.0 + 100, "The first visible photograph must include its matching field")
                XCTAssertGreaterThan(continued.0, body.0 + 1, "A subtle field tail must continue below the photograph")
                whiteSnapshot = snapshot
                break
            }
        }
        let white = try XCTUnwrap(whiteSnapshot, "The sharp portrait and its continued field must both appear")
        let body = try rgb(white, x: 160, y: 700)
        let finished = try rgb(white, x: 160, y: 430)
        XCTAssertLessThan(abs(finished.0 - body.0) + abs(finished.1 - body.1) + abs(finished.2 - body.2), 6,
                          "The field must fade out before the page-body color, rather than tint the whole page")

        try upload(.blue)
        var blueSnapshot: CGImage?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = try heroTestSnapshot(host.view)
            let sharp = try rgb(snapshot, x: 160, y: 80)
            let field = try rgb(snapshot, x: 160, y: 224)
            if sharp.2 > 220, sharp.0 < 35 {
                XCTAssertGreaterThanOrEqual(appearance.count, 2)
                XCTAssertGreaterThan(field.2, field.0 + 60, "The newly visible source must not retain the previous white field")
                let color = try XCTUnwrap(appearance.color)
                var red: CGFloat = 0, blue: CGFloat = 0
                color.getRed(&red, green: nil, blue: &blue, alpha: nil)
                XCTAssertGreaterThan(blue, red + 0.7, "Page color and artwork must change in the same prepared appearance")
                blueSnapshot = snapshot
                break
            }
        }
        let blue = try XCTUnwrap(blueSnapshot, "The field must follow the newly selected image, not retain the white one")
        let unchangedBody = try rgb(blue, x: 160, y: 700)
        XCTAssertLessThan(abs(unchangedBody.0 - body.0) + abs(unchangedBody.1 - body.1) + abs(unchangedBody.2 - body.2), 6)
    }

    func testLongArtistTitleKeepsContrastOnWhiteArtworkAtLargeTypeSizes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, artist) = try await heroTestArtist(in: root)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = try XCTUnwrap(UIGraphicsImageRenderer(
            size: CGSize(width: 600, height: 800), format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }.pngData())
        let file = try installHeroTestArtwork(data, library: library,
            owner: LibraryArtworkOwner(kind: .artist, id: artist.id))
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        let cases: [(String, String, DynamicTypeSize)] = [
            ("short-default", "Adele", .large),
            ("long-default", "A Very Long Artist Name With Multiple Collaborators", .large),
            ("long-accessibility2", "A Very Long Artist Name With Multiple Collaborators", .accessibility2),
        ]
        var titleHeights: [String: CGFloat] = [:]
        for (caseName, name, dynamicType) in cases {
            let probe = HeroTitleBoundsProbe()
            let view = ArtistHeroReadabilityFixture(artist: artist, name: name, probe: probe)
                .dynamicTypeSize(dynamicType)
                .environment(library)
                .environment(SourceManager(sourcesProvider: { [] }))
                .environment(\.scenePhase, .inactive)
            let size = CGSize(width: 390, height: 760)
            let (window, host, original) = try hostHeroTestView(view, size: size)
            defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
            var rendered: CGImage?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                let snapshot = try heroTestSnapshot(host.view)
                let sharp = try rgb(snapshot, x: 195, y: 80)
                if probe.ready, probe.frame.height > 30, min(sharp.0, sharp.1, sharp.2) > 240 {
                    rendered = snapshot
                    break
                }
            }
            let snapshot = try XCTUnwrap(rendered, "The actual photograph, field and page color must finish preparing")
            let attachment = XCTAttachment(image: UIImage(cgImage: snapshot))
            attachment.name = "Actual artist hero white fixture - \(caseName)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let frame = probe.frame
            titleHeights[caseName] = frame.height
            XCTAssertGreaterThan(frame.height, 0)
            if caseName != "short-default" {
                XCTAssertGreaterThan(frame.height, try XCTUnwrap(titleHeights["short-default"]),
                                     "A long name must wrap beyond the single-line title")
            }
            if dynamicType.isAccessibilitySize {
                XCTAssertGreaterThan(frame.height, try XCTUnwrap(titleHeights["long-default"]),
                                     "Accessibility text must grow beyond the default title")
            }
            // Sample the real photograph+field+page composition outside glyphs.
            // No separate title plate may be used to make a white-only test pass.
            for y in [frame.minY + 2, frame.midY, frame.maxY - 2] {
                let background = try rgb(snapshot, x: 3, y: Int(y))
                XCTAssertGreaterThanOrEqual(whiteContrast(on: background), 3,
                    "Actual title contrast for \(caseName) at y=\(y)")
            }
            let baselineProbe = HeroTitleBoundsProbe()
            let baseline = ArtistHeroReadabilityFixture(artist: artist, name: nil, probe: baselineProbe)
                .dynamicTypeSize(dynamicType)
                .environment(library)
                .environment(SourceManager(sourcesProvider: { [] }))
                .environment(\.scenePhase, .inactive)
            let baselineHost = UIHostingController(rootView: baseline)
            baselineHost.safeAreaRegions = []
            window.rootViewController = baselineHost
            baselineHost.view.frame = window.bounds
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                if baselineProbe.ready { break }
            }
            XCTAssertTrue(baselineProbe.ready)
            let noTitle = try heroTestSnapshot(baselineHost.view)
            for y in [frame.minY + 2, frame.midY, frame.maxY - 2] {
                let actual = try rgb(snapshot, x: 3, y: Int(y))
                let expected = try rgb(noTitle, x: 3, y: Int(y))
                XCTAssertLessThan(abs(actual.0 - expected.0) + abs(actual.1 - expected.1) + abs(actual.2 - expected.2), 9,
                                  "The title must not add a full-width local dark band")
            }
            let untouched = try rgb(snapshot, x: 195, y: 80)
            XCTAssertGreaterThan(min(untouched.0, untouched.1, untouched.2), 240,
                                 "The sharp top photograph must remain un-darkened")
        }
    }

    private final class HeroAppearanceProbe {
        var count = 0
        var color: UIColor?
    }

    private final class HeroTitleBoundsProbe {
        var frame = CGRect.zero
        var ready = false
    }

    /// Same portrait composition as ArtistDetailView: prepared artwork over its
    /// actual sampled page color, with the real title anchored to the photo bottom.
    private struct ArtistHeroReadabilityFixture: View {
        let artist: Artist
        let name: String?
        let probe: HeroTitleBoundsProbe
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @State private var tint: Color?
        @State private var palette: [LiquidBackdropColor] = []
        private let coordinates = UUID()

        var body: some View {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(ZStackLayout(alignment: .bottom))
            return ZStack(alignment: .top) {
                LibraryDetailTintStyle.artworkBackground(tint, palette: palette,
                    ambientStyle: .classic, colorScheme: .dark).background
                layout {
                    Color.clear.frame(width: 390, height: 410).background(alignment: .top) {
                        ArtistHeroArtworkView(artist: artist, size: CGSize(width: 390, height: 410),
                            onImageChange: { _ in }, onAppearanceChange: { color, colors in
                                guard let color else { return }
                                tint = color
                                palette = colors
                                probe.ready = true
                            })
                    }
                    if let name {
                        ArtistHeroTitleBlock(name: name)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) }
                            action: { probe.frame = $0 }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }
                }
                .frame(width: 390)
            }
            .frame(width: 390, height: 760)
            .coordinateSpace(name: coordinates)
            .ignoresSafeArea()
        }
    }

    private func whiteContrast(on pixel: (Int, Int, Int), foregroundRGB: (Int, Int, Int) = (255, 255, 255)) -> Double {
        func luminance(_ pixel: (Int, Int, Int)) -> Double {
            func linear(_ channel: Int) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(pixel.0) + 0.7152 * linear(pixel.1) + 0.0722 * linear(pixel.2)
        }
        return (luminance(foregroundRGB) + 0.05) / (luminance(pixel) + 0.05)
    }

    func testArtistHeroClearsRemovedUploadedArtworkAndPreparedAppearance() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, artist) = try await heroTestArtist(in: root)
        let owner = LibraryArtworkOwner(kind: .artist, id: artist.id)
        let file = try installHeroTestArtwork(try image(color: .red, width: 127),
                                             library: library, owner: owner)
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        var plainImage: UIImage?
        var heroImage: UIImage?
        var appearanceColor: Color?
        var appearancePalette: [LiquidBackdropColor] = []
        let view = VStack(spacing: 0) {
            ArtistHeroArtworkView(
                artist: artist, size: CGSize(width: 320, height: 400),
                onImageChange: { heroImage = $0 },
                onAppearanceChange: { color, palette in
                    appearanceColor = color
                    appearancePalette = palette
                }
            )
            .frame(width: 320, height: 400, alignment: .top)
            ArtistArtworkView(artist: artist, size: 64,
                              onImageChange: { plainImage = $0 })
                .frame(width: 64, height: 64)
        }
        .frame(width: 320, height: 500, alignment: .top)
        .background(.black)
        .ignoresSafeArea()
        .environment(library)
        .environment(SourceManager(sourcesProvider: { [] }))
        .environment(\.scenePhase, .inactive)
        let (window, host, original) = try hostHeroTestView(view, size: CGSize(width: 320, height: 500))
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        for _ in 0..<40 {
            if plainImage != nil, heroImage != nil, appearanceColor != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try XCTUnwrap(plainImage, "The normal artwork view must load the uploaded portrait")
        _ = try XCTUnwrap(heroImage, "The hero must load the uploaded portrait")
        XCTAssertNotNil(appearanceColor)
        XCTAssertFalse(appearancePalette.isEmpty)
        XCTAssertTrue(library.setAutomaticArtwork(for: owner))
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if plainImage == nil, heroImage == nil, appearanceColor == nil { break }
        }
        XCTAssertNil(plainImage, "Restoring automatic artwork has no replacement image in this fixture")
        XCTAssertNil(heroImage, "The hero must clear an uploaded image after it has been removed")
        XCTAssertNil(appearanceColor)
        XCTAssertTrue(appearancePalette.isEmpty)
        let pixel = try rgb(heroTestSnapshot(host.view), x: 160, y: 80)
        XCTAssertLessThan(pixel.0, pixel.1 + 60,
                          "The removed red portrait is still visible: \(pixel)")
    }

    private func heroTestArtist(in root: URL) async throws -> (MusicLibrary, Artist) {
        let library = MusicLibrary(storageDirectory: root)
        let name = "Hero surface \(UUID().uuidString)"
        library.addSongs([Song(id: UUID().uuidString, title: "Hero fixture", artistName: name,
                               fileFormat: .mp3, filePath: "/hero-fixture.mp3", sourceID: name)])
        await library.waitForPendingIndex()
        return (library, try XCTUnwrap(library.visibleArtists.first { $0.name == name }))
    }

    /// Return only files created by this fixture, matching the existing override tests.
    private func installHeroTestArtwork(_ data: Data, library: MusicLibrary, owner: LibraryArtworkOwner) throws -> URL? {
        let directory = MetadataAssetStore.shared.customArtworkDirectoryURL
        let existing = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        let contentID = try XCTUnwrap(MetadataAssetStore.shared.storeCustomArtworkSync(data))
        XCTAssertTrue(library.setUploadedArtwork(contentID: contentID, for: owner))
        let url = directory.appendingPathComponent("\(contentID).jpg")
        return existing.contains(url) ? nil : url
    }

    private func hostHeroTestView<Content: View>(_ content: Content, size: CGSize) throws
        -> (UIWindow, UIHostingController<Content>, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        return (window, host, original)
    }

    private func heroTestSnapshot(_ view: UIView) throws -> CGImage {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.cgImage)
    }

    func testArtworkIdentityLookupSkipsUnrelatedCloudPathsAndRevalidatesMatches() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        var resolvedSources: [String] = []
        library.sourceIdentityResolver = { source in
            resolvedSources.append(source)
            return source == "wrong-account" ? "other" : "account"
        }
        let owner = LibraryArtworkOwner(kind: .artist, id: "owner")
        let original = Song(id: "old", title: "Original", duration: 240, fileFormat: .flac, filePath: "target.flac", sourceID: "original")
        XCTAssertTrue(library.setArtwork(for: owner, to: original))
        let unrelated = (0..<2_000).map { index in
            Song(id: "unrelated-\(index)", title: "Other \(index)", duration: 240, fileFormat: .flac, filePath: "other-\(index).flac", sourceID: "source-\(index % 20)")
        }
        let wrong = Song(id: "wrong", title: "Different", duration: 200, fileFormat: .flac, filePath: original.filePath, sourceID: "wrong-account")
        let remounted = Song(id: "new", title: "Renamed", duration: 260, fileFormat: .flac, filePath: original.filePath, sourceID: "new-mount")
        library.addSongs(unrelated + [wrong, remounted])
        resolvedSources = []
        await library.prepareArtworkIdentityResolutions()
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .selectedSong(remounted.id))
        XCTAssertEqual(Set(resolvedSources), ["wrong-account", "new-mount"])
        XCTAssertEqual(resolvedSources.count, 2)
        resolvedSources = []
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .selectedSong(remounted.id))
        XCTAssertTrue(resolvedSources.isEmpty)

        library.addSongs([wrong], affectedSourceIDs: [remounted.sourceID, wrong.sourceID])
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [wrong]), .automatic)
        library.addSongs([remounted], pruneMissingSongs: false)
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .selectedSong(remounted.id))
        library.sourceIdentityResolver = { _ in nil }
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .automatic)
    }

    /// 首页一屏有多张自选封面卡时，第一张触发的整库查找要顺带把其它卡也解析掉，
    /// 后面的卡直接命中缓存，不再各扫一遍。
    func testArtworkIdentityLookupResolvesAllPendingOwnersInOneScan() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        var resolverCalls = 0
        library.sourceIdentityResolver = { _ in
            resolverCalls += 1
            return "account"
        }
        let first = Song(id: "old-1", title: "One", duration: 200, fileFormat: .flac, filePath: "shared/one.flac", sourceID: "original")
        let second = Song(id: "old-2", title: "Two", duration: 200, fileFormat: .flac, filePath: "shared/two.flac", sourceID: "original")
        let ownerA = LibraryArtworkOwner(kind: .artist, id: "artist-a")
        let ownerB = LibraryArtworkOwner(kind: .artist, id: "artist-b")
        XCTAssertTrue(library.setArtwork(for: ownerA, to: first))
        XCTAssertTrue(library.setArtwork(for: ownerB, to: second))
        var remountedFirst = first
        remountedFirst.id = "new-1"
        remountedFirst.sourceID = "mount"
        var remountedSecond = second
        remountedSecond.id = "new-2"
        remountedSecond.sourceID = "mount"
        let unrelated = (0..<500).map { index in
            Song(id: "unrelated-\(index)", title: "Other \(index)", duration: 200, fileFormat: .flac, filePath: "other-\(index).flac", sourceID: "mount")
        }
        library.addSongs(unrelated + [remountedFirst, remountedSecond])

        resolverCalls = 0
        XCTAssertEqual(
            library.artworkOverrideResolution(for: ownerA, eligibleSongs: [remountedFirst]),
            .selectedSong(remountedFirst.id)
        )
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(
            library.artworkOverrideResolution(for: ownerB, eligibleSongs: [remountedSecond]),
            .selectedSong(remountedSecond.id)
        )
        XCTAssertEqual(resolverCalls, 1)
    }

    func testArtworkIdentityLookupKeepsTitleFallbackAndFirstMatchingSong() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let owner = LibraryArtworkOwner(kind: .album, id: "album")
        let original = Song(id: "old", title: "Title", artistName: "Singer", duration: 240, fileFormat: .flac, filePath: "old.flac", sourceID: "source")
        XCTAssertTrue(library.setArtwork(for: owner, to: original))
        var first = original
        first.id = "first"
        first.filePath = "new.flac"
        var second = first
        second.id = "second"
        library.addSongs([first, second])
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [first, second]), .selectedSong(first.id))
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [second]), .automatic)
    }

    // MARK: - 自选封面：元数据与像素对不上的网图 (#104)

    /// 左红右蓝、上下渐变的 JPEG，方便判断方向与是否退化成纯色。
    private func splitJPEG(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            for row in 0..<height {
                let shade = CGFloat(row) / CGFloat(max(1, height - 1))
                UIColor(red: 1, green: shade, blue: 0, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row, width: width / 2, height: 1))
                UIColor(red: 0, green: shade, blue: 1, alpha: 1).setFill()
                context.fill(CGRect(x: width / 2, y: row, width: width - width / 2, height: 1))
            }
        }
        let cgImage = try XCTUnwrap(rendered.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 仿照报告里那张图的 EXIF：IFD0 声称 3745×3745，IFD1 的内嵌缩略图指针
    /// 指到段外（截断），并且同样的段出现两次。
    private func injectingInconsistentExif(into jpeg: Data) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value & 0xFFFF) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
            u16(tag) + u16(type) + u32(count) + value + Array(repeating: 0, count: 4 - value.count)
        }
        var tiff: [UInt8] = Array("MM".utf8) + u16(42) + u32(8)
        let ifd0: [[UInt8]] = [
            entry(0x100, 3, 1, u16(3745)),
            entry(0x101, 3, 1, u16(3745)),
            entry(0x112, 3, 1, u16(1)),
        ]
        let ifd1Offset = 8 + 2 + ifd0.count * 12 + 4
        tiff += u16(ifd0.count) + ifd0.flatMap { $0 } + u32(ifd1Offset)
        let ifd1: [[UInt8]] = [
            entry(0x103, 3, 1, u16(6)),
            entry(0x201, 4, 1, u32(4000)),
            entry(0x202, 4, 1, u32(8701)),
        ]
        tiff += u16(ifd1.count) + ifd1.flatMap { $0 } + u32(0)
        tiff += [0xFF, 0xD8, 0xFF, 0xDB]
        let payload = Array("Exif\0\0".utf8) + tiff
        let segment: [UInt8] = [0xFF, 0xE1] + u16(payload.count + 2) + payload
        var bytes = [UInt8](jpeg)
        bytes.insert(contentsOf: segment + segment, at: 2)
        return Data(bytes)
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        // 位图内存按自上而下存放，第 0 行就是图的顶边。
        let offset = (y * width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    func testUploadWithInconsistentExifKeepsRealPixels() throws {
        let original = injectingInconsistentExif(into: try splitJPEG(width: 300, height: 300))
        let processed = try XCTUnwrap(LibraryArtworkImageProcessor.process(original))
        let image = try decoded(processed)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 300)
        let left = try rgb(image, x: 40, y: 150)
        let right = try rgb(image, x: 260, y: 150)
        XCTAssertGreaterThan(left.0, 200)
        XCTAssertLessThan(left.2, 60)
        XCTAssertLessThan(right.0, 60)
        XCTAssertGreaterThan(right.2, 200)
        XCTAssertLessThan(try rgb(image, x: 40, y: 5).1, try rgb(image, x: 40, y: 295).1 - 150)
    }

    func testStrippedUploadStillAppliesExifOrientation() throws {
        let original = try splitJPEG(width: 300, height: 200, orientation: 6)
        let processed = try XCTUnwrap(LibraryArtworkImageProcessor.process(original))
        let image = try decoded(processed)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 300)

        // 以 ImageIO 自己摆正的结果为准，逐个角落比颜色。
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 300,
        ] as CFDictionary))
        XCTAssertEqual(reference.width, 200)
        for (x, y) in [(20, 20), (180, 20), (20, 280), (180, 280)] {
            let actual = try rgb(image, x: x, y: y)
            let expected = try rgb(reference, x: x, y: y)
            XCTAssertLessThan(abs(actual.0 - expected.0) + abs(actual.1 - expected.1) + abs(actual.2 - expected.2), 60,
                              "corner (\(x),\(y)) \(actual) vs \(expected)")
        }
    }
}

private actor SongGIFWritebackConnector: MusicSourceConnector {
    nonisolated let sourceID = "gif-writeback"
    var cover: Data?
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func writeEmbeddedMetadata(original: Song, updated: Song, coverData: Data?, lyrics: EmbeddedLyricsEdit,
                               writesTextTags: Bool) async throws -> EmbeddedMetadataWritebackResult {
        cover = coverData
        throw SourceFileMutationError.permissionDenied
    }
}
